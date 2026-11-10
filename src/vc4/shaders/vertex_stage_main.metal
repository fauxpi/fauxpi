kernel void vertex_shade(device const uint* inputs [[buffer(0)]], device Vertex* verts [[buffer(1)]],
    constant uint* unif [[buffer(2)]], constant VertexInfo& vi [[buffer(3)]], uint vid [[thread_position_in_grid]]) {
  if (vid >= vi.count) return;
  device const uint* a_in = inputs + vi.first_input + vid * vi.stride;
  uint zero = vid >> 31;
