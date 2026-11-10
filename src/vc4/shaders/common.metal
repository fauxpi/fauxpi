#include <metal_stdlib>
using namespace metal;
// Each QPU operation rounded on its own, as qpu_sim's are: no multiply-adds fused.
#pragma clang fp contract(off)

struct Vertex {
  float x, y, z, inv_w;
  uint unit_w, pad0, pad1, pad2;
  float4 v0, v1, v2, v3;
};

struct VOut {
  float4 pos [[position]];
  float inv_w [[center_no_perspective]];
  float not_unit_w [[center_no_perspective]];
  float4 v0 [[center_no_perspective]];
  float4 v1 [[center_no_perspective]];
  float4 v2 [[center_no_perspective]];
  float4 v3 [[center_no_perspective]];
};

struct DrawInfo {
  uint n_var;
  uint ram_len;
  uint ram_mask;
  uint pad;
};

struct FragOut {
  uint color [[color(0)]];
};

// What a vertex shader's kernel shades: `count` vertices, each given `n_vpm` VPM words (from word
// first_input, `stride` words apart), into verts from first_vertex.
struct VertexInfo {
  uint n_vpm;
  uint n_var;
  uint first_input;
  uint stride;
  uint count;
  uint first_vertex;
  float vp_x;
  float vp_y;
};

static inline float f(uint x) { return as_type<float>(x); }
static inline uint u(float x) { return as_type<uint>(x); }
// A 16-bit float's bits as a float's (exactly).
static inline uint q_unhalf(uint h) {
  uint sign = (h & 0x8000u) << 16;
  uint e = (h >> 10) & 0x1fu;
  uint m = h & 0x3ffu;
  if (e == 0u) { float v = float(m) * f(0x33800000u); return sign | u(v); }
  if (e == 31u) return sign | 0x7f800000u | (m << 13);
  return sign | ((e + 112u) << 23) | (m << 13);
}

static inline uint unorm8(uint v) {
  float x = f(v);
  if (isnan(x)) x = 0.0f;
  x = min(max(x, 0.0f), 1.0f);
  return uint(round(x * 255.0f));
}

static inline uint ftoi(uint v) {
  float x = f(v);
  if (isnan(x)) x = 0.0f;
  x = min(max(x, -2147483648.0f), 2147483520.0f);
  return uint(int(x));
}

static inline uint unpack(uint v, uint mode, bool flt) {
  switch (mode) {
  case 1: { int s = int(v << 16) >> 16; return flt ? q_unhalf(v & 0xffffu) : uint(s); }
  case 2: { int s = int(v) >> 16; return flt ? q_unhalf(v >> 16) : uint(s); }
  case 3: return (v >> 24) * 0x01010101u;
  case 4: case 5: case 6: case 7: {
    uint b = (v >> ((mode - 4) * 8)) & 0xffu;
    return flt ? u(float(b) * (1.0f / 255.0f)) : b;
  }
  default: return v;
  }
}

static inline uint ror(uint a, uint b) {
  uint s = b & 31u;
  return (a >> s) | (a << ((32u - s) & 31u));
}
static inline uint v8adds(uint a, uint b) { return as_type<uint>(addsat(as_type<uchar4>(a), as_type<uchar4>(b))); }
static inline uint v8subs(uint a, uint b) { return as_type<uint>(subsat(as_type<uchar4>(a), as_type<uchar4>(b))); }
static inline uint v8min(uint a, uint b) { return as_type<uint>(min(as_type<uchar4>(a), as_type<uchar4>(b))); }
static inline uint v8max(uint a, uint b) { return as_type<uint>(max(as_type<uchar4>(a), as_type<uchar4>(b))); }
static inline uint v8muld(uint a, uint b) {
  uint4 p = uint4(as_type<uchar4>(a)) * uint4(as_type<uchar4>(b)) + 127u;
  uint4 d = (p + 1u + (p >> 8)) >> 8;
  return as_type<uint>(uchar4(d & 0xffu));
}

// The TMU (qpu_sim's PrecomputedTex), reading textures from the guest's RAM.
struct Tex {
  uint type, base, cpp, width, height;
  float fw, fh;
  uint uw_shift, uh_shift, uw_mask, uh_mask, cpp_shift, alpha_or;
  bool small;
  uint utiles_per_row, tile_w_shift, tile_h_shift, tiles_per_row;
  uint wrap_s, wrap_t;
  bool nearest;
};

static inline bool tex_init(uint p0, uint p1, uint ram_mask, thread Tex& t) {
  t.type = ((p0 >> 4) & 0xfu) | ((p1 >> 31) << 4);
  switch (t.type) {
  case 0: case 1: case 16: t.cpp = 4; break;
  case 4: t.cpp = 2; break;
  case 5: case 6: t.cpp = 1; break;
  default: return false;
  }
  uint w = (p1 >> 8) & 2047u;
  uint h = (p1 >> 20) & 2047u;
  t.width = w == 0 ? 2048u : w;
  t.height = h == 0 ? 2048u : h;
  t.base = (p0 & 0xfffff000u) & ram_mask;
  t.fw = float(t.width);
  t.fh = float(t.height);
  t.nearest = ((p1 >> 7) & 1u) != 0;
  t.wrap_s = p1 & 3u;
  t.wrap_t = (p1 >> 2) & 3u;
  t.uw_shift = t.cpp == 4 ? 2u : 3u;
  t.uh_shift = t.cpp == 1 ? 3u : 2u;
  uint uw = 1u << t.uw_shift;
  uint uh = 1u << t.uh_shift;
  t.uw_mask = uw - 1;
  t.uh_mask = uh - 1;
  t.cpp_shift = t.cpp == 4 ? 2u : (t.cpp == 2 ? 1u : 0u);
  t.alpha_or = t.type == 1 ? 0xff000000u : 0u;
  t.small = t.width <= (uw << 2) || t.height <= (uh << 2);
  t.utiles_per_row = (t.width + uw - 1) >> t.uw_shift;
  t.tile_w_shift = t.uw_shift + 3;
  t.tile_h_shift = t.uh_shift + 3;
  t.tiles_per_row = (t.width + (1u << t.tile_w_shift) - 1) >> t.tile_w_shift;
  return true;
}

static inline uint tex_offset(thread const Tex& t, uint x, uint y) {
  if (t.type == 16) return (y * t.width + x) << 2;
  uint in_utile = (((y & t.uh_mask) << t.uw_shift) | (x & t.uw_mask)) << t.cpp_shift;
  if (t.small) return (((y >> t.uh_shift) * t.utiles_per_row + (x >> t.uw_shift)) << 6) + in_utile;
  uint tile_row = y >> t.tile_h_shift;
  uint tile_col = (tile_row & 1) == 0 ? (x >> t.tile_w_shift) : t.tiles_per_row - 1 - (x >> t.tile_w_shift);
  uint tile_base = (tile_row * t.tiles_per_row + tile_col) << 12;
  uint stile = (((y >> (t.uh_shift + 2)) & 1) << 1) | ((x >> (t.uw_shift + 2)) & 1);
  const uint even_map[4] = {0, 3, 1, 2};
  const uint odd_map[4] = {2, 1, 3, 0};
  uint sub = (tile_row & 1) == 0 ? even_map[stile] : odd_map[stile];
  uint utile_in_sub = (((y >> t.uh_shift) & 3) << 2) | ((x >> t.uw_shift) & 3);
  return tile_base + (sub << 10) + (utile_in_sub << 6) + in_utile;
}

static inline uint rgb565(uint p) {
  uint b = p >> 11;
  uint g = (p >> 5) & 0x3fu;
  uint r = p & 0x1fu;
  return 0xff000000u | ((r << 3) | (r >> 2)) << 16 | ((g << 2) | (g >> 4)) << 8 | ((b << 3) | (b >> 2));
}

static inline uint to_rgb565(uint argb) {
  uint r = (argb >> 16) & 0xffu;
  uint g = (argb >> 8) & 0xffu;
  uint b = argb & 0xffu;
  return ((b * 31 + 127) / 255) << 11 | ((g * 63 + 127) / 255) << 5 | (r * 31 + 127) / 255;
}

static inline bool tex_fetch(device const uchar* ram, uint ram_len, thread const Tex& t, uint x, uint y, thread uint& out) {
  uint off = t.base + tex_offset(t, x, y);
  if (ulong(off) + t.cpp > ram_len) return false;
  if (t.cpp == 4) {
    out = *(device const uint*)(ram + off) | t.alpha_or;
  } else if (t.cpp == 1) {
    uint l = ram[off];
    out = t.type == 5 ? (0xff000000u | (l * 0x010101u)) : (l << 24);
  } else {
    out = rgb565(*(device const ushort*)(ram + off));
  }
  return true;
}

static inline uint tex_wrap(float c, uint size, uint mode) {
  int n = int(max(size, 1u));
  int i = isnan(c) ? 0 : int(clamp(c, -1e9f, 1e9f));
  if (mode == 0) {
    int m = i % n;
    return uint(m < 0 ? m + n : m);
  }
  return uint(clamp(i, 0, n - 1));
}

static inline uint tmu_sample(device const uchar* ram, constant DrawInfo& di, uint p0, uint p1, float s, float tc) {
  Tex t;
  if (!tex_init(p0, p1, di.ram_mask, t)) return 0xff000000u;
  uint c00;
  if (t.nearest) {
    float fx = floor(s * t.fw);
    float fy = floor(tc * t.fh);
    uint wx = (fx >= 0.0f && fx < t.fw) ? uint(fx) : tex_wrap(fx, t.width, t.wrap_s);
    uint wy = (fy >= 0.0f && fy < t.fh) ? uint(fy) : tex_wrap(fy, t.height, t.wrap_t);
    return tex_fetch(ram, di.ram_len, t, wx, wy, c00) ? c00 : 0xff000000u;
  }
  float fx = s * t.fw - 0.5f;
  float fy = tc * t.fh - 0.5f;
  float x0 = floor(fx);
  float y0 = floor(fy);
  uint wx0, wx1, wy0, wy1;
  if (x0 >= 0.0f && x0 + 1.0f < t.fw) {
    wx0 = uint(x0);
    wx1 = wx0 + 1;
  } else {
    wx0 = tex_wrap(x0, t.width, t.wrap_s);
    wx1 = tex_wrap(x0 + 1.0f, t.width, t.wrap_s);
  }
  if (y0 >= 0.0f && y0 + 1.0f < t.fh) {
    wy0 = uint(y0);
    wy1 = wy0 + 1;
  } else {
    wy0 = tex_wrap(y0, t.height, t.wrap_t);
    wy1 = tex_wrap(y0 + 1.0f, t.height, t.wrap_t);
  }
  uint fxf = uint(round((fx - x0) * 256.0f));
  uint fyf = uint(round((fy - y0) * 256.0f));
  if (!tex_fetch(ram, di.ram_len, t, wx0, wy0, c00)) return 0xff000000u;
  if (fxf == 0 && fyf == 0) return c00;
  uint c10, c01, c11;
  if (!tex_fetch(ram, di.ram_len, t, wx1, wy0, c10)) return 0xff000000u;
  if (!tex_fetch(ram, di.ram_len, t, wx0, wy1, c01)) return 0xff000000u;
  if (!tex_fetch(ram, di.ram_len, t, wx1, wy1, c11)) return 0xff000000u;
  if (c00 == c10 && c00 == c01 && c00 == c11) return c00;
  uint ix = 256 - fxf;
  uint iy = 256 - fyf;
  uint w00 = (ix * iy + 128) >> 8;
  uint w10 = (fxf * iy + 128) >> 8;
  uint w01 = (ix * fyf + 128) >> 8;
  uint ws = w00 + w10 + w01;
  uint w11 = ws >= 256 ? 0u : 256 - ws;
  uint4 sum = uint4(as_type<uchar4>(c00)) * w00 + uint4(as_type<uchar4>(c10)) * w10 +
    uint4(as_type<uchar4>(c01)) * w01 + uint4(as_type<uchar4>(c11)) * w11 + 128u;
  return as_type<uint>(uchar4((sum >> 8) & 0xffu));
}

// Where a pixel of a framebuffer is in RAM (texture.texelOffsetOf), for 32 bpp or 16 bpp.
static inline uint fb_offset(uint cpp, uint width, uint height, uint x, uint y) {
  uint uw_shift = cpp == 4 ? 2u : 3u;
  uint uh_shift = 2u;
  uint uw = 1u << uw_shift;
  uint uh = 1u << uh_shift;
  uint cpp_shift = cpp == 4 ? 2u : 1u;
  uint in_utile = (((y & (uh - 1)) << uw_shift) | (x & (uw - 1))) << cpp_shift;
  if (width <= (uw << 2) || height <= (uh << 2)) {
    uint row_stride = ((width + uw - 1) & ~(uw - 1)) << cpp_shift;
    return (y & ~(uh - 1)) * row_stride + ((x >> uw_shift) << 6) + in_utile;
  }
  uint tile_w = uw << 3;
  uint utile_stride = ((width + tile_w - 1) & ~(tile_w - 1)) >> uw_shift;
  uint utile_x = x >> uw_shift;
  uint utile_y = y >> uh_shift;
  uint in_subtile = (((utile_y & 3) << 2) | (utile_x & 3)) << 6;
  uint tile_stride = utile_stride >> 3;
  uint tx = (utile_x & ~3u) >> 3;
  uint ty = (utile_y & ~3u) >> 3;
  bool odd_row = (ty & 1) != 0;
  if (odd_row) tx = tile_stride - tx - 1;
  uint stile = (((utile_y >> 2) & 1) << 1) | ((utile_x >> 2) & 1);
  const uint odd_map[4] = {2, 1, 3, 0};
  const uint even_map[4] = {0, 3, 1, 2};
  uint sub = odd_row ? odd_map[stile] : even_map[stile];
  return ((ty * tile_stride + tx) << 12) + (sub << 10) + in_subtile + in_utile;
}
