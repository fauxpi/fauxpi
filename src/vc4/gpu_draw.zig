//! What V3D's frames are drawn from on a GPU (`metal_renderer.zig`, `gl_renderer.zig`): the
//! triangles V3D shaded and binned on the CPU, with their corners, and the runs of them each fragment
//! shader draws.

const qpu = @import("qpu.zig");
const shader = @import("qpu_to_shader.zig");

/// A triangle's corner (MSL's `Vertex`, GLSL's attributes): where it is in the framebuffer, in
/// pixels; its depth and 1/W; and its varyings, already multiplied by 1/W.
pub const Vertex = extern struct {
    x: f32,
    y: f32,
    z: f32,
    inv_w: f32,
    /// Whether the triangle's corners all have a W of 1 (so 1 is used, exactly, as V3D's CPU path does).
    unit_w: u32,
    pad: [3]u32 = @splat(0),
    varyings: [shader.max_varyings]f32,
};

/// A run of triangles drawn with one fragment shader.
pub const Draw = struct {
    first_vertex: u32,
    vertex_count: u32,
    /// The fragment shader, and its uniforms.
    code: []const qpu.Inst,
    uniforms: *const [shader.max_uniforms]u32,
    num_varyings: u32,
    /// The V3D depth test (`MTLCompareFunction` has the same values, and OpenGL's are 0x200 more)
    /// and whether depth is written.
    depth_func: u3,
    depth_write: bool,
    clip_x: u32,
    clip_y: u32,
    clip_w: u32,
    clip_h: u32,
};

/// The most draws, and corners, a frame is drawn with: as many as V3D bins.
pub const max_draws = 256;
pub const max_vertices = 65536 * 3;
