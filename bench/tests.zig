//! The bare-metal benchmark's tests, by name (shared by the suite and its runner), and what each
//! measures.

pub const Test = struct {
    name: []const u8,
    /// What it measures, for the runner's listing.
    about: []const u8,
};

pub const all = [_]Test{
    .{ .name = "cpu_int", .about = "integer arithmetic in a tight loop (xorshift)" },
    .{ .name = "cpu_branch", .about = "branches and byte loads and stores (a sieve of Eratosthenes)" },
    .{ .name = "cpu_call", .about = "calls and returns (recursive Fibonacci)" },
    .{ .name = "cpu_float", .about = "VFP floating point (a Mandelbrot set)" },
    .{ .name = "cpu_memcpy", .about = "copying memory (8 MiB at a time)" },
    .{ .name = "dma_copy", .about = "the DMA engine copying memory (4 MiB at a time)" },
    .{ .name = "v3d_clear", .about = "V3D frames with no draws: the tiles cleared and stored" },
    .{ .name = "v3d_triangles", .about = "V3D: 20,000 small flat-coloured triangles a frame" },
    .{ .name = "v3d_fill", .about = "V3D: 32 full-screen depth-tested quads a frame" },
    .{ .name = "v3d_texture", .about = "V3D: 2,000 bilinear-textured quads a frame" },
    .{ .name = "v3d_blend", .about = "V3D: 500 translucent quads a frame, blended in the shader" },
    .{ .name = "v3d_draws", .about = "V3D: 1,000 draws of a quad each, a frame" },
    .{ .name = "hvs_planes", .about = "the HVS composing 10 planes, moving, 60 times a second" },
};
