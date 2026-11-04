//! Translates VideoCore IV QPU fragment shaders into the Metal Shading Language, for drawing V3D
//! jobs with Metal (`metal_renderer.zig`). A fragment runs the program as one lane of the QPU, in the
//! order `qpu_sim` runs it, so both draw the same pixels: what `qpu_sim` follows at run time (which
//! uniform is read next, the TMU FIFOs, which varying) is followed here while translating, as the
//! programs have no branches that `qpu_sim` takes.

const std = @import("std");
const qpu = @import("qpu.zig");
const qpu_sim = @import("qpu_sim.zig");

/// The uniforms a draw's fragment shader is given (`unif`, a buffer of this many words).
pub const max_uniforms = 128;
/// The varyings a fragment is given.
pub const max_varyings = 16;

/// What a translated shader needs.
pub const Shader = struct {
    /// Reads the tile buffer's colour (`color_load`), with framebuffer fetch.
    reads_color: bool = false,
};

/// MSL shared by the shaders: the vertex a triangle's corner is drawn from, what a fragment is
/// given, and the helpers the fragment shaders and kernels use. `Vertex` and `DrawInfo` are laid out
/// as the structs of the same names in `metal_renderer.zig`.
pub const common =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct Vertex {
    \\  float x, y, z, inv_w;
    \\  uint unit_w, pad0, pad1, pad2;
    \\  float4 v0, v1, v2, v3;
    \\};
    \\
    \\struct VOut {
    \\  float4 pos [[position]];
    \\  float inv_w [[center_no_perspective]];
    \\  uint unit_w [[flat]];
    \\  float4 v0 [[center_no_perspective]];
    \\  float4 v1 [[center_no_perspective]];
    \\  float4 v2 [[center_no_perspective]];
    \\  float4 v3 [[center_no_perspective]];
    \\};
    \\
    \\struct DrawInfo {
    \\  uint n_var;
    \\  uint ram_len;
    \\  uint ram_mask;
    \\  uint pad;
    \\};
    \\
    \\struct FragOut {
    \\  uint color [[color(0)]];
    \\};
    \\
    \\static inline float f(uint x) { return as_type<float>(x); }
    \\static inline uint u(float x) { return as_type<uint>(x); }
    \\
    \\static inline uint unorm8(uint v) {
    \\  float x = f(v);
    \\  if (isnan(x)) x = 0.0f;
    \\  x = min(max(x, 0.0f), 1.0f);
    \\  return uint(round(x * 255.0f));
    \\}
    \\
    \\static inline uint ftoi(uint v) {
    \\  float x = f(v);
    \\  if (isnan(x)) x = 0.0f;
    \\  x = min(max(x, -2147483648.0f), 2147483520.0f);
    \\  return uint(int(x));
    \\}
    \\
    \\static inline uint unpack(uint v, uint mode, bool flt) {
    \\  switch (mode) {
    \\  case 1: { int s = int(v << 16) >> 16; return flt ? u(float(s)) : uint(s); }
    \\  case 2: { int s = int(v) >> 16; return flt ? u(float(s)) : uint(s); }
    \\  case 3: return (v >> 24) * 0x01010101u;
    \\  case 4: case 5: case 6: case 7: {
    \\    uint b = (v >> ((mode - 4) * 8)) & 0xffu;
    \\    return flt ? u(float(b) * (1.0f / 255.0f)) : b;
    \\  }
    \\  default: return v;
    \\  }
    \\}
    \\
    \\static inline uint ror(uint a, uint b) {
    \\  uint s = b & 31u;
    \\  return (a >> s) | (a << ((32u - s) & 31u));
    \\}
    \\static inline uint v8adds(uint a, uint b) { return as_type<uint>(addsat(as_type<uchar4>(a), as_type<uchar4>(b))); }
    \\static inline uint v8subs(uint a, uint b) { return as_type<uint>(subsat(as_type<uchar4>(a), as_type<uchar4>(b))); }
    \\static inline uint v8min(uint a, uint b) { return as_type<uint>(min(as_type<uchar4>(a), as_type<uchar4>(b))); }
    \\static inline uint v8max(uint a, uint b) { return as_type<uint>(max(as_type<uchar4>(a), as_type<uchar4>(b))); }
    \\static inline uint v8muld(uint a, uint b) {
    \\  uint4 p = uint4(as_type<uchar4>(a)) * uint4(as_type<uchar4>(b)) + 127u;
    \\  uint4 d = (p + 1u + (p >> 8)) >> 8;
    \\  return as_type<uint>(uchar4(d & 0xffu));
    \\}
    \\
    \\// The TMU (qpu_sim's PrecomputedTex), reading textures from the guest's RAM.
    \\struct Tex {
    \\  uint type, base, cpp, width, height;
    \\  float fw, fh;
    \\  uint uw_shift, uh_shift, uw_mask, uh_mask, cpp_shift, alpha_or;
    \\  bool small;
    \\  uint utiles_per_row, tile_w_shift, tile_h_shift, tiles_per_row;
    \\  uint wrap_s, wrap_t;
    \\  bool nearest;
    \\};
    \\
    \\static inline bool tex_init(uint p0, uint p1, uint ram_mask, thread Tex& t) {
    \\  t.type = ((p0 >> 4) & 0xfu) | ((p1 >> 31) << 4);
    \\  switch (t.type) {
    \\  case 0: case 1: case 16: t.cpp = 4; break;
    \\  case 4: t.cpp = 2; break;
    \\  case 5: case 6: t.cpp = 1; break;
    \\  default: return false;
    \\  }
    \\  uint w = (p1 >> 8) & 2047u;
    \\  uint h = (p1 >> 20) & 2047u;
    \\  t.width = w == 0 ? 2048u : w;
    \\  t.height = h == 0 ? 2048u : h;
    \\  t.base = (p0 & 0xfffff000u) & ram_mask;
    \\  t.fw = float(t.width);
    \\  t.fh = float(t.height);
    \\  t.nearest = ((p1 >> 7) & 1u) != 0;
    \\  t.wrap_s = p1 & 3u;
    \\  t.wrap_t = (p1 >> 2) & 3u;
    \\  t.uw_shift = t.cpp == 4 ? 2u : 3u;
    \\  t.uh_shift = t.cpp == 1 ? 3u : 2u;
    \\  uint uw = 1u << t.uw_shift;
    \\  uint uh = 1u << t.uh_shift;
    \\  t.uw_mask = uw - 1;
    \\  t.uh_mask = uh - 1;
    \\  t.cpp_shift = t.cpp == 4 ? 2u : (t.cpp == 2 ? 1u : 0u);
    \\  t.alpha_or = t.type == 1 ? 0xff000000u : 0u;
    \\  t.small = t.width <= (uw << 2) || t.height <= (uh << 2);
    \\  t.utiles_per_row = (t.width + uw - 1) >> t.uw_shift;
    \\  t.tile_w_shift = t.uw_shift + 3;
    \\  t.tile_h_shift = t.uh_shift + 3;
    \\  t.tiles_per_row = (t.width + (1u << t.tile_w_shift) - 1) >> t.tile_w_shift;
    \\  return true;
    \\}
    \\
    \\static inline uint tex_offset(thread const Tex& t, uint x, uint y) {
    \\  if (t.type == 16) return (y * t.width + x) << 2;
    \\  uint in_utile = (((y & t.uh_mask) << t.uw_shift) | (x & t.uw_mask)) << t.cpp_shift;
    \\  if (t.small) return (((y >> t.uh_shift) * t.utiles_per_row + (x >> t.uw_shift)) << 6) + in_utile;
    \\  uint tile_row = y >> t.tile_h_shift;
    \\  uint tile_col = (tile_row & 1) == 0 ? (x >> t.tile_w_shift) : t.tiles_per_row - 1 - (x >> t.tile_w_shift);
    \\  uint tile_base = (tile_row * t.tiles_per_row + tile_col) << 12;
    \\  uint stile = (((y >> (t.uh_shift + 2)) & 1) << 1) | ((x >> (t.uw_shift + 2)) & 1);
    \\  const uint even_map[4] = {0, 3, 1, 2};
    \\  const uint odd_map[4] = {2, 1, 3, 0};
    \\  uint sub = (tile_row & 1) == 0 ? even_map[stile] : odd_map[stile];
    \\  uint utile_in_sub = (((y >> t.uh_shift) & 3) << 2) | ((x >> t.uw_shift) & 3);
    \\  return tile_base + (sub << 10) + (utile_in_sub << 6) + in_utile;
    \\}
    \\
    \\static inline uint rgb565(uint p) {
    \\  uint b = p >> 11;
    \\  uint g = (p >> 5) & 0x3fu;
    \\  uint r = p & 0x1fu;
    \\  return 0xff000000u | ((r << 3) | (r >> 2)) << 16 | ((g << 2) | (g >> 4)) << 8 | ((b << 3) | (b >> 2));
    \\}
    \\
    \\static inline uint to_rgb565(uint argb) {
    \\  uint r = (argb >> 16) & 0xffu;
    \\  uint g = (argb >> 8) & 0xffu;
    \\  uint b = argb & 0xffu;
    \\  return ((b * 31 + 127) / 255) << 11 | ((g * 63 + 127) / 255) << 5 | (r * 31 + 127) / 255;
    \\}
    \\
    \\static inline bool tex_fetch(device const uchar* ram, uint ram_len, thread const Tex& t, uint x, uint y, thread uint& out) {
    \\  uint off = t.base + tex_offset(t, x, y);
    \\  if (ulong(off) + t.cpp > ram_len) return false;
    \\  if (t.cpp == 4) {
    \\    out = *(device const uint*)(ram + off) | t.alpha_or;
    \\  } else if (t.cpp == 1) {
    \\    uint l = ram[off];
    \\    out = t.type == 5 ? (0xff000000u | (l * 0x010101u)) : (l << 24);
    \\  } else {
    \\    out = rgb565(*(device const ushort*)(ram + off));
    \\  }
    \\  return true;
    \\}
    \\
    \\static inline uint tex_wrap(float c, uint size, uint mode) {
    \\  int n = int(max(size, 1u));
    \\  int i = isnan(c) ? 0 : int(clamp(c, -1e9f, 1e9f));
    \\  if (mode == 0) {
    \\    int m = i % n;
    \\    return uint(m < 0 ? m + n : m);
    \\  }
    \\  return uint(clamp(i, 0, n - 1));
    \\}
    \\
    \\static inline uint tmu_sample(device const uchar* ram, constant DrawInfo& di, uint p0, uint p1, float s, float tc) {
    \\  Tex t;
    \\  if (!tex_init(p0, p1, di.ram_mask, t)) return 0xff000000u;
    \\  uint c00;
    \\  if (t.nearest) {
    \\    float fx = floor(s * t.fw);
    \\    float fy = floor(tc * t.fh);
    \\    uint wx = (fx >= 0.0f && fx < t.fw) ? uint(fx) : tex_wrap(fx, t.width, t.wrap_s);
    \\    uint wy = (fy >= 0.0f && fy < t.fh) ? uint(fy) : tex_wrap(fy, t.height, t.wrap_t);
    \\    return tex_fetch(ram, di.ram_len, t, wx, wy, c00) ? c00 : 0xff000000u;
    \\  }
    \\  float fx = s * t.fw - 0.5f;
    \\  float fy = tc * t.fh - 0.5f;
    \\  float x0 = floor(fx);
    \\  float y0 = floor(fy);
    \\  uint wx0, wx1, wy0, wy1;
    \\  if (x0 >= 0.0f && x0 + 1.0f < t.fw) {
    \\    wx0 = uint(x0);
    \\    wx1 = wx0 + 1;
    \\  } else {
    \\    wx0 = tex_wrap(x0, t.width, t.wrap_s);
    \\    wx1 = tex_wrap(x0 + 1.0f, t.width, t.wrap_s);
    \\  }
    \\  if (y0 >= 0.0f && y0 + 1.0f < t.fh) {
    \\    wy0 = uint(y0);
    \\    wy1 = wy0 + 1;
    \\  } else {
    \\    wy0 = tex_wrap(y0, t.height, t.wrap_t);
    \\    wy1 = tex_wrap(y0 + 1.0f, t.height, t.wrap_t);
    \\  }
    \\  uint fxf = uint(round((fx - x0) * 256.0f));
    \\  uint fyf = uint(round((fy - y0) * 256.0f));
    \\  if (!tex_fetch(ram, di.ram_len, t, wx0, wy0, c00)) return 0xff000000u;
    \\  if (fxf == 0 && fyf == 0) return c00;
    \\  uint c10, c01, c11;
    \\  if (!tex_fetch(ram, di.ram_len, t, wx1, wy0, c10)) return 0xff000000u;
    \\  if (!tex_fetch(ram, di.ram_len, t, wx0, wy1, c01)) return 0xff000000u;
    \\  if (!tex_fetch(ram, di.ram_len, t, wx1, wy1, c11)) return 0xff000000u;
    \\  if (c00 == c10 && c00 == c01 && c00 == c11) return c00;
    \\  uint ix = 256 - fxf;
    \\  uint iy = 256 - fyf;
    \\  uint w00 = (ix * iy + 128) >> 8;
    \\  uint w10 = (fxf * iy + 128) >> 8;
    \\  uint w01 = (ix * fyf + 128) >> 8;
    \\  uint ws = w00 + w10 + w01;
    \\  uint w11 = ws >= 256 ? 0u : 256 - ws;
    \\  uint4 sum = uint4(as_type<uchar4>(c00)) * w00 + uint4(as_type<uchar4>(c10)) * w10 +
    \\    uint4(as_type<uchar4>(c01)) * w01 + uint4(as_type<uchar4>(c11)) * w11 + 128u;
    \\  return as_type<uint>(uchar4((sum >> 8) & 0xffu));
    \\}
    \\
    \\// Where a pixel of a framebuffer is in RAM (texture.texelOffsetOf), for 32 bpp or 16 bpp.
    \\static inline uint fb_offset(uint cpp, uint width, uint height, uint x, uint y) {
    \\  uint uw_shift = cpp == 4 ? 2u : 3u;
    \\  uint uh_shift = 2u;
    \\  uint uw = 1u << uw_shift;
    \\  uint uh = 1u << uh_shift;
    \\  uint cpp_shift = cpp == 4 ? 2u : 1u;
    \\  uint in_utile = (((y & (uh - 1)) << uw_shift) | (x & (uw - 1))) << cpp_shift;
    \\  if (width <= (uw << 2) || height <= (uh << 2)) {
    \\    uint row_stride = ((width + uw - 1) & ~(uw - 1)) << cpp_shift;
    \\    return (y & ~(uh - 1)) * row_stride + ((x >> uw_shift) << 6) + in_utile;
    \\  }
    \\  uint tile_w = uw << 3;
    \\  uint utile_stride = ((width + tile_w - 1) & ~(tile_w - 1)) >> uw_shift;
    \\  uint utile_x = x >> uw_shift;
    \\  uint utile_y = y >> uh_shift;
    \\  uint in_subtile = (((utile_y & 3) << 2) | (utile_x & 3)) << 6;
    \\  uint tile_stride = utile_stride >> 3;
    \\  uint tx = (utile_x & ~3u) >> 3;
    \\  uint ty = (utile_y & ~3u) >> 3;
    \\  bool odd_row = (ty & 1) != 0;
    \\  if (odd_row) tx = tile_stride - tx - 1;
    \\  uint stile = (((utile_y >> 2) & 1) << 1) | ((utile_x >> 2) & 1);
    \\  const uint odd_map[4] = {2, 1, 3, 0};
    \\  const uint even_map[4] = {0, 3, 1, 2};
    \\  uint sub = odd_row ? odd_map[stile] : even_map[stile];
    \\  return ((ty * tile_stride + tx) << 12) + (sub << 10) + in_subtile + in_utile;
    \\}
    \\
;

/// MSL of the vertex shader all draws share, and the kernels that load the tile buffer from RAM and
/// store it back (`ls_load`, `ls_store`); compiled after `common`. `LoadStore` is laid out as the
/// struct of the same name in `metal_renderer.zig`.
pub const shared_functions =
    \\vertex VOut vertex_main(uint vid [[vertex_id]], device const Vertex* verts [[buffer(0)]],
    \\    constant float2& fb [[buffer(1)]]) {
    \\  Vertex v = verts[vid];
    \\  VOut o;
    \\  o.pos = float4(v.x / fb.x * 2.0f - 1.0f, 1.0f - v.y / fb.y * 2.0f, v.z, 1.0f);
    \\  o.inv_w = v.inv_w;
    \\  o.unit_w = v.unit_w;
    \\  o.v0 = v.v0;
    \\  o.v1 = v.v1;
    \\  o.v2 = v.v2;
    \\  o.v3 = v.v3;
    \\  return o;
    \\}
    \\
    \\struct LoadStore {
    \\  uint base;
    \\  uint fb_w;
    \\  uint fb_h;
    \\  uint tiling;
    \\  uint cpp;
    \\  uint ram_len;
    \\  uint pad0, pad1;
    \\  uint tiles[32];
    \\};
    \\
    \\static inline bool ls_pixel(constant LoadStore& ls, uint2 p, thread uint& off) {
    \\  if (p.x >= ls.fb_w || p.y >= ls.fb_h) return false;
    \\  if (((ls.tiles[p.y >> 6] >> (p.x >> 6)) & 1u) == 0) return false;
    \\  uint rel = ls.tiling == 0 ? (p.y * ls.fb_w + p.x) * ls.cpp : fb_offset(ls.cpp, ls.fb_w, ls.fb_h, p.x, p.y);
    \\  off = ls.base + rel;
    \\  return ulong(off) + ls.cpp <= ls.ram_len;
    \\}
    \\
    \\kernel void ls_load(texture2d<uint, access::write> tile [[texture(0)]], device const uchar* ram [[buffer(0)]],
    \\    constant LoadStore& ls [[buffer(1)]], uint2 p [[thread_position_in_grid]]) {
    \\  uint off;
    \\  if (!ls_pixel(ls, p, off)) return;
    \\  uint c = ls.cpp == 4 ? *(device const uint*)(ram + off) : rgb565(*(device const ushort*)(ram + off));
    \\  tile.write(uint4(c, 0, 0, 0), p);
    \\}
    \\
    \\kernel void ls_store(texture2d<uint, access::read> tile [[texture(0)]], device uchar* ram [[buffer(0)]],
    \\    constant LoadStore& ls [[buffer(1)]], uint2 p [[thread_position_in_grid]]) {
    \\  uint off;
    \\  if (!ls_pixel(ls, p, off)) return;
    \\  uint c = tile.read(p).r;
    \\  if (ls.cpp == 4) {
    \\    *(device uint*)(ram + off) = c;
    \\  } else {
    \\    *(device ushort*)(ram + off) = ushort(to_rgb565(c));
    \\  }
    \\}
    \\
;

/// The varying interpolation `qpu_sim` stands for: `fmul acc, vary, frag_w` then `fadd dst, acc, r5`
/// gives back the varying, with `r5` the constant it reads as.
const varying_c = "0.25f";

/// Writes `fragment_main` for the fragment shader `decoded` (`qpu_sim.decodeProgram`'s, so that the
/// varying interpolation pairs it fuses are fused here too).
pub fn translate(w: *std.Io.Writer, decoded: []const qpu_sim.DecodedInst) std.Io.Writer.Error!Shader {
    var t: Translator = .{ .w = w };
    // The tile's colour is an input only if the program reads it.
    for (decoded) |d| {
        if (d.sig == .color_load or d.sig == .color_load_end) t.shader.reads_color = true;
    }

    try w.writeAll(
        \\fragment FragOut fragment_main(VOut in [[stage_in]], constant uint* unif [[buffer(0)]],
        \\    device const uchar* ram [[buffer(1)]], constant DrawInfo& di [[buffer(2)]]
    );
    if (t.shader.reads_color) try w.writeAll(",\n    uint tlb_in [[color(0)]]");
    try w.writeAll(
        \\) {
        \\  float W = in.unit_w != 0u ? 1.0f : (fabs(in.inv_w) > 1e-12f ? 1.0f / in.inv_w : 1.0f);
        \\  float V[16] = {
        \\    in.v0.x * W, in.v0.y * W, in.v0.z * W, in.v0.w * W,
        \\    in.v1.x * W, in.v1.y * W, in.v1.z * W, in.v1.w * W,
        \\    in.v2.x * W, in.v2.y * W, in.v2.z * W, in.v2.w * W,
        \\    in.v3.x * W, in.v3.y * W, in.v3.z * W, in.v3.w * W,
        \\  };
        \\  uint ra[32] = {};
        \\  uint rb[32] = {};
        \\  ra[15] = u(W);
        \\  rb[15] = u(in.pos.z);
        \\  uint r0 = 0, r1 = 0, r2 = 0, r3 = 0, r4 = 0, r5 = 0, pa = 0, pb = 0;
        \\  bool flag_z = false, flag_n = false;
        \\  uint px = uint(in.pos.x), py = uint(in.pos.y);
        \\  uint tlb_c = 0;
        \\  bool tlb_w = false;
        \\  uint tmu0_t = 0, tmu1_t = 0;
        \\  uint tmu0_f0 = 0, tmu0_f1 = 0, tmu0_f2 = 0, tmu0_f3 = 0;
        \\  uint tmu1_f0 = 0, tmu1_f1 = 0, tmu1_f2 = 0, tmu1_f3 = 0;
        \\
    );

    var end_at: ?usize = null;
    var ip: usize = 0;
    while (ip < decoded.len) : (ip += 1) {
        if (end_at) |e| if (ip > e) break;
        const d = decoded[ip];
        if (d.sig == .branch) continue;
        try w.print("  {{ // {d}\n", .{ip});

        if ((d.flags & qpu_sim.DecodedInst.FLAG_FUSED_LINTERP) != 0) {
            const k = t.varyings;
            t.varyings += 1;
            try w.print("    uint val = {d}u < di.n_var ? u(V[{d}]) : 0u;\n", .{ k, @min(k, max_varyings - 1) });
            try w.print("    r5 = u({s});\n", .{varying_c});
            if (d.waddr_add != d.waddr_mul) {
                try w.print("    r{d} = u(f(val) - {s});\n", .{ d.waddr_mul - qpu.W.acc0, varying_c });
            }
            try t.write(d.waddr_add, d.add_file, "val", .always, 0, 0);
            try w.writeAll("  }\n");
            ip += 1;
            continue;
        }

        if (d.sig == .load_imm) {
            try w.print("    uint add_r = 0x{x}u, mul_r = 0x{x}u;\n", .{ d.imm_or_small, d.imm_or_small });
        } else {
            if ((d.flags & qpu_sim.DecodedInst.FLAG_FETCH_A) != 0) {
                try w.writeAll("    pa = ");
                try t.port(d.raddr_a, .a);
                try w.writeAll(";\n");
            }
            if (d.sig == .small_imm) {
                try w.print("    pb = 0x{x}u;\n", .{d.imm_or_small});
            } else if ((d.flags & qpu_sim.DecodedInst.FLAG_FETCH_B) != 0) {
                try w.writeAll("    pb = ");
                try t.port(d.raddr_b, .b);
                try w.writeAll(";\n");
            }

            const unpacks = (d.flags & qpu_sim.DecodedInst.FLAG_HAS_UNPACK) != 0;
            try w.writeAll("    uint add_r = ");
            if (d.add_op != .nop) {
                const flt = (d.flags & qpu_sim.DecodedInst.FLAG_FLT_ADD) != 0;
                var in0: [48]u8 = undefined;
                var in1: [48]u8 = undefined;
                try addOp(w, d.add_op, mux(&in0, d.mux0, d, unpacks, flt), mux(&in1, d.mux1, d, unpacks, flt));
            } else {
                try w.writeAll("0u");
            }
            try w.writeAll(";\n    uint mul_r = ");
            if (d.mul_op != .nop) {
                const flt = (d.flags & qpu_sim.DecodedInst.FLAG_FLT_MUL) != 0;
                var in2: [48]u8 = undefined;
                var in3: [48]u8 = undefined;
                try mulOp(w, d.mul_op, mux(&in2, d.mux2, d, unpacks, flt), mux(&in3, d.mux3, d, unpacks, flt));
            } else {
                try w.writeAll("0u");
            }
            try w.writeAll(";\n");

            if ((d.flags & qpu_sim.DecodedInst.FLAG_SF) != 0) {
                const from = if (d.add_op != .nop) "add_r" else "mul_r";
                try w.print("    flag_z = int({s}) == 0; flag_n = int({s}) < 0;\n", .{ from, from });
            }
            if ((d.flags & qpu_sim.DecodedInst.FLAG_READS_VARY) != 0) {
                try w.print("    r5 = u({s});\n", .{varying_c});
            }
        }

        try t.write(d.waddr_add, d.add_file, "add_r", d.cond_add, d.add_pack_a, 0);
        try t.write(d.waddr_mul, d.mul_file, "mul_r", d.cond_mul, d.mul_pack_a, d.mul_pack_m);

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
                try w.writeAll("    r4 = tlb_in;\n");
                if (d.sig == .color_load_end) end_at = ip + 2;
            },
            .prog_end => end_at = ip + 2,
            else => {},
        }
        try w.writeAll("  }\n");
    }

    // Without an end the program fails in qpu_sim, and draws nothing.
    if (end_at == null) try w.writeAll("  discard_fragment();\n");
    try w.writeAll(
        \\  if (!tlb_w) discard_fragment();
        \\  FragOut o;
        \\  o.color = tlb_c;
        \\  return o;
        \\}
        \\
    );
    return t.shader;
}

const Translator = struct {
    w: *std.Io.Writer,
    shader: Shader = .{},
    /// The next uniform and varying read.
    uniforms: usize = 0,
    varyings: usize = 0,
    tmu: [2]Tmu = .{ .{}, .{} },

    /// A TMU's parameters written so far (the uniforms they are), and the samples waiting in its
    /// FIFO (`tmuN_fM`).
    const Tmu = struct {
        params: [4]usize = undefined,
        param_count: u8 = 0,
        has_t: bool = false,
        head: u2 = 0,
        len: u3 = 0,
    };

    fn port(t: *Translator, raddr: u6, file: qpu_sim.File) !void {
        const w = t.w;
        if (raddr < 32) return w.print("{s}[{d}]", .{ if (file == .a) "ra" else "rb", raddr });
        switch (raddr) {
            qpu.R.unif => {
                if (t.uniforms >= max_uniforms) return w.writeAll("0u");
                try w.print("unif[{d}]", .{t.uniforms});
                t.uniforms += 1;
            },
            qpu.R.vary => {
                const k = t.varyings;
                t.varyings += 1;
                try w.print("({d}u < di.n_var ? u((V[{d}] - {s}) / W) : 0u)", .{ k, @min(k, max_varyings - 1), varying_c });
            },
            qpu.R.elem_qpu => try w.writeAll("(px & 15u)"),
            qpu.R.xy_pixel_coord => try w.writeAll(if (file == .a) "px" else "py"),
            else => try w.writeAll("0u"),
        }
    }

    fn write(t: *Translator, waddr: u6, file: qpu_sim.File, val: []const u8, cond: qpu.Cond, a_pack: u4, mul_pack: u4) !void {
        if (waddr == qpu.W.nop or cond == .never) return;
        const w = t.w;
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
                .cs, .cc => "false",
            };
            try w.writeAll("    ");
            if (test_expr) |e| try w.print("if ({s}) ", .{e});
            try w.print("{s} = ", .{dv});
            try pack(w, dv, val, a_pack, mul_pack);
            return w.writeAll(";\n");
        }

        // Everything else is written whatever the condition (as qpu_sim does).
        switch (waddr) {
            qpu.W.tlb_color_all, qpu.W.tlb_color_ms => try w.print("    tlb_c = {s}; tlb_w = true;\n", .{val}),
            qpu.W.sfu_recip => try w.print("    r4 = u(1.0f / f({s}));\n", .{val}),
            qpu.W.sfu_recipsqrt => try w.print("    r4 = u(1.0f / sqrt(f({s})));\n", .{val}),
            qpu.W.sfu_exp => try w.print("    r4 = u(exp2(f({s})));\n", .{val}),
            qpu.W.sfu_log => try w.print("    r4 = u(log2(f({s})));\n", .{val}),
            qpu.W.tmu0_s...qpu.W.tmu1_b => {
                const unit: usize = if (waddr <= qpu.W.tmu0_b) 0 else 1;
                const tmu = &t.tmu[unit];
                if (t.uniforms < max_uniforms and tmu.param_count < 4) {
                    tmu.params[tmu.param_count] = t.uniforms;
                    tmu.param_count += 1;
                    t.uniforms += 1;
                }
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
                try w.print("    tmu{d}_f{d} = tmu_sample(ram, di, unif[{d}], unif[{d}], f({s}), ", .{ unit, slot, tmu.params[0], tmu.params[1], val });
                if (tmu.has_t) {
                    try w.print("f(tmu{d}_t));\n", .{unit});
                } else {
                    try w.writeAll("0.0f);\n");
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

fn addOp(w: *std.Io.Writer, op: qpu.AddOp, a: []const u8, b: []const u8) !void {
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

fn mulOp(w: *std.Io.Writer, op: qpu.MulOp, a: []const u8, b: []const u8) !void {
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
fn pack(w: *std.Io.Writer, dst: []const u8, val: []const u8, a_pack: u4, mul_pack: u4) !void {
    if (a_pack == 0) {
        const shift = (@as(u32, mul_pack) -% 4) *% 8;
        return switch (mul_pack) {
            3 => w.print("unorm8({s}) * 0x01010101u", .{val}),
            4, 5, 6, 7 => w.print("({s} & ~(0xffu << {d})) | (unorm8({s}) << {d})", .{ dst, shift, val, shift }),
            else => w.writeAll(val),
        };
    }
    const shift = (@as(u32, a_pack & 7) -% 4) *% 8;
    return switch (a_pack) {
        1, 9 => w.print("({s} & 0xffff0000u) | ({s} & 0xffffu)", .{ dst, val }),
        2, 10 => w.print("({s} & 0xffffu) | ({s} << 16)", .{ dst, val }),
        3, 11 => w.print("({s} & 0xffu) * 0x01010101u", .{val}),
        4, 5, 6, 7, 12, 13, 14, 15 => w.print("({s} & ~(0xffu << {d})) | (({s} & 0xffu) << {d})", .{ dst, shift, val, shift }),
        else => w.writeAll(val),
    };
}

fn translateForTest(code: []const qpu.Inst, out: []u8) ![]const u8 {
    var decoded_buf: [64]qpu_sim.DecodedInst = undefined;
    var w: std.Io.Writer = .fixed(out);
    _ = try translate(&w, qpu_sim.decodeProgram(code, &decoded_buf));
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
