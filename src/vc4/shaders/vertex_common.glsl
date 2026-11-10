#version 400 core
layout(location = 0) in uvec4 a_in[8];
uniform uint unif[128];
uniform uint n_vpm;
uniform uint n_var;
uniform vec2 vp;
out vec4 tf_pos;
flat out uvec4 tf_unit_w;
out vec4 tf_v0;
out vec4 tf_v1;
out vec4 tf_v2;
out vec4 tf_v3;
