const std = @import("std");
const qpu = @import("qpu.zig");
const qpu_sim = @import("qpu_sim.zig");

/// Metadata extracted when translating a QPU shader to GLSL.
pub const TranslatedShader = struct {
    glsl_len: usize = 0,
    glsl_buf: [16384]u8 = undefined,
    num_uniforms: usize = 0,
    num_vpm_reads: usize = 0,
    num_vpm_writes: usize = 0,
    num_varyings: usize = 0,
    uses_color_load: bool = false,
    tmu_p0_uniform_idx: [2]?usize = .{ null, null },
    tmu_p1_uniform_idx: [2]?usize = .{ null, null },

    pub fn glsl(self: *const TranslatedShader) []const u8 {
        return self.glsl_buf[0..self.glsl_len];
    }
};

const Builder = struct {
    buf: []u8,
    len: usize = 0,

    fn print(self: *Builder, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(self.buf[self.len..], fmt, args) catch return;
        self.len += s.len;
    }

    fn append(self: *Builder, s: []const u8) void {
        const n = @min(s.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len .. self.len + n], s[0..n]);
        self.len += n;
    }
};

/// Translates a VideoCore IV QPU shader (`vertex` or `fragment`) into `#version 330 core` GLSL.
pub fn translate(code: []const qpu.Inst, stage: qpu.Stage) TranslatedShader {
    var out: TranslatedShader = .{};
    var b = Builder{ .buf = &out.glsl_buf };

    b.append("#version 330 core\n");
    b.append("uniform uint u_unif[128];\n");
    if (stage == .vertex) {
        b.append("uniform vec4 u_viewport;\n"); // (vp_x, vp_y, width, height)
        b.append("in uint v_attr0;\nin uint v_attr1;\nin uint v_attr2;\nin uint v_attr3;\n");
        b.append("in uint v_attr4;\nin uint v_attr5;\nin uint v_attr6;\nin uint v_attr7;\n");
        b.append("out vec4 v_vary0;\nout vec4 v_vary1;\n");
    } else {
        b.append("uniform sampler2D u_tex0;\n");
        b.append("uniform sampler2D u_tex1;\n");
        b.append("uniform sampler2D u_tlb_tex;\n");
        b.append("in vec4 v_vary0;\nin vec4 v_vary1;\n");
        b.append("layout(location = 0) out vec4 o_color;\n");
    }

    // Helper functions for QPU pack/unpack/float conversions
    b.append(
        \\uint f2u(float x) { return floatBitsToUint(x); }
        \\float u2f(uint x) { return uintBitsToFloat(x); }
        \\uint unpack8(uint v, uint b, bool flt) {
        \\  uint byte_val = (v >> (b * 8u)) & 0xffu;
        \\  return flt ? f2u(float(byte_val) / 255.0) : byte_val;
        \\}
        \\uint packMul8(uint dst, uint val, uint b) {
        \\  uint u8v = uint(clamp(round(u2f(val) * 255.0), 0.0, 255.0));
        \\  uint sh = b * 8u;
        \\  return (dst & ~(0xffu << sh)) | (u8v << sh);
        \\}
        \\uint packBgra(vec4 rgba) {
        \\  uvec4 c = uvec4(clamp(round(rgba * 255.0), 0.0, 255.0));
        \\  return (c.a << 24u) | (c.r << 16u) | (c.g << 8u) | c.b;
        \\}
        \\
    );

    b.append("void main() {\n");
    b.append("  uint ra[32]; for (int i = 0; i < 32; ++i) ra[i] = 0u;\n");
    b.append("  uint rb[32]; for (int i = 0; i < 32; ++i) rb[i] = 0u;\n");
    b.append("  uint r0 = 0u, r1 = 0u, r2 = 0u, r3 = 0u, r4 = 0u, r5 = 0u;\n");
    b.append("  bool flag_z = false, flag_n = false;\n");
    b.append("  uint tmu0_s = 0u, tmu0_t = 0u, tmu1_s = 0u, tmu1_t = 0u;\n");
    b.append("  uint tmu0_fifo = 0u, tmu1_fifo = 0u;\n");

    if (stage == .vertex) {
        b.append("  uint vpm_in[8] = uint[8](v_attr0, v_attr1, v_attr2, v_attr3, v_attr4, v_attr5, v_attr6, v_attr7);\n");
        b.append("  uint vpm_out[16]; for (int i = 0; i < 16; ++i) vpm_out[i] = 0u;\n");
    } else {
        b.append("  ra[15] = 0x3f800000u;\n"); // frag_w = 1.0 (OpenGL already perspective-interpolated varyings)
        b.append("  rb[15] = f2u(gl_FragCoord.z);\n");
        b.append("  float vary_in[8] = float[8](v_vary0.x, v_vary0.y, v_vary0.z, v_vary0.w, v_vary1.x, v_vary1.y, v_vary1.z, v_vary1.w);\n");
        b.append("  uint tlb_c = 0xff000000u;\n");
    }

    var end_at: ?usize = null;
    var tmu_param_stage: [2]u8 = .{ 0, 0 };

    for (code, 0..) |inst, ip| {
        if (end_at) |e| if (ip > e) break;
        const sig = qpu.getSig(inst);
        if (sig == .branch) continue;

        const ws = qpu.getWs(inst);
        const cond_add: qpu.Cond = @fromBackingInt(@intCast(@as(u3, @truncate(inst >> 49))));
        const cond_mul: qpu.Cond = @fromBackingInt(@intCast(@as(u3, @truncate(inst >> 46))));
        const pm = (inst >> 56) & 1 != 0;
        const pack: u4 = @truncate(inst >> 52);
        const unpack_mode: u3 = @truncate(inst >> 57);
        const sf = (inst >> 45) & 1 != 0;

        const add_op: qpu.AddOp = if (sig == .load_imm) .nop else qpu.getAddOp(inst);
        const mul_op: qpu.MulOp = if (sig == .load_imm) .nop else qpu.getMulOp(inst);

        b.print("  {{ // ip={d}\n", .{ip});

        if (sig == .load_imm) {
            const imm: u32 = @truncate(inst);
            b.print("    uint add_res = 0x{x:0>8}u, mul_res = 0x{x:0>8}u;\n", .{ imm, imm });
        } else {
            const raddr_a = qpu.getRaddrA(inst);
            const raddr_b = qpu.getRaddrB(inst);
            const muxes = [4]qpu.Mux{
                qpu.getMuxAddA(inst),
                qpu.getMuxAddB(inst),
                qpu.getMuxMulA(inst),
                qpu.getMuxMulB(inst),
            };
            const uses_a = (add_op != .nop and (muxes[0] == .a or muxes[1] == .a)) or
                (mul_op != .nop and (muxes[2] == .a or muxes[3] == .a));
            const uses_b = (add_op != .nop and (muxes[0] == .b or muxes[1] == .b)) or
                (mul_op != .nop and (muxes[2] == .b or muxes[3] == .b));

            b.append("    uint port_a = ");
            if (uses_a or raddr_a < 32) {
                emitPortRead(&b, &out, raddr_a, true);
            } else {
                b.append("0u");
            }
            b.append(";\n    uint port_b = ");
            if (sig == .small_imm) {
                b.print("0x{x:0>8}u", .{qpu_sim.smallImm(raddr_b)});
            } else if (uses_b or raddr_b < 32) {
                emitPortRead(&b, &out, raddr_b, false);
            } else {
                b.append("0u");
            }
            b.append(";\n");

            const reads_vary = (uses_a and raddr_a == qpu.R.vary) or (sig != .small_imm and uses_b and raddr_b == qpu.R.vary);

            // Emit 4 mux inputs
            for (muxes, 0..) |m, mi| {
                const flt = if (mi < 2) isFloatAdd(add_op) else (mul_op == .fmul);
                b.print("    uint in{d} = ", .{mi});
                emitMuxExpr(&b, m, pm, unpack_mode, raddr_a, flt);
                b.append(";\n");
            }

            b.append("    uint add_res = ");
            emitAddExpr(&b, add_op);
            b.append(";\n    uint mul_res = ");
            emitMulExpr(&b, mul_op);
            b.append(";\n");

            if (sf) {
                const flag_src = if (add_op != .nop) "add_res" else "mul_res";
                b.print("    flag_z = ({s} == 0u); flag_n = (int({s}) < 0);\n", .{ flag_src, flag_src });
            }
            if (reads_vary) {
                b.append("    r5 = 0u;\n");
            }
        }

        const waddr_add = qpu.getWaddrAdd(inst);
        const waddr_mul = qpu.getWaddrMul(inst);
        const a_pack: u4 = if (!pm) pack else 0;
        const mul_pack: u4 = if (pm) pack else 0;

        emitWrite(&b, &out, &tmu_param_stage, waddr_add, !ws, "add_res", cond_add, if (!ws) a_pack else 0, 0);
        emitWrite(&b, &out, &tmu_param_stage, waddr_mul, ws, "mul_res", cond_mul, if (ws) a_pack else 0, mul_pack);

        switch (sig) {
            .load_tmu0 => b.append("    r4 = tmu0_fifo;\n"),
            .load_tmu1 => b.append("    r4 = tmu1_fifo;\n"),
            .color_load, .color_load_end => {
                out.uses_color_load = true;
                b.append("    r4 = packBgra(texelFetch(u_tlb_tex, ivec2(gl_FragCoord.xy), 0));\n");
                if (sig == .color_load_end) end_at = ip + 2;
            },
            .prog_end => end_at = ip + 2,
            else => {},
        }

        b.append("  }\n");
    }

    if (stage == .vertex) {
        b.append(
            \\  int xs = int(vpm_out[0] & 0xffffu);
            \\  if (xs >= 32768) xs -= 65536;
            \\  int ys = int(vpm_out[0] >> 16u);
            \\  if (ys >= 32768) ys -= 65536;
            \\  float px = float(xs) / 16.0 + u_viewport.x;
            \\  float py = float(ys) / 16.0 + u_viewport.y;
            \\  float ndc_x = (px / (u_viewport.z * 0.5)) - 1.0;
            \\  float ndc_y = (py / (u_viewport.w * 0.5)) - 1.0;
            \\  float ndc_z = u2f(vpm_out[1]) * 2.0 - 1.0;
            \\  float inv_w = u2f(vpm_out[2]);
            \\  float w = (inv_w != 0.0) ? (1.0 / inv_w) : 1.0;
            \\  gl_Position = vec4(ndc_x * w, ndc_y * w, ndc_z * w, w);
            \\  v_vary0 = vec4(u2f(vpm_out[3]), u2f(vpm_out[4]), u2f(vpm_out[5]), u2f(vpm_out[6]));
            \\  v_vary1 = vec4(u2f(vpm_out[7]), u2f(vpm_out[8]), u2f(vpm_out[9]), u2f(vpm_out[10]));
            \\
        );
    } else {
        b.append(
            \\  o_color = vec4(
            \\    float((tlb_c >> 16u) & 0xffu) / 255.0,
            \\    float((tlb_c >> 8u) & 0xffu) / 255.0,
            \\    float(tlb_c & 0xffu) / 255.0,
            \\    float((tlb_c >> 24u) & 0xffu) / 255.0
            \\  );
            \\
        );
    }

    b.append("}\n");
    out.glsl_len = b.len;
    return out;
}

fn isFloatAdd(op: qpu.AddOp) bool {
    return switch (op) {
        .fadd, .fsub, .fmin, .fmax, .fminabs, .fmaxabs, .ftoi => true,
        else => false,
    };
}

fn emitPortRead(b: *Builder, out: *TranslatedShader, raddr: u6, is_a: bool) void {
    if (raddr < 32) {
        b.print("{s}[{d}]", .{ if (is_a) "ra" else "rb", raddr });
        return;
    }
    switch (raddr) {
        qpu.R.unif => {
            const idx = out.num_uniforms;
            out.num_uniforms += 1;
            b.print("u_unif[{d}]", .{idx});
        },
        qpu.R.vary => {
            const idx = out.num_varyings;
            out.num_varyings += 1;
            b.print("f2u(vary_in[{d}])", .{@min(idx, 7)});
        },
        qpu.R.vpm => {
            const idx = out.num_vpm_reads;
            out.num_vpm_reads += 1;
            b.print("vpm_in[{d}]", .{@min(idx, 7)});
        },
        qpu.R.xy_pixel_coord => {
            if (is_a) {
                b.append("uint(gl_FragCoord.x)");
            } else {
                b.append("uint(gl_FragCoord.y)");
            }
        },
        else => b.append("0u"),
    }
}

fn emitMuxExpr(b: *Builder, m: qpu.Mux, pm: bool, unpack_mode: u3, raddr_a: u6, flt: bool) void {
    const base_expr = switch (m) {
        .r0 => "r0",
        .r1 => "r1",
        .r2 => "r2",
        .r3 => "r3",
        .r4 => "r4",
        .r5 => "r5",
        .a => "port_a",
        .b => "port_b",
    };

    const do_unpack = (m == .r4 and pm and unpack_mode != 0) or (m == .a and !pm and raddr_a < 32 and unpack_mode != 0);
    if (!do_unpack) {
        b.append(base_expr);
        return;
    }

    switch (unpack_mode) {
        4, 5, 6, 7 => {
            b.print("unpack8({s}, {d}u, {s})", .{ base_expr, unpack_mode - 4, if (flt) "true" else "false" });
        },
        1 => b.print("(({s} & 0xffffu) | ((({s} & 0x8000u) != 0u) ? 0xffff0000u : 0u))", .{ base_expr, base_expr }),
        2 => b.print("(uint(int({s}) >> 16))", .{base_expr}),
        else => b.append(base_expr),
    }
}

fn emitAddExpr(b: *Builder, op: qpu.AddOp) void {
    switch (op) {
        .nop => b.append("0u"),
        .fadd => b.append("f2u(u2f(in0) + u2f(in1))"),
        .fsub => b.append("f2u(u2f(in0) - u2f(in1))"),
        .fmin => b.append("f2u(min(u2f(in0), u2f(in1)))"),
        .fmax => b.append("f2u(max(u2f(in0), u2f(in1)))"),
        .fminabs => b.append("f2u(min(abs(u2f(in0)), abs(u2f(in1))))"),
        .fmaxabs => b.append("f2u(max(abs(u2f(in0)), abs(u2f(in1))))"),
        .ftoi => b.append("uint(int(u2f(in0)))"),
        .itof => b.append("f2u(float(int(in0)))"),
        .add => b.append("(in0 + in1)"),
        .sub => b.append("(in0 - in1)"),
        .shr => b.append("(in0 >> (in1 & 31u))"),
        .asr => b.append("uint(int(in0) >> int(in1 & 31u))"),
        .shl => b.append("(in0 << (in1 & 31u))"),
        .min => b.append("uint(min(int(in0), int(in1)))"),
        .max => b.append("uint(max(int(in0), int(in1)))"),
        .@"and" => b.append("(in0 & in1)"),
        .@"or" => b.append("(in0 | in1)"),
        .xor => b.append("(in0 ^ in1)"),
        .not => b.append("(~in0)"),
        else => b.append("0u"),
    }
}

fn emitMulExpr(b: *Builder, op: qpu.MulOp) void {
    switch (op) {
        .nop => b.append("0u"),
        .fmul => b.append("f2u(u2f(in2) * u2f(in3))"),
        .mul24 => b.append("((in2 & 0xffffffu) * (in3 & 0xffffffu))"),
        else => b.append("0u"),
    }
}

fn emitWrite(
    b: *Builder,
    out: *TranslatedShader,
    tmu_param_stage: *[2]u8,
    waddr: u6,
    to_a: bool,
    val_name: []const u8,
    cond: qpu.Cond,
    a_pack: u4,
    mul_pack: u4,
) void {
    if (waddr == qpu.W.nop or cond == .never) return;

    const cond_str = switch (cond) {
        .never => return,
        .always => "true",
        .zs => "flag_z",
        .zc => "(!flag_z)",
        .ns => "flag_n",
        .nc => "(!flag_n)",
        .cs, .cc => "false",
    };

    var dst_buf: [32]u8 = undefined;
    const dst_opt: ?[]const u8 = switch (waddr) {
        0...31 => std.fmt.bufPrint(&dst_buf, "{s}[{d}]", .{ if (to_a) "ra" else "rb", waddr }) catch null,
        qpu.W.acc0...qpu.W.acc0 + 3 => std.fmt.bufPrint(&dst_buf, "r{d}", .{waddr - qpu.W.acc0}) catch null,
        qpu.W.acc5 => "r5",
        else => null,
    };

    if (dst_opt) |dst| {
        b.print("    if ({s}) ", .{cond_str});
        if (a_pack == 1 or a_pack == 9) {
            b.print("{s} = ({s} & 0xffff0000u) | ({s} & 0xffffu);\n", .{ dst, dst, val_name });
        } else if (a_pack == 2 or a_pack == 10) {
            b.print("{s} = ({s} & 0x0000ffffu) | (({s} & 0xffffu) << 16u);\n", .{ dst, dst, val_name });
        } else if (mul_pack >= 4 and mul_pack <= 7) {
            b.print("{s} = packMul8({s}, {s}, {d}u);\n", .{ dst, dst, val_name, mul_pack - 4 });
        } else if (mul_pack == 3) {
            b.print("{s} = uint(clamp(round(u2f({s}) * 255.0), 0.0, 255.0)) * 0x01010101u;\n", .{ dst, val_name });
        } else {
            b.print("{s} = {s};\n", .{ dst, val_name });
        }
        return;
    }

    switch (waddr) {
        qpu.W.vpm => {
            const idx = out.num_vpm_writes;
            out.num_vpm_writes += 1;
            b.print("    vpm_out[{d}] = {s};\n", .{ @min(idx, 15), val_name });
        },
        qpu.W.tlb_color_all, qpu.W.tlb_color_ms => {
            b.print("    tlb_c = {s};\n", .{val_name});
        },
        qpu.W.sfu_recip => b.print("    r4 = f2u(1.0 / u2f({s}));\n", .{val_name}),
        qpu.W.sfu_recipsqrt => b.print("    r4 = f2u(inversesqrt(u2f({s})));\n", .{val_name}),
        qpu.W.sfu_exp => b.print("    r4 = f2u(exp2(u2f({s})));\n", .{val_name}),
        qpu.W.sfu_log => b.print("    r4 = f2u(log2(u2f({s})));\n", .{val_name}),
        qpu.W.tmu0_t, qpu.W.tmu0_s, qpu.W.tmu1_t, qpu.W.tmu1_s => {
            const unit: usize = if (waddr <= qpu.W.tmu0_b) 0 else 1;
            const unif_idx = out.num_uniforms;
            out.num_uniforms += 1;
            if (tmu_param_stage[unit] == 0) {
                out.tmu_p0_uniform_idx[unit] = unif_idx;
                tmu_param_stage[unit] = 1;
            } else {
                out.tmu_p1_uniform_idx[unit] = unif_idx;
                tmu_param_stage[unit] = 0;
            }
            if (waddr == qpu.W.tmu0_t) {
                b.print("    tmu0_t = {s};\n", .{val_name});
            } else if (waddr == qpu.W.tmu1_t) {
                b.print("    tmu1_t = {s};\n", .{val_name});
            } else if (waddr == qpu.W.tmu0_s) {
                b.print("    tmu0_s = {s};\n", .{val_name});
                b.append("    tmu0_fifo = packBgra(texture(u_tex0, vec2(u2f(tmu0_s), u2f(tmu0_t))));\n");
            } else if (waddr == qpu.W.tmu1_s) {
                b.print("    tmu1_s = {s};\n", .{val_name});
                b.append("    tmu1_fifo = packBgra(texture(u_tex1, vec2(u2f(tmu1_s), u2f(tmu1_t))));\n");
            }
        },
        else => {},
    }
}

test "QPU to GLSL translation for fragment shader" {
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

    const translated = translate(p.code(), .fragment);
    try std.testing.expectEqual(@as(usize, 3), translated.num_varyings);
    try std.testing.expect(std.mem.indexOf(u8, translated.glsl(), "#version 330 core") != null);
    try std.testing.expect(std.mem.indexOf(u8, translated.glsl(), "tlb_c = ") != null);
}
