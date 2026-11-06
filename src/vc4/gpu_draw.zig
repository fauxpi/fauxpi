//! What V3D's frames are drawn from on a GPU (`metal_renderer.zig`, `gl_renderer.zig`): the
//! triangles V3D shaded and binned on the CPU, with their corners, and the runs of them each fragment
//! shader draws.

const std = @import("std");
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

/// The most draws, corners, and instructions in a shader, a frame is drawn with on the GPU. V3D has
/// no such limits: frames with more are drawn on the CPU.
pub const max_draws = 4096;
pub const max_vertices = 65536 * 3;
pub const max_program_len = 4096;

/// Whether draw `b`, straight after `a`, can have its vertices shaded in the same pass as `a`'s:
/// the same vertex shader, given the same (uniforms, VPM words, viewport, varyings), with its
/// inputs and vertices straight after `a`'s. Many small draws then cost a pass, not one each.
pub fn shadeTogether(a: Draw, b: Draw) bool {
    const va = a.vertex_stage orelse return false;
    const vb = b.vertex_stage orelse return false;
    return vb.first_input == va.first_input + a.vertex_count * va.input_stride and
        b.first_vertex == a.first_vertex + a.vertex_count and
        va.vpm_words == vb.vpm_words and
        va.input_stride == vb.input_stride and
        va.vp_x == vb.vp_x and
        va.vp_y == vb.vp_y and
        a.num_varyings == b.num_varyings and
        std.mem.eql(qpu.Inst, va.code, vb.code) and
        std.mem.eql(u32, va.uniforms, vb.uniforms);
}

/// The draws from `first` whose vertices are shaded in one pass (`shadeTogether`): up to the
/// index returned, and how many vertices they have.
pub fn shadeRun(draws: []const Draw, first: usize) struct { end: usize, vertices: u32 } {
    var end = first + 1;
    var vertices = draws[first].vertex_count;
    while (end < draws.len and shadeTogether(draws[end - 1], draws[end])) : (end += 1) vertices += draws[end].vertex_count;
    return .{ .end = end, .vertices = vertices };
}

test "draws of the same shader, one after another, are shaded in one pass" {
    const code = [_]qpu.Inst{ 1, 2, 3 };
    const other = [_]qpu.Inst{ 1, 2, 4 };
    var unifs: [shader.max_uniforms]u32 = @splat(0);
    var unifs2: [shader.max_uniforms]u32 = @splat(0);
    unifs2[1] = 5;
    const stage: VertexStage = .{ .code = &code, .uniforms = &unifs, .vpm_words = 6, .first_input = 0, .input_stride = 8, .first_corner = 0, .corner_count = 6, .cull = 3, .vp_x = 1, .vp_y = 2 };
    var draws: [5]Draw = undefined;
    for (&draws, 0..) |*d, i| {
        var vs = stage;
        vs.first_input = @intCast(i * 6 * 8);
        d.* = .{ .first_vertex = @intCast(i * 6), .vertex_count = 6, .vertex_stage = vs, .code = &code, .uniforms = &unifs, .num_varyings = 3, .depth_func = 7, .depth_write = false, .clip_x = 0, .clip_y = 0, .clip_w = 64, .clip_h = 64 };
    }
    // Another shader from the third, and other uniforms from the fifth.
    draws[2].vertex_stage.?.code = &other;
    draws[3].vertex_stage.?.code = &other;
    draws[4].vertex_stage.?.code = &other;
    draws[4].vertex_stage.?.uniforms = &unifs2;
    const run = shadeRun(&draws, 0);
    try std.testing.expectEqual(@as(usize, 2), run.end);
    try std.testing.expectEqual(@as(u32, 12), run.vertices);
    try std.testing.expectEqual(@as(usize, 4), shadeRun(&draws, 2).end);
    try std.testing.expectEqual(@as(usize, 5), shadeRun(&draws, 4).end);
}
