vertex VOut vertex_main(uint vid [[vertex_id]], device const Vertex* verts [[buffer(0)]],
    constant float2& fb [[buffer(1)]]) {
  Vertex v = verts[vid];
  VOut o;
  o.pos = float4(v.x / fb.x * 2.0f - 1.0f, 1.0f - v.y / fb.y * 2.0f, v.z, 1.0f);
  o.inv_w = v.inv_w;
  o.not_unit_w = v.unit_w != 0u ? 0.0f : 1.0f;
  o.v0 = v.v0;
  o.v1 = v.v1;
  o.v2 = v.v2;
  o.v3 = v.v3;
  return o;
}

struct LoadStore {
  uint base;
  uint fb_w;
  uint fb_h;
  uint tiling;
  uint cpp;
  uint ram_len;
  uint pad0, pad1;
  uint tiles[32];
};

static inline bool ls_pixel(constant LoadStore& ls, uint2 p, thread uint& off) {
  if (p.x >= ls.fb_w || p.y >= ls.fb_h) return false;
  if (((ls.tiles[p.y >> 6] >> (p.x >> 6)) & 1u) == 0) return false;
  uint rel = ls.tiling == 0 ? (p.y * ls.fb_w + p.x) * ls.cpp : fb_offset(ls.cpp, ls.fb_w, ls.fb_h, p.x, p.y);
  off = ls.base + rel;
  return ulong(off) + ls.cpp <= ls.ram_len;
}

kernel void ls_load(texture2d<uint, access::write> tile [[texture(0)]], device const uchar* ram [[buffer(0)]],
    constant LoadStore& ls [[buffer(1)]], uint2 p [[thread_position_in_grid]]) {
  uint off;
  if (!ls_pixel(ls, p, off)) return;
  uint c = ls.cpp == 4 ? *(device const uint*)(ram + off) : rgb565(*(device const ushort*)(ram + off));
  tile.write(uint4(c, 0, 0, 0), p);
}

kernel void ls_store(texture2d<uint, access::read> tile [[texture(0)]], device uchar* ram [[buffer(0)]],
    constant LoadStore& ls [[buffer(1)]], uint2 p [[thread_position_in_grid]]) {
  uint off;
  if (!ls_pixel(ls, p, off)) return;
  uint c = tile.read(p).r;
  if (ls.cpp == 4) {
    *(device uint*)(ram + off) = c;
  } else {
    *(device ushort*)(ram + off) = ushort(to_rgb565(c));
  }
}


// A draw's triangles' corners (its vertices, from first_vertex), and V3D's configuration bits 0
// to 2: which triangles are drawn.
struct CullInfo {
  uint first_corner;
  uint triangles;
  uint first_vertex;
  uint cull;
};

// Each triangle's corners as drawn, or the first three times (drawing nothing) if V3D doesn't
// draw it: facing the way it isn't drawing, or with no area (as the CPU path decides).
kernel void cull_triangles(device const uint* corners [[buffer(0)]], device const Vertex* verts [[buffer(1)]],
    device uint* indices [[buffer(2)]], constant CullInfo& ci [[buffer(3)]], uint t [[thread_position_in_grid]]) {
  if (t >= ci.triangles) return;
  uint c0 = ci.first_vertex + corners[ci.first_corner + t * 3];
  uint c1 = ci.first_vertex + corners[ci.first_corner + t * 3 + 1];
  uint c2 = ci.first_vertex + corners[ci.first_corner + t * 3 + 2];
  Vertex v0 = verts[c0], v1 = verts[c1], v2 = verts[c2];
  float a = (v1.x - v0.x) * (v2.y - v0.y);
  float b = (v1.y - v0.y) * (v2.x - v0.x);
  float area = a - b;
  bool forward = (ci.cull & 4u) != 0u ? area < 0.0f : area > 0.0f;
  bool drawn = fabs(area) >= 1e-6f && ((forward ? ci.cull & 1u : ci.cull & 2u) != 0u);
  indices[ci.first_corner + t * 3] = c0;
  indices[ci.first_corner + t * 3 + 1] = drawn ? c1 : c0;
  indices[ci.first_corner + t * 3 + 2] = drawn ? c2 : c0;
}
