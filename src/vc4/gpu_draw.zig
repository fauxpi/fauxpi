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

/// A draw's vertices as its vertex shader shades them on the GPU (`gl_renderer.zig`), instead of
/// on the CPU: what it is given, and the triangles it makes.
pub const VertexStage = struct {
    code: []const qpu.Inst,
    uniforms: *const [shader.max_uniforms]u32,
    /// The VPM words each vertex is given, in the frame's inputs from word `first_input`, each
    /// vertex's `input_stride` words after the last's.
    vpm_words: u32,
    first_input: u32,
    input_stride: u32,
    /// Its triangles' corners (its vertices, numbered from 0), 3 a triangle, in the frame's corners.
    first_corner: u32,
    corner_count: u32,
    /// V3D's configuration bits 0 to 2: which way triangles face forward, and which are drawn.
    cull: u8,
    /// Where the viewport's origin is, in pixels.
    vp_x: f32,
    vp_y: f32,
};

/// A run of triangles drawn with one fragment shader: `vertex_count` vertices from `first_vertex`,
/// each 3 a triangle or, with `vertex_stage`, shaded on the GPU and made triangles of by its corners.
pub const Draw = struct {
    first_vertex: u32,
    vertex_count: u32,
    vertex_stage: ?VertexStage = null,
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
