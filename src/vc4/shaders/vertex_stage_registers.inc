  uint ra[32];
  uint rb[32];
  uint vo[32];
  for (int i = 0; i < 32; ++i) {
    ra[i] = zero;
    rb[i] = zero;
    vo[i] = zero;
  }
  ra[15] = 0x3f800000u + zero;
  uint r0 = zero, r1 = zero, r2 = zero, r3 = zero, r4 = zero, r5 = zero, pa = zero, pb = zero;
  bool flag_z = false, flag_n = false, flag_c = false;
