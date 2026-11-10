  int xs = int(vo[0] << 16) >> 16;
  int ys = int(vo[0]) >> 16;
  float inv_w = f(vo[2]) == 0.0 ? 1.0 : f(vo[2]);
  precise float x = float(xs) * 0.0625;
  precise float y = float(ys) * 0.0625;
  precise float px = x + vp.x;
  precise float py = y + vp.y;
  tf_pos = vec4(px, py, f(vo[1]), inv_w);
  tf_unit_w = uvec4(inv_w == 1.0 ? 1u : 0u, 0u, 0u, 0u);
  uint n_out = min(n_var, n_outputs);
  float V[16];
  for (uint i = 0u; i < 16u; ++i) V[i] = i < n_out ? f(q_fmul(vo[3u + i], u(inv_w))) : 0.0;
  tf_v0 = vec4(V[0], V[1], V[2], V[3]);
  tf_v1 = vec4(V[4], V[5], V[6], V[7]);
  tf_v2 = vec4(V[8], V[9], V[10], V[11]);
  tf_v3 = vec4(V[12], V[13], V[14], V[15]);
  gl_Position = vec4(0.0);
}
