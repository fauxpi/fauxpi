) {
  // Exactly 0 only if every corner's 1/W is exactly 1.
  float W = in.not_unit_w == 0.0f ? 1.0f : (fabs(in.inv_w) > 1e-12f ? 1.0f / in.inv_w : 1.0f);
  float V[16] = {
    in.v0.x * W, in.v0.y * W, in.v0.z * W, in.v0.w * W,
    in.v1.x * W, in.v1.y * W, in.v1.z * W, in.v1.w * W,
    in.v2.x * W, in.v2.y * W, in.v2.z * W, in.v2.w * W,
    in.v3.x * W, in.v3.y * W, in.v3.z * W, in.v3.w * W,
  };
  uint ra[32] = {};
  uint rb[32] = {};
  ra[15] = u(W);
  rb[15] = uint(floor(clamp(in.pos.z, 0.0f, 1.0f) * 16777215.0f + 0.5f));
  uint px = uint(in.pos.x), py = uint(in.pos.y);
