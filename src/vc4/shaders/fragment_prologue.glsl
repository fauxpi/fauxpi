  // Exactly 0 only if every corner's 1/W is exactly 1.
  float W = v_not_unit_w == 0.0 ? 1.0 : (abs(i_inv_w) > 1e-12 ? 1.0 / i_inv_w : 1.0);
  float V[16] = float[16](
    i_v0.x * W, i_v0.y * W, i_v0.z * W, i_v0.w * W,
    i_v1.x * W, i_v1.y * W, i_v1.z * W, i_v1.w * W,
    i_v2.x * W, i_v2.y * W, i_v2.z * W, i_v2.w * W,
    i_v3.x * W, i_v3.y * W, i_v3.z * W, i_v3.w * W);
  uint ra[32];
  uint rb[32];
  for (int i = 0; i < 32; ++i) {
    ra[i] = 0u;
    rb[i] = 0u;
  }
  ra[15] = u(W);
  rb[15] = uint(floor(clamp(gl_FragCoord.z, 0.0, 1.0) * 16777215.0 + 0.5));
  uint px = uint(gl_FragCoord.x), py = uint(gl_FragCoord.y);
