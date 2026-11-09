//! The benchmark's tests, by name (shared by the suites and their runner), and what each
//! measures: the bare-metal suite's (bench/baremetal) and the Linux one's (bench/linux).
//!
//! Besides timing workloads, the `v3d_*` feature tests and `kms_v3d_*`/`kms_planes` exercise
//! the VideoCore IV's features as its reference guide (the VideoCore IV 3D Architecture
//! Reference Guide) and Linux's vc4 driver define them, whether FauxPi has them or not. Each
//! reports checksums of what it drew, a value per feature, so a run on a Raspberry Pi (`--image`)
//! is the reference a FauxPi run is compared with:
//!
//! - Control lists: every record (`v3d_control`, `v3d_tile_lists`), branches and sub-lists,
//!   semaphores, extended lists, interrupts, binner overflow, performance counters.
//! - Modes: GL, NV and VG shader state; VG coordinate and inline primitives; compressed and
//!   clipped primitive lists in hand-written tile lists (`v3d_nv_vg`, `v3d_tile_lists`).
//! - Geometry and rasterization: every primitive mode and index size, attributes, point sizes and
//!   line widths, clipping, culling, depth tests, early Z, depth offset, flat shading, oversampling
//!   (`v3d_primitives`, `v3d_clipping`, `v3d_rasterizer`).
//! - Fragments and the tile buffer: shader depth, stencil, discards, the rasterizer's payload;
//!   every colour format and memory layout, general and full-resolution loads and stores, HDR,
//!   multisampling and decimation, double-buffering (`v3d_depth_stencil`, `v3d_tile_buffer`,
//!   `v3d_msaa*`).
//! - The TMU: every texture type, LT and raster formats, filters and mipmaps, wraps and border
//!   colour, cube maps, LOD bias, child images, flips, both units, general memory lookups
//!   (`v3d_tmu`).
//! - The QPU: every ALU operation, pack and unpack, conditions, branches, small immediates,
//!   rotation, the SFU, load immediates, special registers, threads, semaphores and the mutex
//!   (`v3d_qpu`); user programs with VPM DMA and access modes (`v3d_user_programs`).
//! - The HVS: every pixel format and order, tiling, flips, alpha modes, scaling, YUV, background
//!   (`hvs_features`; `kms_planes` through KMS).
//!
//! What they can't show: the HVS's composed output (on a Pi it goes to the display, so the HVS
//! tests measure composing, not pixels), and timing-dependent results (which QPU ran what).

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
    .{ .name = "v3d_primitives", .about = "V3D features: every primitive mode, from arrays and 8 and 16-bit index lists; 8 attribute arrays with 32-bit strides; point sizes, line widths" },
    .{ .name = "v3d_clipping", .about = "V3D features: the near plane, guard band and Z clipping planes, with clipping on and off; viewport offsets and clip windows" },
    .{ .name = "v3d_rasterizer", .about = "V3D features: culling by facing, every depth test, depth updates, early Z, depth offset, flat shading, oversampling" },
    .{ .name = "v3d_depth_stencil", .about = "V3D features: depth written by shaders, the stencil test and ops, discards, the rasterizer's per-fragment data" },
    .{ .name = "v3d_nv_vg", .about = "V3D features: NV mode (pre-shaded vertices, point sizes, clip headers); VG mode (coordinate arrays, inline primitives and shader records, RHTs)" },
    .{ .name = "v3d_tile_lists", .about = "V3D features: rendering from hand-written tile lists: compressed primitive codings, relative branches, XY lists, clipped primitives, sub-lists" },
    .{ .name = "v3d_tile_buffer", .about = "V3D features: every colour format and memory layout; general and full-resolution stores and loads (colour, Z/stencil, VG mask); no-clear stores; HDR; double-buffering; 16x decimation; block sizes" },
    .{ .name = "v3d_control", .about = "V3D features: control list branches and sub-lists, semaphores, extended lists, interrupts, binner overflow (overspill), performance counters, registers" },
    .{ .name = "v3d_tmu", .about = "V3D features: every texture type, LT and raster formats, filters and mipmaps, wrap modes and border colour, cube maps, LOD bias, child images, flips, both TMUs, queued and general memory lookups" },
    .{ .name = "v3d_qpu", .about = "V3D features: the QPU instruction set in fragment shaders: every ALU op, unpacks and packs, conditions, branches, small immediates, rotation, SFU, load immediates, special registers, threads, semaphores, mutex" },
    .{ .name = "v3d_user_programs", .about = "V3D features: QPU user programs (GPGPU): VPM reservation, VDR/VDW DMA, VPM access modes, TMU lookups, mutex, semaphores, host interrupts, the request queue; 20 rounds of 12" },
    .{ .name = "v3d_stress_geometry", .about = "V3D stress: a 515,000-triangle mesh a frame, indexed, in perspective, depth-tested and culled" },
    .{ .name = "v3d_stress_frame", .about = "V3D stress: the largest frame, 2048x2048 4x multisampled, 200 overlapping quads writing each sample" },
    .{ .name = "v3d_stress_textures", .about = "V3D stress: 2048x2048 textures (12-level trilinear RGBA8888, ETC1), 4000 quads at random scales" },
    .{ .name = "v3d_stress_shaders", .about = "V3D stress: a fragment shader of thousands of instructions (loops, SFU) over the frame; 20 varyings from 6 arrays" },
    .{ .name = "v3d_stress_draws", .about = "V3D stress: 10,000 draws a frame, each changing configuration, clip window, flat shading and record" },
    .{ .name = "hvs_planes", .about = "the HVS composing 10 planes, moving, 60 times a second" },
    .{ .name = "hvs_features", .about = "HVS features: every pixel format, order and alpha expansion; T and SAND tiling; flips; alpha modes; every scaling mode; YUV 4:2:0/4:2:2/4:4:4; background fill; 100 planes" },
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
    .{ .name = "kms_v3d_pipeline", .about = "vc4 features: primitive modes, 8/16-bit index buffers, point sizes, line widths, culling, depth tests, depth offset, flat shading, viewports; depth, stencil, discard in shaders" },
    .{ .name = "kms_v3d_textures", .about = "vc4 features: every texture type the kernel takes, wrap modes, mipmaps and filters" },
    .{ .name = "kms_v3d_qpu", .about = "vc4 features: the QPU instruction groups the kernel's shader validator accepts" },
    .{ .name = "kms_v3d_surfaces", .about = "vc4 features: colour formats and layouts, depth/stencil written and read, multisampled full-resolution writes and reads, clear values, partial frames" },
    .{ .name = "kms_v3d_stress", .about = "vc4 stress: a 260,000-triangle mesh 4 times a frame, 4000 draws each with its own record, a 2048x2048 multisampled frame" },
    .{ .name = "kms_planes", .about = "KMS/HVS features: overlay planes in every pixel format, linear, T-tiled and SAND128; scaled, reflected, rotated, alpha, blend modes; all overlays at once" },
};
