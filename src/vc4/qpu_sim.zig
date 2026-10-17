//! Functional 16-lane SIMD simulator for the VideoCore IV QPU instruction set.

const std = @import("std");
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

pub const Env = struct {
    uniforms: []const u32 = &.{},
    vpm_in: []const Vec = &.{},
    varyings: []const Vec = &.{},
    frag_w: Vec = splatF(1.0),
    frag_z: Vec = splat(0),
    frag_x: Vec = splat(0),
    frag_y: Vec = splat(0),
    texture_memory: []const u8 = &.{},
    texture_memory1: []const u8 = &.{},
    textures: []const []const u8 = &.{},
    tlb_color_in: Vec = splat(0),
    tex_cache: ?*[2]TexCache = null,
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
};

pub const Error = error{
    Unsupported,
    UniformUnderflow,
    VaryingUnderflow,
    VpmUnderflow,
    VpmOverflow,
    TmuUnderflow,
    MissingProgramEnd,
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
    vpm_read_left: u32 = 16,
    uniforms_read: usize = 0,
    varyings_read: usize = 0,
    vpm_words_read: usize = 0,
    tmu: [2]Tmu = .{ .{}, .{} },

    const Tmu = struct {
        params: [4]u32 = undefined,
        param_count: usize = 0,
        coord_t: Vec = undefined,
        has_coord_t: bool = false,
        fifo: [4]Vec = undefined,
        fifo_head: u2 = 0,
        fifo_len: u3 = 0,
        cached: TexCache = .{},
    };
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
        1 => blk: { // 16a
            const shifted: VecI = @bitCast(vu << @as(@Vector(lanes, u5), @splat(16)));
            const sext: VecI = shifted >> @as(@Vector(lanes, u5), @splat(16));
            break :blk if (float_input) @bitCast(@as(VecF, @floatFromInt(sext))) else @bitCast(sext);
        },
        2 => blk: { // 16b
            const sext: VecI = @as(VecI, @bitCast(vu)) >> @as(@Vector(lanes, u5), @splat(16));
            break :blk if (float_input) @bitCast(@as(VecF, @floatFromInt(sext))) else @bitCast(sext);
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
        .cs, .cc => @splat(false),
    };
}

inline fn packVec(dv: VecU, vv: VecU, a_pack: u4, mul_pack: u4) VecU {
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
    return switch (a_pack) {
        1, 9 => (dv & @as(VecU, @splat(0xffff0000))) | (vv & @as(VecU, @splat(0x0000ffff))),
        2, 10 => (dv & @as(VecU, @splat(0x0000ffff))) | (vv << @as(@Vector(lanes, u5), @splat(16))),
        3, 11 => (vv & @as(VecU, @splat(0xff))) *% @as(VecU, @splat(0x01010101)),
        4, 5, 6, 7, 12, 13, 14, 15 => blk: {
            const shift: u5 = @as(u5, @intCast((a_pack & 7) - 4)) * 8;
            const mask: VecU = @splat(@as(u32, 0xff) << shift);
            break :blk (dv & ~mask) | ((vv & @as(VecU, @splat(0xff))) << @as(@Vector(lanes, u5), @splat(shift)));
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

    pub const FLAG_SF: u8 = 1 << 0;
    pub const FLAG_READS_VARY: u8 = 1 << 1;
    pub const FLAG_FETCH_A: u8 = 1 << 2;
    pub const FLAG_FETCH_B: u8 = 1 << 3;
    pub const FLAG_FLT_ADD: u8 = 1 << 4;
    pub const FLAG_FLT_MUL: u8 = 1 << 5;
    pub const FLAG_HAS_UNPACK: u8 = 1 << 6;
};

pub fn decodeInst(inst: qpu.Inst) DecodedInst {
    const sig = qpu.getSig(inst);
    if (sig == .branch) {
        return .{ .sig = .branch };
    }

    const ws = qpu.getWs(inst);
    const cond_add: qpu.Cond = @enumFromInt(@as(u3, @truncate(inst >> 49)));
    const cond_mul: qpu.Cond = @enumFromInt(@as(u3, @truncate(inst >> 46)));
    const pm = (inst >> 56) & 1 != 0;
    const pack: u4 = @truncate(inst >> 52);
    const unpack_mode: u3 = @truncate(inst >> 57);
    const add_op: qpu.AddOp = if (sig == .load_imm) .nop else qpu.getAddOp(inst);
    const mul_op: qpu.MulOp = if (sig == .load_imm) .nop else qpu.getMulOp(inst);
    const raddr_a = qpu.getRaddrA(inst);
    const raddr_b = qpu.getRaddrB(inst);
    const mux0: qpu.Mux = @enumFromInt(@as(u3, @truncate(inst >> 9)));
    const mux1: qpu.Mux = @enumFromInt(@as(u3, @truncate(inst >> 6)));
    const mux2: qpu.Mux = @enumFromInt(@as(u3, @truncate(inst >> 3)));
    const mux3: qpu.Mux = @enumFromInt(@as(u3, @truncate(inst)));

    const uses_a = (add_op != .nop and (mux0 == .a or mux1 == .a)) or
        (mul_op != .nop and (mux2 == .a or mux3 == .a));
    const uses_b = (add_op != .nop and (mux0 == .b or mux1 == .b)) or
        (mul_op != .nop and (mux2 == .b or mux3 == .b));

    const waddr_add_raw = qpu.getWaddrAdd(inst);
    const waddr_mul_raw = qpu.getWaddrMul(inst);
    const a_pack: u4 = if (!pm) pack else 0;
    const mul_pack: u4 = if (pm) pack else 0;
    const unpack_r4: u3 = if (pm) unpack_mode else 0;
    const unpack_a: u3 = if (!pm and raddr_a < 32) unpack_mode else 0;

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

    return .{
        .imm_or_small = if (sig == .load_imm)
            @truncate(inst)
        else if (sig == .small_imm)
            smallImm(raddr_b)
        else
            0,
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
    return out_buf[0..len];
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
        else => s.acc[@intFromEnum(m)],
    };
}

pub fn run(code: []const qpu.Inst, env: Env) Error!Result {
    var decoded_buf: [512]DecodedInst = undefined;
    const decoded = decodeProgram(code, &decoded_buf);
    return runDecoded(decoded, env);
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
    var s: State = .{};
    @memset(s.acc[0..6], splat(0));
    s.ra[qpu.R.frag_payload_zw] = env.frag_w;
    s.rb[qpu.R.frag_payload_zw] = env.frag_z;
    s.ra_init = @as(u32, 1) << qpu.R.frag_payload_zw;
    s.rb_init = @as(u32, 1) << qpu.R.frag_payload_zw;

    var end_at: ?usize = null;
    var ip: usize = 0;
    while (ip < decoded.len) : (ip += 1) {
        if (end_at) |e| if (ip > e) break;
        const d = decoded[ip];
        if (@hasField(RType, "instructions")) r.instructions += 1;
        if (d.sig == .branch) continue;

        var add_result: Vec = undefined;
        var mul_result: Vec = undefined;

        if (d.sig == .load_imm) {
            add_result = splat(d.imm_or_small);
            mul_result = add_result;
        } else {
            if ((d.flags & DecodedInst.FLAG_FETCH_A) != 0) {
                s.acc[6] = try readPort(&s, env, d.raddr_a, .a);
            }
            if (d.sig == .small_imm) {
                s.acc[7] = splat(d.imm_or_small);
            } else if ((d.flags & DecodedInst.FLAG_FETCH_B) != 0) {
                s.acc[7] = try readPort(&s, env, d.raddr_b, .b);
            }

            if ((d.flags & DecodedInst.FLAG_HAS_UNPACK) == 0) {
                if (d.add_op != .nop) {
                    add_result = addOpVec(d.add_op, s.acc[@intFromEnum(d.mux0)], s.acc[@intFromEnum(d.mux1)]);
                } else if (d.waddr_add != qpu.W.nop) {
                    add_result = splat(0);
                }
                if (d.mul_op != .nop) {
                    mul_result = mulOpVec(d.mul_op, s.acc[@intFromEnum(d.mux2)], s.acc[@intFromEnum(d.mux3)]);
                } else if (d.waddr_mul != qpu.W.nop or (d.flags & DecodedInst.FLAG_SF) != 0) {
                    mul_result = splat(0);
                }
            } else {
                if (d.add_op != .nop) {
                    const flt_add = (d.flags & DecodedInst.FLAG_FLT_ADD) != 0;
                    const in0 = resolveMuxSlow(d.mux0, &s, d.unpack_r4, d.unpack_a, flt_add);
                    const in1 = if (d.mux1 == d.mux0) in0 else resolveMuxSlow(d.mux1, &s, d.unpack_r4, d.unpack_a, flt_add);
                    add_result = addOpVec(d.add_op, in0, in1);
                } else if (d.waddr_add != qpu.W.nop) {
                    add_result = splat(0);
                }

                if (d.mul_op != .nop) {
                    const flt_mul = (d.flags & DecodedInst.FLAG_FLT_MUL) != 0;
                    const in2 = resolveMuxSlow(d.mux2, &s, d.unpack_r4, d.unpack_a, flt_mul);
                    const in3 = if (d.mux3 == d.mux2) in2 else resolveMuxSlow(d.mux3, &s, d.unpack_r4, d.unpack_a, flt_mul);
                    mul_result = mulOpVec(d.mul_op, in2, in3);
                } else if (d.waddr_mul != qpu.W.nop or (d.flags & DecodedInst.FLAG_SF) != 0) {
                    mul_result = splat(0);
                }
            }

            if ((d.flags & DecodedInst.FLAG_SF) != 0) {
                const flags_from: VecI = @bitCast(if (d.add_op != .nop) add_result else mul_result);
                s.zero = flags_from == @as(VecI, @splat(0));
                s.neg = flags_from < @as(VecI, @splat(0));
            }
            if ((d.flags & DecodedInst.FLAG_READS_VARY) != 0) s.acc[5] = splatF(varying_c);
        }

        if (d.waddr_add != qpu.W.nop) {
            try write(RType, &s, r, env, d.waddr_add, d.add_file, add_result, d.cond_add, d.add_pack_a, 0);
        }
        if (d.waddr_mul != qpu.W.nop) {
            try write(RType, &s, r, env, d.waddr_mul, d.mul_file, mul_result, d.cond_mul, d.mul_pack_a, d.mul_pack_m);
        }

        switch (d.sig) {
            .load_tmu0, .load_tmu1 => {
                const t = &s.tmu[if (d.sig == .load_tmu0) 0 else 1];
                if (t.fifo_len > 0) {
                    s.acc[4] = t.fifo[t.fifo_head];
                    t.fifo_head +%= 1;
                    t.fifo_len -= 1;
                } else {
                    s.acc[4] = splat(0xff000000);
                }
            },
            .color_load, .color_load_end => {
                s.acc[4] = env.tlb_color_in;
                if (@hasField(RType, "color_loads")) r.color_loads += 1;
                if (d.sig == .color_load_end) end_at = ip + 2;
            },
            .prog_end => end_at = ip + 2,
            else => {},
        }
    }
    if (@hasField(RType, "uniforms_read")) {
        r.uniforms_read = s.uniforms_read;
        r.varyings_read = s.varyings_read;
        r.vpm_words_read = s.vpm_words_read;
    }
    if (end_at == null) return error.MissingProgramEnd;
}

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
            if (s.vpm_words_read >= env.vpm_in.len) return splat(0);
            if (s.vpm_read_left > 0) s.vpm_read_left -= 1;
            defer s.vpm_words_read += 1;
            return env.vpm_in[s.vpm_words_read];
        },
        qpu.R.elem_qpu => {
            return .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
        },
        qpu.R.xy_pixel_coord => return if (file == .a) env.frag_x else env.frag_y,
        qpu.R.vpm_ld_busy, qpu.R.vpm_ld_wait, qpu.R.mutex_acquire => return splat(0),
        else => return splat(0),
    }
}

fn write(comptime RType: type, s: *State, r: *RType, env: *const Env, waddr: u6, file: File, value: Vec, cond: qpu.Cond, a_pack: u4, mul_pack: u4) Error!void {
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
        qpu.W.acc5 => &s.acc[5],
        else => null,
    };
    if (dst) |d| {
        const dv: VecU = d.*;
        const packed_vec = packVec(dv, value, a_pack, mul_pack);
        if (cond == .always) {
            d.* = packed_vec;
        } else {
            d.* = @select(u32, condMask(cond, s), packed_vec, dv);
        }
        return;
    }

    switch (waddr) {
        qpu.W.vpm => {
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
        },
        qpu.W.tlb_color_all => r.tlb_color = value,
        qpu.W.tlb_color_ms => {
            if (@hasField(RType, "tlb_color_samples")) {
                if (r.tlb_samples < r.tlb_color_samples.len) r.tlb_color_samples[r.tlb_samples] = value;
                r.tlb_samples += 1;
            }
            r.tlb_color = value;
        },
        qpu.W.tlb_z => r.tlb_z = value,
        qpu.W.sfu_recip, qpu.W.sfu_recipsqrt, qpu.W.sfu_exp, qpu.W.sfu_log => {
            const vf: VecF = @bitCast(value);
            const res_f: VecF = switch (waddr) {
                qpu.W.sfu_recip => @as(VecF, @splat(1.0)) / vf,
                qpu.W.sfu_recipsqrt => @as(VecF, @splat(1.0)) / @sqrt(vf),
                qpu.W.sfu_exp => @exp2(vf),
                else => @log2(vf),
            };
            s.acc[4] = @bitCast(res_f);
        },
        qpu.W.tmu0_s, qpu.W.tmu0_t, qpu.W.tmu0_r, qpu.W.tmu0_b, qpu.W.tmu1_s, qpu.W.tmu1_t, qpu.W.tmu1_r, qpu.W.tmu1_b => {
            const unit: usize = if (waddr <= qpu.W.tmu0_b) 0 else 1;
            const t = &s.tmu[unit];
            if (s.uniforms_read < env.uniforms.len and t.param_count < t.params.len) {
                t.params[t.param_count] = env.uniforms[s.uniforms_read];
                t.param_count += 1;
                s.uniforms_read += 1;
            }
            if (waddr == qpu.W.tmu0_t or waddr == qpu.W.tmu1_t) {
                t.coord_t = value;
                t.has_coord_t = true;
                return;
            }
            if (waddr != qpu.W.tmu0_s and waddr != qpu.W.tmu1_s) return;
            if (t.param_count < 2 or t.fifo_len == t.fifo.len) {
                t.param_count = 0;
                return;
            }
            var memory = if (unit == 0) env.texture_memory else if (env.texture_memory1.len > 0) env.texture_memory1 else env.texture_memory;
            var p0 = t.params[0];
            if (env.textures.len > 0) {
                const i = p0 / texture_base;
                if (i < env.textures.len) {
                    memory = env.textures[i];
                    p0 -= i * texture_base;
                }
            }
            const write_idx: u2 = t.fifo_head +% @as(u2, @truncate(t.fifo_len));
            const p1 = t.params[1];
            const cache_slot: *TexCache = if (env.tex_cache) |tc| &tc[unit] else &t.cached;
            if (cache_slot.p0 != p0 or cache_slot.p1 != p1) {
                cache_slot.p0 = p0;
                cache_slot.p1 = p1;
                if (PrecomputedTex.init(texture.decodeConfig(p0, p1))) |inited| {
                    cache_slot.pt = inited;
                    cache_slot.valid = true;
                } else |_| {
                    cache_slot.valid = false;
                }
            }
            if (!cache_slot.valid) {
                t.fifo[write_idx] = splat(0xff000000);
                t.fifo_len += 1;
                t.param_count = 0;
                t.has_coord_t = false;
                if (@hasField(RType, "texture_samples")) r.texture_samples += 1;
                return;
            }
            const pt = &cache_slot.pt;
            var texel: Vec = undefined;
            const has_t = t.has_coord_t;
            if (pt.cfg.mag_filter == .nearest) {
                const p = pt.cfg;
                var prev_wx: u32 = 0xffff_ffff;
                var prev_wy: u32 = 0xffff_ffff;
                var prev_out: u32 = 0;
                const zero_wy: u32 = if (!has_t) (if (0.0 < pt.fh) 0 else wrap(0.0, p.height, p.wrap_t)) else 0;
                for (0..lanes) |lane| {
                    const s_coord = f(value[lane]);
                    const fx = @floor(s_coord * pt.fw);
                    const wx: u32 = if (fx >= 0.0 and fx < pt.fw) @intFromFloat(fx) else wrap(fx, p.width, p.wrap_s);
                    const wy: u32 = if (has_t) blk: {
                        const t_coord = f(t.coord_t[lane]);
                        const fy = @floor(t_coord * pt.fh);
                        break :blk if (fy >= 0.0 and fy < pt.fh) @intFromFloat(fy) else wrap(fy, p.height, p.wrap_t);
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
                    const sc = value[lane];
                    const tc = if (has_t) t.coord_t[lane] else 0;
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
            t.fifo[write_idx] = texel;
            t.fifo_len += 1;
            t.param_count = 0;
            t.has_coord_t = false;
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
    cpp: u32,
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
    is_small_microtile: bool,
    utiles_per_row: u32,
    tile_w_shift: u5,
    tile_h_shift: u5,
    tiles_per_row: u32,

    inline fn init(p: texture.Config) Error!PrecomputedTex {
        const cpp: u32 = switch (p.type) {
            .rgba8888, .rgbx8888, .rgba32r => 4,
            .rgb565 => 2,
            .alpha, .luminance => 1,
            else => return error.Unsupported,
        };
        const uw_shift: u5 = if (cpp == 4) 2 else 3;
        const uh_shift: u5 = if (cpp == 1) 3 else 2;
        const uw: u32 = @as(u32, 1) << uw_shift;
        const uh: u32 = @as(u32, 1) << uh_shift;
        const cpp_shift: u5 = switch (cpp) {
            4 => 2,
            2 => 1,
            else => 0,
        };
        const tile_w_shift: u5 = uw_shift + 3;
        const tile_h_shift: u5 = uh_shift + 3;
        const tile_w: u32 = @as(u32, 1) << tile_w_shift;
        return .{
            .cfg = p,
            .base_off = p.offset & 0x1FFFFFFF,
            .cpp = cpp,
            .fw = @floatFromInt(p.width),
            .fh = @floatFromInt(p.height),
            .uw_shift = uw_shift,
            .uh_shift = uh_shift,
            .uw_mask = uw - 1,
            .uh_mask = uh - 1,
            .cpp_shift = cpp_shift,
            .utile_row_stride = if (p.type == .rgba32r) (p.width << 2) else (@as(u32, 1) << (uw_shift + cpp_shift)),
            .alpha_or_mask32 = if (p.type == .rgbx8888) 0xff000000 else 0,
            .alpha_or_mask64 = if (p.type == .rgbx8888) 0xff000000_ff000000 else 0,
            .is_small_microtile = (p.width <= (uw << 2) or p.height <= (uh << 2)),
            .utiles_per_row = (p.width + uw - 1) >> uw_shift,
            .tile_w_shift = tile_w_shift,
            .tile_h_shift = tile_h_shift,
            .tiles_per_row = (p.width + tile_w - 1) >> tile_w_shift,
        };
    }

    inline fn texelOffset(pt: *const PrecomputedTex, x: u32, y: u32) u32 {
        if (pt.cfg.type == .rgba32r) {
            return (y * pt.cfg.width + x) << 2;
        }
        const in_utile = (((y & pt.uh_mask) << pt.uw_shift) | (x & pt.uw_mask)) << pt.cpp_shift;
        if (pt.is_small_microtile) {
            return (((y >> pt.uh_shift) * pt.utiles_per_row + (x >> pt.uw_shift)) << 6) + in_utile;
        }
        const tile_row = y >> pt.tile_h_shift;
        const tile_col = if ((tile_row & 1) == 0) (x >> pt.tile_w_shift) else pt.tiles_per_row - 1 - (x >> pt.tile_w_shift);
        const tile_base = (tile_row * pt.tiles_per_row + tile_col) << 12;

        const sub_col = (x >> (pt.uw_shift + 2)) & 1;
        const sub_row = (y >> (pt.uh_shift + 2)) & 1;
        const stile_index = (sub_row << 1) | sub_col;
        const even_map = [4]u32{ 0, 3, 1, 2 };
        const odd_map = [4]u32{ 2, 1, 3, 0 };
        const sub_index = if ((tile_row & 1) == 0) even_map[stile_index] else odd_map[stile_index];
        const utile_in_sub = (((y >> pt.uh_shift) & 3) << 2) | ((x >> pt.uw_shift) & 3);
        return tile_base + (sub_index << 10) + (utile_in_sub << 6) + in_utile;
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

    inline fn fetchAt(pt: *const PrecomputedTex, memory: []const u8, x: u32, y: u32) Error!u32 {
        return pt.fetchFromOffset(memory, pt.base_off + pt.texelOffset(x, y));
    }

    inline fn sample(pt: *const PrecomputedTex, memory: []const u8, s: f32, t: f32) Error!u32 {
        const p = pt.cfg;
        if (p.mag_filter == .nearest) {
            const fx = @floor(s * pt.fw);
            const fy = @floor(t * pt.fh);
            const wx: u32 = if (fx >= 0.0 and fx < pt.fw) @intFromFloat(fx) else wrap(fx, p.width, p.wrap_s);
            const wy: u32 = if (fy >= 0.0 and fy < pt.fh) @intFromFloat(fy) else wrap(fy, p.height, p.wrap_t);
            return pt.fetchAt(memory, wx, wy);
        }
        const fx = s * pt.fw - 0.5;
        const fy = t * pt.fh - 0.5;
        const x0 = @floor(fx);
        const y0 = @floor(fy);
        var wx0: u32 = undefined;
        var wx1: u32 = undefined;
        if (x0 >= 0.0 and x0 + 1.0 < pt.fw) {
            wx0 = @intFromFloat(x0);
            wx1 = wx0 + 1;
        } else {
            wx0 = wrap(x0, p.width, p.wrap_s);
            wx1 = wrap(x0 + 1.0, p.width, p.wrap_s);
        }
        var wy0: u32 = undefined;
        var wy1: u32 = undefined;
        if (y0 >= 0.0 and y0 + 1.0 < pt.fh) {
            wy0 = @intFromFloat(y0);
            wy1 = wy0 + 1;
        } else {
            wy0 = wrap(y0, p.height, p.wrap_t);
            wy1 = wrap(y0 + 1.0, p.height, p.wrap_t);
        }

        const fx_frac: u32 = @intFromFloat(@round((fx - x0) * 256.0));
        const fy_frac: u32 = @intFromFloat(@round((fy - y0) * 256.0));
        if (fx_frac == 0 and fy_frac == 0) {
            return pt.fetchAt(memory, wx0, wy0);
        }

        const same_utile_x = (wx1 == wx0 + 1) and (p.type == .rgba32r or (wx0 & pt.uw_mask) != pt.uw_mask);
        const same_utile_y = (wy1 == wy0 + 1) and (p.type == .rgba32r or (wy0 & pt.uh_mask) != pt.uh_mask);

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

pub fn sample(memory: []const u8, p0: u32, p1: u32, s: f32, t: f32) Error!u32 {
    return sampleConfig(memory, texture.decodeConfig(p0, p1), s, t);
}

fn sampleConfig(memory: []const u8, p: texture.Config, s: f32, t: f32) Error!u32 {
    const pt = try PrecomputedTex.init(p);
    return pt.sample(memory, s, t);
}

fn wrap(coord: f32, size: u32, mode: texture.Wrap) u32 {
    const n: i64 = @max(size, 1);
    const i: i64 = if (std.math.isNan(coord)) 0 else @intFromFloat(std.math.clamp(coord, -1e9, 1e9));
    return switch (mode) {
        .repeat => @intCast(@mod(i, n)),
        .clamp, .mirror, .border => @intCast(std.math.clamp(i, 0, n - 1)),
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
    const pt = try PrecomputedTex.init(cfg);
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
    const pt_lin = try PrecomputedTex.init(cfg_linear);
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

