//! The benchmark's tests, by name (shared by the suites and their runner), and what each
//! measures: the bare-metal suite's (bench/baremetal) and the Linux one's (bench/linux).

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
    .{ .name = "v3d_lines", .about = "V3D: 10,000 lines 2 pixels wide a frame, some clipped" },
    .{ .name = "v3d_points", .about = "V3D: 10,000 points 1 to 16 pixels wide a frame, sized by the vertex shader" },
    .{ .name = "v3d_msaa", .about = "V3D: 20,000 small triangles a frame, 4x multisampled" },
    .{ .name = "v3d_msaa_blend", .about = "V3D: 500 translucent quads a frame, 4x multisampled, each sample blended" },
    .{ .name = "hvs_planes", .about = "the HVS composing 10 planes, moving, 60 times a second" },
};

pub const linux = [_]Test{
    .{ .name = "linux_boot", .about = "Linux booting to init, and vc4 to /dev/dri/card0" },
    .{ .name = "linux_syscalls", .about = "system calls (200,000 getppid)" },
    .{ .name = "linux_pagefault", .about = "page faults (fresh memory touched a page at a time)" },
    .{ .name = "kms_flip", .about = "KMS page flips, each waited for (vblank-paced)" },
    .{ .name = "kms_triangles", .about = "vc4 (SUBMIT_CL): 20,000 small triangles a frame, shown by page flips" },
    .{ .name = "kms_fill", .about = "vc4: 32 full-screen depth-tested quads a frame" },
    .{ .name = "kms_texture", .about = "vc4: 2,000 bilinear-textured quads a frame" },
    .{ .name = "kms_blend", .about = "vc4: 500 translucent quads a frame, blended in the shader" },
    .{ .name = "kms_draws", .about = "vc4: 1,000 draws of a quad each, a frame" },
    .{ .name = "kms_lines", .about = "vc4: 10,000 lines 2 pixels wide a frame, some clipped" },
    .{ .name = "kms_points", .about = "vc4: 10,000 points 1 to 16 pixels wide a frame, sized by the vertex shader" },
    .{ .name = "kms_msaa", .about = "vc4: 20,000 small triangles a frame, 4x multisampled" },
    .{ .name = "kms_msaa_blend", .about = "vc4: 500 translucent quads a frame, 4x multisampled, each sample blended" },
};
