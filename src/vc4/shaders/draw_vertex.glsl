#version 400 core
layout(location = 0) in vec4 a_pos;
layout(location = 1) in uint a_unit_w;
layout(location = 2) in vec4 a_v0;
layout(location = 3) in vec4 a_v1;
layout(location = 4) in vec4 a_v2;
layout(location = 5) in vec4 a_v3;
uniform vec2 fb;
noperspective out float v_inv_w;
noperspective out float v_not_unit_w;
noperspective out vec4 v_v0;
noperspective out vec4 v_v1;
noperspective out vec4 v_v2;
noperspective out vec4 v_v3;
void main() {
  gl_Position = vec4(a_pos.x / fb.x * 2.0 - 1.0, a_pos.y / fb.y * 2.0 - 1.0, a_pos.z * 2.0 - 1.0, 1.0);
  v_inv_w = a_pos.w;
  v_not_unit_w = a_unit_w != 0u ? 0.0 : 1.0;
  v_v0 = a_v0;
  v_v1 = a_v1;
  v_v2 = a_v2;
  v_v3 = a_v3;
}
