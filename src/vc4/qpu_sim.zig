//! Functional 16-lane SIMD simulator for the VideoCore IV QPU instruction set.

const std = @import("std");
const qpu = @import("qpu.zig");
const texture = @import("texture.zig");
const pixel = @import("format.zig");

pub const lanes = 16;
pub const Vec = [lanes]u32;

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
    ra: [32]Vec = std.mem.zeroes([32]Vec),
    rb: [32]Vec = std.mem.zeroes([32]Vec),
    acc: [6]Vec = std.mem.zeroes([6]Vec),
    zero: [lanes]bool = @splat(false),
    neg: [lanes]bool = @splat(false),
    vpm_read_left: u32 = 16,
    tmu: [2]Tmu = .{ .{}, .{} },

    const Tmu = struct {
        params: [4]u32 = undefined,
        param_count: usize = 0,
        coord_t: Vec = splat(0),
        fifo: [4]Vec = undefined,
        fifo_len: usize = 0,
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

fn unpack(v: u32, mode: u3, float_input: bool) Error!u32 {
    return switch (mode) {
        0 => v,
        1 => blk: { // 16a
            const lo: i16 = @bitCast(@as(u16, @truncate(v)));
            break :blk if (float_input) u(@as(f32, @floatFromInt(lo))) else @bitCast(@as(i32, lo));
        },
        2 => blk: { // 16b
            const hi: i16 = @bitCast(@as(u16, @truncate(v >> 16)));
            break :blk if (float_input) u(@as(f32, @floatFromInt(hi))) else @bitCast(@as(i32, hi));
        },
        3 => blk: { // 8d_rep
            const byte: u8 = @truncate(v >> 24);
            break :blk @as(u32, byte) * 0x01010101;
        },
        4, 5, 6, 7 => blk: {
            const byte: u8 = @truncate(v >> (@as(u5, mode - 4) * 8));
            break :blk if (float_input) u(@as(f32, @floatFromInt(byte)) / 255.0) else byte;
        },
    };
}

fn ftoi(x: f32) u32 {
    if (std.math.isNan(x)) return 0;
    const clamped = std.math.clamp(x, -2147483648.0, 2147483520.0);
    return @bitCast(@as(i32, @intFromFloat(@trunc(clamped))));
}

fn addOp(op: qpu.AddOp, a: u32, b: u32) Error!u32 {
    const ai: i32 = @bitCast(a);
    const bi: i32 = @bitCast(b);
    return switch (op) {
        .nop => 0,
        .fadd => u(f(a) + f(b)),
        .fsub => u(f(a) - f(b)),
        .fmin => u(@min(f(a), f(b))),
        .fmax => u(@max(f(a), f(b))),
        .fminabs => u(@min(@abs(f(a)), @abs(f(b)))),
        .fmaxabs => u(@max(@abs(f(a)), @abs(f(b)))),
        .ftoi => ftoi(f(a)),
        .itof => u(@floatFromInt(ai)),
        .add => a +% b,
        .sub => a -% b,
        .shr => a >> @truncate(b),
        .asr => @bitCast(ai >> @truncate(b)),
        .ror => std.math.rotr(u32, a, @as(u5, @truncate(b))),
        .shl => a << @truncate(b),
        .min => @bitCast(@min(ai, bi)),
        .max => @bitCast(@max(ai, bi)),
        .@"and" => a & b,
        .@"or" => a | b,
        .xor => a ^ b,
        .not => ~a,
        .clz => @clz(a),
        .v8adds => blk: {
            var res: u32 = 0;
            for (0..4) |i| {
                const shift: u5 = @intCast(i * 8);
                const ba: u16 = @truncate((a >> shift) & 0xff);
                const bb: u16 = @truncate((b >> shift) & 0xff);
                res |= @as(u32, @min(ba + bb, 255)) << shift;
            }
            break :blk res;
        },
        .v8subs => blk: {
            var res: u32 = 0;
            for (0..4) |i| {
                const shift: u5 = @intCast(i * 8);
                const ba: i16 = @intCast((a >> shift) & 0xff);
                const bb: i16 = @intCast((b >> shift) & 0xff);
                res |= @as(u32, @intCast(@max(ba - bb, 0))) << shift;
            }
            break :blk res;
        },
        else => 0,
    };
}

fn mulOp(op: qpu.MulOp, a: u32, b: u32) Error!u32 {
    return switch (op) {
        .nop => 0,
        .fmul => u(f(a) * f(b)),
        .mul24 => (a & 0xffffff) *% (b & 0xffffff),
        .v8muld => blk: {
            var res: u32 = 0;
            for (0..4) |i| {
                const shift: u5 = @intCast(i * 8);
                const ba: u32 = (a >> shift) & 0xff;
                const bb: u32 = (b >> shift) & 0xff;
                res |= ((ba * bb + 127) / 255) << shift;
            }
            break :blk res;
        },
        .v8min => blk: {
            var res: u32 = 0;
            for (0..4) |i| {
                const shift: u5 = @intCast(i * 8);
                res |= @min((a >> shift) & 0xff, (b >> shift) & 0xff) << shift;
            }
            break :blk res;
        },
        .v8max => blk: {
            var res: u32 = 0;
            for (0..4) |i| {
                const shift: u5 = @intCast(i * 8);
                res |= @max((a >> shift) & 0xff, (b >> shift) & 0xff) << shift;
            }
            break :blk res;
        },
        .v8adds => addOp(.v8adds, a, b),
        .v8subs => addOp(.v8subs, a, b),
    };
}

pub fn smallImm(v: u6) u32 {
    return switch (v) {
        0...15 => v,
        16...31 => @bitCast(@as(i32, v) - 32),
        32...39 => u(std.math.pow(f32, 2.0, @floatFromInt(@as(i32, v) - 32))),
        40...47 => u(std.math.pow(f32, 2.0, @floatFromInt(@as(i32, v) - 48))),
        else => 0,
    };
}

fn unorm8(x: f32) u8 {
    const c = std.math.clamp(x, 0.0, 1.0);
    return @intFromFloat(@round(c * 255.0));
}

fn condPasses(cond: qpu.Cond, s: *const State, lane: usize) bool {
    return switch (cond) {
        .never => false,
        .always => true,
        .zs => s.zero[lane],
        .zc => !s.zero[lane],
        .ns => s.neg[lane],
        .nc => !s.neg[lane],
        .cs, .cc => false,
    };
}

pub fn run(code: []const qpu.Inst, env: Env) Error!Result {
    var s: State = .{};
    var r: Result = .{};
    s.ra[qpu.R.frag_payload_zw] = env.frag_w;
    s.rb[qpu.R.frag_payload_zw] = env.frag_z;

    var end_at: ?usize = null;
    var ip: usize = 0;
    while (ip < code.len) : (ip += 1) {
        if (end_at) |e| if (ip > e) break;
        const inst = code[ip];
        r.instructions += 1;
        const sig = qpu.getSig(inst);
        if (sig == .branch) continue;

        const ws = qpu.getWs(inst);
        const cond_add: qpu.Cond = @enumFromInt(@as(u3, @truncate(inst >> 49)));
        const cond_mul: qpu.Cond = @enumFromInt(@as(u3, @truncate(inst >> 46)));
        const pm = (inst >> 56) & 1 != 0;
        const pack: u4 = @truncate(inst >> 52);
        const unpack_mode: u3 = @truncate(inst >> 57);

        var add_result: Vec = undefined;
        var mul_result: Vec = undefined;
        const add_op: qpu.AddOp = if (sig == .load_imm) .nop else qpu.getAddOp(inst);
        const mul_op: qpu.MulOp = if (sig == .load_imm) .nop else qpu.getMulOp(inst);

        if (sig == .load_imm) {
            add_result = splat(@truncate(inst));
            mul_result = add_result;
        } else {
            const raddr_a = qpu.getRaddrA(inst);
            const raddr_b = qpu.getRaddrB(inst);
            const muxes = [4]qpu.Mux{
                @enumFromInt(@as(u3, @truncate(inst >> 9))),
                @enumFromInt(@as(u3, @truncate(inst >> 6))),
                @enumFromInt(@as(u3, @truncate(inst >> 3))),
                @enumFromInt(@as(u3, @truncate(inst))),
            };

            const uses_a = (add_op != .nop and (muxes[0] == .a or muxes[1] == .a)) or
                (mul_op != .nop and (muxes[2] == .a or muxes[3] == .a));
            const uses_b = (add_op != .nop and (muxes[0] == .b or muxes[1] == .b)) or
                (mul_op != .nop and (muxes[2] == .b or muxes[3] == .b));

            const va: Vec = if (uses_a or raddr_a < 32) try readPort(&s, &r, env, raddr_a, .a) else splat(0);
            const vb: Vec = if (sig == .small_imm)
                splat(smallImm(raddr_b))
            else if (uses_b or raddr_b < 32)
                try readPort(&s, &r, env, raddr_b, .b)
            else
                splat(0);

            const old_r4 = s.acc[4];
            const reads_vary = (uses_a and raddr_a == qpu.R.vary) or (sig != .small_imm and uses_b and raddr_b == qpu.R.vary);

            for (0..lanes) |lane| {
                var in: [4]u32 = undefined;
                for (muxes, 0..) |m, i| {
                    const float_input = if (i < 2) isFloatInputAdd(add_op) else isFloatInputMul(mul_op);
                    in[i] = switch (m) {
                        .r0, .r1, .r2, .r3, .r5 => s.acc[@intFromEnum(m)][lane],
                        .r4 => if (pm) try unpack(old_r4[lane], unpack_mode, float_input) else old_r4[lane],
                        .a => if (!pm and raddr_a < 32) try unpack(va[lane], unpack_mode, float_input) else va[lane],
                        .b => vb[lane],
                    };
                }
                add_result[lane] = try addOp(add_op, in[0], in[1]);
                mul_result[lane] = try mulOp(mul_op, in[2], in[3]);
            }

            if (inst & (1 << 45) != 0) {
                const flags_from = if (add_op != .nop) add_result else mul_result;
                for (0..lanes) |lane| {
                    s.zero[lane] = flags_from[lane] == 0;
                    s.neg[lane] = @as(i32, @bitCast(flags_from[lane])) < 0;
                }
            }
            if (reads_vary) s.acc[5] = splatF(varying_c);
        }

        const waddr_add = qpu.getWaddrAdd(inst);
        const waddr_mul = qpu.getWaddrMul(inst);
        const a_pack: u4 = if (!pm) pack else 0;
        const mul_pack: u4 = if (pm) pack else 0;
        try write(&s, &r, env, waddr_add, if (ws) .b else .a, add_result, cond_add, if (!ws) a_pack else 0, 0);
        try write(&s, &r, env, waddr_mul, if (ws) .a else .b, mul_result, cond_mul, if (ws) a_pack else 0, mul_pack);

        switch (sig) {
            .load_tmu0, .load_tmu1 => {
                const t = &s.tmu[if (sig == .load_tmu0) 0 else 1];
                if (t.fifo_len > 0) {
                    s.acc[4] = t.fifo[0];
                    std.mem.copyForwards(Vec, t.fifo[0 .. t.fifo_len - 1], t.fifo[1..t.fifo_len]);
                    t.fifo_len -= 1;
                } else {
                    s.acc[4] = splat(0xff000000);
                }
            },
            .color_load, .color_load_end => {
                s.acc[4] = env.tlb_color_in;
                r.color_loads += 1;
                if (sig == .color_load_end) end_at = ip + 2;
            },
            .prog_end => end_at = ip + 2,
            else => {},
        }
    }
    if (end_at == null) return error.MissingProgramEnd;
    return r;
}

const File = enum { a, b };

fn readPort(s: *State, r: *Result, env: Env, raddr: u6, file: File) Error!Vec {
    if (raddr < 32) return if (file == .a) s.ra[raddr] else s.rb[raddr];
    switch (raddr) {
        qpu.R.nop => return splat(0),
        qpu.R.unif => {
            if (r.uniforms_read >= env.uniforms.len) return splat(0);
            defer r.uniforms_read += 1;
            return splat(env.uniforms[r.uniforms_read]);
        },
        qpu.R.vary => {
            if (r.varyings_read >= env.varyings.len) return splat(0);
            defer r.varyings_read += 1;
            var v: Vec = undefined;
            for (&v, env.varyings[r.varyings_read], env.frag_w) |*out, value, w|
                out.* = u((f(value) - varying_c) / f(w));
            return v;
        },
        qpu.R.vpm => {
            if (r.vpm_words_read >= env.vpm_in.len) return splat(0);
            if (s.vpm_read_left > 0) s.vpm_read_left -= 1;
            defer r.vpm_words_read += 1;
            return env.vpm_in[r.vpm_words_read];
        },
        qpu.R.elem_qpu => {
            var v: Vec = undefined;
            for (&v, 0..) |*e, i| e.* = @intCast(i);
            return v;
        },
        qpu.R.xy_pixel_coord => return if (file == .a) env.frag_x else env.frag_y,
        qpu.R.vpm_ld_busy, qpu.R.vpm_ld_wait, qpu.R.mutex_acquire => return splat(0),
        else => return splat(0),
    }
}

fn write(s: *State, r: *Result, env: Env, waddr: u6, file: File, value: Vec, cond: qpu.Cond, a_pack: u4, mul_pack: u4) Error!void {
    if (waddr == qpu.W.nop or cond == .never) return;

    const dst: ?*Vec = switch (waddr) {
        0...31 => if (file == .a) &s.ra[waddr] else &s.rb[waddr],
        qpu.W.acc0...qpu.W.acc0 + 3 => &s.acc[waddr - qpu.W.acc0],
        qpu.W.acc5 => &s.acc[5],
        else => null,
    };
    if (dst) |d| {
        for (0..lanes) |lane| {
            if (!condPasses(cond, s, lane)) continue;
            const v = value[lane];
            d[lane] = switch (a_pack) {
                0 => switch (mul_pack) {
                    0 => v,
                    4, 5, 6, 7 => blk: {
                        const shift: u5 = @as(u5, @intCast(mul_pack - 4)) * 8;
                        const mask = @as(u32, 0xff) << shift;
                        break :blk (d[lane] & ~mask) | (@as(u32, unorm8(f(v))) << shift);
                    },
                    3 => @as(u32, unorm8(f(v))) * 0x01010101,
                    else => v,
                },
                1, 9 => (d[lane] & 0xffff0000) | (v & 0xffff),
                2, 10 => (d[lane] & 0x0000ffff) | (v << 16),
                3, 11 => (v & 0xff) * 0x01010101,
                4, 5, 6, 7, 12, 13, 14, 15 => blk: {
                    const idx: u5 = @intCast((a_pack & 7) - 4);
                    const shift: u5 = idx * 8;
                    const mask = @as(u32, 0xff) << shift;
                    break :blk (d[lane] & ~mask) | ((v & 0xff) << shift);
                },
                else => v,
            };
        }
        return;
    }

    switch (waddr) {
        qpu.W.vpm => {
            if (r.vpm_out_len < max_vpm_out) {
                r.vpm_out[r.vpm_out_len] = value;
                r.vpm_out_len += 1;
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
            if (r.tlb_samples < r.tlb_color_samples.len) r.tlb_color_samples[r.tlb_samples] = value;
            r.tlb_samples += 1;
            r.tlb_color = value;
        },
        qpu.W.tlb_z => r.tlb_z = value,
        qpu.W.sfu_recip, qpu.W.sfu_recipsqrt, qpu.W.sfu_exp, qpu.W.sfu_log => {
            for (&s.acc[4], value) |*o, v| o.* = u(switch (waddr) {
                qpu.W.sfu_recip => 1.0 / f(v),
                qpu.W.sfu_recipsqrt => 1.0 / @sqrt(@max(f(v), 1e-20)),
                qpu.W.sfu_exp => std.math.exp2(f(v)),
                else => std.math.log2(@max(f(v), 1e-20)),
            });
        },
        qpu.W.tmu0_s, qpu.W.tmu0_t, qpu.W.tmu0_r, qpu.W.tmu0_b, qpu.W.tmu1_s, qpu.W.tmu1_t, qpu.W.tmu1_r, qpu.W.tmu1_b => {
            const unit: usize = if (waddr <= qpu.W.tmu0_b) 0 else 1;
            const t = &s.tmu[unit];
            if (r.uniforms_read < env.uniforms.len and t.param_count < t.params.len) {
                t.params[t.param_count] = env.uniforms[r.uniforms_read];
                t.param_count += 1;
                r.uniforms_read += 1;
            }
            if (waddr == qpu.W.tmu0_t or waddr == qpu.W.tmu1_t) {
                t.coord_t = value;
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
            var texel: Vec = undefined;
            for (&texel, value, t.coord_t) |*o, sc, tc|
                o.* = sample(memory, p0, t.params[1], f(sc), f(tc)) catch 0xff000000;
            t.fifo[t.fifo_len] = texel;
            t.fifo_len += 1;
            t.param_count = 0;
            t.coord_t = splat(0);
            r.texture_samples += 1;
        },
        else => {},
    }
}

pub const texture_base: u32 = 1 << 28;

pub fn sample(memory: []const u8, p0: u32, p1: u32, s: f32, t: f32) Error!u32 {
    const p = texture.decodeConfig(p0, p1);
    const cpp: u32 = switch (p.type) {
        .rgba8888, .rgbx8888, .rgba32r => 4,
        .rgb565 => 2,
        .alpha, .luminance => 1,
        else => return error.Unsupported,
    };
    const w: f32 = @floatFromInt(p.width);
    const h: f32 = @floatFromInt(p.height);
    if (p.mag_filter == .nearest) return fetch(memory, p, cpp, try wrap(@floor(s * w), p.width, p.wrap_s), try wrap(@floor(t * h), p.height, p.wrap_t));
    const fx = s * w - 0.5;
    const fy = t * h - 0.5;
    const x0 = @floor(fx);
    const y0 = @floor(fy);
    const ax = fx - x0;
    const ay = fy - y0;
    var out: u32 = 0;
    var c: [4]u32 = undefined;
    for (0..4) |k| {
        const x = try wrap(x0 + @as(f32, @floatFromInt(k & 1)), p.width, p.wrap_s);
        const y = try wrap(y0 + @as(f32, @floatFromInt(k >> 1)), p.height, p.wrap_t);
        c[k] = try fetch(memory, p, cpp, x, y);
    }
    for (0..4) |byte| {
        const sh: u5 = @intCast(byte * 8);
        var v: f32 = 0;
        for (c, [4]f32{ (1 - ax) * (1 - ay), ax * (1 - ay), (1 - ax) * ay, ax * ay }) |cc, k| v += @as(f32, @floatFromInt(cc >> sh & 0xff)) * k;
        out |= @as(u32, @intFromFloat(@round(v))) << sh;
    }
    return out;
}

fn fetch(memory: []const u8, p: texture.Config, cpp: u32, x: u32, y: u32) Error!u32 {
    const base_off = p.offset & 0x1FFFFFFF;
    const tex_off = if (p.type == .rgba32r)
        (y * p.width + x) * 4
    else
        referenceTexelOffsetOf(cpp, p.width, p.height, x, y);
    const offset = base_off + tex_off;
    if (offset + cpp > memory.len) return error.Unsupported;
    if (cpp == 4) {
        const raw = std.mem.readInt(u32, memory[offset..][0..4], .little);
        return if (p.type == .rgbx8888) (raw | 0xff000000) else raw;
    }
    if (cpp == 1) {
        if (p.type == .luminance) {
            const l: u32 = memory[offset];
            return 0xff000000 | (l << 16) | (l << 8) | l;
        }
        return @as(u32, memory[offset]) << 24;
    }
    return pixel.fromRgb565(std.mem.readInt(u16, memory[offset..][0..2], .little));
}

fn wrap(coord: f32, size: u32, mode: texture.Wrap) Error!u32 {
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
    const uw: u32 = if (cpp == 4) 4 else 8;
    const uh: u32 = if (cpp == 1) 8 else 4;
    const in_utile = ((y % uh) * uw + (x % uw)) * cpp;
    if (width <= 4 * uw or height <= 4 * uh) {
        const utiles_per_row = (width + uw - 1) / uw;
        return ((y / uh) * utiles_per_row + x / uw) * 64 + in_utile;
    }
    const tile_w = 8 * uw;
    const tile_h = 8 * uh;
    const tiles_per_row = (width + tile_w - 1) / tile_w;
    const tile_row = y / tile_h;
    const tile_col = if (tile_row % 2 == 0) x / tile_w else tiles_per_row - 1 - x / tile_w;
    const tile_base = (tile_row * tiles_per_row + tile_col) * 4096;

    const sub_col = (x / (4 * uw)) % 2;
    const sub_row = (y / (4 * uh)) % 2;
    const Pos = struct { col: u32, row: u32 };
    const even = [4]Pos{ .{ .col = 0, .row = 0 }, .{ .col = 0, .row = 1 }, .{ .col = 1, .row = 1 }, .{ .col = 1, .row = 0 } };
    const odd = [4]Pos{ .{ .col = 1, .row = 1 }, .{ .col = 1, .row = 0 }, .{ .col = 0, .row = 0 }, .{ .col = 0, .row = 1 } };
    const order = if (tile_row % 2 == 0) &even else &odd;
    var sub_index: u32 = 0;
    for (order, 0..) |pos, i| {
        if (pos.col == sub_col and pos.row == sub_row) sub_index = @intCast(i);
    }
    const utile_in_sub = ((y / uh) % 4) * 4 + (x / uw) % 4;
    return tile_base + sub_index * 1024 + utile_in_sub * 64 + in_utile;
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
