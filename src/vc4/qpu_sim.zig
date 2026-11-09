//! Functional 16-lane SIMD simulator for the VideoCore IV QPU instruction set.

const std = @import("std");
const vc_bus = @import("../soc/vc_bus.zig");
const qpu = @import("qpu.zig");
const texture = @import("texture.zig");
const pixel = @import("format.zig");

pub const lanes = 16;
pub const Vec = [lanes]u32;
const VecU = @Vector(lanes, u32);
const VecI = @Vector(lanes, i32);
const VecF = @Vector(lanes, f32);
const VecB = @Vector(lanes * 4, u8);
const VecU16 = @Vector(lanes * 4, u16);
const VecBool = @Vector(lanes, bool);

pub fn splat(v: u32) Vec {
    return @splat(v);
}

pub fn splatF(v: f32) Vec {
    return @splat(@bitCast(v));
}

/// A program's uniforms: read in turn, as many as it reads (from guest RAM, so maybe unaligned).
pub const Uniforms = []align(1) const u32;

pub const Env = struct {
    uniforms: Uniforms = &.{},
    vpm_in: []const Vec = &.{},
    varyings: []const Vec = &.{},
    frag_w: Vec = splatF(1.0),
    frag_z: Vec = splat(0),
    frag_x: Vec = splat(0),
    frag_y: Vec = splat(0),
    /// What MS_FLAGS reads (regfile A): the samples each fragment covers; and REV_FLAG
    /// (regfile B): 1 where the primitive faces back.
    ms_mask: Vec = splat(0xf),
    rev_flag: Vec = splat(0),
    /// What an alpha-mask load reads: each fragment's VG mask.
    alpha_mask_in: Vec = splat(0),
    texture_memory: []const u8 = &.{},
    texture_memory1: []const u8 = &.{},
    textures: []const []const u8 = &.{},
    tlb_color_in: Vec = splat(0),
    /// Multisampled: each sample's colour in the tile buffer, which colour loads read in turn
    /// (`tlb_color_in` is then not read).
    tlb_samples_in: ?*const [4]Vec = null,
    tex_cache: ?*[2]TexCache = null,
    /// Where the program is on the bus: what absolute branches and link addresses are relative
    /// to.
    code_addr: u32 = 0,
    /// Memory uniforms are read from after a write to UNIFORMS_ADDRESS (bus addresses, masked).
    uniform_memory: []const u8 = &.{},
    /// The QPU it runs on (QPU_NUMBER), the most instructions it runs, and (for user programs)
    /// the semaphores and mutex it shares with other QPUs, the VPM it reads and writes as
    /// addressed (not as a vertex shader's stream), and the memory its DMA reads and writes.
    qpu_number: u32 = 0,
    max_steps: usize = 1 << 22,
    sync: ?*Sync = null,
    vpm_mem: ?*[vpm_words]u32 = null,
    dma_ram: ?[]u8 = null,
};

/// The VPM: 12 KiB, rows of 16 words.
pub const vpm_words = 192 * 16;

/// What QPUs share: the 16 semaphores, the mutex (the QPU holding it), and the host interrupts
/// raised (a bit a QPU).
pub const Sync = struct {
    sema: [16]u4 = @splat(0),
    mutex: ?u32 = null,
    host_int: u16 = 0,
};

pub const max_vpm_out = 32;

pub const Result = struct {
    vpm_out: [max_vpm_out]Vec = undefined,
    vpm_out_len: usize = 0,
    tlb_color: ?Vec = null,
    tlb_color_samples: [4]Vec = undefined,
    tlb_samples: usize = 0,
    color_loads: usize = 0,
    tlb_z: ?Vec = null,
    uniforms_read: usize = 0,
    varyings_read: usize = 0,
    vpm_words_read: usize = 0,
    texture_samples: usize = 0,
    instructions: usize = 0,

    pub fn vpmOut(r: *const Result) []const Vec {
        return r.vpm_out[0..r.vpm_out_len];
    }
};

pub const FragResult = struct {
    tlb_color: ?Vec = null,
    tlb_z: ?Vec = null,
    /// Multisampled: each sample's colour, as written in turn (to tlb_color_ms).
    tlb_color_samples: [4]Vec = undefined,
    tlb_samples: usize = 0,
    /// A lookup took its level of detail from the differences across its 2x2 quads of
    /// elements (which a fragment shader's must be, for it to be right).
    needs_quads: bool = false,
    /// The elements written (bit n element n): their colour (or each sample's), their Z (a
    /// 24-bit integer), and their MS_FLAGS (the samples they cover, from then on). A fragment
    /// whose colour and Z aren't written is discarded.
    tlb_color_mask: u16 = 0,
    tlb_sample_masks: [4]u16 = @splat(0),
    tlb_z_mask: u16 = 0,
    ms_flags: Vec = splat(0xf),
    ms_flags_mask: u16 = 0,
    /// The TLB_STENCIL_SETUP words written (element 0's), in turn.
    stencil_setups: [3]u32 = @splat(0),
    stencil_count: usize = 0,
    /// The VG mask written (TLB_ALPHA_MASK: bits 7:0), and where.
    alpha_mask: Vec = splat(0),
    alpha_mask_mask: u16 = 0,
};

/// The lanes `cond` holds for.
fn laneBits(cond: qpu.Cond, s: *const State) u16 {
    return @bitCast(condMask(cond, s));
}

/// `old` with the lanes in `mask` from `new`.
fn mergeLanes(old: ?Vec, new: Vec, mask: u16) Vec {
    if (mask == 0xffff) return new;
    const m: VecBool = @bitCast(mask);
    return @select(u32, m, new, old orelse splat(0));
}

/// Depths (32-bit floats, 0 to 1) as the 24-bit integers the fragment's Z payload reads and
/// TLB_Z is written.
pub fn z24Of(z: Vec) Vec {
    const zf: VecF = @bitCast(z);
    const c = @min(@max(zf, @as(VecF, @splat(0))), @as(VecF, @splat(1)));
    const z24: VecU = @intFromFloat(@round(c * @as(VecF, @splat(16777215.0))));
    return z24;
}


pub const Error = error{
    Unsupported,
    UniformUnderflow,
    VaryingUnderflow,
    VpmUnderflow,
    VpmOverflow,
    TmuUnderflow,
    MissingProgramEnd,
    /// It ran longer than any program here would (a branch looping for ever).
    TooLong,
};

const varying_c: f32 = 0.25;

const State = struct {
    ra: [32]Vec = undefined,
    rb: [32]Vec = undefined,
    ra_init: u32 = 0,
    rb_init: u32 = 0,
    /// Indices 0..5 are accumulators r0..r5; index 6 is mux .a; index 7 is mux .b.
    acc: [8]Vec = undefined,
    zero: VecBool = @splat(false),
    neg: VecBool = @splat(false),
    carry: VecBool = @splat(false),
    /// Uniforms read from memory since a write to UNIFORMS_ADDRESS.
    unif_override: ?Uniforms = null,
    vpm_read_left: u32 = 16,
    /// The VPM's generic read and write setups (each access moving them on), and its DMA's: the
    /// load (VDR) and its extended pitch, the store (VDW) and its stride.
    vpm_rd: u32 = 0,
    vpm_wr: u32 = 0,
    vdr: u32 = 0,
    vdr_pitch: u32 = 0,
    vdw: u32 = 0,
    vdw_stride: u32 = 0,
    uniforms_read: usize = 0,
    varyings_read: usize = 0,
    vpm_words_read: usize = 0,
    tmu_param_count: [2]u8 = .{ 0, 0 },
    tmu_has_coord_t: [2]bool = .{ false, false },
    tmu_fifo_head: [2]u2 = .{ 0, 0 },
    tmu_fifo_len: [2]u3 = .{ 0, 0 },
    tmu_params: [2][4]u32 = undefined,
    tmu_coord_t: [2]Vec = undefined,
    /// The r and b coordinates, if written since the last request.
    tmu_coord_r: [2]?Vec = .{ null, null },
    tmu_coord_b: [2]?Vec = .{ null, null },
    tmu_fifo: [2][4]Vec = undefined,
    /// A lookup's second word (RGBA64's blue and alpha), read after its first.
    tmu_fifo_second: [2][4]?Vec = @splat(@splat(null)),
    tmu_cached: [2]TexCache = .{ .{}, .{} },
};

fn f(v: u32) f32 {
    return @bitCast(v);
}

fn u(v: f32) u32 {
    return @bitCast(v);
}

fn isFloatInputAdd(op: qpu.AddOp) bool {
    return switch (op) {
        .fadd, .fsub, .fmin, .fmax, .fminabs, .fmaxabs, .ftoi => true,
        else => false,
    };
}

fn isFloatInputMul(op: qpu.MulOp) bool {
    return op == .fmul;
}

fn unpackVec(v: Vec, mode: u3, float_input: bool) Vec {
    if (mode == 0) return v;
    const vu: VecU = v;
    return switch (mode) {
        0 => unreachable,
        // 16a, 16b: a 16-bit float to a float for a float instruction, else a signed integer.
        1 => blk: {
            if (float_input) break :blk halfToFloat(@truncate(vu));
            const shifted: VecI = @bitCast(vu << @as(@Vector(lanes, u5), @splat(16)));
            break :blk @bitCast(shifted >> @as(@Vector(lanes, u5), @splat(16)));
        },
        2 => blk: {
            if (float_input) break :blk halfToFloat(@truncate(vu >> @as(@Vector(lanes, u5), @splat(16))));
            break :blk @bitCast(@as(VecI, @bitCast(vu)) >> @as(@Vector(lanes, u5), @splat(16)));
        },
        3 => (vu >> @as(@Vector(lanes, u5), @splat(24))) *% @as(VecU, @splat(0x01010101)), // 8d_rep
        4, 5, 6, 7 => blk: {
            const shift: u5 = @as(u5, mode - 4) * 8;
            const bytes: VecU = (vu >> @as(@Vector(lanes, u5), @splat(shift))) & @as(VecU, @splat(0xff));
            if (float_input) {
                const vf: VecF = @floatFromInt(bytes);
                break :blk @bitCast(vf * @as(VecF, @splat(1.0 / 255.0)));
            }
            break :blk bytes;
        },
    };
}

/// 16-bit floats to 32-bit floats' bits.
fn halfToFloat(h: @Vector(lanes, u16)) Vec {
    const hf: @Vector(lanes, f16) = @bitCast(h);
    const vf: VecF = @floatCast(hf);
    return @bitCast(vf);
}

/// 32-bit floats' bits to 16-bit floats, rounded to nearest even (`halfOf`).
fn floatToHalf(v: VecU) @Vector(lanes, u16) {
    var out: @Vector(lanes, u16) = undefined;
    inline for (0..lanes) |i| out[i] = halfOf(v[i]);
    return out;
}

/// A 32-bit float's bits as a 16-bit float, rounded to nearest even, in integer arithmetic (as
/// the GPU translation does it too: its own conversion's rounding isn't defined).
pub fn halfOf(x: u32) u16 {
    const sign: u32 = (x >> 16) & 0x8000;
    const exp: i32 = @as(i32, @intCast((x >> 23) & 0xff)) - 127 + 15;
    const mant: u32 = x & 0x7fffff;
    if ((x >> 23) & 0xff == 0xff) return @intCast(sign | 0x7c00 | (if (mant != 0) @as(u32, 0x200) else 0));
    if (exp >= 31) return @intCast(sign | 0x7c00);
    if (exp <= 0) {
        if (exp < -10) return @intCast(sign);
        const m = mant | 0x800000;
        const shift: u5 = @intCast(14 - exp);
        var h = m >> shift;
        const rem = m & ((@as(u32, 1) << shift) - 1);
        const half = @as(u32, 1) << (shift - 1);
        if (rem > half or (rem == half and h & 1 != 0)) h += 1;
        return @intCast(sign | h);
    }
    var h: u32 = @as(u32, @intCast(exp)) << 10 | mant >> 13;
    const rem = mant & 0x1fff;
    if (rem > 0x1000 or (rem == 0x1000 and h & 1 != 0)) h += 1;
    return @intCast(sign | h);
}

/// The SFU's functions as FauxPi computes them: in float adds and multiplies (each rounded on
/// its own), so its GPU translation gets the same bits. Denormal inputs count as 0, as GPUs
/// flush them.
fn bitsOf(x: f32) u32 {
    return @bitCast(x);
}

pub fn sfuRsqrt(x: f32) f32 {
    if (std.math.isNan(x) or x < 0) return std.math.nan(f32);
    if (std.math.isInf(x)) return 0;
    if (bitsOf(x) & 0x7f800000 == 0) return std.math.inf(f32);
    var y: f32 = @bitCast(@as(u32, 0x5f3759df) - (bitsOf(x) >> 1));
    const hx = x * 0.5;
    for (0..4) |_| {
        var t = hx * y;
        t = t * y;
        t = 1.5 - t;
        y = y * t;
    }
    return y;
}

/// 2^f's polynomial for f in [0, 1): ln 2^k / k!, highest first.
pub const exp2_coeffs = [_]f32{ 1.5252734e-5, 1.5403530e-4, 1.3333558e-3, 9.6181291e-3, 5.5504109e-2, 2.4022651e-1, 6.9314718e-1, 1.0 };

pub fn sfuExp2(x: f32) f32 {
    if (std.math.isNan(x)) return x;
    if (x >= 128) return std.math.inf(f32);
    if (x <= -150) return 0;
    const i = @floor(x);
    const fr = x - i;
    var p: f32 = exp2_coeffs[0];
    for (exp2_coeffs[1..]) |c| {
        p = p * fr;
        p = p + c;
    }
    const n: i32 = @intFromFloat(i);
    if (n >= -126) return p * @as(f32, @bitCast(@as(u32, @intCast(n + 127)) << 23));
    const tiny: f32 = @bitCast(@as(u32, 1) << 23);
    return (p * tiny) * @as(f32, @bitCast(@as(u32, @intCast(n + 126 + 127)) << 23));
}

/// log2(1 + y)'s polynomial for y in [-0.3, 0.42]: (-1)^(k+1) / (k ln 2), highest first.
pub const log2_coeffs = blk: {
    var c: [16]f32 = undefined;
    for (0..16) |j| {
        const k: f64 = @floatFromInt(16 - j);
        const sign: f64 = if ((16 - j) % 2 == 1) 1 else -1;
        c[j] = @floatCast(sign / (k * std.math.ln2));
    }
    break :blk c;
};

pub fn sfuLog2(x: f32) f32 {
    if (std.math.isNan(x) or x < 0) return std.math.nan(f32);
    if (std.math.isInf(x)) return x;
    if (bitsOf(x) & 0x7f800000 == 0) return -std.math.inf(f32);
    var e: i32 = @as(i32, @intCast((bitsOf(x) >> 23) & 0xff)) - 127;
    var m: f32 = @bitCast(bitsOf(x) & 0x7fffff | 0x3f800000);
    if (m > 1.41421356) {
        m = m * 0.5;
        e += 1;
    }
    const y = m - 1;
    var p: f32 = log2_coeffs[0];
    for (log2_coeffs[1..]) |c| {
        p = p * y;
        p = p + c;
    }
    p = p * y;
    return @as(f32, @floatFromInt(e)) + p;
}

/// The add or sub result `a op b` saturated to a signed 32-bit integer (the 32-bit saturating
/// pack), from the operation's overflow.
fn saturate32(op: qpu.AddOp, a: Vec, b: Vec) Vec {
    const ai: @Vector(lanes, i64) = @as(VecI, @bitCast(a));
    const bi: @Vector(lanes, i64) = @as(VecI, @bitCast(b));
    const wide = if (op == .sub) ai - bi else ai + bi;
    const clamped = @min(@max(wide, @as(@Vector(lanes, i64), @splat(std.math.minInt(i32)))), @as(@Vector(lanes, i64), @splat(std.math.maxInt(i32))));
    return @bitCast(@as(VecI, @intCast(clamped)));
}

/// The carry flags of `op` on `a`, `b`: an integer add's carry out, a subtraction's borrow.
fn carryOf(op: qpu.AddOp, a: Vec, b: Vec) VecBool {
    const av: VecU = a;
    const bv: VecU = b;
    return switch (op) {
        .add => (av +% bv) < av,
        .sub => av < bv,
        else => @splat(false),
    };
}

/// `v` rotated up by `n` elements (element 0 to element n).
fn rotateVec(v: Vec, n: u4) Vec {
    if (n == 0) return v;
    var out: Vec = undefined;
    for (0..lanes) |i| out[(i + n) & 15] = v[i];
    return out;
}

inline fn ftoiVec(af: VecF) Vec {
    const non_nan = @select(f32, af == af, af, @as(VecF, @splat(0.0)));
    const clamped = @min(@max(non_nan, @as(VecF, @splat(-2147483648.0))), @as(VecF, @splat(2147483520.0)));
    const vi: VecI = @intFromFloat(clamped);
    return @bitCast(vi);
}

inline fn v8muldVec(au: VecU, bu: VecU) Vec {
    const ab: VecB = @bitCast(au);
    const bb: VecB = @bitCast(bu);
    const prod: VecU16 = @as(VecU16, ab) * @as(VecU16, bb) + @as(VecU16, @splat(127));
    const div255: VecU16 = (prod + @as(VecU16, @splat(1)) + (prod >> @as(@Vector(lanes * 4, u4), @splat(8)))) >> @as(@Vector(lanes * 4, u4), @splat(8));
    const res_b: VecB = @truncate(div255);
    return @bitCast(res_b);
}

fn addOpVec(op: qpu.AddOp, a: Vec, b: Vec) Vec {
    const au: VecU = a;
    const bu: VecU = b;
    const ai: VecI = @bitCast(au);
    const bi: VecI = @bitCast(bu);
    const af: VecF = @bitCast(au);
    const bf: VecF = @bitCast(bu);
    return switch (op) {
        .nop => splat(0),
        .fadd => @bitCast(af + bf),
        .fsub => @bitCast(af - bf),
        .fmin => @bitCast(@min(af, bf)),
        .fmax => @bitCast(@max(af, bf)),
        .fminabs => @bitCast(@min(@abs(af), @abs(bf))),
        .fmaxabs => @bitCast(@max(@abs(af), @abs(bf))),
        .ftoi => ftoiVec(af),
        .itof => blk: {
            const vf: VecF = @floatFromInt(ai);
            break :blk @bitCast(vf);
        },
        .add => au +% bu,
        .sub => au -% bu,
        .shr => au >> @as(@Vector(lanes, u5), @truncate(bu)),
        .asr => @bitCast(ai >> @as(@Vector(lanes, u5), @truncate(bu))),
        .ror => blk: {
            const sh: @Vector(lanes, u5) = @truncate(bu);
            const neg_sh: @Vector(lanes, u5) = @as(@Vector(lanes, u5), @splat(0)) -% sh;
            break :blk (au >> sh) | (au << neg_sh);
        },
        .shl => au << @as(@Vector(lanes, u5), @truncate(bu)),
        .min => @bitCast(@min(ai, bi)),
        .max => @bitCast(@max(ai, bi)),
        .@"and" => au & bu,
        .@"or" => au | bu,
        .xor => au ^ bu,
        .not => ~au,
        .clz => @clz(au),
        .v8adds => @bitCast(@as(VecB, @bitCast(au)) +| @as(VecB, @bitCast(bu))),
        .v8subs => @bitCast(@as(VecB, @bitCast(au)) -| @as(VecB, @bitCast(bu))),
        else => splat(0),
    };
}

fn mulOpVec(op: qpu.MulOp, a: Vec, b: Vec) Vec {
    const au: VecU = a;
    const bu: VecU = b;
    const af: VecF = @bitCast(au);
    const bf: VecF = @bitCast(bu);
    return switch (op) {
        .nop => splat(0),
        .fmul => @bitCast(af * bf),
        .mul24 => (au & @as(VecU, @splat(0xffffff))) *% (bu & @as(VecU, @splat(0xffffff))),
        .v8muld => v8muldVec(au, bu),
        .v8min => @bitCast(@min(@as(VecB, @bitCast(au)), @as(VecB, @bitCast(bu)))),
        .v8max => @bitCast(@max(@as(VecB, @bitCast(au)), @as(VecB, @bitCast(bu)))),
        .v8adds => @bitCast(@as(VecB, @bitCast(au)) +| @as(VecB, @bitCast(bu))),
        .v8subs => @bitCast(@as(VecB, @bitCast(au)) -| @as(VecB, @bitCast(bu))),
    };
}

pub fn smallImm(v: u6) u32 {
    return switch (v) {
        0...15 => v,
        16...31 => @bitCast(@as(i32, v) - 32),
        32...39 => @as(u32, (@as(u32, 127) + @as(u32, v - 32)) << 23),
        40...47 => @as(u32, (@as(u32, 127) - @as(u32, 48 - v)) << 23),
        else => 0,
    };
}

fn unorm8(x: f32) u8 {
    const c = std.math.clamp(x, 0.0, 1.0);
    return @intFromFloat(@round(c * 255.0));
}

inline fn unorm8Vec(v: VecU) VecU {
    const vf: VecF = @bitCast(v);
    const non_nan = @select(f32, vf == vf, vf, @as(VecF, @splat(0.0)));
    const clamped = @min(@max(non_nan, @as(VecF, @splat(0.0))), @as(VecF, @splat(1.0)));
    const scaled = @round(clamped * @as(VecF, @splat(255.0)));
    return @intFromFloat(scaled);
}

inline fn condMask(cond: qpu.Cond, s: *const State) VecBool {
    return switch (cond) {
        .never => @splat(false),
        .always => @splat(true),
        .zs => s.zero,
        .zc => !s.zero,
        .ns => s.neg,
        .nc => !s.neg,
        .cs => s.carry,
        .cc => !s.carry,
    };
}

inline fn packVec(dv: VecU, vv: VecU, a_pack: u4, mul_pack: u4, float_result: bool) VecU {
    if (a_pack == 0) {
        return switch (mul_pack) {
            0 => vv,
            3 => unorm8Vec(vv) *% @as(VecU, @splat(0x01010101)),
            4, 5, 6, 7 => blk: {
                const shift: u5 = @as(u5, @intCast(mul_pack - 4)) * 8;
                const mask: VecU = @splat(@as(u32, 0xff) << shift);
                break :blk (dv & ~mask) | (unorm8Vec(vv) << @as(@Vector(lanes, u5), @splat(shift)));
            },
            else => vv,
        };
    }
    // A half: a 16-bit float of a float result, else the integer's low 16 bits (saturated to a
    // signed 16-bit integer for 9 and 10).
    const half: VecU = if (float_result) floatToHalf(vv) else if (a_pack >= 8) blk: {
        const vi: VecI = @bitCast(vv);
        const c = @min(@max(vi, @as(VecI, @splat(-32768))), @as(VecI, @splat(32767)));
        break :blk @as(VecU, @bitCast(c)) & @as(VecU, @splat(0xffff));
    } else vv & @as(VecU, @splat(0xffff));
    // A byte: the low 8 bits, or (11 to 15) saturated to 0 to 255.
    const byte: VecU = if (a_pack >= 8) blk: {
        const vi: VecI = @bitCast(vv);
        const c: VecI = @min(@max(vi, @as(VecI, @splat(0))), @as(VecI, @splat(255)));
        break :blk @bitCast(c);
    } else vv & @as(VecU, @splat(0xff));
    return switch (a_pack) {
        1, 9 => (dv & @as(VecU, @splat(0xffff0000))) | half,
        2, 10 => (dv & @as(VecU, @splat(0x0000ffff))) | (half << @as(@Vector(lanes, u5), @splat(16))),
        3, 11 => byte *% @as(VecU, @splat(0x01010101)),
        4, 5, 6, 7, 12, 13, 14, 15 => blk: {
            const shift: u5 = @as(u5, @intCast((a_pack & 7) - 4)) * 8;
            const mask: VecU = @splat(@as(u32, 0xff) << shift);
            break :blk (dv & ~mask) | (byte << @as(@Vector(lanes, u5), @splat(shift)));
        },
        else => vv,
    };
}

pub const File = enum(u1) { a = 0, b = 1 };

pub const DecodedInst = struct {
    imm_or_small: u32 = 0,
    sig: qpu.Sig = .none,
    add_op: qpu.AddOp = .nop,
    mul_op: qpu.MulOp = .nop,
    raddr_a: u6 = qpu.R.nop,
    raddr_b: u6 = qpu.R.nop,
    waddr_add: u6 = qpu.W.nop,
    waddr_mul: u6 = qpu.W.nop,
    cond_add: qpu.Cond = .never,
    cond_mul: qpu.Cond = .never,
    add_file: File = .a,
    mul_file: File = .b,
    mux0: qpu.Mux = .r0,
    mux1: qpu.Mux = .r0,
    mux2: qpu.Mux = .r0,
    mux3: qpu.Mux = .r0,
    unpack_r4: u3 = 0,
    unpack_a: u3 = 0,
    add_pack_a: u4 = 0,
    mul_pack_a: u4 = 0,
    mul_pack_m: u4 = 0,
    flags: u8 = 0,
    /// The mul output's rotation (small immediates 48 to 63): 0 none, 1 to 15, or 16 by r5.
    rotate: u5 = 0,
    /// A load immediate's kind (bits 59:57): 0 32-bit, 1 signed 2-bit per element, 3 unsigned,
    /// 4 a semaphore.
    limm_mode: u3 = 0,
    /// A branch's condition, whether relative, the regfile A register added (if any).
    branch_cond: u4 = 0,
    branch_rel: bool = false,
    branch_reg: ?u5 = null,

    pub const FLAG_SF: u8 = 1 << 0;
    pub const FLAG_READS_VARY: u8 = 1 << 1;
    pub const FLAG_FETCH_A: u8 = 1 << 2;
    pub const FLAG_FETCH_B: u8 = 1 << 3;
    pub const FLAG_FLT_ADD: u8 = 1 << 4;
    pub const FLAG_FLT_MUL: u8 = 1 << 5;
    pub const FLAG_HAS_UNPACK: u8 = 1 << 6;
    pub const FLAG_FUSED_LINTERP: u8 = 1 << 7;
};

pub fn decodeInst(inst: qpu.Inst) DecodedInst {
    const sig = qpu.getSig(inst);
    if (sig == .branch) {
        const reg = (inst >> 50) & 1 != 0;
        const ws_b = qpu.getWs(inst);
        return .{
            .sig = .branch,
            .imm_or_small = @truncate(inst),
            .branch_cond = @truncate(inst >> 52),
            .branch_rel = (inst >> 51) & 1 != 0,
            .branch_reg = if (reg) @truncate(inst >> 45) else null,
            .waddr_add = qpu.getWaddrAdd(inst),
            .waddr_mul = qpu.getWaddrMul(inst),
            .cond_add = .always,
            .cond_mul = .always,
            .add_file = if (ws_b) .b else .a,
            .mul_file = if (ws_b) .a else .b,
        };
    }

    const ws = qpu.getWs(inst);
    const cond_add: qpu.Cond = @fromBackingInt(@intCast(@as(u3, @truncate(inst >> 49))));
    const cond_mul: qpu.Cond = @fromBackingInt(@intCast(@as(u3, @truncate(inst >> 46))));
    const pm = (inst >> 56) & 1 != 0;
    const pack: u4 = @truncate(inst >> 52);
    const unpack_mode: u3 = @truncate(inst >> 57);
    const add_op: qpu.AddOp = if (sig == .load_imm) .nop else qpu.getAddOp(inst);
    const mul_op: qpu.MulOp = if (sig == .load_imm) .nop else qpu.getMulOp(inst);
    const raddr_a = qpu.getRaddrA(inst);
    const raddr_b = qpu.getRaddrB(inst);
    const mux0: qpu.Mux = @fromBackingInt(@intCast(@as(u3, @truncate(inst >> 9))));
    const mux1: qpu.Mux = @fromBackingInt(@intCast(@as(u3, @truncate(inst >> 6))));
    const mux2: qpu.Mux = @fromBackingInt(@intCast(@as(u3, @truncate(inst >> 3))));
    const mux3: qpu.Mux = @fromBackingInt(@intCast(@as(u3, @truncate(inst))));

    const uses_a = (add_op != .nop and (mux0 == .a or mux1 == .a)) or
        (mul_op != .nop and (mux2 == .a or mux3 == .a));
    const uses_b = (add_op != .nop and (mux0 == .b or mux1 == .b)) or
        (mul_op != .nop and (mux2 == .b or mux3 == .b));

    const waddr_add_raw = qpu.getWaddrAdd(inst);
    const waddr_mul_raw = qpu.getWaddrMul(inst);
    const a_pack: u4 = if (!pm) pack else 0;
    const mul_pack: u4 = if (pm) pack else 0;
    const unpack_r4: u3 = if (pm and sig != .load_imm) unpack_mode else 0;
    const unpack_a: u3 = if (!pm and raddr_a < 32 and sig != .load_imm) unpack_mode else 0;

    var flags: u8 = 0;
    if ((inst & (1 << 45)) != 0) flags |= DecodedInst.FLAG_SF;
    if ((uses_a and raddr_a == qpu.R.vary) or (sig != .small_imm and uses_b and raddr_b == qpu.R.vary)) {
        flags |= DecodedInst.FLAG_READS_VARY;
    }
    if (uses_a) flags |= DecodedInst.FLAG_FETCH_A;
    if (sig != .small_imm and uses_b) flags |= DecodedInst.FLAG_FETCH_B;
    if (isFloatInputAdd(add_op)) flags |= DecodedInst.FLAG_FLT_ADD;
    if (isFloatInputMul(mul_op)) flags |= DecodedInst.FLAG_FLT_MUL;
    if (unpack_r4 != 0 or unpack_a != 0) flags |= DecodedInst.FLAG_HAS_UNPACK;

    const limm_mode: u3 = if (sig == .load_imm) @truncate(inst >> 57) else 0;
    return .{
        .imm_or_small = if (sig == .load_imm)
            @truncate(inst)
        else if (sig == .small_imm)
            smallImm(raddr_b)
        else
            0,
        .rotate = if (sig == .small_imm and raddr_b >= 48) @intCast(if (raddr_b == 48) 16 else raddr_b - 48) else 0,
        .limm_mode = limm_mode,
        .sig = sig,
        .add_op = add_op,
        .mul_op = mul_op,
        .raddr_a = raddr_a,
        .raddr_b = raddr_b,
        .waddr_add = if (cond_add != .never) waddr_add_raw else qpu.W.nop,
        .waddr_mul = if (cond_mul != .never) waddr_mul_raw else qpu.W.nop,
        .cond_add = cond_add,
        .cond_mul = cond_mul,
        .add_file = if (ws) .b else .a,
        .mul_file = if (ws) .a else .b,
        .mux0 = mux0,
        .mux1 = mux1,
        .mux2 = mux2,
        .mux3 = mux3,
        .unpack_r4 = unpack_r4,
        .unpack_a = unpack_a,
        .add_pack_a = if (!ws) a_pack else 0,
        .mul_pack_a = if (ws) a_pack else 0,
        .mul_pack_m = mul_pack,
        .flags = flags,
    };
}

pub fn decodeProgram(code: []const qpu.Inst, out_buf: []DecodedInst) []const DecodedInst {
    const len = @min(code.len, out_buf.len);
    for (0..len) |i| {
        out_buf[i] = decodeInst(code[i]);
    }
    // Fuse canonical varying linear interpolation pairs:
    //   inst[i]:     fmul r_acc, vary, ra15 (frag_w)
    //   inst[i + 1]: fadd dst, r_acc, r5
    var end_limit: usize = len;
    var i: usize = 0;
    while (i + 1 < end_limit) : (i += 1) {
        const d0 = out_buf[i];
        if (d0.sig == .prog_end or d0.sig == .color_load_end) {
            end_limit = @min(len, i + 3);
        }
        if (i + 1 >= end_limit) break;
        const d1 = out_buf[i + 1];
        if (d0.sig == .none and d1.sig == .none and
            d0.add_op == .nop and d0.waddr_add == qpu.W.nop and
            d0.mul_op == .fmul and d0.cond_mul == .always and
            d0.mul_pack_a == 0 and d0.mul_pack_m == 0 and
            (d0.flags & (DecodedInst.FLAG_HAS_UNPACK | DecodedInst.FLAG_SF)) == 0 and
            d0.waddr_mul >= qpu.W.acc0 and d0.waddr_mul <= qpu.W.acc0 + 3 and
            ((d0.mux2 == .a and d0.mux3 == .b) or (d0.mux2 == .b and d0.mux3 == .a)) and
            d0.raddr_a == qpu.R.frag_payload_zw and d0.raddr_b == qpu.R.vary and
            d1.mul_op == .nop and d1.waddr_mul == qpu.W.nop and
            d1.add_op == .fadd and d1.cond_add == .always and d1.add_pack_a == 0 and
            (d1.flags & (DecodedInst.FLAG_HAS_UNPACK | DecodedInst.FLAG_SF)) == 0)
        {
            const acc_mux: qpu.Mux = @fromBackingInt(@intCast(d0.waddr_mul - qpu.W.acc0));
            if ((d1.mux0 == acc_mux and d1.mux1 == .r5) or (d1.mux0 == .r5 and d1.mux1 == acc_mux)) {
                out_buf[i].flags |= DecodedInst.FLAG_FUSED_LINTERP;
                out_buf[i].waddr_add = d1.waddr_add;
                out_buf[i].add_file = d1.add_file;
                i += 1;
            }
        }
    }
    return out_buf[0..len];
}

pub const FastFragKind = enum(u8) {
    none,
    constant_color,
    varying_pack_rgba,
    tmu0_blit,
};

pub const FastFragShader = struct {
    kind: FastFragKind = .none,
    color: u32 = 0,
    var_idx: [4]u8 = .{ 0xff, 0xff, 0xff, 0xff },
    tmu_p0_unif: u8 = 0,
    tmu_p1_unif: u8 = 1,
    tmu_modulate: bool = false,
    /// Its texture lookups take their level of detail from 2x2 quads of pixels: it must be
    /// given its pixels in quads (`v3d`'s quad path), not as they come.
    quads: bool = false,
};

const Tmu0SampleInfo = struct {
    s_var: u8,
    t_var: u8,
    p0_unif: u8,
    p1_unif: u8,
};

const PackedRgbaInfo = struct {
    /// Each byte's varying, 0xff if it is `const_rgba`'s, or `unknown_byte` if it isn't known (what
    /// the register held before bytes were packed into it).
    var_idx: [4]u8,
    const_rgba: u32,

    const unknown_byte = 0xfe;

    fn complete(p: PackedRgbaInfo) bool {
        return std.mem.indexOfScalar(u8, &p.var_idx, unknown_byte) == null;
    }
};

const SymVal = union(enum) {
    unknown,
    constant: u32,
    varying: u8,
    packed_rgba: PackedRgbaInfo,
    tmu0_texel: Tmu0SampleInfo,
    tmu0_modulated: struct {
        s_var: u8,
        t_var: u8,
        p0_unif: u8,
        p1_unif: u8,
        color: u32,
    },
};

pub fn analyzeFragmentShader(decoded: []const DecodedInst, uniforms: Uniforms) FastFragShader {
    var fast = analyzeFragmentShaderKind(decoded, uniforms);
    fast.quads = tlbUse(decoded).any() or needsQuads(decoded, uniforms);
    return fast;
}

/// What a fragment shader does with the TLB besides writing every fragment's colour (and its
/// Z as the rasterizer gives it): what the quad path is for.
pub const TlbUse = struct {
    /// Writes TLB_STENCIL_SETUP: the stencil test.
    stencil: bool = false,
    /// Writes MS_FLAGS: the samples drawn.
    ms_flags: bool = false,
    /// Writes TLB_Z other than the Z payload as it is.
    shader_z: bool = false,
    /// Writes its colour, or Z, to some fragments (discarding the rest).
    conditional: bool = false,
    /// Reads MS_FLAGS or REV_FLAG.
    reads_flags: bool = false,
    /// Reads or writes the VG mask.
    vg_mask: bool = false,

    pub fn any(t: TlbUse) bool {
        return t.stencil or t.ms_flags or t.shader_z or t.conditional or t.reads_flags or t.vg_mask;
    }
};

pub fn tlbUse(decoded: []const DecodedInst) TlbUse {
    var t: TlbUse = .{};
    for (decoded) |d| {
        if (d.sig == .branch) continue;
        if (d.sig == .alpha_mask_load) t.vg_mask = true;
        if (d.raddr_a == qpu.R.ms_rev_flags or (d.raddr_b == qpu.R.ms_rev_flags and d.sig != .small_imm and d.sig != .load_imm)) {
            if (d.sig != .load_imm) t.reads_flags = true;
        }
        if (d.sig == .load_imm) {
            // Its value to both outputs: as a write of a constant.
            for ([2]u6{ d.waddr_add, d.waddr_mul }, [2]qpu.Cond{ d.cond_add, d.cond_mul }) |wa, cond| tlbWrite(&t, wa, cond, false);
            continue;
        }
        tlbWrite(&t, d.waddr_add, d.cond_add, d.add_op == .@"or" and d.mux0 == .b and d.mux1 == .b and d.raddr_b == qpu.R.frag_payload_zw and d.sig != .small_imm and d.add_pack_a == 0);
        tlbWrite(&t, d.waddr_mul, d.cond_mul, d.mul_op == .v8min and d.mux2 == .b and d.mux3 == .b and d.raddr_b == qpu.R.frag_payload_zw and d.sig != .small_imm and d.mul_pack_a == 0 and d.mul_pack_m == 0);
    }
    return t;
}

fn tlbWrite(t: *TlbUse, waddr: u6, cond: qpu.Cond, z_payload: bool) void {
    if (cond == .never) return;
    switch (waddr) {
        qpu.W.tlb_stencil_setup => t.stencil = true,
        qpu.W.ms_flags => t.ms_flags = true,
        qpu.W.tlb_alpha_mask => t.vg_mask = true,
        qpu.W.tlb_z => {
            if (!z_payload) t.shader_z = true;
            if (cond != .always) t.conditional = true;
        },
        qpu.W.tlb_color_all, qpu.W.tlb_color_ms => if (cond != .always) {
            t.conditional = true;
        },
        else => {},
    }
}

/// Whether a fragment shader's texture lookups take their level of detail from 2x2 quads: those
/// with lookups run once (their textures' configs are the uniforms', whatever the inputs), to
/// see (if it can't be, as if they did).
fn needsQuads(decoded: []const DecodedInst, uniforms: Uniforms) bool {
    var looks_up = false;
    for (decoded) |d| {
        for ([2]u6{ d.waddr_add, d.waddr_mul }) |wa| {
            if (wa >= qpu.W.tmu0_s and wa <= qpu.W.tmu1_b) looks_up = true;
        }
    }
    if (!looks_up) return false;
    const zeros: [64]Vec = @splat(splat(0));
    const res = runFragmentDecoded(decoded, &.{ .uniforms = uniforms, .varyings = &zeros }) catch return true;
    return res.needs_quads;
}

fn analyzeFragmentShaderKind(decoded: []const DecodedInst, uniforms: Uniforms) FastFragShader {
    if (decoded.len == 0) return .{};

    var reads_vary = false;
    var reads_other_per_pixel = false;
    var uses_tmu0 = false;
    var can_use_sym = true;

    var ra_sym: [32]SymVal = @splat(.{ .constant = 0 });
    var rb_sym: [32]SymVal = @splat(.{ .constant = 0 });
    var acc_sym: [8]SymVal = @splat(.{ .constant = 0 });
    var sym_unifs_read: usize = 0;
    var sym_varyings_read: u8 = 0;

    var tmu0_has_t = false;
    var tmu0_t_var: u8 = 0xff;
    var tmu0_p0_unif: u8 = 0;
    var tmu0_pending: ?Tmu0SampleInfo = null;
    var tmu0_loads: usize = 0;

    var tlb_sym: SymVal = .unknown;
    var tlb_writes: usize = 0;
    var end_at: ?usize = null;

    const writeSym = struct {
        fn apply(
            waddr: u6,
            file: File,
            val: SymVal,
            cond: qpu.Cond,
            a_pack: u4,
            mul_pack: u4,
            ra: *[32]SymVal,
            rb: *[32]SymVal,
            acc: *[8]SymVal,
            unifs_read: *usize,
            has_t: *bool,
            t_var: *u8,
            p0_unif: *u8,
            pending: *?Tmu0SampleInfo,
            tlb_out: *SymVal,
            tlb_cnt: *usize,
            sym_ok: *bool,
        ) void {
            if (waddr == qpu.W.nop or cond == .never) return;
            if (cond != .always) {
                sym_ok.* = false;
                return;
            }
            const dst_ptr: ?*SymVal = switch (waddr) {
                0...31 => if (file == .a) &ra[waddr] else &rb[waddr],
                qpu.W.acc0...qpu.W.acc0 + 3 => &acc[waddr - qpu.W.acc0],
                qpu.W.acc5 => &acc[5],
                else => null,
            };
            if (dst_ptr) |dst| {
                if (a_pack == 0 and mul_pack == 0) {
                    dst.* = val;
                    return;
                }
                if (a_pack == 0 and mul_pack >= 4 and mul_pack <= 7) {
                    const byte_lane: u2 = @intCast(mul_pack - 4);
                    const shift: u5 = @as(u5, byte_lane) * 8;
                    var cur_pack: PackedRgbaInfo = switch (dst.*) {
                        .constant => |c| .{ .var_idx = [4]u8{ 0xff, 0xff, 0xff, 0xff }, .const_rgba = c },
                        .packed_rgba => |p| p,
                        .unknown => .{ .var_idx = @splat(PackedRgbaInfo.unknown_byte), .const_rgba = 0 },
                        else => {
                            dst.* = .unknown;
                            return;
                        },
                    };
                    switch (val) {
                        .varying => |vi| {
                            cur_pack.var_idx[byte_lane] = vi;
                            cur_pack.const_rgba &= ~(@as(u32, 0xff) << shift);
                            dst.* = .{ .packed_rgba = cur_pack };
                        },
                        .constant => |c| {
                            const b_val: u32 = unorm8(@bitCast(c));
                            cur_pack.var_idx[byte_lane] = 0xff;
                            cur_pack.const_rgba = (cur_pack.const_rgba & ~(@as(u32, 0xff) << shift)) | (b_val << shift);
                            if (cur_pack.var_idx[0] == 0xff and cur_pack.var_idx[1] == 0xff and
                                cur_pack.var_idx[2] == 0xff and cur_pack.var_idx[3] == 0xff)
                            {
                                dst.* = .{ .constant = cur_pack.const_rgba };
                            } else {
                                dst.* = .{ .packed_rgba = cur_pack };
                            }
                        },
                        else => dst.* = .unknown,
                    }
                    return;
                }
                if (mul_pack == 0 and ((a_pack >= 4 and a_pack <= 7) or (a_pack >= 12 and a_pack <= 15))) {
                    const byte_lane: u2 = @intCast((a_pack & 7) - 4);
                    const shift: u5 = @as(u5, byte_lane) * 8;
                    if (val == .constant) {
                        const b_val: u32 = val.constant & 0xff;
                        var cur_pack: PackedRgbaInfo = switch (dst.*) {
                            .constant => |c| .{ .var_idx = [4]u8{ 0xff, 0xff, 0xff, 0xff }, .const_rgba = c },
                            .packed_rgba => |p| p,
                            .unknown => .{ .var_idx = @splat(PackedRgbaInfo.unknown_byte), .const_rgba = 0 },
                            else => {
                                dst.* = .unknown;
                                return;
                            },
                        };
                        cur_pack.var_idx[byte_lane] = 0xff;
                        cur_pack.const_rgba = (cur_pack.const_rgba & ~(@as(u32, 0xff) << shift)) | (b_val << shift);
                        if (cur_pack.var_idx[0] == 0xff and cur_pack.var_idx[1] == 0xff and
                            cur_pack.var_idx[2] == 0xff and cur_pack.var_idx[3] == 0xff)
                        {
                            dst.* = .{ .constant = cur_pack.const_rgba };
                        } else {
                            dst.* = .{ .packed_rgba = cur_pack };
                        }
                        return;
                    }
                }
                dst.* = .unknown;
                return;
            }

            switch (waddr) {
                qpu.W.tlb_color_all => {
                    tlb_out.* = val;
                    tlb_cnt.* += 1;
                },
                qpu.W.tmu0_t => {
                    if (unifs_read.* < 255) {
                        p0_unif.* = @intCast(unifs_read.*);
                        unifs_read.* += 1;
                        if (val == .varying) {
                            t_var.* = val.varying;
                            has_t.* = true;
                        } else {
                            sym_ok.* = false;
                        }
                    } else {
                        sym_ok.* = false;
                    }
                },
                qpu.W.tmu0_s => {
                    if (unifs_read.* < 255 and has_t.* and val == .varying and pending.* == null) {
                        const p1_u: u8 = @intCast(unifs_read.*);
                        unifs_read.* += 1;
                        pending.* = .{
                            .s_var = val.varying,
                            .t_var = t_var.*,
                            .p0_unif = p0_unif.*,
                            .p1_unif = p1_u,
                        };
                        has_t.* = false;
                    } else {
                        sym_ok.* = false;
                    }
                },
                else => {
                    sym_ok.* = false;
                },
            }
        }
    }.apply;

    var ip: usize = 0;
    while (ip < decoded.len) : (ip += 1) {
        if (end_at) |e| if (ip > e) break;
        const d = decoded[ip];

        switch (d.sig) {
            .branch, .color_load, .color_load_end, .load_tmu1, .coverage_load, .alpha_mask_load => return .{},
            .load_tmu0 => uses_tmu0 = true,
            else => {},
        }
        if (d.waddr_add == qpu.W.tlb_z or d.waddr_mul == qpu.W.tlb_z or
            d.waddr_add == qpu.W.tlb_color_ms or d.waddr_mul == qpu.W.tlb_color_ms or
            d.waddr_add == qpu.W.tlb_stencil_setup or d.waddr_mul == qpu.W.tlb_stencil_setup or
            d.waddr_add == qpu.W.tlb_alpha_mask or d.waddr_mul == qpu.W.tlb_alpha_mask or
            d.waddr_add >= qpu.W.tmu1_s or d.waddr_mul >= qpu.W.tmu1_s)
        {
            return .{};
        }
        if (d.waddr_add >= qpu.W.tmu0_s or d.waddr_mul >= qpu.W.tmu0_s) {
            uses_tmu0 = true;
        }
        if ((d.flags & DecodedInst.FLAG_SF) != 0 or d.rotate != 0 or d.limm_mode != 0 or
            d.waddr_add == qpu.W.acc5 or d.waddr_mul == qpu.W.acc5 or d.waddr_add == qpu.W.uniforms_address)
        {
            can_use_sym = false;
        }

        if ((d.flags & DecodedInst.FLAG_FUSED_LINTERP) != 0) {
            reads_vary = true;
            const v_idx = sym_varyings_read;
            sym_varyings_read +|= 1;
            acc_sym[5] = .{ .constant = @bitCast(varying_c) };
            acc_sym[d.waddr_mul - qpu.W.acc0] = .unknown;
            writeSym(
                d.waddr_add,
                d.add_file,
                .{ .varying = v_idx },
                .always,
                0,
                0,
                &ra_sym,
                &rb_sym,
                &acc_sym,
                &sym_unifs_read,
                &tmu0_has_t,
                &tmu0_t_var,
                &tmu0_p0_unif,
                &tmu0_pending,
                &tlb_sym,
                &tlb_writes,
                &can_use_sym,
            );
            ip += 1;
            continue;
        }

        // A varying read on its own, not fused with its add of C (as one whose value is dropped
        // may be): what it reads isn't followed, but the next read is of the next varying, and r5
        // then holds C.
        const vary_alone = (d.flags & DecodedInst.FLAG_READS_VARY) != 0;
        if (vary_alone) {
            reads_vary = true;
            sym_varyings_read +|= 1;
            const reads_a = (d.flags & DecodedInst.FLAG_FETCH_A) != 0 and d.raddr_a == qpu.R.vary;
            const reads_b = (d.flags & DecodedInst.FLAG_FETCH_B) != 0 and d.raddr_b == qpu.R.vary and d.sig != .small_imm;
            if (reads_a and reads_b) can_use_sym = false;
        }
        // W, read to scale a varying read on its own (into what isn't followed), is no other input.
        const reads_w_for_vary = vary_alone and d.raddr_a == qpu.R.frag_payload_zw;
        if ((d.flags & DecodedInst.FLAG_FETCH_A) != 0 and !reads_w_for_vary) {
            switch (d.raddr_a) {
                qpu.R.frag_payload_zw, qpu.R.xy_pixel_coord, qpu.R.elem_qpu, qpu.R.ms_rev_flags, qpu.R.vpm => {
                    reads_other_per_pixel = true;
                    can_use_sym = false;
                },
                else => {},
            }
        }
        if ((d.flags & DecodedInst.FLAG_FETCH_B) != 0) {
            switch (d.raddr_b) {
                qpu.R.frag_payload_zw, qpu.R.xy_pixel_coord, qpu.R.elem_qpu, qpu.R.ms_rev_flags, qpu.R.vpm => {
                    reads_other_per_pixel = true;
                    can_use_sym = false;
                },
                else => {},
            }
        }

        if (can_use_sym) {
            var add_sym: SymVal = .{ .constant = 0 };
            var mul_sym: SymVal = .{ .constant = 0 };

            if (d.sig == .load_imm) {
                add_sym = .{ .constant = d.imm_or_small };
                mul_sym = add_sym;
            } else {
                if ((d.flags & DecodedInst.FLAG_FETCH_A) != 0) {
                    acc_sym[6] = if (reads_w_for_vary)
                        .unknown
                    else if (d.raddr_a < 32)
                        ra_sym[d.raddr_a]
                    else if (d.raddr_a == qpu.R.unif) blk: {
                        const c = if (sym_unifs_read < uniforms.len) uniforms[sym_unifs_read] else 0;
                        sym_unifs_read += 1;
                        break :blk .{ .constant = c };
                    } else .unknown;
                }
                if (d.sig == .small_imm) {
                    acc_sym[7] = .{ .constant = d.imm_or_small };
                } else if ((d.flags & DecodedInst.FLAG_FETCH_B) != 0) {
                    acc_sym[7] = if (d.raddr_b < 32)
                        rb_sym[d.raddr_b]
                    else if (d.raddr_b == qpu.R.unif) blk: {
                        const c = if (sym_unifs_read < uniforms.len) uniforms[sym_unifs_read] else 0;
                        sym_unifs_read += 1;
                        break :blk .{ .constant = c };
                    } else .unknown;
                }

                if ((d.flags & DecodedInst.FLAG_HAS_UNPACK) != 0) {
                    if (d.add_op != .nop) add_sym = .unknown;
                    if (d.mul_op != .nop) mul_sym = .unknown;
                } else {
                    if (d.add_op != .nop) {
                        const in0 = acc_sym[@backingInt(d.mux0)];
                        const in1 = acc_sym[@backingInt(d.mux1)];
                        if (d.add_op == .@"or" and d.mux0 == d.mux1) {
                            add_sym = in0;
                        } else if (in0 == .constant and in1 == .constant) {
                            add_sym = .{ .constant = addOpVec(d.add_op, splat(in0.constant), splat(in1.constant))[0] };
                        } else {
                            add_sym = .unknown;
                        }
                    }
                    if (d.mul_op != .nop) {
                        const in2 = acc_sym[@backingInt(d.mux2)];
                        const in3 = acc_sym[@backingInt(d.mux3)];
                        if (in2 == .constant and in3 == .constant) {
                            mul_sym = .{ .constant = mulOpVec(d.mul_op, splat(in2.constant), splat(in3.constant))[0] };
                        } else if (d.mul_op == .fmul) {
                            if (in2 == .varying and in3 == .constant and in3.constant == 0x3f800000) {
                                mul_sym = in2;
                            } else if (in3 == .varying and in2 == .constant and in2.constant == 0x3f800000) {
                                mul_sym = in3;
                            } else {
                                mul_sym = .unknown;
                            }
                        } else if (d.mul_op == .v8muld) {
                            if (in2 == .tmu0_texel and in3 == .constant) {
                                mul_sym = .{ .tmu0_modulated = .{
                                    .s_var = in2.tmu0_texel.s_var,
                                    .t_var = in2.tmu0_texel.t_var,
                                    .p0_unif = in2.tmu0_texel.p0_unif,
                                    .p1_unif = in2.tmu0_texel.p1_unif,
                                    .color = in3.constant,
                                } };
                            } else if (in3 == .tmu0_texel and in2 == .constant) {
                                mul_sym = .{ .tmu0_modulated = .{
                                    .s_var = in3.tmu0_texel.s_var,
                                    .t_var = in3.tmu0_texel.t_var,
                                    .p0_unif = in3.tmu0_texel.p0_unif,
                                    .p1_unif = in3.tmu0_texel.p1_unif,
                                    .color = in2.constant,
                                } };
                            } else if (in2 == .tmu0_texel and d.mux2 == d.mux3) {
                                mul_sym = .unknown;
                            } else {
                                mul_sym = .unknown;
                            }
                        } else {
                            mul_sym = .unknown;
                        }
                    }
                }
            }

            writeSym(
                d.waddr_add,
                d.add_file,
                add_sym,
                d.cond_add,
                d.add_pack_a,
                0,
                &ra_sym,
                &rb_sym,
                &acc_sym,
                &sym_unifs_read,
                &tmu0_has_t,
                &tmu0_t_var,
                &tmu0_p0_unif,
                &tmu0_pending,
                &tlb_sym,
                &tlb_writes,
                &can_use_sym,
            );
            writeSym(
                d.waddr_mul,
                d.mul_file,
                mul_sym,
                d.cond_mul,
                d.mul_pack_a,
                d.mul_pack_m,
                &ra_sym,
                &rb_sym,
                &acc_sym,
                &sym_unifs_read,
                &tmu0_has_t,
                &tmu0_t_var,
                &tmu0_p0_unif,
                &tmu0_pending,
                &tlb_sym,
                &tlb_writes,
                &can_use_sym,
            );
        }

        switch (d.sig) {
            .load_tmu0 => {
                if (can_use_sym and tmu0_pending != null and tmu0_loads == 0) {
                    const p = tmu0_pending.?;
                    acc_sym[4] = .{ .tmu0_texel = .{
                        .s_var = p.s_var,
                        .t_var = p.t_var,
                        .p0_unif = p.p0_unif,
                        .p1_unif = p.p1_unif,
                    } };
                    tmu0_pending = null;
                    tmu0_loads = 1;
                } else {
                    can_use_sym = false;
                }
            },
            .prog_end => end_at = ip + 2,
            else => {},
        }
        if (vary_alone) acc_sym[5] = .{ .constant = @bitCast(varying_c) };
    }

    if (end_at == null) return .{};

    if (!reads_vary and !reads_other_per_pixel and !uses_tmu0) {
        const env: Env = .{ .uniforms = uniforms };
        if (runFragmentDecoded(decoded, &env)) |res| {
            if (res.tlb_color) |c| {
                if (res.tlb_z == null) {
                    return .{ .kind = .constant_color, .color = c[0] };
                }
            }
        } else |_| {}
    }

    if (can_use_sym and tlb_writes == 1 and !reads_other_per_pixel) {
        switch (tlb_sym) {
            .constant => |c| return .{ .kind = .constant_color, .color = c },
            .packed_rgba => |p| {
                if (!uses_tmu0 and p.complete()) {
                    return .{
                        .kind = .varying_pack_rgba,
                        .color = p.const_rgba,
                        .var_idx = p.var_idx,
                    };
                }
            },
            .tmu0_texel => |t| {
                if (tmu0_loads == 1 and tmu0_pending == null) {
                    return .{
                        .kind = .tmu0_blit,
                        .color = 0xffff_ffff,
                        .var_idx = .{ t.s_var, t.t_var, 0xff, 0xff },
                        .tmu_p0_unif = t.p0_unif,
                        .tmu_p1_unif = t.p1_unif,
                        .tmu_modulate = false,
                    };
                }
            },
            .tmu0_modulated => |t| {
                if (tmu0_loads == 1 and tmu0_pending == null) {
                    return .{
                        .kind = .tmu0_blit,
                        .color = t.color,
                        .var_idx = .{ t.s_var, t.t_var, 0xff, 0xff },
                        .tmu_p0_unif = t.p0_unif,
                        .tmu_p1_unif = t.p1_unif,
                        .tmu_modulate = true,
                    };
                }
            },
            else => {},
        }
    }

    return .{};
}

pub inline fn runFragmentFast(
    fast: FastFragShader,
    decoded: []const DecodedInst,
    env: *const Env,
) Error!FragResult {
    switch (fast.kind) {
        .none => return runFragmentDecoded(decoded, env),
        .constant_color => return .{ .tlb_color = splat(fast.color), .tlb_color_mask = 0xffff },
        .varying_pack_rgba => {
            var out: VecU = @splat(fast.color);
            inline for (0..4) |b_i| {
                const vi = fast.var_idx[b_i];
                if (vi != 0xff) {
                    const shift: u5 = @intCast(b_i * 8);
                    const v_vec: VecU = if (vi < env.varyings.len) env.varyings[vi] else @splat(0);
                    out |= unorm8Vec(v_vec) << @as(@Vector(lanes, u5), @splat(shift));
                }
            }
            return .{ .tlb_color = out, .tlb_color_mask = 0xffff };
        },
        .tmu0_blit => {
            const p0 = if (fast.tmu_p0_unif < env.uniforms.len) env.uniforms[fast.tmu_p0_unif] else 0;
            const p1 = if (fast.tmu_p1_unif < env.uniforms.len) env.uniforms[fast.tmu_p1_unif] else 0;
            const s_var = fast.var_idx[0];
            const t_var = fast.var_idx[1];
            const s_vec: Vec = if (s_var < env.varyings.len) env.varyings[s_var] else splat(0);
            const t_vec: Vec = if (t_var < env.varyings.len) env.varyings[t_var] else splat(0);
            var local_cache: TexCache = .{};
            var second: ?Vec = null;
            const req: TmuRequest = .{ .params = .{ p0, p1, 0, 0 }, .count = 2, .s = s_vec, .t = t_vec, .r = null, .b = null };
            const texel = sampleTmuVec(0, &req, env, &local_cache, &second);
            if (fast.tmu_modulate) {
                return .{ .tlb_color = v8muldVec(texel, @splat(fast.color)), .tlb_color_mask = 0xffff };
            }
            return .{ .tlb_color = texel, .tlb_color_mask = 0xffff };
        },
    }
}

inline fn resolveMuxSlow(
    m: qpu.Mux,
    s: *const State,
    unpack_r4: u3,
    unpack_a: u3,
    float_input: bool,
) Vec {
    return switch (m) {
        .r4 => if (unpack_r4 != 0) unpackVec(s.acc[4], unpack_r4, float_input) else s.acc[4],
        .a => if (unpack_a != 0) unpackVec(s.acc[6], unpack_a, float_input) else s.acc[6],
        else => s.acc[@backingInt(m)],
    };
}

/// Runs `code` (a test's: decoded each time).
pub fn run(code: []const qpu.Inst, env: Env) Error!Result {
    const decoded_buf = std.heap.smp_allocator.alloc(DecodedInst, code.len) catch return error.Unsupported;
    defer std.heap.smp_allocator.free(decoded_buf);
    return runDecoded(decodeProgram(code, decoded_buf), env);
}

pub fn runDecoded(decoded: []const DecodedInst, env: Env) Error!Result {
    var r: Result = .{};
    try executeDecoded(Result, decoded, &env, &r);
    return r;
}

pub fn runFragmentDecoded(decoded: []const DecodedInst, env: *const Env) Error!FragResult {
    var r: FragResult = .{};
    try executeDecoded(FragResult, decoded, env, &r);
    return r;
}

fn executeDecoded(comptime RType: type, decoded: []const DecodedInst, env: *const Env, r: *RType) Error!void {
    var m: Machine = .init(env);
    _ = try m.run(RType, decoded, env, r, std.math.maxInt(usize));
    m.finish(RType, r);
    if (m.end_at == null) return error.MissingProgramEnd;
}

/// What stops a machine: its program ended, it would wait (on a semaphore or the mutex), or it
/// ran as long as it was given.
pub const Stop = enum { ended, waiting, slice };

/// A QPU running a program, which can stop and go on (user programs waiting on each other).
pub const Machine = struct {
    s: State = .{},
    end_at: ?usize = null,
    loads: usize = 0,
    ip: usize = 0,
    /// A branch taken: where to, once its three delay slots (the instructions after it) have run.
    branch_target: ?usize = null,
    branch_from: usize = 0,
    steps: usize = 0,

    pub fn init(env: *const Env) Machine {
        var m: Machine = .{};
        @memset(m.s.acc[0..6], splat(0));
        m.s.ra[qpu.R.frag_payload_zw] = env.frag_w;
        m.s.rb[qpu.R.frag_payload_zw] = z24Of(env.frag_z);
        m.s.ra_init = @as(u32, 1) << qpu.R.frag_payload_zw;
        m.s.rb_init = @as(u32, 1) << qpu.R.frag_payload_zw;
        return m;
    }

    pub fn finish(m: *const Machine, comptime RType: type, r: *RType) void {
        if (@hasField(RType, "uniforms_read")) {
            r.uniforms_read = m.s.uniforms_read;
            r.varyings_read = m.s.varyings_read;
            r.vpm_words_read = m.s.vpm_words_read;
        }
    }

    /// Whether `d` would wait: on a semaphore at 0, or the mutex another QPU holds.
    fn waits(d: DecodedInst, env: *const Env) bool {
        const sync = env.sync orelse return false;
        if (d.sig == .load_imm and d.limm_mode == 4 and (d.imm_or_small >> 4) & 1 != 0) return sync.sema[d.imm_or_small & 15] == 0;
        if (d.sig != .load_imm and d.sig != .branch and (d.flags & DecodedInst.FLAG_FETCH_A) != 0 and d.raddr_a == qpu.R.mutex_acquire) {
            if (sync.mutex) |owner| return owner != env.qpu_number;
        }
        return false;
    }

    /// Runs (at most `slice` more instructions) until the program ends, or it waits.
    pub fn run(m: *Machine, comptime RType: type, decoded: []const DecodedInst, env: *const Env, r: *RType, slice: usize) Error!Stop {
    const s = &m.s;
    const until = m.steps +| slice;
    while (m.ip < decoded.len) : (m.ip += 1) {
        if (m.branch_target) |t| {
            if (m.ip >= m.branch_from + 4) {
                m.ip = t;
                m.branch_target = null;
                if (m.ip >= decoded.len) break;
            }
        }
        if (m.end_at) |e| if (m.ip > e) return .ended;
        const d = decoded[m.ip];
        if (waits(d, env)) return .waiting;
        if (m.steps >= until) return .slice;
        m.steps += 1;
        if (m.steps > env.max_steps) return error.TooLong;
        if (@hasField(RType, "instructions")) r.instructions += 1;
        if (d.sig == .branch) {
            const any = struct {
                fn f(v: VecBool) bool {
                    return @reduce(.Or, v);
                }
                fn all(v: VecBool) bool {
                    return @reduce(.And, v);
                }
            };
            const flag = switch (d.branch_cond >> 2) {
                0 => s.zero,
                1 => s.neg,
                else => s.carry,
            };
            const taken = switch (d.branch_cond) {
                15 => true,
                12, 13, 14 => false,
                else => switch (d.branch_cond & 3) {
                    0 => any.all(flag),
                    1 => any.all(!flag),
                    2 => any.f(flag),
                    else => any.f(!flag),
                },
            };
            // The link address (after the delay slots) comes out of both ALUs.
            const link: u32 = env.code_addr +% @as(u32, @intCast((m.ip + 4) * 8));
            try write(RType, s, r, env, d.waddr_add, d.add_file, splat(link), .always, 0, 0, false);
            try write(RType, s, r, env, d.waddr_mul, d.mul_file, splat(link), .always, 0, 0, false);
            if (taken and m.branch_target == null) {
                var target: u32 = d.imm_or_small;
                if (d.branch_rel) target +%= link;
                if (d.branch_reg) |rg| target +%= (if ((s.ra_init >> rg) & 1 != 0) s.ra[rg][0] else 0);
                m.branch_target = (target -% env.code_addr) / 8;
                m.branch_from = m.ip;
            }
            continue;
        }

        if ((d.flags & DecodedInst.FLAG_FUSED_LINTERP) != 0) {
            const val: Vec = if (s.varyings_read < env.varyings.len) blk: {
                defer s.varyings_read += 1;
                break :blk env.varyings[s.varyings_read];
            } else splat(0);
            s.acc[5] = splatF(varying_c);
            if (d.waddr_add != d.waddr_mul) {
                s.acc[d.waddr_mul - qpu.W.acc0] = @bitCast(@as(VecF, @bitCast(val)) - @as(VecF, @splat(varying_c)));
            }
            if (d.waddr_add != qpu.W.nop) {
                if (d.waddr_add < 32) {
                    const bit = @as(u32, 1) << @intCast(d.waddr_add);
                    if (d.add_file == .a) {
                        s.ra_init |= bit;
                        s.ra[d.waddr_add] = val;
                    } else {
                        s.rb_init |= bit;
                        s.rb[d.waddr_add] = val;
                    }
                } else if (d.waddr_add >= qpu.W.acc0 and d.waddr_add <= qpu.W.acc0 + 3) {
                    s.acc[d.waddr_add - qpu.W.acc0] = val;
                } else {
                    try write(RType, s, r, env, d.waddr_add, d.add_file, val, .always, 0, 0, true);
                }
            }
            if (@hasField(RType, "instructions")) r.instructions += 1;
            m.ip += 1;
            continue;
        }

        var add_result: Vec = undefined;
        var mul_result: Vec = undefined;

        if (d.sig == .load_imm) {
            // A semaphore counted up, or down (Machine.waits held it back at 0).
            if (d.limm_mode == 4) if (env.sync) |sync| {
                const n = d.imm_or_small & 15;
                if ((d.imm_or_small >> 4) & 1 != 0) sync.sema[n] -|= 1 else sync.sema[n] +|= 1;
            };
            add_result = switch (d.limm_mode) {
                // Each element's 2 bits: its low bit at bit n, its high one at bit 16 + n.
                1, 3 => blk: {
                    var v: Vec = undefined;
                    for (0..lanes) |i| {
                        const two: u32 = (d.imm_or_small >> @intCast(i)) & 1 | ((d.imm_or_small >> @intCast(16 + i)) & 1) << 1;
                        v[i] = if (d.limm_mode == 1 and two >= 2) two -% 4 else two;
                    }
                    break :blk v;
                },
                else => splat(d.imm_or_small),
            };
            mul_result = add_result;
        } else {
            var add_a: Vec = splat(0);
            var add_b: Vec = splat(0);
            if ((d.flags & DecodedInst.FLAG_FETCH_A) != 0) {
                s.acc[6] = try readPort(s, env, d.raddr_a, .a);
            }
            if (d.sig == .small_imm) {
                s.acc[7] = splat(d.imm_or_small);
            } else if ((d.flags & DecodedInst.FLAG_FETCH_B) != 0) {
                s.acc[7] = try readPort(s, env, d.raddr_b, .b);
            }

            if ((d.flags & DecodedInst.FLAG_HAS_UNPACK) == 0) {
                if (d.add_op != .nop) {
                    add_a = s.acc[@backingInt(d.mux0)];
                    add_b = s.acc[@backingInt(d.mux1)];
                    add_result = addOpVec(d.add_op, add_a, add_b);
                } else if (d.waddr_add != qpu.W.nop) {
                    add_result = splat(0);
                }
                if (d.mul_op != .nop) {
                    mul_result = mulOpVec(d.mul_op, s.acc[@backingInt(d.mux2)], s.acc[@backingInt(d.mux3)]);
                } else if (d.waddr_mul != qpu.W.nop or (d.flags & DecodedInst.FLAG_SF) != 0) {
                    mul_result = splat(0);
                }
            } else {
                if (d.add_op != .nop) {
                    const flt_add = (d.flags & DecodedInst.FLAG_FLT_ADD) != 0;
                    const in0 = resolveMuxSlow(d.mux0, s, d.unpack_r4, d.unpack_a, flt_add);
                    const in1 = if (d.mux1 == d.mux0) in0 else resolveMuxSlow(d.mux1, s, d.unpack_r4, d.unpack_a, flt_add);
                    add_a = in0;
                    add_b = in1;
                    add_result = addOpVec(d.add_op, in0, in1);
                } else if (d.waddr_add != qpu.W.nop) {
                    add_result = splat(0);
                }

                if (d.mul_op != .nop) {
                    const flt_mul = (d.flags & DecodedInst.FLAG_FLT_MUL) != 0;
                    const in2 = resolveMuxSlow(d.mux2, s, d.unpack_r4, d.unpack_a, flt_mul);
                    const in3 = if (d.mux3 == d.mux2) in2 else resolveMuxSlow(d.mux3, s, d.unpack_r4, d.unpack_a, flt_mul);
                    mul_result = mulOpVec(d.mul_op, in2, in3);
                } else if (d.waddr_mul != qpu.W.nop or (d.flags & DecodedInst.FLAG_SF) != 0) {
                    mul_result = splat(0);
                }
            }

            if (d.rotate != 0 and d.mul_op != .nop) {
                const n: u4 = if (d.rotate == 16) @truncate(s.acc[5][0]) else @intCast(d.rotate);
                mul_result = rotateVec(mul_result, n);
            }
            // The 32-bit saturating pack: an add's or sub's result saturated, not wrapped.
            if (d.add_pack_a == 8 and (d.add_op == .add or d.add_op == .sub)) add_result = saturate32(d.add_op, add_a, add_b);
            if ((d.flags & DecodedInst.FLAG_SF) != 0) {
                const flags_from: VecI = @bitCast(if (d.add_op != .nop) add_result else mul_result);
                s.zero = flags_from == @as(VecI, @splat(0));
                s.neg = flags_from < @as(VecI, @splat(0));
                s.carry = if (d.add_op != .nop) carryOf(d.add_op, add_a, add_b) else @splat(false);
            }
            if ((d.flags & DecodedInst.FLAG_READS_VARY) != 0) s.acc[5] = splatF(varying_c);
        }

        if (d.waddr_add != qpu.W.nop) {
            if (d.cond_add == .always and d.add_pack_a == 0) {
                if (d.waddr_add < 32) {
                    const bit = @as(u32, 1) << @intCast(d.waddr_add);
                    if (d.add_file == .a) {
                        s.ra_init |= bit;
                        s.ra[d.waddr_add] = add_result;
                    } else {
                        s.rb_init |= bit;
                        s.rb[d.waddr_add] = add_result;
                    }
                } else if (d.waddr_add >= qpu.W.acc0 and d.waddr_add <= qpu.W.acc0 + 3) {
                    s.acc[d.waddr_add - qpu.W.acc0] = add_result;
                } else {
                    try write(RType, s, r, env, d.waddr_add, d.add_file, add_result, d.cond_add, d.add_pack_a, 0, d.sig != .load_imm and floatResultAdd(d.add_op));
                }
            } else {
                try write(RType, s, r, env, d.waddr_add, d.add_file, add_result, d.cond_add, d.add_pack_a, 0, d.sig != .load_imm and floatResultAdd(d.add_op));
            }
        }
        if (d.waddr_mul != qpu.W.nop) {
            if (d.cond_mul == .always and d.mul_pack_a == 0 and d.mul_pack_m == 0) {
                if (d.waddr_mul < 32) {
                    const bit = @as(u32, 1) << @intCast(d.waddr_mul);
                    if (d.mul_file == .a) {
                        s.ra_init |= bit;
                        s.ra[d.waddr_mul] = mul_result;
                    } else {
                        s.rb_init |= bit;
                        s.rb[d.waddr_mul] = mul_result;
                    }
                } else if (d.waddr_mul >= qpu.W.acc0 and d.waddr_mul <= qpu.W.acc0 + 3) {
                    s.acc[d.waddr_mul - qpu.W.acc0] = mul_result;
                } else {
                    try write(RType, s, r, env, d.waddr_mul, d.mul_file, mul_result, d.cond_mul, d.mul_pack_a, d.mul_pack_m, d.sig != .load_imm and d.mul_op == .fmul);
                }
            } else {
                try write(RType, s, r, env, d.waddr_mul, d.mul_file, mul_result, d.cond_mul, d.mul_pack_a, d.mul_pack_m, d.sig != .load_imm and d.mul_op == .fmul);
            }
        }

        switch (d.sig) {
            .load_tmu0, .load_tmu1 => {
                const unit: usize = if (d.sig == .load_tmu0) 0 else 1;
                if (s.tmu_fifo_len[unit] > 0) {
                    const head = s.tmu_fifo_head[unit];
                    s.acc[4] = s.tmu_fifo[unit][head];
                    if (s.tmu_fifo_second[unit][head]) |second| {
                        s.tmu_fifo[unit][head] = second;
                        s.tmu_fifo_second[unit][head] = null;
                    } else {
                        s.tmu_fifo_head[unit] +%= 1;
                        s.tmu_fifo_len[unit] -= 1;
                    }
                } else {
                    s.acc[4] = splat(0xff000000);
                }
            },
            .alpha_mask_load => s.acc[4] = env.alpha_mask_in,
            .color_load, .color_load_end => {
                s.acc[4] = if (env.tlb_samples_in) |samples| samples[m.loads % 4] else env.tlb_color_in;
                m.loads += 1;
                if (@hasField(RType, "color_loads")) r.color_loads += 1;
                if (d.sig == .color_load_end) m.end_at = m.ip + 2;
            },
            .prog_end => m.end_at = m.ip + 2,
            else => {},
        }
    }
    return .ended;
    }
};

fn readPort(s: *State, env: *const Env, raddr: u6, file: File) Error!Vec {
    if (raddr < 32) {
        const bit = @as(u32, 1) << @intCast(raddr);
        if (file == .a) {
            return if ((s.ra_init & bit) != 0) s.ra[raddr] else splat(0);
        } else {
            return if ((s.rb_init & bit) != 0) s.rb[raddr] else splat(0);
        }
    }
    switch (raddr) {
        qpu.R.nop => return splat(0),
        qpu.R.unif => {
            if (s.unif_override) |list| {
                if (list.len == 0) return splat(0);
                s.unif_override = list[1..];
                return splat(list[0]);
            }
            if (s.uniforms_read >= env.uniforms.len) return splat(0);
            defer s.uniforms_read += 1;
            return splat(env.uniforms[s.uniforms_read]);
        },
        qpu.R.vary => {
            if (s.varyings_read >= env.varyings.len) return splat(0);
            defer s.varyings_read += 1;
            const val_f: VecF = @bitCast(env.varyings[s.varyings_read]);
            const w_f: VecF = @bitCast(env.frag_w);
            const c_f: VecF = @splat(varying_c);
            return @bitCast((val_f - c_f) / w_f);
        },
        qpu.R.vpm => {
            if (env.vpm_mem) |vpm| return vpmGenericRead(s, vpm);
            if (s.vpm_words_read >= env.vpm_in.len) return splat(0);
            if (s.vpm_read_left > 0) s.vpm_read_left -= 1;
            defer s.vpm_words_read += 1;
            return env.vpm_in[s.vpm_words_read];
        },
        // The element number (A), or the QPU's number (B: for shaders, which runs it isn't
        // known; 0).
        qpu.R.elem_qpu => {
            if (file == .b) return splat(env.qpu_number);
            return .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
        },
        qpu.R.xy_pixel_coord => return if (file == .a) env.frag_x else env.frag_y,
        qpu.R.ms_rev_flags => return if (file == .a) env.ms_mask else env.rev_flag,
        qpu.R.mutex_acquire => {
            // Taken (Machine.waits held it back while another QPU had it).
            if (file == .a) if (env.sync) |sync| {
                sync.mutex = env.qpu_number;
            };
            return splat(0);
        },
        // The DMA is done at once: never busy, nothing to wait for.
        qpu.R.vpm_ld_busy, qpu.R.vpm_ld_wait => return splat(0),
        else => return splat(0),
    }
}

/// The VPM word at row `y`, column `x` (wrapping).
fn vpmIndex(y: u32, x: u32) usize {
    return (@as(usize, y) * 16 + x) % vpm_words;
}

/// Where a generic access `setup` (its size, 8, 16 or 32-bit; horizontal or vertical) puts
/// element `i`: the word, and the bit offset in it (8 and 16-bit laned); then the setup moved on
/// by its stride.
fn vpmElement(setup: u32, i: u32) struct { usize, u5 } {
    const size = (setup >> 8) & 3;
    const horiz = (setup >> 11) & 1 != 0;
    const addr = setup & 0xff;
    return switch (size) {
        0 => if (horiz) .{ vpmIndex(addr >> 2, i), @intCast((addr & 3) * 8) } else .{ vpmIndex(((addr >> 6) << 4) + i, (addr >> 2) & 15), @intCast((addr & 3) * 8) },
        1 => if (horiz) .{ vpmIndex(addr >> 1, i), @intCast((addr & 1) * 16) } else .{ vpmIndex(((addr >> 5) << 4) + i, (addr >> 1) & 15), @intCast((addr & 1) * 16) },
        else => if (horiz) .{ vpmIndex(addr, i), 0 } else .{ vpmIndex(((addr >> 4) << 4) + i, addr & 15), 0 },
    };
}

fn vpmAdvance(setup: u32) u32 {
    const stride: u32 = if ((setup >> 12) & 0x3f == 0) 64 else (setup >> 12) & 0x3f;
    return (setup & ~@as(u32, 0xff)) | ((setup +% stride) & 0xff);
}

/// A generic VPM read: 32-bit words, or 8 and 16-bit values laned (each element one, zero
/// extended) or packed (each element the words they're in).
fn vpmGenericRead(s: *State, vpm: *const [vpm_words]u32) Vec {
    var out: Vec = undefined;
    const size = (s.vpm_rd >> 8) & 3;
    const laned = (s.vpm_rd >> 10) & 1 != 0;
    for (0..lanes) |i| {
        const w, const sh = vpmElement(s.vpm_rd, @intCast(i));
        out[i] = if (size < 2 and laned) (vpm[w] >> sh) & (if (size == 0) @as(u32, 0xff) else 0xffff) else vpm[w];
    }
    s.vpm_rd = vpmAdvance(s.vpm_rd);
    return out;
}

fn vpmGenericWrite(s: *State, vpm: *[vpm_words]u32, value: Vec) void {
    const size = (s.vpm_wr >> 8) & 3;
    const laned = (s.vpm_wr >> 10) & 1 != 0;
    for (0..lanes) |i| {
        const w, const sh = vpmElement(s.vpm_wr, @intCast(i));
        if (size < 2 and laned) {
            const mask: u32 = (if (size == 0) @as(u32, 0xff) else 0xffff) << sh;
            vpm[w] = (vpm[w] & ~mask) | ((value[i] << sh) & mask);
        } else vpm[w] = value[i];
    }
    s.vpm_wr = vpmAdvance(s.vpm_wr);
}

/// A DMA mode's element: its bytes (4, 2 or 1) and bit offset in a VPM word.
fn dmaElement(modew: u32) struct { u32, u5 } {
    return switch (modew) {
        0, 1 => .{ 4, 0 },
        2, 3 => .{ 2, @intCast((modew & 1) * 16) },
        else => .{ 1, @intCast((modew & 3) * 8) },
    };
}

/// A DMA load (VDR) from `addr`: rows of words (or 16 or 8-bit values) `pitch` bytes apart in
/// memory, into VPM rows (or columns) `vpitch` apart.
fn vdrLoad(s: *const State, vpm: *[vpm_words]u32, ram: []const u8, addr: u32) void {
    const v = s.vdr;
    const bytes, const sh = dmaElement((v >> 28) & 7);
    const mpitch = (v >> 24) & 0xf;
    const pitch: u32 = if (mpitch == 0) s.vdr_pitch else @as(u32, 8) << @intCast(mpitch);
    const rowlen: u32 = if ((v >> 20) & 0xf == 0) 16 else (v >> 20) & 0xf;
    const nrows: u32 = if ((v >> 16) & 0xf == 0) 16 else (v >> 16) & 0xf;
    const vpitch: u32 = if ((v >> 12) & 0xf == 0) 16 else (v >> 12) & 0xf;
    const vert = (v >> 11) & 1 != 0;
    const y0 = (v & 0x7ff) >> 4;
    const x0 = v & 15;
    const mask = vc_bus.ramMask(ram.len);
    for (0..nrows) |r_| {
        const r: u32 = @intCast(r_);
        for (0..rowlen) |c_| {
            const c: u32 = @intCast(c_);
            const m = (addr +% r *% pitch +% c * bytes) & mask;
            if (m + bytes > ram.len) continue;
            const val: u32 = switch (bytes) {
                4 => std.mem.readInt(u32, ram[m..][0..4], .little),
                2 => std.mem.readInt(u16, ram[m..][0..2], .little),
                else => ram[m],
            };
            const w = if (vert) vpmIndex(y0 + c, x0 + r * vpitch) else vpmIndex(y0 + r * vpitch, x0 + c);
            if (bytes == 4) vpm[w] = val else {
                const fmask: u32 = (if (bytes == 2) @as(u32, 0xffff) else 0xff) << sh;
                vpm[w] = (vpm[w] & ~fmask) | ((val << sh) & fmask);
            }
        }
    }
}

/// A DMA store (VDW) to `addr`: units (rows, or columns) of words (or 16 or 8-bit values) from
/// the VPM, each unit packed in memory and the stride after it.
fn vdwStore(s: *const State, vpm: *const [vpm_words]u32, ram: []u8, addr: u32) void {
    const v = s.vdw;
    const bytes, const sh = dmaElement(v & 7);
    const units: u32 = if ((v >> 23) & 0x7f == 0) 128 else (v >> 23) & 0x7f;
    const depth: u32 = if ((v >> 16) & 0x7f == 0) 128 else (v >> 16) & 0x7f;
    const horiz = (v >> 14) & 1 != 0;
    const base = (v >> 3) & 0x7ff;
    const y0 = base >> 4;
    const x0 = base & 15;
    const stride = s.vdw_stride & 0xffff;
    const mask = vc_bus.ramMask(ram.len);
    for (0..units) |u_| {
        const un: u32 = @intCast(u_);
        for (0..depth) |d_| {
            const dp: u32 = @intCast(d_);
            const w = if (horiz) (@as(usize, y0 + un) * 16 + x0 + dp) % vpm_words else (@as(usize, y0 + dp) * 16 + x0 + un) % vpm_words;
            const m = (addr +% un *% (depth * bytes + stride) +% dp * bytes) & mask;
            if (m + bytes > ram.len) continue;
            const val = vpm[w] >> sh;
            switch (bytes) {
                4 => std.mem.writeInt(u32, ram[m..][0..4], val, .little),
                2 => std.mem.writeInt(u16, ram[m..][0..2], @truncate(val), .little),
                else => ram[m] = @truncate(val),
            }
        }
    }
}

/// The next uniform (for the TMU's config parameters), from memory after a write to
/// UNIFORMS_ADDRESS.
fn nextUniform(s: *State, env: *const Env) u32 {
    if (s.unif_override) |list| {
        if (list.len == 0) return 0;
        s.unif_override = list[1..];
        return list[0];
    }
    if (s.uniforms_read >= env.uniforms.len) return 0;
    defer s.uniforms_read += 1;
    return env.uniforms[s.uniforms_read];
}

/// A texture lookup: its config parameters (in the order written, from the uniforms), and its
/// coordinates.
const TmuRequest = struct {
    params: [4]u32,
    count: u8,
    s: Vec,
    t: ?Vec,
    r: ?Vec,
    b: ?Vec,

    fn config(q: *const TmuRequest) texture.Config {
        return texture.decodeConfig(q.params[0], if (q.count > 1) q.params[1] else 0);
    }

    /// What config parameters 2 and 3 say.
    fn extra(q: *const TmuRequest) TexExtra {
        var e: TexExtra = .{};
        for (q.params[2..@max(q.count, 2)]) |p| {
            switch (p >> 30) {
                1 => {
                    e.cube_stride = p & 0x3ffff000;
                    e.bslod = p & 1 != 0;
                },
                2 => {
                    e.child_w = p & 0x7ff;
                    e.child_h = (p >> 12) & 0x7ff;
                },
                3 => {
                    e.child_x = p & 0x7ff;
                    e.child_y = (p >> 12) & 0x7ff;
                },
                else => {},
            }
        }
        return e;
    }

    /// Whether the level of detail comes from the coordinates' differences across 2x2 quads.
    fn lodFromQuads(q: *const TmuRequest) bool {
        return needsLod(q.config()) and !q.extra().bslod;
    }
};

const TexExtra = struct {
    /// Cube map faces' distance apart.
    cube_stride: u32 = 0,
    /// The level of detail is the b coordinate alone (else it's added to that computed).
    bslod: bool = false,
    /// A child image: the window of the texture sampled (none if 0 wide).
    child_w: u32 = 0,
    child_h: u32 = 0,
    child_x: u32 = 0,
    child_y: u32 = 0,
};

/// Whether sampling `c` depends on the level of detail: mipmapped, or minified with another
/// filter than magnified.
fn needsLod(c: texture.Config) bool {
    return c.min_filter != c.mag_filter or (c.mip_filter != .none and c.mip_levels > 0);
}

/// The texture memory a TMU lookup at `addr` reads (tests may give each texture its own), and
/// the address in it.
fn tmuMemory(unit: usize, addr: u32, env: *const Env) struct { []const u8, u32 } {
    const memory = if (unit == 0) env.texture_memory else if (env.texture_memory1.len > 0) env.texture_memory1 else env.texture_memory;
    if (env.textures.len > 0) {
        const i = addr / texture_base;
        if (i < env.textures.len) return .{ env.textures[i], addr - i * texture_base };
    }
    return .{ memory, addr };
}

/// A general memory lookup: the word at each element's address.
fn directLookup(unit: usize, addrs: Vec, env: *const Env) Vec {
    var out: Vec = undefined;
    for (0..lanes) |lane| {
        const mem, const addr = tmuMemory(unit, addrs[lane], env);
        const off = addr & vc_bus.ramMask(mem.len) & ~@as(u32, 3);
        out[lane] = if (mem.len >= 4 and off + 4 <= mem.len) std.mem.readInt(u32, mem[off..][0..4], .little) else 0;
    }
    return out;
}

/// The size of a power of two at least `v`.
fn potOf(v: u32) u32 {
    return std.math.ceilPowerOfTwo(u32, @max(v, 1)) catch 2048;
}

/// Level `level` of the texture `c` whose level 0 is at `base`: the levels below level 0
/// are before it in memory, each smaller after the one bigger, each half the last (its size
/// rounded up to a power of two first), down to 1.
fn levelConfig(c: texture.Config, base: u32, level: u32, memory_len: usize) texture.Config {
    var l = c;
    l.offset = base;
    if (level == 0) return l;
    var off = base;
    for (1..level + 1) |j| {
        var lj = c;
        lj.width = @max(potOf(c.width) >> @intCast(j), 1);
        lj.height = @max(potOf(c.height) >> @intCast(j), 1);
        const pt = PrecomputedTex.init(lj, memory_len) catch return l;
        off -%= pt.len;
        l.width = lj.width;
        l.height = lj.height;
    }
    l.offset = off;
    return l;
}

/// Where a cube map's coordinates point: the face (+X, -X, +Y, -Y, +Z, -Z), and s and t on it.
fn cubeFace(x: f32, y: f32, z: f32) struct { u32, f32, f32 } {
    const ax = @abs(x);
    const ay = @abs(y);
    const az = @abs(z);
    var face: u32 = undefined;
    var ma: f32 = undefined;
    var sc: f32 = undefined;
    var tc: f32 = undefined;
    if (ax >= ay and ax >= az) {
        face = if (x >= 0) 0 else 1;
        ma = ax;
        sc = if (x >= 0) -z else z;
        tc = -y;
    } else if (ay >= az) {
        face = if (y >= 0) 2 else 3;
        ma = ay;
        sc = x;
        tc = if (y >= 0) z else -z;
    } else {
        face = if (z >= 0) 4 else 5;
        ma = az;
        sc = if (z >= 0) x else -x;
        tc = -y;
    }
    if (!(ma > 0)) return .{ face, 0.5, 0.5 };
    return .{ face, (sc / ma + 1) * 0.5, (tc / ma + 1) * 0.5 };
}

/// The level of detail of each element's lookup, from the differences of its coordinates
/// (`s`, `t`, in texels of level 0) across its 2x2 quad of elements (0 and 1 its top row, 2 and
/// 3 below): log2 of the longer of the steps across and down.
fn quadLod(s: [lanes]f32, t: [lanes]f32) [lanes]f32 {
    var out: [lanes]f32 = undefined;
    for (0..lanes) |lane| {
        const q = lane & ~@as(usize, 3);
        const row = (lane >> 1) & 1;
        const col = lane & 1;
        const dsdx = s[q + row * 2 + 1] - s[q + row * 2];
        const dtdx = t[q + row * 2 + 1] - t[q + row * 2];
        const dsdy = s[q + 2 + col] - s[q + col];
        const dtdy = t[q + 2 + col] - t[q + col];
        const rx = dsdx * dsdx + dtdx * dtdx;
        const ry = dsdy * dsdy + dtdy * dtdy;
        const rho2 = @max(rx, ry);
        out[lane] = if (rho2 > 0 and !std.math.isInf(rho2)) 0.5 * sfuLog2(rho2) else if (rho2 > 0) 32 else -32;
    }
    return out;
}

fn sampleTmuVec(
    unit: usize,
    req: *const TmuRequest,
    env: *const Env,
    fallback_cache: *TexCache,
    second: *?Vec,
) Vec {
    second.* = null;
    const p0_in = req.params[0];
    const p1 = if (req.count > 1) req.params[1] else 0;
    const memory, const p0 = tmuMemory(unit, p0_in, env);
    const cfg = texture.decodeConfig(p0, p1);
    const cube = (p0 >> 9) & 1 != 0;
    const extra = req.extra();
    if (cube or extra.child_w != 0 or needsLod(cfg) or cfg.wrap_s == .border or cfg.wrap_t == .border or extra.bslod) {
        return sampleTmuFull(memory, cfg, cube, extra, req, second);
    }
    const s_vec = req.s;
    const t_vec = req.t;
    const cache_slot: *TexCache = if (env.tex_cache) |tc| &tc[unit] else fallback_cache;
    if (cache_slot.p0 != p0 or cache_slot.p1 != p1) {
        cache_slot.p0 = p0;
        cache_slot.p1 = p1;
        if (PrecomputedTex.init(cfg, memory.len)) |inited| {
            cache_slot.pt = inited;
            cache_slot.valid = true;
        } else |_| {
            cache_slot.valid = false;
        }
    }
    if (!cache_slot.valid) return splat(0xff000000);
    const pt = &cache_slot.pt;
    var texel: Vec = undefined;
    if (pt.float16 or pt.unblended) {
        // Words not of bytes (and RGBA64's second).
        var hi: Vec = undefined;
        for (0..lanes) |lane| {
            const tc = if (t_vec) |tv| f(tv[lane]) else 0;
            const v = pt.sampleWide(memory, f(s_vec[lane]), tc) catch 0xff000000;
            texel[lane] = @truncate(v);
            hi[lane] = @truncate(v >> 32);
        }
        if (pt.cfg.type == .rgba64) second.* = hi;
        return texel;
    }
    if (pt.cfg.mag_filter == .nearest) {
        const p = pt.cfg;
        var prev_wx: u32 = 0xffff_ffff;
        var prev_wy: u32 = 0xffff_ffff;
        var prev_out: u32 = 0;
        const zero_wy: u32 = if (t_vec == null) (if (0.0 < pt.fh) 0 else wrap(0.0, pt.wh, p.wrap_t)) else 0;
        for (0..lanes) |lane| {
            const s_coord = f(s_vec[lane]);
            const fx = @floor(s_coord * pt.fw);
            const wx: u32 = if (fx >= 0.0 and fx < pt.fw) @intFromFloat(fx) else wrap(fx, pt.ww, p.wrap_s);
            const wy: u32 = if (t_vec) |tv| blk: {
                const t_coord = f(tv[lane]);
                const fy = @floor(t_coord * pt.fh);
                break :blk if (fy >= 0.0 and fy < pt.fh) @intFromFloat(fy) else wrap(fy, pt.wh, p.wrap_t);
            } else zero_wy;
            if (wx == prev_wx and wy == prev_wy) {
                texel[lane] = prev_out;
                continue;
            }
            const sampled = pt.fetchAt(memory, wx, wy) catch 0xff000000;
            texel[lane] = sampled;
            prev_wx = wx;
            prev_wy = wy;
            prev_out = sampled;
        }
    } else {
        var prev_sc: u32 = 0;
        var prev_tc: u32 = 0;
        var prev_out: u32 = 0;
        for (0..lanes) |lane| {
            const sc = s_vec[lane];
            const tc = if (t_vec) |tv| tv[lane] else 0;
            if (lane > 0 and sc == prev_sc and tc == prev_tc) {
                texel[lane] = prev_out;
                continue;
            }
            const sampled = pt.sample(memory, f(sc), f(tc)) catch 0xff000000;
            texel[lane] = sampled;
            prev_sc = sc;
            prev_tc = tc;
            prev_out = sampled;
        }
    }
    return texel;
}

/// A lookup with all the TMU's features: levels of detail (from 2x2 quads of elements, plus
/// the b coordinate's bias, or the bias alone) choosing the filter and mipmap levels, cube maps,
/// child images, and border colours (the r coordinate's word).
fn sampleTmuFull(memory: []const u8, cfg: texture.Config, cube: bool, extra: TexExtra, req: *const TmuRequest, second: *?Vec) Vec {
    var s: [lanes]f32 = undefined;
    var t: [lanes]f32 = undefined;
    var face: [lanes]u32 = @splat(0);
    for (0..lanes) |lane| {
        s[lane] = f(req.s[lane]);
        t[lane] = if (req.t) |tv| f(tv[lane]) else 0;
        if (cube) {
            const r = if (req.r) |rv| f(rv[lane]) else 0;
            face[lane], s[lane], t[lane] = cubeFace(s[lane], t[lane], r);
        }
    }
    var lod: [lanes]f32 = @splat(0);
    if (needsLod(cfg)) {
        if (!extra.bslod) {
            // In texels of level 0 (of the child image, if one).
            const w: f32 = @floatFromInt(if (extra.child_w != 0) extra.child_w else cfg.width);
            const h: f32 = @floatFromInt(if (extra.child_w != 0) extra.child_h else cfg.height);
            var st: [lanes]f32 = undefined;
            var tt: [lanes]f32 = undefined;
            for (0..lanes) |lane| {
                st[lane] = s[lane] * w;
                tt[lane] = t[lane] * h;
            }
            lod = quadLod(st, tt);
        } else lod = @splat(0);
        if (req.b) |bv| {
            for (0..lanes) |lane| {
                const bias = f(bv[lane]);
                if (!std.math.isNan(bias)) lod[lane] += bias;
            }
        }
    }
    var out: Vec = undefined;
    var hi: Vec = undefined;
    for (0..lanes) |lane| {
        const border: u64 = if (req.r) |rv| (if (cube) 0 else rv[lane]) else 0;
        const v = sampleLod(memory, cfg, extra, cfg.offset +% face[lane] *% extra.cube_stride, s[lane], t[lane], lod[lane], border);
        out[lane] = @truncate(v);
        hi[lane] = @truncate(v >> 32);
    }
    if (cfg.type == .rgba64) second.* = hi;
    return out;
}

/// A lookup at level of detail `lod` (magnified at 0 or less).
fn sampleLod(memory: []const u8, cfg: texture.Config, extra: TexExtra, base: u32, s: f32, t: f32, lod: f32, border: u64) u64 {
    if (!(lod > 0)) return sampleLevel(memory, cfg, extra, base, 0, cfg.mag_filter, s, t, border);
    const mipmapped = cfg.mip_filter != .none and cfg.mip_levels > 0;
    if (!mipmapped) return sampleLevel(memory, cfg, extra, base, 0, cfg.min_filter, s, t, border);
    const top: f32 = @floatFromInt(cfg.mip_levels);
    if (cfg.mip_filter == .nearest) {
        const l: u32 = @intFromFloat(@min(@floor(lod + 0.5), top));
        return sampleLevel(memory, cfg, extra, base, l, cfg.min_filter, s, t, border);
    }
    const l0 = @floor(lod);
    if (l0 >= top) return sampleLevel(memory, cfg, extra, base, cfg.mip_levels, cfg.min_filter, s, t, border);
    const frac: u32 = @intFromFloat(@round((lod - l0) * 256.0));
    const level: u32 = @intFromFloat(l0);
    const a = sampleLevel(memory, cfg, extra, base, level, cfg.min_filter, s, t, border);
    if (frac == 0) return a;
    const b = sampleLevel(memory, cfg, extra, base, level + 1, cfg.min_filter, s, t, border);
    return blendLevels(cfg.type, a, b, frac);
}

/// Two levels' lookups blended, `frac` 256ths of the way to `b`.
fn blendLevels(ty: texture.Type, a: u64, b: u64, frac: u32) u64 {
    switch (ty) {
        .s8, .s16 => return if (frac < 128) a else b,
        .s16f, .rgba64 => {
            const channels: u32 = if (ty == .rgba64) 4 else 1;
            const wa: f32 = @floatFromInt(256 - frac);
            const wb: f32 = @floatFromInt(frac);
            var out: u64 = 0;
            for (0..channels) |ch| {
                const sh: u6 = @intCast(ch * 16);
                const ha = f(halfToFloatScalar(@truncate(a >> sh)));
                const hb = f(halfToFloatScalar(@truncate(b >> sh)));
                out |= @as(u64, halfOf(u((ha * wa + hb * wb) * (1.0 / 256.0)))) << sh;
            }
            return out;
        },
        else => {
            var out: u32 = 0;
            for (0..4) |i| {
                const sh: u5 = @intCast(i * 8);
                const ca: u32 = @truncate((a >> sh) & 0xff);
                const cb: u32 = @truncate((b >> sh) & 0xff);
                out |= ((ca * (256 - frac) + cb * frac + 128) >> 8) << sh;
            }
            return out;
        },
    }
}

/// A lookup of level `level` with `filter`.
fn sampleLevel(memory: []const u8, cfg: texture.Config, extra: TexExtra, base: u32, level: u32, filter: texture.Filter, s: f32, t: f32, border: u64) u64 {
    var lc = levelConfig(cfg, base, level, memory.len);
    lc.mag_filter = filter;
    var pt = PrecomputedTex.init(lc, memory.len) catch return 0xff000000;
    if (extra.child_w != 0) pt.setChild(extra.child_w >> @intCast(level), extra.child_h >> @intCast(level), extra.child_x >> @intCast(level), extra.child_y >> @intCast(level));
    pt.border = border;
    if (pt.float16 or pt.unblended) return pt.sampleWide(memory, s, t) catch 0xff000000;
    return pt.sample(memory, s, t) catch 0xff000000;
}

/// Whether `op` gives a float (which a 16-bit pack converts to a 16-bit float).
fn floatResultAdd(op: qpu.AddOp) bool {
    return switch (op) {
        .fadd, .fsub, .fmin, .fmax, .fminabs, .fmaxabs, .itof => true,
        else => false,
    };
}

fn write(comptime RType: type, s: *State, r: *RType, env: *const Env, waddr: u6, file: File, value_in: Vec, cond: qpu.Cond, a_pack: u4, mul_pack: u4, float_result: bool) Error!void {
    var value = value_in;
    if (waddr == qpu.W.nop or cond == .never) return;

    const dst: ?*Vec = switch (waddr) {
        0...31 => blk: {
            const bit = @as(u32, 1) << @intCast(waddr);
            if (file == .a) {
                if ((s.ra_init & bit) == 0) {
                    s.ra_init |= bit;
                    if (cond != .always or a_pack != 0 or mul_pack != 0) {
                        s.ra[waddr] = splat(0);
                    }
                }
                break :blk &s.ra[waddr];
            } else {
                if ((s.rb_init & bit) == 0) {
                    s.rb_init |= bit;
                    if (cond != .always or a_pack != 0 or mul_pack != 0) {
                        s.rb[waddr] = splat(0);
                    }
                }
                break :blk &s.rb[waddr];
            }
        },
        qpu.W.acc0...qpu.W.acc0 + 3 => &s.acc[waddr - qpu.W.acc0],
        qpu.W.acc5 => blk: {
            // Written through regfile A, each quad's first pixel to all four; through B,
            // element 0 to all.
            if (file == .a) {
                for (0..lanes) |i| value[i] = value_in[i & ~@as(usize, 3)];
            } else value = splat(value_in[0]);
            break :blk &s.acc[5];
        },
        else => null,
    };
    if (dst) |d| {
        const dv: VecU = d.*;
        const packed_vec = packVec(dv, value, a_pack, mul_pack, float_result);
        if (cond == .always) {
            d.* = packed_vec;
        } else {
            d.* = @select(u32, condMask(cond, s), packed_vec, dv);
        }
        return;
    }

    switch (waddr) {
        qpu.W.uniforms_address => {
            // Uniforms from here on read from the address in element 0.
            const mem = env.uniform_memory;
            if (mem.len >= 4) {
                const off = (value[0] & vc_bus.ramMask(mem.len)) & ~@as(u32, 3);
                s.unif_override = if (off < mem.len) std.mem.bytesAsSlice(u32, mem[off .. mem.len / 4 * 4]) else &.{};
            } else s.unif_override = &.{};
        },
        qpu.W.vpm => {
            if (env.vpm_mem) |vpm| return vpmGenericWrite(s, vpm, value);
            if (@hasField(RType, "vpm_out")) {
                if (r.vpm_out_len < max_vpm_out) {
                    r.vpm_out[r.vpm_out_len] = value;
                    r.vpm_out_len += 1;
                }
            }
        },
        qpu.W.vpmvcd_setup => {
            const v = value[0];
            if (file == .a) {
                const n: u32 = (v >> 20) & 0xf;
                s.vpm_read_left = if (n == 0) 16 else n;
            }
            if (env.vpm_mem != null) {
                if (file == .a) {
                    // Read setups: generic (bit 31 clear), the DMA load's, or its extended pitch.
                    if (v >> 31 == 0) s.vpm_rd = v else if (v >> 28 == 9) s.vdr_pitch = v & 0x1fff else s.vdr = v;
                } else switch (v >> 30) {
                    // Write setups: generic, the DMA store's, or its stride.
                    0 => s.vpm_wr = v,
                    2 => s.vdw = v,
                    3 => s.vdw_stride = v,
                    else => {},
                }
            }
        },
        qpu.W.vpm_addr => if (env.vpm_mem) |vpm| {
            if (env.dma_ram) |ram| {
                if (file == .a) vdrLoad(s, vpm, ram, value[0]) else vdwStore(s, vpm, ram, value[0]);
            }
        },
        qpu.W.mutex_release => if (env.sync) |sync| {
            if (sync.mutex == env.qpu_number) sync.mutex = null;
        },
        qpu.W.host_int => if (env.sync) |sync| {
            sync.host_int |= @as(u16, 1) << @intCast(env.qpu_number & 15);
        },
        // Written to the elements the condition holds for (the others discarded).
        qpu.W.tlb_color_all => {
            const m = laneBits(cond, s);
            r.tlb_color = mergeLanes(r.tlb_color, value, m);
            if (@hasField(RType, "tlb_color_mask")) r.tlb_color_mask |= m;
        },
        qpu.W.tlb_color_ms => {
            const m = laneBits(cond, s);
            if (@hasField(RType, "tlb_color_samples")) {
                if (r.tlb_samples < r.tlb_color_samples.len) {
                    r.tlb_color_samples[r.tlb_samples] = value;
                    if (@hasField(RType, "tlb_sample_masks")) r.tlb_sample_masks[r.tlb_samples] = m;
                }
                r.tlb_samples += 1;
                if (@hasField(RType, "tlb_color_mask")) r.tlb_color_mask |= m;
            }
            r.tlb_color = mergeLanes(r.tlb_color, value, m);
        },
        qpu.W.tlb_z => {
            const m = laneBits(cond, s);
            r.tlb_z = mergeLanes(r.tlb_z, value, m);
            if (@hasField(RType, "tlb_z_mask")) r.tlb_z_mask |= m;
        },
        qpu.W.ms_flags => if (@hasField(RType, "ms_flags")) {
            const m = laneBits(cond, s);
            r.ms_flags = mergeLanes(r.ms_flags, value, m);
            r.ms_flags_mask |= m;
        },
        qpu.W.tlb_alpha_mask => if (@hasField(RType, "alpha_mask")) {
            const m = laneBits(cond, s);
            r.alpha_mask = mergeLanes(r.alpha_mask, value, m);
            r.alpha_mask_mask |= m;
        },
        qpu.W.tlb_stencil_setup => if (@hasField(RType, "stencil_setups")) {
            if (r.stencil_count < r.stencil_setups.len) r.stencil_setups[r.stencil_count] = value[0];
            r.stencil_count += 1;
        },
        qpu.W.sfu_recip, qpu.W.sfu_recipsqrt, qpu.W.sfu_exp, qpu.W.sfu_log => {
            const vf: VecF = @bitCast(value);
            var res_f: VecF = undefined;
            switch (waddr) {
                qpu.W.sfu_recip => res_f = @as(VecF, @splat(1.0)) / vf,
                qpu.W.sfu_recipsqrt => inline for (0..lanes) |i| {
                    res_f[i] = sfuRsqrt(vf[i]);
                },
                qpu.W.sfu_exp => inline for (0..lanes) |i| {
                    res_f[i] = sfuExp2(vf[i]);
                },
                else => inline for (0..lanes) |i| {
                    res_f[i] = sfuLog2(vf[i]);
                },
            }
            s.acc[4] = @bitCast(res_f);
        },
        qpu.W.tmu0_s, qpu.W.tmu0_t, qpu.W.tmu0_r, qpu.W.tmu0_b, qpu.W.tmu1_s, qpu.W.tmu1_t, qpu.W.tmu1_r, qpu.W.tmu1_b => {
            const unit: usize = if (waddr <= qpu.W.tmu0_b) 0 else 1;
            const reg = (waddr - qpu.W.tmu0_s) & 3;
            const p_cnt = s.tmu_param_count[unit];
            // S written first: a general memory lookup, of the word at each address.
            const direct = reg == 0 and p_cnt == 0;
            // Each other write takes the next of the texture's config parameters.
            if (!direct and p_cnt < 4) {
                s.tmu_params[unit][p_cnt] = nextUniform(s, env);
                s.tmu_param_count[unit] = p_cnt + 1;
            }
            switch (reg) {
                1 => {
                    s.tmu_coord_t[unit] = value;
                    s.tmu_has_coord_t[unit] = true;
                    return;
                },
                2 => {
                    s.tmu_coord_r[unit] = value;
                    return;
                },
                3 => {
                    s.tmu_coord_b[unit] = value;
                    return;
                },
                else => {},
            }
            defer {
                s.tmu_param_count[unit] = 0;
                s.tmu_has_coord_t[unit] = false;
                s.tmu_coord_r[unit] = null;
                s.tmu_coord_b[unit] = null;
            }
            if (s.tmu_fifo_len[unit] == 4) return;
            const write_idx: u2 = s.tmu_fifo_head[unit] +% @as(u2, @truncate(s.tmu_fifo_len[unit]));
            s.tmu_fifo_second[unit][write_idx] = null;
            if (direct) {
                s.tmu_fifo[unit][write_idx] = directLookup(unit, value, env);
            } else {
                const req: TmuRequest = .{
                    .params = s.tmu_params[unit],
                    .count = s.tmu_param_count[unit],
                    .s = value,
                    .t = if (s.tmu_has_coord_t[unit]) s.tmu_coord_t[unit] else null,
                    .r = s.tmu_coord_r[unit],
                    .b = s.tmu_coord_b[unit],
                };
                if (@hasField(RType, "needs_quads")) {
                    if (req.lodFromQuads()) r.needs_quads = true;
                }
                s.tmu_fifo[unit][write_idx] = sampleTmuVec(unit, &req, env, &s.tmu_cached[unit], &s.tmu_fifo_second[unit][write_idx]);
            }
            s.tmu_fifo_len[unit] += 1;
            if (@hasField(RType, "texture_samples")) r.texture_samples += 1;
        },
        else => {},
    }
}

pub const texture_base: u32 = 1 << 28;

pub const TexCache = struct {
    p0: u32 = 0xffff_ffff,
    p1: u32 = 0xffff_ffff,
    valid: bool = false,
    pt: PrecomputedTex = undefined,
};

const PrecomputedTex = struct {
    cfg: texture.Config,
    base_off: u32,
    /// Bytes a texel, for the types read a whole number of bytes at a time from tiles
    /// (`fast`: RGBA8888, RGBX8888, RGBA32R, RGB565, luminance and alpha); 0 for the rest.
    cpp: u32,
    /// Bits a texel (an ETC1 block's for ETC1), and whether each texel is a whole number of
    /// bytes of one of the original types (read without decoding).
    bpp: u32,
    fast: bool,
    /// Results aren't 8-bit channels, blended byte by byte: 16-bit floats (blended as floats:
    /// S16F, RGBA64), or integers (not blended: S8, S16).
    float16: bool,
    unblended: bool,
    fw: f32,
    fh: f32,
    uw_shift: u5,
    uh_shift: u5,
    uw_mask: u32,
    uh_mask: u32,
    cpp_shift: u5,
    utile_row_stride: u32,
    alpha_or_mask32: u32,
    alpha_or_mask64: u64,
    /// Raster (not tiled): bytes a row.
    raster_stride: u32,
    is_small_microtile: bool,
    utiles_per_row: u32,
    tile_w_shift: u5,
    tile_h_shift: u5,
    tiles_per_row: u32,
    /// The bytes it takes.
    len: u32,
    /// The size coordinates are scaled by and wrapped in (a child image's), and where that
    /// window is in the texture.
    ww: u32,
    wh: u32,
    child_x: u32 = 0,
    child_y: u32 = 0,
    /// What texels past the edge are, wrapped to the border.
    border: u64 = 0,

    inline fn init(p: texture.Config, memory_len: usize) Error!PrecomputedTex {
        // Bits a texel (ETC1: a 4x4 block's, its texels addressed by block).
        const bpp: u32 = switch (p.type) {
            .rgba8888, .rgbx8888, .rgba32r => 32,
            .rgba4444, .rgba5551, .rgb565, .lumalpha, .s16f, .s16, .yuv422r => 16,
            .luminance, .alpha, .s8 => 8,
            .a4 => 4,
            .bw1, .a1 => 1,
            .rgba64, .etc1 => 64,
            _ => return error.Unsupported,
        };
        const fast = switch (p.type) {
            .rgba8888, .rgbx8888, .rgba32r, .rgb565, .luminance, .alpha => true,
            else => false,
        };
        const raster = p.type == .rgba32r or p.type == .yuv422r;
        // A 64-byte microtile: 2x4 texels of 64 bits, 4x4 of 32, 8x4 of 16, 8x8 of 8, 16x8 of 4,
        // 32x16 of 1.
        const uw_shift: u5 = switch (bpp) {
            64 => 1,
            32 => 2,
            16, 8 => 3,
            4 => 4,
            else => 5,
        };
        const uh_shift: u5 = switch (bpp) {
            64, 32, 16 => 2,
            8, 4 => 3,
            else => 4,
        };
        const uw: u32 = @as(u32, 1) << uw_shift;
        const uh: u32 = @as(u32, 1) << uh_shift;
        const cpp: u32 = if (fast) bpp / 8 else 0;
        const cpp_shift: u5 = switch (cpp) {
            4 => 2,
            2 => 1,
            else => 0,
        };
        // The grid of what's addressed: texels, or ETC1's blocks.
        const gw = if (p.type == .etc1) (p.width + 3) >> 2 else p.width;
        const gh = if (p.type == .etc1) (p.height + 3) >> 2 else p.height;
        const tile_w_shift: u5 = uw_shift + 3;
        const tile_h_shift: u5 = uh_shift + 3;
        const tile_w: u32 = @as(u32, 1) << tile_w_shift;
        const tile_h: u32 = @as(u32, 1) << tile_h_shift;
        const small = gw <= (uw << 2) or gh <= (uh << 2);
        const utiles_per_row = (gw + uw - 1) >> uw_shift;
        const tiles_per_row = (gw + tile_w - 1) >> tile_w_shift;
        const raster_stride = p.width * (bpp / 8);
        const len: u32 = if (raster)
            raster_stride * p.height
        else if (small)
            utiles_per_row * ((gh + uh - 1) >> uh_shift) * 64
        else
            tiles_per_row * ((gh + tile_h - 1) >> tile_h_shift) * 4096;
        return .{
            .cfg = p,
            .base_off = p.offset & vc_bus.ramMask(memory_len),
            .cpp = cpp,
            .bpp = bpp,
            .fast = fast and !p.flip_y,
            .float16 = p.type == .s16f or p.type == .rgba64,
            .unblended = p.type == .s8 or p.type == .s16,
            .fw = @floatFromInt(p.width),
            .fh = @floatFromInt(p.height),
            .uw_shift = uw_shift,
            .uh_shift = uh_shift,
            .uw_mask = uw - 1,
            .uh_mask = uh - 1,
            .cpp_shift = cpp_shift,
            .utile_row_stride = if (raster) raster_stride else (@as(u32, 1) << (uw_shift + cpp_shift)),
            .alpha_or_mask32 = if (p.type == .rgbx8888) 0xff000000 else 0,
            .alpha_or_mask64 = if (p.type == .rgbx8888) 0xff000000_ff000000 else 0,
            .raster_stride = raster_stride,
            .is_small_microtile = small,
            .utiles_per_row = utiles_per_row,
            .tile_w_shift = tile_w_shift,
            .tile_h_shift = tile_h_shift,
            .tiles_per_row = tiles_per_row,
            .len = len,
            .ww = p.width,
            .wh = p.height,
        };
    }

    /// Samples the window `w` by `h` at (`x`, `y`) of it, as if it were the texture.
    fn setChild(pt: *PrecomputedTex, w: u32, h: u32, x: u32, y: u32) void {
        pt.ww = @max(w, 1);
        pt.wh = @max(h, 1);
        pt.fw = @floatFromInt(pt.ww);
        pt.fh = @floatFromInt(pt.wh);
        pt.child_x = x;
        pt.child_y = y;
        pt.fast = false;
    }

    /// Where microtile (`ux`, `uy`) is, from the texture's start: LT format (microtiles in rows),
    /// or T format (4 KiB tiles in rows, alternate rows reversed, of 1 KiB subtiles, of 4x4
    /// microtiles).
    inline fn utileOffset(pt: *const PrecomputedTex, ux: u32, uy: u32) u32 {
        if (pt.is_small_microtile) return (uy * pt.utiles_per_row + ux) << 6;
        const tile_row = uy >> 3;
        const tile_col = if ((tile_row & 1) == 0) (ux >> 3) else pt.tiles_per_row - 1 - (ux >> 3);
        const tile_base = (tile_row * pt.tiles_per_row + tile_col) << 12;
        const stile_index = (((uy >> 2) & 1) << 1) | ((ux >> 2) & 1);
        const even_map = [4]u32{ 0, 3, 1, 2 };
        const odd_map = [4]u32{ 2, 1, 3, 0 };
        const sub_index = if ((tile_row & 1) == 0) even_map[stile_index] else odd_map[stile_index];
        return tile_base + (sub_index << 10) + ((((uy & 3) << 2) | (ux & 3)) << 6);
    }

    /// Where texel (`x`, `y`) of a `fast` type is.
    inline fn texelOffset(pt: *const PrecomputedTex, x: u32, y: u32) u32 {
        if (pt.cfg.type == .rgba32r) {
            return (y * pt.cfg.width + x) << 2;
        }
        const in_utile = (((y & pt.uh_mask) << pt.uw_shift) | (x & pt.uw_mask)) << pt.cpp_shift;
        return pt.utileOffset(x >> pt.uw_shift, y >> pt.uh_shift) + in_utile;
    }

    inline fn fetchFromOffset(pt: *const PrecomputedTex, memory: []const u8, offset: u32) Error!u32 {
        if (offset + pt.cpp > memory.len) return error.Unsupported;
        if (pt.cpp == 4) {
            return std.mem.readInt(u32, memory[offset..][0..4], .little) | pt.alpha_or_mask32;
        }
        if (pt.cpp == 1) {
            if (pt.cfg.type == .luminance) {
                const l: u32 = memory[offset];
                return 0xff000000 | (l * 0x010101);
            }
            return @as(u32, memory[offset]) << 24;
        }
        return pixel.fromRgb565(std.mem.readInt(u16, memory[offset..][0..2], .little));
    }

    inline fn fetchPairFromOffset(pt: *const PrecomputedTex, memory: []const u8, offset: u32) Error![2]u32 {
        if (offset + (pt.cpp << 1) > memory.len) return error.Unsupported;
        if (pt.cpp == 4) {
            const pair = std.mem.readInt(u64, memory[offset..][0..8], .little) | pt.alpha_or_mask64;
            return .{ @truncate(pair), @truncate(pair >> 32) };
        }
        if (pt.cpp == 1) {
            const b0: u32 = memory[offset];
            const b1: u32 = memory[offset + 1];
            if (pt.cfg.type == .luminance) {
                return .{ 0xff000000 | (b0 * 0x010101), 0xff000000 | (b1 * 0x010101) };
            }
            return .{ b0 << 24, b1 << 24 };
        }
        const raw = std.mem.readInt(u32, memory[offset..][0..4], .little);
        return .{ pixel.fromRgb565(@truncate(raw)), pixel.fromRgb565(@truncate(raw >> 16)) };
    }

    /// Texel (`x`, `y`) as the TMU returns it (RGBA64: its first word).
    inline fn fetchAt(pt: *const PrecomputedTex, memory: []const u8, x: u32, y: u32) Error!u32 {
        if ((x | y) & border_texel != 0) return @truncate(pt.border);
        if (pt.fast) return pt.fetchFromOffset(memory, pt.base_off + pt.texelOffset(x, y));
        return @truncate(try pt.fetchWide(memory, x, y));
    }

    /// Texel (`x`, `y`) as the TMU returns it: a word (byte 0 red, or the type's first channel;
    /// S8, S16 and S16F in the low bits), or RGBA64's two (red and green, then blue and alpha).
    fn fetchWide(pt: *const PrecomputedTex, memory: []const u8, x_in: u32, y_in: u32) Error!u64 {
        if ((x_in | y_in) & border_texel != 0) return pt.border;
        const p = pt.cfg;
        const x = x_in + pt.child_x;
        const y_c = y_in + pt.child_y;
        if (x >= p.width or y_c >= p.height) return 0xff000000;
        const y = if (p.flip_y) p.height - 1 - y_c else y_c;
        if (pt.cpp != 0) return try pt.fetchFromOffset(memory, pt.base_off + pt.texelOffset(x, y));
        switch (p.type) {
            .yuv422r => {
                // Y0 U Y1 V, a pair of texels.
                const off = pt.base_off + y * pt.raster_stride + ((x & ~@as(u32, 1)) << 1);
                if (off + 4 > memory.len) return error.Unsupported;
                return yuvToRgb(memory[off + (x & 1) * 2], memory[off + 1], memory[off + 3]);
            },
            .etc1 => {
                const bx = x >> 2;
                const by = y >> 2;
                const off = pt.base_off + pt.utileOffset(bx >> 1, by >> 2) + ((((by & 3) << 1) | (bx & 1)) << 3);
                if (off + 8 > memory.len) return error.Unsupported;
                const row = if (p.etc_flip) y & 3 else 3 - (y & 3);
                return etc1Texel(memory[off..][0..8], x & 3, row);
            },
            else => {},
        }
        const i = ((y & pt.uh_mask) << pt.uw_shift) | (x & pt.uw_mask);
        const bit = i * pt.bpp;
        const off = pt.base_off + pt.utileOffset(x >> pt.uw_shift, y >> pt.uh_shift) + (bit >> 3);
        if (off + @max(pt.bpp / 8, 1) > memory.len) return error.Unsupported;
        switch (pt.bpp) {
            64 => return std.mem.readInt(u64, memory[off..][0..8], .little),
            16 => {
                const v: u32 = std.mem.readInt(u16, memory[off..][0..2], .little);
                return switch (p.type) {
                    // The top bits to byte 0.
                    .rgba4444 => ((v >> 12) | ((v >> 8) & 0xf) << 8 | ((v >> 4) & 0xf) << 16 | (v & 0xf) << 24) * 0x11,
                    .rgba5551 => @as(u32, expand5(v >> 11)) | @as(u32, expand5((v >> 6) & 0x1f)) << 8 | @as(u32, expand5((v >> 1) & 0x1f)) << 16 | (v & 1) * 0xff000000,
                    .lumalpha => (v & 0xff) * 0x010101 | (v >> 8) << 24,
                    else => v,
                };
            },
            8 => return memory[off],
            4 => return @as(u32, (memory[off] >> @intCast(bit & 7)) & 0xf) * 0x11000000,
            else => {
                const set = (memory[off] >> @intCast(bit & 7)) & 1 != 0;
                return switch (p.type) {
                    .bw1 => if (set) 0xffffffff else 0xff000000,
                    else => if (set) 0xff000000 else 0,
                };
            },
        }
    }

    /// The texels the bilinear filter blends for (`s`, `t`), and their weights in 256ths.
    const Footprint = struct { x0: u32, x1: u32, y0: u32, y1: u32, fx: u32, fy: u32 };

    inline fn footprint(pt: *const PrecomputedTex, s: f32, t: f32) Footprint {
        const p = pt.cfg;
        const fx = s * pt.fw - 0.5;
        const fy = t * pt.fh - 0.5;
        const x0 = @floor(fx);
        const y0 = @floor(fy);
        var r: Footprint = undefined;
        if (x0 >= 0.0 and x0 + 1.0 < pt.fw) {
            r.x0 = @intFromFloat(x0);
            r.x1 = r.x0 + 1;
        } else {
            r.x0 = wrap(x0, pt.ww, p.wrap_s);
            r.x1 = wrap(x0 + 1.0, pt.ww, p.wrap_s);
        }
        if (y0 >= 0.0 and y0 + 1.0 < pt.fh) {
            r.y0 = @intFromFloat(y0);
            r.y1 = r.y0 + 1;
        } else {
            r.y0 = wrap(y0, pt.wh, p.wrap_t);
            r.y1 = wrap(y0 + 1.0, pt.wh, p.wrap_t);
        }
        r.fx = @intFromFloat(@round((fx - x0) * 256.0));
        r.fy = @intFromFloat(@round((fy - y0) * 256.0));
        return r;
    }

    inline fn nearestAt(pt: *const PrecomputedTex, s: f32, t: f32) [2]u32 {
        const p = pt.cfg;
        const fx = @floor(s * pt.fw);
        const fy = @floor(t * pt.fh);
        const wx: u32 = if (fx >= 0.0 and fx < pt.fw) @intFromFloat(fx) else wrap(fx, pt.ww, p.wrap_s);
        const wy: u32 = if (fy >= 0.0 and fy < pt.fh) @intFromFloat(fy) else wrap(fy, pt.wh, p.wrap_t);
        return .{ wx, wy };
    }

    /// A lookup of a texture not of bytes: 16-bit floats blended as floats (S16F, RGBA64), or
    /// integers not blended (S8, S16): its word, or two (RGBA64).
    fn sampleWide(pt: *const PrecomputedTex, memory: []const u8, s: f32, t: f32) Error!u64 {
        if (pt.cfg.mag_filter == .nearest or pt.unblended) {
            const at = pt.nearestAt(s, t);
            return pt.fetchWide(memory, at[0], at[1]);
        }
        const fp = pt.footprint(s, t);
        const c = [4]u64{
            try pt.fetchWide(memory, fp.x0, fp.y0),
            try pt.fetchWide(memory, fp.x1, fp.y0),
            try pt.fetchWide(memory, fp.x0, fp.y1),
            try pt.fetchWide(memory, fp.x1, fp.y1),
        };
        const ix = 256 - fp.fx;
        const iy = 256 - fp.fy;
        const w = blendWeights(fp.fx, fp.fy, ix, iy);
        const channels: u32 = if (pt.cfg.type == .rgba64) 4 else 1;
        var out: u64 = 0;
        for (0..channels) |ch| {
            const sh: u6 = @intCast(ch * 16);
            var h: [4]f32 = undefined;
            for (&h, c) |*hv, cv| hv.* = f(halfToFloatScalar(@truncate(cv >> sh)));
            const v = ((h[0] * w[0] + h[1] * w[1]) + (h[2] * w[2] + h[3] * w[3])) * (1.0 / 256.0);
            out |= @as(u64, halfOf(u(v))) << sh;
        }
        return out;
    }

    inline fn sample(pt: *const PrecomputedTex, memory: []const u8, s: f32, t: f32) Error!u32 {
        const p = pt.cfg;
        if (!pt.fast) {
            if (pt.float16 or pt.unblended) return @truncate(try pt.sampleWide(memory, s, t));
        }
        if (p.mag_filter == .nearest) {
            const at = pt.nearestAt(s, t);
            return pt.fetchAt(memory, at[0], at[1]);
        }
        const fp = pt.footprint(s, t);
        const wx0 = fp.x0;
        const wx1 = fp.x1;
        const wy0 = fp.y0;
        const wy1 = fp.y1;
        const fx_frac = fp.fx;
        const fy_frac = fp.fy;
        if (fx_frac == 0 and fy_frac == 0) {
            return pt.fetchAt(memory, wx0, wy0);
        }

        const raster = p.type == .rgba32r;
        const same_utile_x = pt.fast and (wx1 == wx0 + 1) and (raster or (wx0 & pt.uw_mask) != pt.uw_mask);
        const same_utile_y = pt.fast and (wy1 == wy0 + 1) and (raster or (wy0 & pt.uh_mask) != pt.uh_mask);

        var c00: u32 = undefined;
        var c10: u32 = undefined;
        var c01: u32 = undefined;
        var c11: u32 = undefined;

        if (same_utile_x and same_utile_y) {
            const off00 = pt.base_off + pt.texelOffset(wx0, wy0);
            const row0 = try pt.fetchPairFromOffset(memory, off00);
            const row1 = try pt.fetchPairFromOffset(memory, off00 + pt.utile_row_stride);
            c00 = row0[0];
            c10 = row0[1];
            c01 = row1[0];
            c11 = row1[1];
        } else if (same_utile_x) {
            const row0 = try pt.fetchPairFromOffset(memory, pt.base_off + pt.texelOffset(wx0, wy0));
            const row1 = if (wy1 == wy0) row0 else try pt.fetchPairFromOffset(memory, pt.base_off + pt.texelOffset(wx0, wy1));
            c00 = row0[0];
            c10 = row0[1];
            c01 = row1[0];
            c11 = row1[1];
        } else if (same_utile_y) {
            const off00 = pt.base_off + pt.texelOffset(wx0, wy0);
            c00 = try pt.fetchFromOffset(memory, off00);
            c01 = try pt.fetchFromOffset(memory, off00 + pt.utile_row_stride);
            if (wx1 == wx0) {
                c10 = c00;
                c11 = c01;
            } else {
                const off10 = pt.base_off + pt.texelOffset(wx1, wy0);
                c10 = try pt.fetchFromOffset(memory, off10);
                c11 = try pt.fetchFromOffset(memory, off10 + pt.utile_row_stride);
            }
        } else {
            c00 = try pt.fetchAt(memory, wx0, wy0);
            if (wx0 == wx1 and wy0 == wy1) return c00;
            c10 = if (wx1 == wx0) c00 else try pt.fetchAt(memory, wx1, wy0);
            c01 = if (wy1 == wy0) c00 else try pt.fetchAt(memory, wx0, wy1);
            c11 = if (wx1 == wx0) c01 else if (wy1 == wy0) c10 else try pt.fetchAt(memory, wx1, wy1);
        }

        if (c00 == c10 and c00 == c01 and c00 == c11) return c00;
        const ix: u32 = 256 - fx_frac;
        const iy: u32 = 256 - fy_frac;
        const w00: u16 = @intCast((ix * iy + 128) >> 8);
        const w10: u16 = @intCast((fx_frac * iy + 128) >> 8);
        const w01: u16 = @intCast((ix * fy_frac + 128) >> 8);
        const w11: u16 = @intCast(256 -| (@as(u32, w00) + w10 + w01));
        const V4U8 = @Vector(4, u8);
        const V4U16 = @Vector(4, u16);
        const v00: V4U16 = @as(V4U8, @bitCast(c00));
        const v10: V4U16 = @as(V4U8, @bitCast(c10));
        const v01: V4U16 = @as(V4U8, @bitCast(c01));
        const v11: V4U16 = @as(V4U8, @bitCast(c11));
        const sum: V4U16 = v00 * @as(V4U16, @splat(w00)) +
            v10 * @as(V4U16, @splat(w10)) +
            v01 * @as(V4U16, @splat(w01)) +
            v11 * @as(V4U16, @splat(w11)) +
            @as(V4U16, @splat(128));
        const out_bytes: V4U8 = @truncate(sum >> @as(@Vector(4, u4), @splat(8)));
        return @bitCast(out_bytes);
    }
};

/// The bilinear filter's weights (in 256ths, summing to 256) for texels (x0, y0), (x1, y0),
/// (x0, y1), (x1, y1), the sample `fx`, `fy` 256ths past (x0, y0); `ix`, `iy` 256 less those.
fn blendWeights(fx: u32, fy: u32, ix: u32, iy: u32) [4]f32 {
    const w00 = (ix * iy + 128) >> 8;
    const w10 = (fx * iy + 128) >> 8;
    const w01 = (ix * fy + 128) >> 8;
    const w11 = 256 -| (w00 + w10 + w01);
    return .{ @floatFromInt(w00), @floatFromInt(w10), @floatFromInt(w01), @floatFromInt(w11) };
}

fn halfToFloatScalar(h: u16) u32 {
    const hf: f16 = @bitCast(h);
    return u(@floatCast(hf));
}

fn expand5(v: u32) u8 {
    return @intCast((v << 3) | (v >> 2));
}

/// A YUV (BT.601, video range) texel as RGB, byte 0 red.
fn yuvToRgb(y: u8, cb: u8, cr: u8) u32 {
    const c: i32 = @as(i32, y) - 16;
    const d: i32 = @as(i32, cb) - 128;
    const e: i32 = @as(i32, cr) - 128;
    const r = std.math.clamp((298 * c + 409 * e + 128) >> 8, 0, 255);
    const g = std.math.clamp((298 * c - 100 * d - 208 * e + 128) >> 8, 0, 255);
    const b = std.math.clamp((298 * c + 516 * d + 128) >> 8, 0, 255);
    return 0xff000000 | @as(u32, @intCast(b)) << 16 | @as(u32, @intCast(g)) << 8 | @as(u32, @intCast(r));
}

/// Texel (`x`, `row`) of an ETC1 block (its 8 bytes as ETC1 has them), as RGB, byte 0 red.
fn etc1Texel(block: *const [8]u8, x: u32, row: u32) u32 {
    const tables = [8][4]i32{
        .{ 2, 8, -2, -8 },       .{ 5, 17, -5, -17 },     .{ 9, 29, -9, -29 },     .{ 13, 42, -13, -42 },
        .{ 18, 60, -18, -60 },   .{ 24, 80, -24, -80 },   .{ 33, 106, -33, -106 }, .{ 47, 183, -47, -183 },
    };
    const diff = block[3] & 2 != 0;
    const flip = block[3] & 1 != 0;
    const second = if (flip) row >= 2 else x >= 2;
    var base: [3]i32 = undefined;
    for (0..3) |ch| {
        const b: u32 = block[ch];
        if (diff) {
            const c1 = b >> 3;
            const delta: i32 = @as(i32, @intCast(b & 7)) - @as(i32, if (b & 4 != 0) 8 else 0);
            const c: u32 = if (second) @intCast((@as(i32, @intCast(c1)) + delta) & 31) else c1;
            base[ch] = @intCast((c << 3) | (c >> 2));
        } else {
            const c = if (second) b & 0xf else b >> 4;
            base[ch] = @intCast(c * 17);
        }
    }
    const table = if (second) (block[3] >> 2) & 7 else block[3] >> 5;
    const bit: u4 = @intCast(x * 4 + row);
    const msb = (std.mem.readInt(u16, block[4..6], .big) >> bit) & 1;
    const lsb = (std.mem.readInt(u16, block[6..8], .big) >> bit) & 1;
    const m = tables[table][msb * 2 + lsb];
    var out: u32 = 0xff000000;
    for (base, 0..) |b, ch| out |= @as(u32, @intCast(std.math.clamp(b + m, 0, 255))) << @intCast(ch * 8);
    return out;
}

pub fn sample(memory: []const u8, p0: u32, p1: u32, s: f32, t: f32) Error!u32 {
    return sampleConfig(memory, texture.decodeConfig(p0, p1), s, t);
}

/// The texture `p0`, `p1` (TMU parameters 0 and 1) as the TMU reads it, a texel a word, row by
/// row: its size, and the bytes of RAM it is read from. Null if it is of a type the TMU doesn't
/// read here (its samples are then 0xff000000), or runs past the end of RAM.
pub const DecodedTexture = struct {
    width: u32,
    height: u32,
    bytes: []const u8,

    pub fn of(memory: []const u8, p0: u32, p1: u32) ?DecodedTexture {
        const pt = PrecomputedTex.init(texture.decodeConfig(p0, p1), memory.len) catch return null;
        // Its texels aren't words of 8-bit channels blended byte by byte.
        if (pt.float16 or pt.unblended) return null;
        const len: usize = pt.len;
        if (@as(usize, pt.base_off) + len > memory.len) return null;
        return .{ .width = pt.cfg.width, .height = pt.cfg.height, .bytes = memory[pt.base_off..][0..len] };
    }

    /// Whether the TMU's lookups of texture `p0`, `p1` are of words of 8-bit channels, blended
    /// byte by byte (as the GPU translations blend `decode`'s words): not of S16F, RGBA64, S8
    /// or S16.
    pub fn blendsBytes(p0: u32, p1: u32) bool {
        return switch (texture.decodeConfig(p0, p1).type) {
            .s16f, .rgba64, .s8, .s16 => false,
            else => true,
        };
    }

    /// Whether the OpenGL translation's TMU samples texture `p0`, `p1` (given s and t alone) as
    /// `sample` does: blended byte by byte, its level of detail not mattering, not a cube map.
    pub fn sampledOnGpu(p0: u32, p1: u32) bool {
        return blendsBytes(p0, p1) and !needsLod(texture.decodeConfig(p0, p1)) and (p0 >> 9) & 1 == 0;
    }

    /// Whether the Metal translation's TMU, reading RAM itself, reads texture `p0`, `p1`: of
    /// the types it decodes (RGBA8888, RGBX8888, RGBA32R, RGB565, luminance, alpha), the right
    /// way up. Other types are 0xff000000 to it, as to `sample`.
    pub fn readInShader(p0: u32, p1: u32) bool {
        const c = texture.decodeConfig(p0, p1);
        if (needsLod(c) or (p0 >> 9) & 1 != 0) return false;
        if (@backingInt(c.wrap_s) >= 2 or @backingInt(c.wrap_t) >= 2) return false;
        return switch (c.type) {
            .rgba8888, .rgbx8888, .rgba32r, .rgb565, .luminance, .alpha => !c.flip_y,
            .rgba4444, .rgba5551, .lumalpha, .etc1, .s16f, .s8, .s16, .bw1, .a4, .a1, .rgba64, .yuv422r => false,
            _ => true,
        };
    }

    /// Decodes it into `out` (`width * height` words), as `sample` fetches each texel.
    pub fn decode(memory: []const u8, p0: u32, p1: u32, out: []u32) bool {
        const pt = PrecomputedTex.init(texture.decodeConfig(p0, p1), memory.len) catch return false;
        const w = pt.cfg.width;
        for (0..pt.cfg.height) |y| {
            for (0..w) |x| {
                out[y * w + x] = pt.fetchAt(memory, @intCast(x), @intCast(y)) catch return false;
            }
        }
        return true;
    }
};

fn sampleConfig(memory: []const u8, p: texture.Config, s: f32, t: f32) Error!u32 {
    const pt = try PrecomputedTex.init(p, memory.len);
    return pt.sample(memory, s, t);
}

/// A texel past the edge, wrapped to the border (its colour instead).
const border_texel: u32 = 0x8000_0000;

fn wrap(coord: f32, size: u32, mode: texture.Wrap) u32 {
    const n: i64 = @max(size, 1);
    const i: i64 = if (std.math.isNan(coord)) 0 else @intFromFloat(std.math.clamp(coord, -1e9, 1e9));
    return switch (mode) {
        .repeat => @intCast(@mod(i, n)),
        .clamp => @intCast(std.math.clamp(i, 0, n - 1)),
        .mirror => blk: {
            const m = @mod(i, 2 * n);
            break :blk @intCast(if (m < n) m else 2 * n - 1 - m);
        },
        .border => if (i < 0 or i >= n) border_texel else @intCast(i),
    };
}

pub fn referenceTexelOffset(width: u32, height: u32, x: u32, y: u32) u32 {
    return referenceTexelOffsetOf(4, width, height, x, y);
}

pub fn referenceTexelOffsetOf(cpp: u32, width: u32, height: u32, x: u32, y: u32) u32 {
    const uw_shift: u5 = if (cpp == 4) 2 else 3;
    const uh_shift: u5 = if (cpp == 1) 3 else 2;
    const uw: u32 = @as(u32, 1) << uw_shift;
    const uh: u32 = @as(u32, 1) << uh_shift;
    const cpp_shift: u5 = switch (cpp) {
        4 => 2,
        2 => 1,
        else => 0,
    };
    const in_utile = (((y & (uh - 1)) << uw_shift) | (x & (uw - 1))) << cpp_shift;
    if (width <= (uw << 2) or height <= (uh << 2)) {
        const utiles_per_row = (width + uw - 1) >> uw_shift;
        return (((y >> uh_shift) * utiles_per_row + (x >> uw_shift)) << 6) + in_utile;
    }
    const tile_w_shift: u5 = uw_shift + 3;
    const tile_h_shift: u5 = uh_shift + 3;
    const tile_w: u32 = @as(u32, 1) << tile_w_shift;
    const tiles_per_row = (width + tile_w - 1) >> tile_w_shift;
    const tile_row = y >> tile_h_shift;
    const tile_col = if ((tile_row & 1) == 0) (x >> tile_w_shift) else tiles_per_row - 1 - (x >> tile_w_shift);
    const tile_base = (tile_row * tiles_per_row + tile_col) << 12;

    const sub_col = (x >> (uw_shift + 2)) & 1;
    const sub_row = (y >> (uh_shift + 2)) & 1;
    const stile_index = (sub_row << 1) | sub_col;
    const even_map = [4]u32{ 0, 3, 1, 2 };
    const odd_map = [4]u32{ 2, 1, 3, 0 };
    const sub_index = if ((tile_row & 1) == 0) even_map[stile_index] else odd_map[stile_index];
    const utile_in_sub = (((y >> uh_shift) & 3) << 2) | ((x >> uw_shift) & 3);
    return tile_base + (sub_index << 10) + (utile_in_sub << 6) + in_utile;
}

pub fn packColor(r: f32, g: f32, b: f32, a: f32) u32 {
    return @as(u32, unorm8(a)) << 24 | @as(u32, unorm8(r)) << 16 | @as(u32, unorm8(g)) << 8 | unorm8(b);
}

test "QPU simulator runs fragment shader" {
    var p: qpu.Program(16) = .{};
    for (0..3) |i| {
        const acc: u3 = @intCast(i);
        p.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(acc), .a = qpu.vary, .b = qpu.frag_w } }));
        p.emit(try qpu.alu(.{ .add = .{ .op = .fadd, .dst = qpu.wr(acc), .a = qpu.r(acc), .b = qpu.r(5) } }));
    }
    const one = qpu.smallImmFloat(1.0);
    p.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = qpu.r(2), .b = one }, .pack = .{ .mul = .@"8a" } }));
    p.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = qpu.r(1), .b = one }, .pack = .{ .mul = .@"8b" } }));
    p.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = qpu.r(0), .b = one }, .pack = .{ .mul = .@"8c" } }));
    p.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = one, .b = one }, .pack = .{ .mul = .@"8d" } }));
    p.emit(try qpu.mov(qpu.tlb_color_all, qpu.r(3)));
    p.end(.fragment);

    const varyings = [_]Vec{ splatF(1.0), splatF(0.5), splatF(0.25) };
    const res = try run(p.code(), .{ .varyings = &varyings, .frag_w = splatF(2.0) });
    try std.testing.expectEqual(packColor(1.0, 0.5, 0.25, 1.0), res.tlb_color.?[0]);
}

test "QPU TMU bilinear same-utile and cross-utile sampling" {
    var mem: [4096]u8 = @splat(0);
    const cfg: texture.Config = .{
        .offset = 0,
        .width = 8,
        .height = 8,
        .type = .rgba8888,
        .mag_filter = .linear,
        .min_filter = .linear,
        .wrap_s = .clamp,
        .wrap_t = .clamp,
    };
    const pt = try PrecomputedTex.init(cfg, mem.len);
    for (0..8) |y| {
        for (0..8) |x| {
            const off = pt.texelOffset(@intCast(x), @intCast(y));
            const color: u32 = 0xff000000 |
                (@as(u32, @intCast(x * 30)) << 16) |
                (@as(u32, @intCast(y * 30)) << 8) |
                @as(u32, @intCast((x + y) * 15));
            std.mem.writeInt(u32, mem[off..][0..4], color, .little);
        }
    }

    // Same-utile sample: between (1, 1) and (2, 2) at midpoint -> s = 2.0/8.0, t = 2.0/8.0
    const s_same = try pt.sample(&mem, 2.0 / 8.0, 2.0 / 8.0);
    // Expected average of (1,1), (2,1), (1,2), (2,2): R = 45, G = 45, B = 45, A = 255
    try std.testing.expectEqual(@as(u32, 0xff2d2d2d), s_same);

    // Cross-utile X & Y sample: between (3, 3) and (4, 4) at midpoint -> s = 4.0/8.0, t = 4.0/8.0
    const s_cross = try pt.sample(&mem, 4.0 / 8.0, 4.0 / 8.0);
    // Expected average of (3,3), (4,3), (3,4), (4,4): R = 105, G = 105, B = 105, A = 255
    try std.testing.expectEqual(@as(u32, 0xff696969), s_cross);
}

test "QPU vectorized v8muld, v8min, v8max, v8adds, v8subs, and shifts" {
    // Exhaustively verify v8muldVec matches (a * b + 127) / 255 for all 65,536 byte pairs
    var a_vec: Vec = undefined;
    var b_vec: Vec = undefined;
    var pair: u32 = 0;
    while (pair < 65536) : (pair += 64) {
        for (0..lanes) |l| {
            var aw: u32 = 0;
            var bw: u32 = 0;
            inline for (0..4) |bi| {
                const idx = pair + @as(u32, @intCast(l * 4 + bi));
                const a8: u32 = idx & 0xff;
                const b8: u32 = (idx >> 8) & 0xff;
                aw |= a8 << @intCast(bi * 8);
                bw |= b8 << @intCast(bi * 8);
            }
            a_vec[l] = aw;
            b_vec[l] = bw;
        }
        const got = mulOpVec(.v8muld, a_vec, b_vec);
        for (0..lanes) |l| {
            var exp: u32 = 0;
            inline for (0..4) |bi| {
                const idx = pair + @as(u32, @intCast(l * 4 + bi));
                const a8: u32 = idx & 0xff;
                const b8: u32 = (idx >> 8) & 0xff;
                exp |= ((a8 * b8 + 127) / 255) << @intCast(bi * 8);
            }
            try std.testing.expectEqual(exp, got[l]);
        }
    }

    const va = splat(0xf080_1005);
    const vb = splat(0x2090_0810);
    try std.testing.expectEqual(@as(u32, 0xffff_1815), addOpVec(.v8adds, va, vb)[0]);
    try std.testing.expectEqual(@as(u32, 0xd000_0800), addOpVec(.v8subs, va, vb)[0]);
    try std.testing.expectEqual(@as(u32, 0x2080_0805), mulOpVec(.v8min, va, vb)[0]);
    try std.testing.expectEqual(@as(u32, 0xf090_1010), mulOpVec(.v8max, va, vb)[0]);
    try std.testing.expectEqual(@as(u32, 0x05f0_8010), addOpVec(.ror, va, splat(8))[0]);
}

test "QPU vectorized ftoi, predicated writes, and TMU FIFO ring wrap-around" {
    var f_in: Vec = splatF(0.0);
    f_in[0] = u(42.9);
    f_in[1] = u(-17.8);
    f_in[2] = u(std.math.nan(f32));
    f_in[3] = u(1e12);
    f_in[4] = u(-1e12);
    const i_out = addOpVec(.ftoi, f_in, f_in);
    try std.testing.expectEqual(@as(i32, 42), @as(i32, @bitCast(i_out[0])));
    try std.testing.expectEqual(@as(i32, -17), @as(i32, @bitCast(i_out[1])));
    try std.testing.expectEqual(@as(i32, 0), @as(i32, @bitCast(i_out[2])));
    try std.testing.expectEqual(@as(i32, 2147483520), @as(i32, @bitCast(i_out[3])));
    try std.testing.expectEqual(@as(i32, -2147483648), @as(i32, @bitCast(i_out[4])));

    // Predicated writes (.zs, .zc, .ns, .nc) across 16 lanes using elem_qpu - 4
    var p: qpu.Program(16) = .{};
    p.emit(try qpu.alu(.{
        .add = .{ .op = .sub, .dst = qpu.wr(0), .a = qpu.ra(qpu.R.elem_qpu), .b = qpu.smallImmInt(4) },
        .sf = true,
    }));
    p.emit(try qpu.loadImm(.{ .add_dst = qpu.wr(1), .value = 0x1111_1111 }));
    p.emit(try qpu.alu(.{
        .add = .{ .op = .@"or", .dst = qpu.wr(1), .a = qpu.smallImmInt(2), .b = qpu.smallImmInt(2), .cond = .zs },
    }));
    p.emit(try qpu.alu(.{
        .add = .{ .op = .@"or", .dst = qpu.wr(1), .a = qpu.smallImmInt(3), .b = qpu.smallImmInt(3), .cond = .ns },
    }));
    p.emit(try qpu.mov(qpu.tlb_color_all, qpu.r(1)));
    p.end(.fragment);

    const res = try run(p.code(), .{});
    const out = res.tlb_color.?;
    for (0..4) |lane| try std.testing.expectEqual(@as(u32, 3), out[lane]); // elem < 4 -> .ns
    try std.testing.expectEqual(@as(u32, 2), out[4]); // elem == 4 -> .zs
    for (5..16) |lane| try std.testing.expectEqual(@as(u32, 0x1111_1111), out[lane]); // elem > 4 -> untouched
}

test "QPU TexCache memoization, nearest coordinate deduplication, and exact texel-center fast path" {
    var mem: [256]u8 = @splat(0);

    const cfg_linear: texture.Config = .{
        .offset = 0,
        .width = 2,
        .height = 2,
        .type = .rgba8888,
        .mag_filter = .linear,
        .min_filter = .linear,
        .wrap_s = .clamp,
        .wrap_t = .clamp,
    };
    const cfg_nearest: texture.Config = .{
        .offset = 0,
        .width = 2,
        .height = 2,
        .type = .rgba8888,
        .mag_filter = .nearest,
        .min_filter = .nearest,
        .wrap_s = .clamp,
        .wrap_t = .clamp,
    };
    const p0 = texture.p0(cfg_linear);
    const p1_nearest = texture.p1(cfg_nearest);

    // Exact texel center at (0.5/2.0, 0.5/2.0) -> (0.25, 0.25) hits texel (0,0) with fx_frac == 0, fy_frac == 0
    const pt_lin = try PrecomputedTex.init(cfg_linear, mem.len);
    std.mem.writeInt(u32, mem[pt_lin.texelOffset(0, 0)..][0..4], 0xff102030, .little);
    std.mem.writeInt(u32, mem[pt_lin.texelOffset(1, 0)..][0..4], 0xff304050, .little);
    std.mem.writeInt(u32, mem[pt_lin.texelOffset(0, 1)..][0..4], 0xff506070, .little);
    std.mem.writeInt(u32, mem[pt_lin.texelOffset(1, 1)..][0..4], 0xff708090, .little);
    try std.testing.expectEqual(@as(u32, 0xff102030), try pt_lin.sample(&mem, 0.25, 0.25));
    try std.testing.expectEqual(@as(u32, 0xff708090), try pt_lin.sample(&mem, 0.75, 0.75));
    // Quarter-way interpolation between (0,0) and (1,0): (3 * 0x10 + 1 * 0x30) / 4 = 0x18, etc.
    try std.testing.expectEqual(@as(u32, 0xff182838), try pt_lin.sample(&mem, 0.375, 0.25));

    // Verify Env.tex_cache is populated and reused across QPU invocations
    var p: qpu.Program(16) = .{};
    p.emit(try qpu.loadImm(.{ .add_dst = .{ .periph = qpu.W.tmu0_t }, .value = u(0.25) }));
    p.emit(try qpu.loadImm(.{ .add_dst = .{ .periph = qpu.W.tmu0_s }, .value = u(0.75) }));
    p.emit(qpu.nop(.load_tmu0));
    p.emit(try qpu.mov(qpu.tlb_color_all, qpu.r(4)));
    p.end(.fragment);

    var decoded_buf: [16]DecodedInst = undefined;
    const decoded = decodeProgram(p.code(), &decoded_buf);
    var shared_cache: [2]TexCache = .{ .{}, .{} };
    const unifs = [_]u32{ p0, p1_nearest };
    const env: Env = .{
        .uniforms = &unifs,
        .texture_memory = &mem,
        .tex_cache = &shared_cache,
    };
    const r1 = try runFragmentDecoded(decoded, &env);
    try std.testing.expect(shared_cache[0].valid);
    try std.testing.expectEqual(p0, shared_cache[0].p0);
    try std.testing.expectEqual(p1_nearest, shared_cache[0].p1);
    for (0..lanes) |l| try std.testing.expectEqual(@as(u32, 0xff304050), r1.tlb_color.?[l]);

    const r2 = try runFragmentDecoded(decoded, &env);
    for (0..lanes) |l| try std.testing.expectEqual(@as(u32, 0xff304050), r2.tlb_color.?[l]);
}

test "QPU fused varying linterp and fast-path fragment shader compilation" {
    // 1. Constant/uniform color shader
    var p_const: qpu.Program(16) = .{};
    p_const.emit(try qpu.mov(qpu.tlb_color_all, qpu.unif));
    p_const.end(.fragment);
    var dec_const_buf: [16]DecodedInst = undefined;
    const dec_const = decodeProgram(p_const.code(), &dec_const_buf);
    const unif_const = [_]u32{0xff112233};
    const fast_const = analyzeFragmentShader(dec_const, &unif_const);
    try std.testing.expectEqual(FastFragKind.constant_color, fast_const.kind);
    try std.testing.expectEqual(@as(u32, 0xff112233), fast_const.color);

    // 2. Smooth-shaded varying RGBA shader with fused varying linterp
    var p_var: qpu.Program(16) = .{};
    for (0..3) |i| {
        const acc: u3 = @intCast(i);
        p_var.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(acc), .a = qpu.vary, .b = qpu.frag_w } }));
        p_var.emit(try qpu.alu(.{ .add = .{ .op = .fadd, .dst = qpu.wr(acc), .a = qpu.r(acc), .b = qpu.r(5) } }));
    }
    const one = qpu.smallImmFloat(1.0);
    p_var.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = qpu.r(2), .b = one }, .pack = .{ .mul = .@"8a" } }));
    p_var.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = qpu.r(1), .b = one }, .pack = .{ .mul = .@"8b" } }));
    p_var.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = qpu.r(0), .b = one }, .pack = .{ .mul = .@"8c" } }));
    p_var.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = one, .b = one }, .pack = .{ .mul = .@"8d" } }));
    p_var.emit(try qpu.mov(qpu.tlb_color_all, qpu.r(3)));
    p_var.end(.fragment);

    var dec_var_buf: [16]DecodedInst = undefined;
    const dec_var = decodeProgram(p_var.code(), &dec_var_buf);
    try std.testing.expect((dec_var[0].flags & DecodedInst.FLAG_FUSED_LINTERP) != 0);
    try std.testing.expect((dec_var[2].flags & DecodedInst.FLAG_FUSED_LINTERP) != 0);
    try std.testing.expect((dec_var[4].flags & DecodedInst.FLAG_FUSED_LINTERP) != 0);

    const fast_var = analyzeFragmentShader(dec_var, &.{});
    try std.testing.expectEqual(FastFragKind.varying_pack_rgba, fast_var.kind);
    try std.testing.expectEqual([4]u8{ 2, 1, 0, 0xff }, fast_var.var_idx);
    try std.testing.expectEqual(@as(u32, 0xff000000), fast_var.color);

    const varyings = [_]Vec{ splatF(1.0), splatF(0.5), splatF(0.25) };
    const env_var: Env = .{ .varyings = &varyings, .frag_w = splatF(2.0) };
    const res_var_fast = try runFragmentFast(fast_var, dec_var, &env_var);
    const res_var_dec = try runFragmentDecoded(dec_var, &env_var);
    try std.testing.expectEqual(res_var_dec.tlb_color.?[0], res_var_fast.tlb_color.?[0]);
    try std.testing.expectEqual(packColor(1.0, 0.5, 0.25, 1.0), res_var_fast.tlb_color.?[0]);

    // 3. Textured compositor blit shader with v8muld modulation
    var mem: [256]u8 = @splat(0);
    const cfg_nearest: texture.Config = .{
        .offset = 0,
        .width = 2,
        .height = 2,
        .type = .rgba8888,
        .mag_filter = .nearest,
        .min_filter = .nearest,
        .wrap_s = .clamp,
        .wrap_t = .clamp,
    };
    const pt = try PrecomputedTex.init(cfg_nearest, mem.len);
    std.mem.writeInt(u32, mem[pt.texelOffset(1, 0)..][0..4], 0xff804020, .little);

    var p_tex: qpu.Program(16) = .{};
    // Interpolate t (varying 0) -> tmu0_t
    p_tex.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(0), .a = qpu.vary, .b = qpu.frag_w } }));
    p_tex.emit(try qpu.alu(.{ .add = .{ .op = .fadd, .dst = .{ .periph = qpu.W.tmu0_t }, .a = qpu.r(0), .b = qpu.r(5) } }));
    // Interpolate s (varying 1) -> tmu0_s
    p_tex.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(1), .a = qpu.vary, .b = qpu.frag_w } }));
    p_tex.emit(try qpu.alu(.{ .add = .{ .op = .fadd, .dst = .{ .periph = qpu.W.tmu0_s }, .a = qpu.r(1), .b = qpu.r(5) } }));
    p_tex.emit(qpu.nop(.load_tmu0));
    p_tex.emit(try qpu.alu(.{ .mul = .{ .op = .v8muld, .dst = qpu.tlb_color_all, .a = qpu.r(4), .b = qpu.unif } }));
    p_tex.end(.fragment);

    var dec_tex_buf: [16]DecodedInst = undefined;
    const dec_tex = decodeProgram(p_tex.code(), &dec_tex_buf);
    const unif_tex = [_]u32{ texture.p0(cfg_nearest), texture.p1(cfg_nearest), 0x80ffffff };
    const fast_tex = analyzeFragmentShader(dec_tex, &unif_tex);
    try std.testing.expectEqual(FastFragKind.tmu0_blit, fast_tex.kind);
    try std.testing.expect(fast_tex.tmu_modulate);
    try std.testing.expectEqual(@as(u32, 0x80ffffff), fast_tex.color);

    const tex_varyings = [_]Vec{ splatF(0.25), splatF(0.75) }; // t=0.25 (y=0), s=0.75 (x=1)
    var shared_cache: [2]TexCache = .{ .{}, .{} };
    const env_tex: Env = .{
        .uniforms = &unif_tex,
        .varyings = &tex_varyings,
        .texture_memory = &mem,
        .tex_cache = &shared_cache,
    };
    const res_tex_fast = try runFragmentFast(fast_tex, dec_tex, &env_tex);
    const res_tex_dec = try runFragmentDecoded(dec_tex, &env_tex);
    try std.testing.expectEqual(res_tex_dec.tlb_color.?[0], res_tex_fast.tlb_color.?[0]);
}

test "a texture decoded as the TMU reads it gives what it samples" {
    // 32 by 32 RGBA, T-format, in RAM from 0x1000.
    var ram: [0x1000 + 32 * 32 * 4]u8 = undefined;
    for (&ram, 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 7);
    const cfg: texture.Config = .{ .offset = 0x1000, .type = .rgba8888, .width = 32, .height = 32, .mag_filter = .nearest };
    const p0 = texture.p0(cfg);
    const p1 = texture.p1(cfg);
    const dt = DecodedTexture.of(&ram, p0, p1).?;
    try std.testing.expectEqual(@as(u32, 32), dt.width);
    try std.testing.expectEqual(@as(usize, 32 * 32 * 4), dt.bytes.len);
    var out: [32 * 32]u32 = undefined;
    try std.testing.expect(DecodedTexture.decode(&ram, p0, p1, &out));
    for (0..32) |y| for (0..32) |x| {
        const s = (@as(f32, @floatFromInt(x)) + 0.5) / 32;
        const t = (@as(f32, @floatFromInt(y)) + 0.5) / 32;
        try std.testing.expectEqual(try sample(&ram, p0, p1, s, t), out[y * 32 + x]);
    };
    // Past the end of RAM: none.
    try std.testing.expect(DecodedTexture.of(ram[0..0x1800], p0, p1) == null);
}

test "TMU decodes every texture type" {
    var mem: [8192]u8 = @splat(0);
    const Case = struct { type: texture.Type, bytes: []const u8, texel: u64 };
    const cases = [_]Case{
        // The top bits to byte 0.
        .{ .type = .rgba4444, .bytes = &.{ 0x34, 0x12 }, .texel = 0x44332211 },
        .{ .type = .rgba5551, .bytes = &.{ 0x01, 0xf8 }, .texel = 0xff0000ff },
        // Luminance in the low byte, alpha the high.
        .{ .type = .lumalpha, .bytes = &.{ 0x40, 0x80 }, .texel = 0x80404040 },
        .{ .type = .s16f, .bytes = &.{ 0x00, 0x3c }, .texel = 0x3c00 },
        .{ .type = .s8, .bytes = &.{0x9a}, .texel = 0x9a },
        .{ .type = .s16, .bytes = &.{ 0x34, 0x12 }, .texel = 0x1234 },
        .{ .type = .bw1, .bytes = &.{0x01}, .texel = 0xffffffff },
        .{ .type = .a4, .bytes = &.{0x0a}, .texel = 0xaa000000 },
        .{ .type = .a1, .bytes = &.{0x01}, .texel = 0xff000000 },
        .{ .type = .rgba64, .bytes = &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, .texel = 0x0807060504030201 },
        // Y 0x80, U and V 0x80 (grey).
        .{ .type = .yuv422r, .bytes = &.{ 0x80, 0x80, 0x10, 0x80 }, .texel = 0xff828282 },
        // Individual colours 0x8 (0x88), table 0, every index 0 (+2).
        .{ .type = .etc1, .bytes = &.{ 0x88, 0x88, 0x88, 0x00, 0, 0, 0, 0 }, .texel = 0xff8a8a8a },
    };
    for (cases) |c| {
        @memset(&mem, 0);
        @memcpy(mem[0..c.bytes.len], c.bytes);
        const pt = try PrecomputedTex.init(.{ .type = c.type, .width = 16, .height = 16, .etc_flip = true }, mem.len);
        try std.testing.expectEqual(c.texel, try pt.fetchWide(&mem, 0, 0));
    }
    // Flipped: row 0 read from the bottom.
    @memset(&mem, 0);
    const flipped = try PrecomputedTex.init(.{ .type = .rgba8888, .width = 4, .height = 4, .flip_y = true }, mem.len);
    std.mem.writeInt(u32, mem[48..52], 0x11223344, .little);
    try std.testing.expectEqual(@as(u32, 0x11223344), try flipped.fetchAt(&mem, 0, 0));
}

test "TMU wraps, cube faces, mipmap levels and levels of detail" {
    // Mirror and border wraps.
    try std.testing.expectEqual(@as(u32, 1), wrap(-2, 4, .mirror));
    try std.testing.expectEqual(@as(u32, 3), wrap(4, 4, .mirror));
    try std.testing.expectEqual(@as(u32, 0), wrap(8, 4, .mirror));
    try std.testing.expectEqual(border_texel, wrap(-1, 4, .border));
    try std.testing.expectEqual(@as(u32, 2), wrap(2, 4, .border));

    // Each axis's face, and the middle of it.
    const faces = [6][3]f32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };
    for (faces, 0..) |d, i| {
        const face, const s, const t = cubeFace(d[0], d[1], d[2]);
        try std.testing.expectEqual(@as(u32, @intCast(i)), face);
        try std.testing.expectEqual(@as(f32, 0.5), s);
        try std.testing.expectEqual(@as(f32, 0.5), t);
    }

    // A 64 square RGBA8888 texture's levels before it: 32 (T format, 4 KiB), then 16 (LT, 1 KiB).
    const c: texture.Config = .{ .offset = 0x10000, .width = 64, .height = 64, .mip_levels = 2 };
    try std.testing.expectEqual(@as(u32, 0x10000 - 4096), levelConfig(c, c.offset, 1, 1 << 20).offset);
    try std.testing.expectEqual(@as(u32, 0x10000 - 4096 - 1024), levelConfig(c, c.offset, 2, 1 << 20).offset);
    // A non-power-of-two texture's levels are of the next power of two's sizes.
    const npot = levelConfig(.{ .offset = 0x10000, .width = 100, .height = 60, .mip_levels = 1 }, 0x10000, 1, 1 << 20);
    try std.testing.expectEqual(@as(u32, 64), npot.width);
    try std.testing.expectEqual(@as(u32, 32), npot.height);

    // Coordinates 4 texels apart across a quad and 2 down: level of detail 2.
    var s: [lanes]f32 = undefined;
    var t: [lanes]f32 = undefined;
    for (0..lanes) |i| {
        s[i] = @floatFromInt((i & 1) * 4);
        t[i] = @floatFromInt(((i >> 1) & 1) * 2);
    }
    for (quadLod(s, t)) |l| try std.testing.expectApproxEqAbs(@as(f32, 2), l, 1e-5);
}

test "TMU general memory lookups read the word at each address" {
    var mem: [64]u8 = undefined;
    for (&mem, 0..) |*b, i| b.* = @intCast(i);
    var addrs: Vec = undefined;
    for (0..lanes) |i| addrs[i] = @intCast((i % 16) * 4);
    const out = directLookup(0, addrs, &.{ .texture_memory = &mem });
    try std.testing.expectEqual(@as(u32, 0x03020100), out[0]);
    try std.testing.expectEqual(@as(u32, 0x07060504), out[1]);
}
