//! Translates VideoCore IV QPU fragment shaders into the Metal Shading Language (for drawing V3D
//! jobs with Metal, `metal_renderer.zig`) or GLSL (with OpenGL, `gl_renderer.zig`). A fragment runs
//! the program as one lane of the QPU, in the order `qpu_sim` runs it, so both draw the same pixels:
//! what `qpu_sim` follows at run time (which uniform is read next, the TMU FIFOs, which varying) is
//! followed here while translating, as the programs have no branches that `qpu_sim` takes.

const std = @import("std");
const qpu = @import("qpu.zig");
const qpu_sim = @import("qpu_sim.zig");

/// The uniforms a draw's fragment shader is given (`unif`, a buffer of this many words).
pub const max_uniforms = 128;
/// The varyings a fragment is given.
pub const max_varyings = 16;

pub const Language = enum { msl, glsl };

/// The textures a GLSL shader samples, each its own (`tex[k]`).
pub const max_samples = 8;

/// What a translated shader needs.
pub const Shader = struct {
    /// Reads the tile buffer's colour (`color_load`): with framebuffer fetch (Metal), or from the
    /// framebuffer as a texture (OpenGL).
    reads_color: bool = false,
    /// GLSL: what each texture sampled is, as the uniforms holding its parameters (for `tex[k]`).
    samples: [max_samples]Sample = undefined,
    sample_count: usize = 0,
    /// GLSL: it samples more textures than it has units for, so it can't be drawn.
    too_many_samples: bool = false,
    /// It reads more uniforms than are given to it (`max_uniforms`), so it can't be drawn.
    too_many_uniforms: bool = false,
    /// It does what can't be run a fragment at a time (branches, rotating vectors, writing r5 or
    /// moving the uniforms): drawn on the CPU.
    unsupported: bool = false,
    /// GLSL, multisampled: it writes each sample's colour (tlb_color_ms), so runs once a sample
    /// (`gl_SampleID`), its varyings still at the pixel's middle.
    per_sample: bool = false,
};

/// How a fragment shader is translated.
pub const Options = struct {
    /// GLSL: drawn into a 4x multisampled tile buffer (`tlb_ms`), whose samples its colour loads
    /// read in turn, and its writes to tlb_color_ms write in turn.
    multisampled: bool = false,
};

/// A texture sampled: the uniforms with its TMU parameters 0 and 1.
pub const Sample = struct { p0: usize, p1: usize };

/// MSL shared by the shaders: the vertex a triangle's corner is drawn from, what a fragment is
/// given, and the helpers the fragment shaders and kernels use. `Vertex` and `DrawInfo` are laid out
/// as the structs of the same names in `metal_renderer.zig`.
pub const msl_common = @embedFile("shaders/common.metal") ++ sfuHelpers("", "static inline ");

/// MSL of the vertex shader all draws share, and the kernels that load the tile buffer from RAM and
/// store it back (`ls_load`, `ls_store`); compiled after `msl_common`. `LoadStore` is laid out as the
/// struct of the same name in `metal_renderer.zig`.
pub const msl_shared_functions = @embedFile("shaders/shared_functions.metal");

/// GLSL shared by the fragment shaders: what a fragment is given (the varyings, the draw's uniforms,
/// the textures it samples, decoded, and the tile buffer it reads), and the helpers the shaders use,
/// as `msl_common`'s do. Each texture sampled is decoded as the TMU reads it (`qpu_sim`), 32 bits a
/// texel, so sampling it only wraps and filters.
pub const glsl_common = @embedFile("shaders/fragment_common.glsl") ++ glsl_helpers;

/// GLSL shared by the vertex shaders: a vertex's VPM words (`a_in`, `n_vpm` of them), the draw's
/// uniforms, and what is captured of the vertex (as `gpu_draw.Vertex`), then the helpers.
pub const glsl_vertex_common = @embedFile("shaders/vertex_common.glsl") ++ glsl_helpers;

/// The names of what a vertex shader's vertex is captured as, in `gpu_draw.Vertex`'s order.
pub const glsl_vertex_captured = [_][*:0]const u8{ "tf_pos", "tf_unit_w", "tf_v0", "tf_v1", "tf_v2", "tf_v3" };

/// Float constants as their bits (`f(0x...u)`), so both languages' compilers take them exactly.
fn constBits(comptime x: f32) []const u8 {
    return std.fmt.comptimePrint("f(0x{x}u)", .{@as(u32, @bitCast(x))});
}

/// The SFU's functions and the 16-bit float conversion as qpu_sim computes them (`sfuRsqrt`,
/// `sfuExp2`, `sfuLog2`, `halfOf`), in either language: `prec` is what keeps a float operation
/// rounded on its own (`precise ` in GLSL), `int`/`uint` its integer types.
fn sfuHelpers(comptime prec: []const u8, comptime fn_prefix: []const u8) []const u8 {
    comptime var exp2_poly: []const u8 = "  " ++ prec ++ "float p = " ++ constBits(qpu_sim.exp2_coeffs[0]) ++ ";\n";
    inline for (qpu_sim.exp2_coeffs[1..]) |c| exp2_poly = exp2_poly ++ "  p = p * fr; p = p + " ++ constBits(c) ++ ";\n";
    comptime var log2_poly: []const u8 = "  " ++ prec ++ "float p = " ++ constBits(qpu_sim.log2_coeffs[0]) ++ ";\n";
    inline for (qpu_sim.log2_coeffs[1..]) |c| log2_poly = log2_poly ++ "  p = p * y; p = p + " ++ constBits(c) ++ ";\n";
    return fn_prefix ++ "uint q_rsqrt(uint a) {\n" ++
        "  " ++ prec ++ "float x = f(a);\n" ++
        "  if (isnan(x) || x < 0.0) return 0x7fc00000u;\n" ++
        "  if (isinf(x)) return 0u;\n" ++
        "  if ((a & 0x7f800000u) == 0u) return 0x7f800000u;\n" ++
        "  " ++ prec ++ "float y = f(0x5f3759dfu - (a >> 1));\n" ++
        "  " ++ prec ++ "float hx = x * 0.5;\n" ++
        "  for (int i = 0; i < 4; i++) { " ++ prec ++ "float t = hx * y; t = t * y; t = 1.5 - t; y = y * t; }\n" ++
        "  return u(y);\n" ++
        "}\n" ++
        fn_prefix ++ "uint q_exp2(uint a) {\n" ++
        "  " ++ prec ++ "float x = f(a);\n" ++
        "  if (isnan(x)) return a;\n" ++
        "  if (x >= 128.0) return 0x7f800000u;\n" ++
        "  if (x <= -150.0) return 0u;\n" ++
        "  " ++ prec ++ "float i = floor(x);\n" ++
        "  " ++ prec ++ "float fr = x - i;\n" ++
        exp2_poly ++
        "  int n = int(i);\n" ++
        "  if (n >= -126) { " ++ prec ++ "float r = p * f(uint(n + 127) << 23); return u(r); }\n" ++
        "  " ++ prec ++ "float r = (p * f(0x00800000u)) * f(uint(n + 253) << 23);\n" ++
        "  return u(r);\n" ++
        "}\n" ++
        fn_prefix ++ "uint q_log2(uint a) {\n" ++
        "  " ++ prec ++ "float x = f(a);\n" ++
        "  if (isnan(x) || x < 0.0) return 0x7fc00000u;\n" ++
        "  if (isinf(x)) return a;\n" ++
        "  if ((a & 0x7f800000u) == 0u) return 0xff800000u;\n" ++
        "  int e = int((a >> 23) & 0xffu) - 127;\n" ++
        "  " ++ prec ++ "float m = f((a & 0x7fffffu) | 0x3f800000u);\n" ++
        "  if (m > " ++ constBits(1.41421356) ++ ") { m = m * 0.5; e += 1; }\n" ++
        "  " ++ prec ++ "float y = m - 1.0;\n" ++
        log2_poly ++
        "  p = p * y;\n" ++
        "  " ++ prec ++ "float r = float(e) + p;\n" ++
        "  return u(r);\n" ++
        "}\n" ++
        // Round to nearest even, in integers.
        fn_prefix ++ "uint q_half(uint x) {\n" ++
        "  uint sign = (x >> 16) & 0x8000u;\n" ++
        "  int ex = int((x >> 23) & 0xffu) - 112;\n" ++
        "  uint mant = x & 0x7fffffu;\n" ++
        "  if (((x >> 23) & 0xffu) == 0xffu) return sign | 0x7c00u | (mant != 0u ? 0x200u : 0u);\n" ++
        "  if (ex >= 31) return sign | 0x7c00u;\n" ++
        "  if (ex <= 0) {\n" ++
        "    if (ex < -10) return sign;\n" ++
        "    uint m = mant | 0x800000u;\n" ++
        "    uint sh = uint(14 - ex);\n" ++
        "    uint h = m >> sh;\n" ++
        "    uint rem = m & ((1u << sh) - 1u);\n" ++
        "    uint hf = 1u << (sh - 1u);\n" ++
        "    if (rem > hf || (rem == hf && (h & 1u) != 0u)) h += 1u;\n" ++
        "    return sign | h;\n" ++
        "  }\n" ++
        "  uint h = (uint(ex) << 10) | (mant >> 13);\n" ++
        "  uint rem = mant & 0x1fffu;\n" ++
        "  if (rem > 0x1000u || (rem == 0x1000u && (h & 1u) != 0u)) h += 1u;\n" ++
        "  return sign | h;\n" ++
        "}\n" ++
        // Saturating 32-bit add and subtract, and the packs' saturations.
        fn_prefix ++ "uint q_addsat(uint a, uint b) { uint r = a + b; return ((~(a ^ b) & (a ^ r)) >> 31) != 0u ? ((a >> 31) != 0u ? 0x80000000u : 0x7fffffffu) : r; }\n" ++
        fn_prefix ++ "uint q_subsat(uint a, uint b) { uint r = a - b; return (((a ^ b) & (a ^ r)) >> 31) != 0u ? ((a >> 31) != 0u ? 0x80000000u : 0x7fffffffu) : r; }\n" ++
        fn_prefix ++ "uint q_sat16(uint v) { return uint(clamp(int(v), -32768, 32767)) & 0xffffu; }\n" ++
        fn_prefix ++ "uint q_sat8(uint v) { return uint(clamp(int(v), 0, 255)); }\n";
}

/// The GLSL helpers the shaders share. The QPU's float arithmetic is `precise`: each operation
/// rounded on its own, as qpu_sim does, not fused or rearranged.
const glsl_helpers = @embedFile("shaders/helpers.glsl") ++ sfuHelpers("precise ", "");

/// The start of a GLSL fragment shader's `main`: its inputs (as interpolated for the fragment).
const glsl_inputs = @embedFile("shaders/fragment_inputs.glsl");

/// `glsl_inputs`, run once a sample: interpolated at the pixel's middle all the same, as V3D does.
const glsl_inputs_centre = @embedFile("shaders/fragment_inputs_centre.glsl");

/// What follows `glsl_inputs`: the inputs as `translate` reads them.
const glsl_prologue = @embedFile("shaders/fragment_prologue.glsl");

/// The GLSL vertex shader all draws share: a corner (`gl_renderer.Vertex`) where it is in the
/// framebuffer (`fb` pixels big; its rows up from the bottom of the GL framebuffer, as in RAM), and
/// what the fragments get.
pub const glsl_vertex = @embedFile("shaders/draw_vertex.glsl");

/// The varying interpolation `qpu_sim` stands for: `fmul acc, vary, frag_w` then `fadd dst, acc, r5`
/// gives back the varying, with `r5` the constant it reads as.
const varying_c = "0.25f";

/// Writes the fragment shader `decoded` (`qpu_sim.decodeProgram`'s, so that the varying
/// interpolation pairs it fuses are fused here too) in `lang`: MSL's `fragment_main` (after
/// `msl_common`), or GLSL's `main` (after `glsl_common`).
pub fn translate(w: *std.Io.Writer, decoded: []const qpu_sim.DecodedInst, lang: Language) std.Io.Writer.Error!Shader {
    return translateWith(w, decoded, lang, .{});
}

/// `translate`, as `options` say.
pub fn translateWith(w: *std.Io.Writer, decoded: []const qpu_sim.DecodedInst, lang: Language, options: Options) std.Io.Writer.Error!Shader {
    var t: Translator = .{ .w = w, .lang = lang, .multisampled = options.multisampled and lang == .glsl };
    // The tile's colour is an input only if the program reads it.
    for (decoded) |d| {
        if (d.sig == .color_load or d.sig == .color_load_end) t.shader.reads_color = true;
        if (d.waddr_add == qpu.W.tlb_color_ms or d.waddr_mul == qpu.W.tlb_color_ms) t.shader.per_sample = t.multisampled;
    }
    // The stencil test, the samples drawn, Z from the shader, and the coverage and facing:
    // left to qpu_sim.
    const tlb = qpu_sim.tlbUse(decoded);
    if (tlb.stencil or tlb.ms_flags or tlb.shader_z or tlb.reads_flags or tlb.vg_mask) t.shader.unsupported = true;

    if (lang == .glsl) {
        try w.writeAll(if (t.shader.per_sample) glsl_inputs_centre else glsl_inputs);
        try w.writeAll(glsl_prologue);
        if (t.shader.reads_color and !t.multisampled) try w.writeAll("  uint tlb_in = texelFetch(tlb_tex, ivec2(gl_FragCoord.xy), 0).r;\n");
    } else {
        try w.writeAll(@embedFile("shaders/fragment_main.metal"));
        if (t.shader.reads_color) try w.writeAll(",\n    uint tlb_in [[color(0)]]");
        try w.writeAll(@embedFile("shaders/fragment_prologue.metal"));
    }
    try w.writeAll(@embedFile("shaders/fragment_registers.inc"));

    var end_at: ?usize = null;
    var ip: usize = 0;
    while (ip < decoded.len) : (ip += 1) {
        if (end_at) |e| if (ip > e) break;
        const d = decoded[ip];
        if (d.sig == .branch) {
            t.notSupported();
            continue;
        }
        try w.print("  {{ // {d}\n", .{ip});

        if ((d.flags & qpu_sim.DecodedInst.FLAG_FUSED_LINTERP) != 0) {
            const k = t.varyings;
            t.varyings += 1;
            try w.print("    uint val = {d}u < {s} ? u(V[{d}]) : 0u;\n", .{ k, t.nVar(), @min(k, max_varyings - 1) });
            try w.print("    r5 = u({s});\n", .{varying_c});
            if (d.waddr_add != d.waddr_mul) {
                try w.print("    r{d} = u(f(val) - {s});\n", .{ d.waddr_mul - qpu.W.acc0, varying_c });
            }
            try t.write(d.waddr_add, d.add_file, "val", .always, 0, 0, true);
            try w.writeAll("  }\n");
            ip += 1;
            continue;
        }

        try t.instruction(d);

        switch (d.sig) {
            .load_tmu0, .load_tmu1 => {
                const unit: usize = if (d.sig == .load_tmu0) 0 else 1;
                const fifo = &t.tmu[unit];
                if (fifo.len > 0) {
                    try w.print("    r4 = tmu{d}_f{d};\n", .{ unit, fifo.head });
                    fifo.head +%= 1;
                    fifo.len -= 1;
                } else {
                    try w.writeAll("    r4 = 0xff000000u;\n");
                }
            },
            .color_load, .color_load_end => {
                // Multisampled, each sample in turn.
                if (t.multisampled) {
                    try w.print("    r4 = texelFetch(tlb_ms, ivec2(gl_FragCoord.xy), {d}).r;\n", .{t.color_loads % 4});
                    t.color_loads += 1;
                } else try w.writeAll("    r4 = tlb_in;\n");
                if (d.sig == .color_load_end) end_at = ip + 2;
            },
            .prog_end => end_at = ip + 2,
            else => {},
        }
        try w.writeAll("  }\n");
    }

    // Without an end the program fails in qpu_sim, and draws nothing.
    const discard = if (lang == .glsl) "discard" else "discard_fragment()";
    if (end_at == null) try w.print("  {s};\n", .{discard});
    try w.print("  if (!tlb_w) {s};\n", .{discard});
    try w.writeAll(if (lang == .glsl)
        @embedFile("shaders/fragment_end.glsl")
    else
        @embedFile("shaders/fragment_end.metal"));
    return t.shader;
}

/// What a translated vertex shader needs, or that it can't be.
pub const VertexShader = struct {
    /// It can't be run as a GPU shader the same as qpu_sim runs it: it reads something only the
    /// QPU has (its lane's number, a varying, a texture or the tile), writes fewer than the 3 words
    /// of a vertex's position, or doesn't end.
    unsupported: bool = false,
    /// The VPM words it writes: the position (x and y, z, 1/W) and then the varyings.
    outputs: usize = 0,
};

/// Writes the vertex shader `decoded` (`qpu_sim.decodeProgram`'s) in `lang`: the vertex as V3D
/// shades it (`v3d.zig`'s `VertexJob`), as a `gpu_draw.Vertex`. GLSL's `main` (after
/// `glsl_vertex_common`) gives it to transform feedback; MSL's `vertex_shade` kernel (after
/// `msl_common` and `msl_shared_functions`) shades `VertexInfo`'s vertices.
pub fn translateVertex(w: *std.Io.Writer, decoded: []const qpu_sim.DecodedInst, lang: Language) std.Io.Writer.Error!VertexShader {
    return translateVertexStage(w, decoded, lang, false);
}

/// A coordinate shader translated (GLSL): each vertex's clip coordinates (its first four VPM
/// words, as floats) captured in `tf_pos`, for the clipper.
pub fn translateCoordinates(w: *std.Io.Writer, decoded: []const qpu_sim.DecodedInst) std.Io.Writer.Error!VertexShader {
    return translateVertexStage(w, decoded, .glsl, true);
}

fn translateVertexStage(w: *std.Io.Writer, decoded: []const qpu_sim.DecodedInst, lang: Language, clip: bool) std.Io.Writer.Error!VertexShader {
    var t: Translator = .{ .w = w, .lang = lang, .stage = .vertex, .opaque_zero = " + zero" };
    // The registers start as qpu_sim's do (ra15 and rb15 a fragment's W, 1, and Z, 0), from a zero
    // the compiler doesn't know is 0 (a vertex's number is never 2^31 or more).
    try w.writeAll(if (lang == .glsl)
        @embedFile("shaders/vertex_stage_main.glsl")
    else
        @embedFile("shaders/vertex_stage_main.metal"));
    try w.writeAll(@embedFile("shaders/vertex_stage_registers.inc"));
    var end_at: ?usize = null;
    var ip: usize = 0;
    while (ip < decoded.len) : (ip += 1) {
        if (end_at) |e| if (ip > e) break;
        const d = decoded[ip];
        if (d.sig == .branch) {
            t.notSupported();
            continue;
        }
        if ((d.flags & qpu_sim.DecodedInst.FLAG_FUSED_LINTERP) != 0) t.vertex.unsupported = true;
        try w.print("  {{ // {d}\n", .{ip});
        try t.instruction(d);
        switch (d.sig) {
            .load_tmu0, .load_tmu1, .color_load, .color_load_end, .coverage_load, .alpha_mask_load => t.vertex.unsupported = true,
            .prog_end => end_at = ip + 2,
            else => {},
        }
        try w.writeAll("  }\n");
    }
    if (end_at == null) t.vertex.unsupported = true;
    t.vertex.outputs = t.vpm_writes;
    if (t.vpm_writes < 3) t.vertex.unsupported = true;
    if (clip) {
        if (t.vpm_writes < 4) t.vertex.unsupported = true;
        try w.writeAll(@embedFile("shaders/coordinates_end.glsl"));
        return t.vertex;
    }
    // The vertex, as V3D's position words give it: x and y in 12.4 fixed point, z, and 1/W (taken
    // as 1 if 0); the varyings multiplied by 1/W.
    if (lang == .msl) {
        // The varyings it writes.
        try w.print("  const uint n_outputs = {d}u;\n", .{t.vpm_writes -| 3});
        try w.writeAll(@embedFile("shaders/vertex_stage_end.metal"));
        return t.vertex;
    }
    // The varyings it writes.
    try w.print("  const uint n_outputs = {d}u;\n", .{t.vpm_writes -| 3});
    try w.writeAll(@embedFile("shaders/vertex_stage_end.glsl"));
    return t.vertex;
}

const Translator = struct {
    w: *std.Io.Writer,
    lang: Language,
    stage: enum { fragment, vertex } = .fragment,
    shader: Shader = .{},
    vertex: VertexShader = .{},
    /// Added to constants, so that the compiler can't fold them into the arithmetic (and, say, take
    /// 0 times a negative number as +0, not -0): a zero it doesn't know is 0.
    opaque_zero: []const u8 = "",
    /// A vertex shader's VPM words read and written so far.
    vpm_reads: usize = 0,
    vpm_writes: usize = 0,
    /// The next uniform and varying read.
    uniforms: usize = 0,
    varyings: usize = 0,
    tmu: [2]Tmu = .{ .{}, .{} },
    /// GLSL: drawn multisampled (`Options`), and the tile's samples read and written so far.
    multisampled: bool = false,
    color_loads: usize = 0,
    sample_writes: usize = 0,

    /// A TMU's parameters written so far (the uniforms they are), and the samples waiting in its
    /// FIFO (`tmuN_fM`).
    const Tmu = struct {
        params: [4]usize = undefined,
        param_count: u8 = 0,
        has_t: bool = false,
        head: u2 = 0,
        len: u3 = 0,
    };

    /// An instruction's ALU operations and register writes (not its signal's).
    fn instruction(t: *Translator, d: qpu_sim.DecodedInst) !void {
        const w = t.w;
        if (d.rotate != 0) t.notSupported();
        if (d.sig == .load_imm and (d.limm_mode == 1 or d.limm_mode == 3)) {
            // Each element's 2 bits (the element as the fragment's X & 15, as qpu_sim's spans of
            // 16 have it).
            if (t.stage == .vertex) t.notSupported();
            const lo = d.imm_or_small & 0xffff;
            const hi = d.imm_or_small >> 16;
            try w.print("    uint lane = px & 15u; uint two = ((0x{x}u >> lane) & 1u) | (((0x{x}u >> lane) & 1u) << 1);\n", .{ lo, hi });
            if (d.limm_mode == 1) try w.writeAll("    if (two >= 2u) two -= 4u;\n");
            try w.print("    uint add_r = two{s}, mul_r = two{s};\n", .{ t.opaque_zero, t.opaque_zero });
        } else if (d.sig == .load_imm) {
            try w.print("    uint add_r = 0x{x}u{s}, mul_r = 0x{x}u{s};\n", .{ d.imm_or_small, t.opaque_zero, d.imm_or_small, t.opaque_zero });
        } else {
            if ((d.flags & qpu_sim.DecodedInst.FLAG_FETCH_A) != 0) {
                try w.writeAll("    pa = ");
                try t.port(d.raddr_a, .a);
                try w.writeAll(";\n");
            }
            if (d.sig == .small_imm) {
                try w.print("    pb = 0x{x}u{s};\n", .{ d.imm_or_small, t.opaque_zero });
            } else if ((d.flags & qpu_sim.DecodedInst.FLAG_FETCH_B) != 0) {
                try w.writeAll("    pb = ");
                try t.port(d.raddr_b, .b);
                try w.writeAll(";\n");
            }

            const unpacks = (d.flags & qpu_sim.DecodedInst.FLAG_HAS_UNPACK) != 0;
            var in0: [48]u8 = undefined;
            var in1: [48]u8 = undefined;
            const flt_add = (d.flags & qpu_sim.DecodedInst.FLAG_FLT_ADD) != 0;
            const a0 = mux(&in0, d.mux0, d, unpacks, flt_add);
            const a1 = mux(&in1, d.mux1, d, unpacks, flt_add);
            try w.writeAll("    uint add_r = ");
            if (d.add_pack_a == 8 and (d.add_op == .add or d.add_op == .sub)) {
                // The 32-bit saturating pack: saturated, not wrapped.
                try w.print("q_{s}sat({s}, {s})", .{ @tagName(d.add_op), a0, a1 });
            } else if (d.add_op != .nop) {
                try addOp(w, t.lang, d.add_op, a0, a1);
            } else {
                try w.writeAll("0u");
            }
            try w.writeAll(";\n    uint mul_r = ");
            if (d.mul_op != .nop) {
                const flt = (d.flags & qpu_sim.DecodedInst.FLAG_FLT_MUL) != 0;
                var in2: [48]u8 = undefined;
                var in3: [48]u8 = undefined;
                try mulOp(w, t.lang, d.mul_op, mux(&in2, d.mux2, d, unpacks, flt), mux(&in3, d.mux3, d, unpacks, flt));
            } else {
                try w.writeAll("0u");
            }
            try w.writeAll(";\n");

            if ((d.flags & qpu_sim.DecodedInst.FLAG_SF) != 0) {
                const from = if (d.add_op != .nop) "add_r" else "mul_r";
                try w.print("    flag_z = int({s}) == 0; flag_n = int({s}) < 0;\n", .{ from, from });
                switch (d.add_op) {
                    .add => try w.print("    flag_c = add_r < {s};\n", .{a0}),
                    .sub => try w.print("    flag_c = {s} < {s};\n", .{ a0, a1 }),
                    else => try w.writeAll("    flag_c = false;\n"),
                }
            }
            if ((d.flags & qpu_sim.DecodedInst.FLAG_READS_VARY) != 0) {
                try w.print("    r5 = u({s});\n", .{varying_c});
            }
        }

        const imm = d.sig == .load_imm;
        try t.write(d.waddr_add, d.add_file, "add_r", d.cond_add, if (d.add_pack_a == 8) 0 else d.add_pack_a, 0, !imm and floatResult(d.add_op));
        try t.write(d.waddr_mul, d.mul_file, "mul_r", d.cond_mul, d.mul_pack_a, d.mul_pack_m, !imm and d.mul_op == .fmul);
    }

    /// The program does what this translation can't: drawn (or shaded) on the CPU.
    fn notSupported(t: *Translator) void {
        if (t.stage == .vertex) t.vertex.unsupported = true else t.shader.unsupported = true;
    }

    /// The program reads past the uniforms it is given: it can't be drawn (on the GPU).
    fn tooManyUniforms(t: *Translator) void {
        if (t.stage == .vertex) t.vertex.unsupported = true else t.shader.too_many_uniforms = true;
    }

    /// How many varyings the draw gives.
    fn nVar(t: *const Translator) []const u8 {
        return if (t.lang == .glsl) "n_var" else "di.n_var";
    }

    fn port(t: *Translator, raddr: u6, file: qpu_sim.File) !void {
        const w = t.w;
        if (raddr < 32) return w.print("{s}[{d}]", .{ if (file == .a) "ra" else "rb", raddr });
        switch (raddr) {
            qpu.R.unif => {
                if (t.uniforms >= max_uniforms) {
                    t.tooManyUniforms();
                    return w.writeAll("0u");
                }
                try w.print("unif[{d}]", .{t.uniforms});
                t.uniforms += 1;
            },
            qpu.R.vary => {
                if (t.stage == .vertex) {
                    t.vertex.unsupported = true;
                    return w.writeAll("0u");
                }
                const k = t.varyings;
                t.varyings += 1;
                try w.print("({d}u < {s} ? u((V[{d}] - {s}) / W) : 0u)", .{ k, t.nVar(), @min(k, max_varyings - 1), varying_c });
            },
            qpu.R.vpm => {
                if (t.stage != .vertex) return w.writeAll("0u");
                // As qpu_sim reads them: in order, 0 past those given.
                const k = t.vpm_reads;
                t.vpm_reads += 1;
                if (k >= 32) return w.writeAll("0u");
                if (t.lang == .glsl)
                    try w.print("({d}u < n_vpm ? a_in[{d}].{c} : 0u)", .{ k, k / 4, "xyzw"[k % 4] })
                else
                    try w.print("({d}u < vi.n_vpm ? a_in[{d}] : 0u)", .{ k, k });
            },
            qpu.R.elem_qpu => {
                // The QPU's number (B) reads as 0, as in qpu_sim.
                if (file == .b) return w.writeAll("0u");
                if (t.stage == .vertex) t.vertex.unsupported = true;
                try w.writeAll("(px & 15u)");
            },
            qpu.R.xy_pixel_coord => {
                if (t.stage == .vertex) {
                    t.vertex.unsupported = true;
                    return w.writeAll("0u");
                }
                try w.writeAll(if (file == .a) "px" else "py");
            },
            else => try w.writeAll("0u"),
        }
    }

    fn write(t: *Translator, waddr: u6, file: qpu_sim.File, val: []const u8, cond: qpu.Cond, a_pack: u4, mul_pack: u4, float_result: bool) !void {
        if (waddr == qpu.W.nop or cond == .never) return;
        const w = t.w;
        // r5 written (replicated across a quad or the vector) and the uniforms moved: what a
        // fragment on its own can't do.
        if (waddr == qpu.W.acc5 or waddr == qpu.W.uniforms_address) t.notSupported();
        var dst_buf: [8]u8 = undefined;
        const dst: ?[]const u8 = switch (waddr) {
            0...31 => std.fmt.bufPrint(&dst_buf, "{s}[{d}]", .{ if (file == .a) "ra" else "rb", waddr }) catch unreachable,
            qpu.W.acc0...qpu.W.acc0 + 3 => std.fmt.bufPrint(&dst_buf, "r{d}", .{waddr - qpu.W.acc0}) catch unreachable,
            qpu.W.acc5 => "r5",
            else => null,
        };
        if (dst) |dv| {
            const test_expr: ?[]const u8 = switch (cond) {
                .never => unreachable,
                .always => null,
                .zs => "flag_z",
                .zc => "!flag_z",
                .ns => "flag_n",
                .nc => "!flag_n",
                .cs => "flag_c",
                .cc => "!flag_c",
            };
            try w.writeAll("    ");
            if (test_expr) |e| try w.print("if ({s}) ", .{e});
            try w.print("{s} = ", .{dv});
            try pack(w, dv, val, a_pack, mul_pack, float_result);
            return w.writeAll(";\n");
        }

        // Everything else is written whatever the condition (as qpu_sim does).
        if (t.stage == .vertex) {
            switch (waddr) {
                qpu.W.vpm => {
                    if (t.vpm_writes < 32) try w.print("    vo[{d}] = {s};\n", .{ t.vpm_writes, val });
                    t.vpm_writes += 1;
                    return;
                },
                qpu.W.tmu0_s...qpu.W.tmu1_b, qpu.W.tlb_color_all, qpu.W.tlb_color_ms => {
                    t.vertex.unsupported = true;
                    return;
                },
                else => {},
            }
        }
        // Colours written to the fragments the condition holds for (the others discarded).
        const tlb_test: []const u8 = switch (cond) {
            .never, .always => "true",
            .zs => "flag_z",
            .zc => "!flag_z",
            .ns => "flag_n",
            .nc => "!flag_n",
            .cs => "flag_c",
            .cc => "!flag_c",
        };
        switch (waddr) {
            // Run once a sample, each sample's colour is the write to it.
            qpu.W.tlb_color_ms => if (t.shader.per_sample) {
                try w.print("    if (gl_SampleID == {d} && {s}) {{ tlb_c = {s}; tlb_w = true; }}\n", .{ t.sample_writes, tlb_test, val });
                t.sample_writes += 1;
            } else try w.print("    if ({s}) {{ tlb_c = {s}; tlb_w = true; }}\n", .{ tlb_test, val }),
            qpu.W.tlb_color_all => try w.print("    if ({s}) {{ tlb_c = {s}; tlb_w = true; }}\n", .{ tlb_test, val }),
            qpu.W.sfu_recip => if (t.lang == .glsl)
                try w.print("    r4 = q_recip({s});\n", .{val})
            else
                try w.print("    r4 = u(1.0f / f({s}));\n", .{val}),
            qpu.W.sfu_recipsqrt => try w.print("    r4 = q_rsqrt({s});\n", .{val}),
            qpu.W.sfu_exp => try w.print("    r4 = q_exp2({s});\n", .{val}),
            qpu.W.sfu_log => try w.print("    r4 = q_log2({s});\n", .{val}),
            qpu.W.tmu0_s...qpu.W.tmu1_b => {
                const unit: usize = if (waddr <= qpu.W.tmu0_b) 0 else 1;
                const tmu = &t.tmu[unit];
                if (t.uniforms >= max_uniforms) t.tooManyUniforms();
                if ((waddr == qpu.W.tmu0_s or waddr == qpu.W.tmu1_s) and tmu.param_count == 0) t.shader.unsupported = true;
                if (t.uniforms < max_uniforms and tmu.param_count < 4) {
                    tmu.params[tmu.param_count] = t.uniforms;
                    tmu.param_count += 1;
                    t.uniforms += 1;
                }
                // The r and b coordinates (cube maps, child images, border colours, levels of
                // detail), and general memory lookups (s alone): left to qpu_sim.
                if ((waddr - qpu.W.tmu0_s) & 3 >= 2) t.shader.unsupported = true;
                if (waddr == qpu.W.tmu0_t or waddr == qpu.W.tmu1_t) {
                    try w.print("    tmu{d}_t = {s};\n", .{ unit, val });
                    tmu.has_t = true;
                    return;
                }
                if (waddr != qpu.W.tmu0_s and waddr != qpu.W.tmu1_s) return;
                if (tmu.param_count < 2 or tmu.len == 4) {
                    tmu.param_count = 0;
                    return;
                }
                const slot = tmu.head +% @as(u2, @truncate(tmu.len));
                // Whether the sample is called for (not with no unit left for it).
                var sampled = true;
                if (t.lang == .glsl) {
                    // Each texture sampled has a unit of its own.
                    const k = t.shader.sample_count;
                    if (k == max_samples) {
                        t.shader.too_many_samples = true;
                        sampled = false;
                        try w.print("    tmu{d}_f{d} = 0xff000000u;\n", .{ unit, slot });
                    } else {
                        t.shader.samples[k] = .{ .p0 = tmu.params[0], .p1 = tmu.params[1] };
                        t.shader.sample_count += 1;
                        try w.print("    tmu{d}_f{d} = tmu_sample(tex[{d}], tex_ok[{d}], unif[{d}], unif[{d}], f({s}), ", .{ unit, slot, k, k, tmu.params[0], tmu.params[1], val });
                    }
                } else {
                    try w.print("    tmu{d}_f{d} = tmu_sample(ram, di, unif[{d}], unif[{d}], f({s}), ", .{ unit, slot, tmu.params[0], tmu.params[1], val });
                }
                if (sampled) {
                    if (tmu.has_t) {
                        try w.print("f(tmu{d}_t));\n", .{unit});
                    } else {
                        try w.writeAll("0.0f);\n");
                    }
                }
                tmu.len += 1;
                tmu.param_count = 0;
                tmu.has_t = false;
            },
            else => {},
        }
    }
};

/// The value `m` gives an ALU input, unpacked as the instruction asks.
fn mux(buf: []u8, m: qpu.Mux, d: qpu_sim.DecodedInst, unpacks: bool, flt: bool) []const u8 {
    const name = switch (m) {
        .r0 => "r0",
        .r1 => "r1",
        .r2 => "r2",
        .r3 => "r3",
        .r4 => "r4",
        .r5 => "r5",
        .a => "pa",
        .b => "pb",
    };
    const mode: u3 = if (!unpacks) 0 else switch (m) {
        .r4 => d.unpack_r4,
        .a => d.unpack_a,
        else => 0,
    };
    if (mode == 0) return name;
    return std.fmt.bufPrint(buf, "unpack({s}, {d}u, {s})", .{ name, mode, if (flt) "true" else "false" }) catch unreachable;
}

fn addOp(w: *std.Io.Writer, lang: Language, op: qpu.AddOp, a: []const u8, b: []const u8) !void {
    if (lang == .glsl) switch (op) {
        .fadd => return w.print("q_fadd({s}, {s})", .{ a, b }),
        .fsub => return w.print("q_fsub({s}, {s})", .{ a, b }),
        else => {},
    };
    switch (op) {
        .fadd => try w.print("u(f({s}) + f({s}))", .{ a, b }),
        .fsub => try w.print("u(f({s}) - f({s}))", .{ a, b }),
        .fmin => try w.print("u(fmin(f({s}), f({s})))", .{ a, b }),
        .fmax => try w.print("u(fmax(f({s}), f({s})))", .{ a, b }),
        .fminabs => try w.print("u(fmin(fabs(f({s})), fabs(f({s}))))", .{ a, b }),
        .fmaxabs => try w.print("u(fmax(fabs(f({s})), fabs(f({s}))))", .{ a, b }),
        .ftoi => try w.print("ftoi({s})", .{a}),
        .itof => try w.print("u(float(int({s})))", .{a}),
        .add => try w.print("({s} + {s})", .{ a, b }),
        .sub => try w.print("({s} - {s})", .{ a, b }),
        .shr => try w.print("({s} >> ({s} & 31u))", .{ a, b }),
        .asr => try w.print("uint(int({s}) >> int({s} & 31u))", .{ a, b }),
        .ror => try w.print("ror({s}, {s})", .{ a, b }),
        .shl => try w.print("({s} << ({s} & 31u))", .{ a, b }),
        .min => try w.print("uint(min(int({s}), int({s})))", .{ a, b }),
        .max => try w.print("uint(max(int({s}), int({s})))", .{ a, b }),
        .@"and" => try w.print("({s} & {s})", .{ a, b }),
        .@"or" => try w.print("({s} | {s})", .{ a, b }),
        .xor => try w.print("({s} ^ {s})", .{ a, b }),
        .not => try w.print("(~{s})", .{a}),
        .clz => try w.print("clz({s})", .{a}),
        .v8adds => try w.print("v8adds({s}, {s})", .{ a, b }),
        .v8subs => try w.print("v8subs({s}, {s})", .{ a, b }),
        else => try w.writeAll("0u"),
    }
}

fn mulOp(w: *std.Io.Writer, lang: Language, op: qpu.MulOp, a: []const u8, b: []const u8) !void {
    if (lang == .glsl and op == .fmul) return w.print("q_fmul({s}, {s})", .{ a, b });
    switch (op) {
        .nop => try w.writeAll("0u"),
        .fmul => try w.print("u(f({s}) * f({s}))", .{ a, b }),
        .mul24 => try w.print("(({s} & 0xffffffu) * ({s} & 0xffffffu))", .{ a, b }),
        .v8muld => try w.print("v8muld({s}, {s})", .{ a, b }),
        .v8min => try w.print("v8min({s}, {s})", .{ a, b }),
        .v8max => try w.print("v8max({s}, {s})", .{ a, b }),
        .v8adds => try w.print("v8adds({s}, {s})", .{ a, b }),
        .v8subs => try w.print("v8subs({s}, {s})", .{ a, b }),
    }
}

/// `val` packed into `dst` as qpu_sim's `packVec` does.
/// Whether `op` gives a float (which a 16-bit pack converts to a 16-bit float).
fn floatResult(op: qpu.AddOp) bool {
    return switch (op) {
        .fadd, .fsub, .fmin, .fmax, .fminabs, .fmaxabs, .itof => true,
        else => false,
    };
}

fn pack(w: *std.Io.Writer, dst: []const u8, val: []const u8, a_pack: u4, mul_pack: u4, float_result: bool) !void {
    if (a_pack == 0) {
        const shift = (@as(u32, mul_pack) -% 4) *% 8;
        return switch (mul_pack) {
            3 => w.print("unorm8({s}) * 0x01010101u", .{val}),
            4, 5, 6, 7 => w.print("({s} & ~(0xffu << {d})) | (unorm8({s}) << {d})", .{ dst, shift, val, shift }),
            else => w.writeAll(val),
        };
    }
    const shift = (@as(u32, a_pack & 7) -% 4) *% 8;
    // A half: a 16-bit float of a float result, else the integer's low 16 bits (saturated for 9
    // and 10); a byte: the low 8 bits, or (11 to 15) saturated.
    var half_buf: [96]u8 = undefined;
    const half = if (float_result)
        std.fmt.bufPrint(&half_buf, "q_half({s})", .{val}) catch unreachable
    else if (a_pack >= 8)
        std.fmt.bufPrint(&half_buf, "q_sat16({s})", .{val}) catch unreachable
    else
        std.fmt.bufPrint(&half_buf, "({s} & 0xffffu)", .{val}) catch unreachable;
    var byte_buf: [96]u8 = undefined;
    const byte = if (a_pack >= 8)
        std.fmt.bufPrint(&byte_buf, "q_sat8({s})", .{val}) catch unreachable
    else
        std.fmt.bufPrint(&byte_buf, "({s} & 0xffu)", .{val}) catch unreachable;
    return switch (a_pack) {
        1, 9 => w.print("({s} & 0xffff0000u) | {s}", .{ dst, half }),
        2, 10 => w.print("({s} & 0xffffu) | ({s} << 16)", .{ dst, half }),
        3, 11 => w.print("{s} * 0x01010101u", .{byte}),
        4, 5, 6, 7, 12, 13, 14, 15 => w.print("({s} & ~(0xffu << {d})) | ({s} << {d})", .{ dst, shift, byte, shift }),
        else => w.writeAll(val),
    };
}

fn translateForTest(code: []const qpu.Inst, out: []u8) ![]const u8 {
    var decoded_buf: [64]qpu_sim.DecodedInst = undefined;
    var w: std.Io.Writer = .fixed(out);
    _ = try translate(&w, qpu_sim.decodeProgram(code, &decoded_buf), .msl);
    return w.buffered();
}

test "QPU to MSL: varying interpolation is fused, and colour packed into the TLB" {
    var p: qpu.Program(16) = .{};
    for (0..3) |i| {
        const acc: u3 = @intCast(i);
        p.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(acc), .a = qpu.vary, .b = qpu.frag_w } }));
        p.emit(try qpu.alu(.{ .add = .{ .op = .fadd, .dst = qpu.wr(acc), .a = qpu.r(acc), .b = qpu.r(5) } }));
    }
    const one = qpu.smallImmFloat(1.0);
    p.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = qpu.r(2), .b = one }, .pack = .{ .mul = .@"8a" } }));
    p.emit(try qpu.mov(qpu.tlb_color_all, qpu.r(3)));
    p.end(.fragment);

    var buf: [32 * 1024]u8 = undefined;
    const src = try translateForTest(p.code(), &buf);
    // Three varyings, each read once and given back whole.
    try std.testing.expect(std.mem.indexOf(u8, src, "0u < di.n_var ? u(V[0])") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "2u < di.n_var ? u(V[2])") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "3u < di.n_var") == null);
    try std.testing.expect(std.mem.indexOf(u8, src, "(r3 & ~(0xffu << 0)) | (unorm8(mul_r) << 0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "tlb_c = ") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "tlb_in") == null);
}

test "QPU to MSL: a texture sample takes its parameters from the uniforms in order" {
    var p: qpu.Program(16) = .{};
    // A uniform first, then the TMU's two parameters as s and t are written.
    p.emit(try qpu.mov(qpu.wr(0), qpu.unif));
    p.emit(try qpu.mov(.{ .periph = qpu.W.tmu0_t }, qpu.r(0)));
    p.emit(try qpu.mov(.{ .periph = qpu.W.tmu0_s }, qpu.r(0)));
    p.emit(qpu.nop(.load_tmu0));
    p.emit(try qpu.mov(qpu.tlb_color_all, qpu.r(4)));
    p.end(.fragment);

    var buf: [32 * 1024]u8 = undefined;
    const src = try translateForTest(p.code(), &buf);
    try std.testing.expect(std.mem.indexOf(u8, src, "pa = unif[0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "tmu0_f0 = tmu_sample(ram, di, unif[1], unif[2], f(add_r), f(tmu0_t))") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "r4 = tmu0_f0;") != null);
}
