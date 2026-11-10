#version 400 core
#extension GL_ARB_derivative_control : enable
#define Q_FRAGMENT 1
#ifdef GL_ARB_derivative_control
#define Q_DFDX dFdxFine
#define Q_DFDY dFdyFine
#else
#define Q_DFDX dFdx
#define Q_DFDY dFdy
#endif
noperspective in float v_inv_w;
noperspective in float v_not_unit_w;
noperspective in vec4 v_v0;
noperspective in vec4 v_v1;
noperspective in vec4 v_v2;
noperspective in vec4 v_v3;
uniform uint unif[128];
uniform uint n_var;
uniform usampler2D tex[8];
uniform uint tex_ok[8];
uniform usampler2D tlb_tex;
uniform usampler2DMS tlb_ms;
layout(location = 0) out uint o_color;
