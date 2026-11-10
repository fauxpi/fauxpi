float f(uint x) { return uintBitsToFloat(x); }
uint u(float x) { return floatBitsToUint(x); }
// A 16-bit float's bits as a float's (exactly).
uint q_unhalf(uint h) {
  uint sign = (h & 0x8000u) << 16;
  uint e = (h >> 10) & 0x1fu;
  uint m = h & 0x3ffu;
  if (e == 0u) { float v = float(m) * f(0x33800000u); return sign | u(v); }
  if (e == 31u) return sign | 0x7f800000u | (m << 13);
  return sign | ((e + 112u) << 23) | (m << 13);
}
uint q_fadd(uint a, uint b) { precise float r = f(a) + f(b); return u(r); }
uint q_fsub(uint a, uint b) { precise float r = f(a) - f(b); return u(r); }
uint q_fmul(uint a, uint b) { precise float r = f(a) * f(b); return u(r); }
// 1/x rounded as dividing is (a GPU's reciprocal is only nearly), by a step of Newton's method.
uint q_recip(uint a) {
  precise float x = f(a);
  precise float r = 1.0 / x;
  if (isinf(r) || r == 0.0 || isnan(r)) return u(r);
  precise float e = fma(-x, r, 1.0);
  precise float r2 = fma(e, r, r);
  return u(r2);
}
float fmin(float a, float b) { return min(a, b); }
float fmax(float a, float b) { return max(a, b); }
float fabs(float a) { return abs(a); }
uint clz(uint x) {
  if (x == 0u) return 32u;
  uint n = 0u;
  if ((x & 0xffff0000u) == 0u) { n += 16u; x <<= 16; }
  if ((x & 0xff000000u) == 0u) { n += 8u; x <<= 8; }
  if ((x & 0xf0000000u) == 0u) { n += 4u; x <<= 4; }
  if ((x & 0xc0000000u) == 0u) { n += 2u; x <<= 2; }
  if ((x & 0x80000000u) == 0u) n += 1u;
  return n;
}

uint unorm8(uint v) {
  float x = f(v);
  if (isnan(x)) x = 0.0;
  x = min(max(x, 0.0), 1.0);
  return uint(floor(x * 255.0 + 0.5));
}

uint ftoi(uint v) {
  float x = f(v);
  if (isnan(x)) x = 0.0;
  x = min(max(x, -2147483648.0), 2147483520.0);
  return uint(int(x));
}

uint unpack(uint v, uint mode, bool flt) {
  if (mode == 1u) { int s = int(v << 16) >> 16; return flt ? q_unhalf(v & 0xffffu) : uint(s); }
  if (mode == 2u) { int s = int(v) >> 16; return flt ? q_unhalf(v >> 16) : uint(s); }
  if (mode == 3u) return (v >> 24) * 0x01010101u;
  if (mode >= 4u && mode <= 7u) {
    uint b = (v >> ((mode - 4u) * 8u)) & 0xffu;
    return flt ? u(float(b) * (1.0 / 255.0)) : b;
  }
  return v;
}

uint ror(uint a, uint b) {
  uint s = b & 31u;
  return (a >> s) | (a << ((32u - s) & 31u));
}
uvec4 bytes(uint a) { return uvec4(a & 0xffu, (a >> 8) & 0xffu, (a >> 16) & 0xffu, a >> 24); }
uint pack4(uvec4 b) { return b.x | (b.y << 8) | (b.z << 16) | (b.w << 24); }
uint v8adds(uint a, uint b) { return pack4(min(bytes(a) + bytes(b), uvec4(255u))); }
uint v8subs(uint a, uint b) { return pack4(uvec4(max(ivec4(bytes(a)) - ivec4(bytes(b)), ivec4(0)))); }
uint v8min(uint a, uint b) { return pack4(min(bytes(a), bytes(b))); }
uint v8max(uint a, uint b) { return pack4(max(bytes(a), bytes(b))); }
uint v8muld(uint a, uint b) {
  uvec4 p = bytes(a) * bytes(b) + 127u;
  return pack4(((p + 1u + (p >> 8)) >> 8) & 0xffu);
}

// The TMU's wrapping (qpu_sim's wrap): repeat, clamp to the edge, mirror, or the border
// (0x80000000: the border colour, 0 with no r coordinate).
uint tex_wrap(float c, uint size, uint mode) {
  int n = int(max(size, 1u));
  int i = isnan(c) ? 0 : int(clamp(c, -1e9, 1e9));
  if (mode == 0u) return uint(i >= 0 ? i % n : (n - 1) - ((-i - 1) % n));
  if (mode == 2u) {
    int p = 2 * n;
    int m = i >= 0 ? i % p : (p - 1) - ((-i - 1) % p);
    return uint(m < n ? m : p - 1 - m);
  }
  if (mode == 3u) return (i < 0 || i >= n) ? 0x80000000u : uint(i);
  return uint(clamp(i, 0, n - 1));
}

uint texel(usampler2D t, int lvl, uint x, uint y) {
  if (((x | y) & 0x80000000u) != 0u) return 0u;
  return texelFetch(t, ivec2(x, y), lvl).r;
}

// One level of texture `t` (`width` by `height`) sampled, nearest or bilinear, as qpu_sim's
// PrecomputedTex.sample does.
uint tmu_level(usampler2D t, int lvl, uint width, uint height, uint wrap_s, uint wrap_t, bool nearest, float s, float tc) {
  float fw = float(width);
  float fh = float(height);
  if (nearest) {
    float fx = floor(s * fw);
    float fy = floor(tc * fh);
    uint wx = (fx >= 0.0 && fx < fw) ? uint(fx) : tex_wrap(fx, width, wrap_s);
    uint wy = (fy >= 0.0 && fy < fh) ? uint(fy) : tex_wrap(fy, height, wrap_t);
    return texel(t, lvl, wx, wy);
  }
  float fx = s * fw - 0.5;
  float fy = tc * fh - 0.5;
  float x0 = floor(fx);
  float y0 = floor(fy);
  uint wx0, wx1, wy0, wy1;
  if (x0 >= 0.0 && x0 + 1.0 < fw) {
    wx0 = uint(x0);
    wx1 = wx0 + 1u;
  } else {
    wx0 = tex_wrap(x0, width, wrap_s);
    wx1 = tex_wrap(x0 + 1.0, width, wrap_s);
  }
  if (y0 >= 0.0 && y0 + 1.0 < fh) {
    wy0 = uint(y0);
    wy1 = wy0 + 1u;
  } else {
    wy0 = tex_wrap(y0, height, wrap_t);
    wy1 = tex_wrap(y0 + 1.0, height, wrap_t);
  }
  uint fxf = uint(floor((fx - x0) * 256.0 + 0.5));
  uint fyf = uint(floor((fy - y0) * 256.0 + 0.5));
  uint c00 = texel(t, lvl, wx0, wy0);
  if (fxf == 0u && fyf == 0u) return c00;
  uint c10 = texel(t, lvl, wx1, wy0);
  uint c01 = texel(t, lvl, wx0, wy1);
  uint c11 = texel(t, lvl, wx1, wy1);
  if (c00 == c10 && c00 == c01 && c00 == c11) return c00;
  uint ix = 256u - fxf;
  uint iy = 256u - fyf;
  uint w00 = (ix * iy + 128u) >> 8;
  uint w10 = (fxf * iy + 128u) >> 8;
  uint w01 = (ix * fyf + 128u) >> 8;
  uint ws = w00 + w10 + w01;
  uint w11 = ws >= 256u ? 0u : 256u - ws;
  uvec4 sum = bytes(c00) * w00 + bytes(c10) * w10 + bytes(c01) * w01 + bytes(c11) * w11 + 128u;
  return pack4((sum >> 8) & 0xffu);
}

uint q_log2(uint a);

// A level's size: level 0's, then halves of it rounded up to a power of two (qpu_sim's
// levelConfig).
uint tex_pot(uint v) {
  uint p = 1u;
  while (p < v && p < 2048u) p <<= 1;
  return p;
}
uint tex_level_size(uint size, uint l) { return l == 0u ? size : max(tex_pot(size) >> l, 1u); }

// The TMU sampling texture `t` (decoded from RAM, each level; `ok` if it could be), as
// qpu_sim does: its level of detail from the coordinates' differences across 2x2 quads
// (fragment shaders only), choosing the magnifying or minifying filter and the mipmap levels.
uint tmu_sample(usampler2D t, uint ok, uint p0, uint p1, float s, float tc) {
  uint w = (p1 >> 8) & 2047u;
  uint h = (p1 >> 20) & 2047u;
  uint width = w == 0u ? 2048u : w;
  uint height = h == 0u ? 2048u : h;
  precise float st = s * float(width);
  precise float tt = tc * float(height);
#ifdef Q_FRAGMENT
  precise float dsx = Q_DFDX(st);
  precise float dtx = Q_DFDX(tt);
  precise float dsy = Q_DFDY(st);
  precise float dty = Q_DFDY(tt);
#else
  float dsx = 0.0, dtx = 0.0, dsy = 0.0, dty = 0.0;
#endif
  if (ok == 0u) return 0xff000000u;
  uint wrap_s = p1 & 3u;
  uint wrap_t = (p1 >> 2) & 3u;
  uint mips = p0 & 15u;
  uint minc = (p1 >> 4) & 7u;
  bool mag_nearest = ((p1 >> 7) & 1u) != 0u;
  bool min_nearest = minc == 1u || minc == 2u || minc == 3u;
  uint mipf = (minc == 2u || minc == 4u) ? 1u : ((minc == 3u || minc == 5u) ? 2u : 0u);
  if (mipf == 0u) mips = 0u;
  if (min_nearest == mag_nearest && mips == 0u) return tmu_level(t, 0, width, height, wrap_s, wrap_t, mag_nearest, s, tc);
  precise float rx = dsx * dsx + dtx * dtx;
  precise float ry = dsy * dsy + dty * dty;
  float rho2 = max(rx, ry);
  float lod = (rho2 > 0.0 && !isinf(rho2)) ? 0.5 * f(q_log2(u(rho2))) : (rho2 > 0.0 ? 32.0 : -32.0);
  if (!(lod > 0.0)) return tmu_level(t, 0, width, height, wrap_s, wrap_t, mag_nearest, s, tc);
  if (mips == 0u) return tmu_level(t, 0, width, height, wrap_s, wrap_t, min_nearest, s, tc);
  float top = float(mips);
  uint l0;
  uint frac = 0u;
  if (mipf == 1u) {
    l0 = uint(min(floor(lod + 0.5), top));
  } else {
    float fl = floor(lod);
    if (fl >= top) {
      l0 = mips;
    } else {
      l0 = uint(fl);
      frac = uint(floor((lod - fl) * 256.0 + 0.5));
    }
  }
  uint a = tmu_level(t, int(l0), tex_level_size(width, l0), tex_level_size(height, l0), wrap_s, wrap_t, min_nearest, s, tc);
  if (frac == 0u) return a;
  uint l1 = l0 + 1u;
  uint b = tmu_level(t, int(l1), tex_level_size(width, l1), tex_level_size(height, l1), wrap_s, wrap_t, min_nearest, s, tc);
  uvec4 mix = (bytes(a) * (256u - frac) + bytes(b) * frac + 128u) >> 8;
  return pack4(mix & 0xffu);
}
