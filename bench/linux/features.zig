//! The Linux suite's feature tests: the VideoCore IV features Linux's vc4 driver exposes, used as
//! a program would: the 3D pipeline through SUBMIT_CL (primitives and index buffers, rasterizer
//! state, fragment depth and stencil, textures, the QPU instructions the kernel's shader
//! validator accepts, and the tile buffer's surfaces: colour formats and layouts, depth and
//! stencil, multisampled and full-resolution reads and writes, partial frames), and the HVS
//! through KMS (plane formats, tiling modifiers, scaling, rotation, alpha and blending). Frames
//! are drawn offscreen and reported by their checksums; what the kernel rejects is counted.

const std = @import("std");
const linux = std.os.linux;
const scene = @import("scene");
const init = @import("init.zig");

const programs = scene.programs;
const Params = init.Params;
const Result = init.Result;
const Bo = init.Bo;

/// A shader buffer, or null if the kernel's validator rejects the program.
fn tryShader(fd: i32, code: []const u64) ?u32 {
    var c: init.CreateShaderBo = .{ .size = @intCast(code.len * 8), .data = @intFromPtr(code.ptr) };
    if (init.ioctl(fd, init.drmIowr(0x45, init.CreateShaderBo), &c) != .SUCCESS) return null;
    return c.handle;
}

fn checksum(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (std.mem.bytesAsSlice(u32, bytes[0 .. bytes.len / 4 * 4])) |w| h = (h ^ w) *% 0x100000001b3;
    return h;
}

fn rand(seed: *u32) f32 {
    return scene.rand(seed);
}

fn colour(seed: *u32) [3]f32 {
    return .{ rand(seed), rand(seed), rand(seed) };
}

/// An offscreen frame drawn through SUBMIT_CL: clip-space vertices (positions and colours in two
/// buffers), the clip-space shaders, and a job's lists.
const Gl = struct {
    fd: i32,
    width: u32,
    height: u32,
    target: Bo,
    surface: Bo,
    surface2: Bo,
    pos: Bo,
    col: Bo,
    idx: Bo,
    vs: [5]u32,
    cs: u32,
    flat: u32,
    unifs: [4]u32,
    n: u32 = 0,
    msaa: bool = false,
    bcl: []u8,
    bcl_len: usize = 0,
    rec: []u8,
    rec_len: usize = 0,
    rec_count: u32 = 0,
    uniforms: []u32,
    uniforms_len: usize = 0,
    handles: [64]u32 = undefined,
    handle_count: u32 = 0,
    rejected: u64 = 0,

    fn create(fd: i32, width: u32, height: u32) Gl {
        return createWith(fd, width, height, true);
    }

    /// The scene; `with_surfaces`: with buffers for depth, stencil and full-resolution stores (four
    /// times the frame's bytes each).
    fn createWith(fd: i32, width: u32, height: u32, with_surfaces: bool) Gl {
        const fb_bytes = ((width + 63) / 64 * 64) * ((height + 63) / 64 * 64) * 4;
        const surface_bytes: usize = if (with_surfaces) fb_bytes * 4 else 4096;
        var g: Gl = .{
            .fd = fd,
            .width = width,
            .height = height,
            .target = .create(fd, fb_bytes),
            .surface = .create(fd, surface_bytes),
            .surface2 = .create(fd, surface_bytes),
            .pos = .create(fd, (1 << 18) * 16),
            .col = .create(fd, (1 << 18) * 16),
            .idx = .create(fd, (1 << 20) * 2),
            .vs = undefined,
            .cs = init.shaderBo(fd, programs.clipVertexShader(.{ .varyings = 0 }, true).code()),
            .flat = init.shaderBo(fd, programs.flatFragmentShader().code()),
            .unifs = .{ @bitCast(@as(f32, @floatFromInt(width)) * 8), @bitCast(-@as(f32, @floatFromInt(height)) * 8), @bitCast(@as(f32, 0.5)), @bitCast(@as(f32, 0.5)) },
            .bcl = std.heap.page_allocator.alloc(u8, 1 << 20) catch init.fail("out of memory", .{}),
            .rec = std.heap.page_allocator.alloc(u8, 1 << 20) catch init.fail("out of memory", .{}),
            .uniforms = std.heap.page_allocator.alloc(u32, 1 << 18) catch init.fail("out of memory", .{}),
        };
        for (&g.vs, 0..) |*v, k| v.* = init.shaderBo(fd, programs.clipVertexShader(.{ .varyings = @intCast(k) }, false).code());
        return g;
    }

    fn byte(g: *Gl, v: u8) void {
        g.bcl[g.bcl_len] = v;
        g.bcl_len += 1;
    }
    fn half(g: *Gl, v: u16) void {
        std.mem.writeInt(u16, g.bcl[g.bcl_len..][0..2], v, .little);
        g.bcl_len += 2;
    }
    fn word(g: *Gl, v: u32) void {
        std.mem.writeInt(u32, g.bcl[g.bcl_len..][0..4], v, .little);
        g.bcl_len += 4;
    }
    fn float(g: *Gl, v: f32) void {
        g.word(@bitCast(v));
    }
    fn recWord(g: *Gl, v: u32) void {
        std.mem.writeInt(u32, g.rec[g.rec_len..][0..4], v, .little);
        g.rec_len += 4;
    }
    fn recByte(g: *Gl, v: u8) void {
        g.rec[g.rec_len] = v;
        g.rec_len += 1;
    }
    fn unif(g: *Gl, v: u32) void {
        g.uniforms[g.uniforms_len] = v;
        g.uniforms_len += 1;
    }
    fn index(g: *Gl, handle: u32) u32 {
        for (g.handles[0..g.handle_count], 0..) |h, i| if (h == handle) return @intCast(i);
        g.handles[g.handle_count] = handle;
        g.handle_count += 1;
        return g.handle_count - 1;
    }

    fn tileSize(g: *const Gl) u32 {
        return if (g.msaa) 32 else 64;
    }

    /// Starts a job: the binning configuration (the kernel's memory), the prefix state.
    fn begin(g: *Gl) void {
        g.bcl_len = 0;
        g.rec_len = 0;
        g.rec_count = 0;
        g.uniforms_len = 0;
        g.handle_count = 0;
        _ = g.index(g.target.handle);
        g.byte(112);
        g.word(0);
        g.word(0);
        g.word(0);
        g.byte(@intCast((g.width + g.tileSize() - 1) / g.tileSize()));
        g.byte(@intCast((g.height + g.tileSize() - 1) / g.tileSize()));
        g.byte(@intFromBool(g.msaa));
        g.byte(6);
        g.byte(56);
        g.byte(0x12);
        g.clipWindow(0, 0, @intCast(g.width), @intCast(g.height));
        g.byte(103);
        g.half(@intCast(g.width * 8));
        g.half(@intCast(g.height * 8));
        g.byte(105);
        g.float(@as(f32, @floatFromInt(g.width)) * 8);
        g.float(-@as(f32, @floatFromInt(g.height)) * 8);
        g.byte(106);
        g.float(0.5);
        g.float(0.5);
    }

    fn config(g: *Gl, cfg: u24) void {
        g.byte(96);
        g.byte(@truncate(cfg));
        g.byte(@truncate(cfg >> 8));
        g.byte(@truncate(cfg >> 16));
    }
    fn clipWindow(g: *Gl, x: u16, y: u16, w: u16, h: u16) void {
        g.byte(102);
        g.half(x);
        g.half(y);
        g.half(w);
        g.half(h);
    }
    fn viewport(g: *Gl, x16: u16, y16: u16) void {
        g.byte(103);
        g.half(x16);
        g.half(y16);
    }
    fn packetF32(g: *Gl, code: u8, v: f32) void {
        g.byte(code);
        g.float(v);
    }
    fn packetU32(g: *Gl, code: u8, v: u32) void {
        g.byte(code);
        g.word(v);
    }
    fn arrays(g: *Gl, mode: u8, count: u32, first: u32) void {
        g.byte(33);
        g.byte(mode);
        g.word(count);
        g.word(first);
    }
    /// An indexed draw from the index buffer (named to the kernel with a GEM handles packet).
    fn indexed(g: *Gl, mode: u8, sixteen: bool, count: u32, offset: u32, max_index: u32) void {
        g.byte(254);
        g.word(g.index(g.idx.handle));
        g.word(0);
        g.byte(32);
        g.byte(mode | @as(u8, @intFromBool(sixteen)) << 4);
        g.word(count);
        g.word(offset);
        g.word(max_index);
    }

    fn vertex4(g: *Gl, px: f32, py: f32, z: f32, w: f32, c: [4]f32) u32 {
        const hw = @as(f32, @floatFromInt(g.width)) / 2;
        const hh = @as(f32, @floatFromInt(g.height)) / 2;
        const pos = g.pos.floats();
        const col = g.col.floats();
        pos[g.n * 4 ..][0..4].* = .{ (px - hw) / hw * w, -(py - hh) / hh * w, (z * 2 - 1) * w, w };
        col[g.n * 4 ..][0..4].* = c;
        g.n += 1;
        return g.n - 1;
    }
    fn vertex(g: *Gl, px: f32, py: f32, z: f32, rgb: [3]f32) u32 {
        return g.vertex4(px, py, z, 1, .{ rgb[0], rgb[1], rgb[2], z });
    }

    /// The next shader state: a record drawing these vertices with fragment shader `fs` (reading
    /// `varyings`), its uniforms `fs_unifs` (a texture's as the kernel takes them: its buffer's
    /// index, then its parameters).
    fn shaderState(g: *Gl, fs: u32, varyings: u8, fs_unifs: []const u32, opts: struct { clipping: bool = true, single_threaded: bool = true }) void {
        g.recWord(g.index(fs));
        g.recWord(g.index(g.vs[varyings]));
        g.recWord(g.index(g.cs));
        g.recWord(g.index(g.pos.handle));
        g.recWord(g.index(g.col.handle));
        g.recByte(@as(u8, @intFromBool(opts.single_threaded)) | @as(u8, @intFromBool(opts.clipping)) << 2);
        g.recByte(0);
        g.recByte(0);
        g.recByte(varyings);
        g.recWord(0);
        g.recWord(0);
        g.recByte(0);
        g.recByte(0);
        g.recByte(if (varyings > 0) 3 else 1);
        g.recByte(16 + varyings * 4);
        g.recWord(0);
        g.recWord(0);
        g.recByte(0);
        g.recByte(0);
        g.recByte(1);
        g.recByte(16);
        g.recWord(0);
        g.recWord(0);
        // Attributes: positions, colours.
        g.recWord(0);
        g.recByte(15);
        g.recByte(16);
        g.recByte(0);
        g.recByte(0);
        g.recWord(0);
        g.recByte(@max(varyings, 1) * 4 - 1);
        g.recByte(16);
        g.recByte(16);
        g.recByte(16);
        g.rec_count += 1;
        for (fs_unifs) |u| g.unif(u);
        for (0..2) |_| for (g.unifs) |u| g.unif(u);
        g.byte(64);
        g.word(2);
    }

    const Surfaces = struct {
        /// The colour write's render configuration bits (format, memory layout, multisampling).
        color_bits: u16 = 1 << 2,
        zs_write: bool = false,
        zs_read: bool = false,
        msaa_color: bool = false,
        msaa_zs: bool = false,
        /// The colour loaded first: from the second surface at full resolution.
        color_read_full: bool = false,
        clear_z: u32 = 0xffffff,
        clear_s: u8 = 0,
        clear_color: u32 = 0xff000000,
        /// The tiles drawn (all if null): x0, y0, x1, y1.
        tiles: ?[4]u8 = null,
    };

    /// Submits the job and waits for it: false if the kernel rejected it.
    fn submit(g: *Gl, s: Surfaces) bool {
        g.byte(7);
        g.byte(4);
        const tiles_w: u8 = @intCast((g.width + g.tileSize() - 1) / g.tileSize());
        const tiles_h: u8 = @intCast((g.height + g.tileSize() - 1) / g.tileSize());
        const t: [4]u8 = s.tiles orelse .{ 0, 0, tiles_w - 1, tiles_h - 1 };
        var cl: init.SubmitCl = .{
            .bin_cl = @intFromPtr(g.bcl.ptr),
            .bin_cl_size = @intCast(g.bcl_len),
            .shader_rec = @intFromPtr(g.rec.ptr),
            .shader_rec_size = @intCast(g.rec_len),
            .shader_rec_count = g.rec_count,
            .uniforms = @intFromPtr(g.uniforms.ptr),
            .uniforms_size = @intCast(g.uniforms_len * 4),
            .bo_handles = @intFromPtr(&g.handles),
            .bo_handle_count = 0,
            .width = @intCast(g.width),
            .height = @intCast(g.height),
            .min_x_tile = t[0],
            .min_y_tile = t[1],
            .max_x_tile = t[2],
            .max_y_tile = t[3],
            .color_write = .{ .hindex = 0, .bits = s.color_bits },
            .clear_color = .{ s.clear_color, s.clear_color },
            .clear_z = s.clear_z,
            .clear_s = s.clear_s,
            .flags = 1,
        };
        // Depth and stencil written to the surface (T-format), or read from it.
        const zs_bits: u16 = 2 | 1 << 4;
        if (s.zs_write) cl.zs_write = .{ .hindex = g.index(g.surface.handle), .bits = zs_bits };
        if (s.zs_read) cl.zs_read = .{ .hindex = g.index(g.surface.handle), .bits = zs_bits };
        if (s.msaa_color) cl.msaa_color_write = .{ .hindex = g.index(g.surface.handle) };
        if (s.msaa_zs) cl.msaa_zs_write = .{ .hindex = g.index(g.surface2.handle) };
        if (s.color_read_full) cl.color_read = .{ .hindex = g.index(g.surface.handle), .flags = 1 };
        cl.bo_handle_count = g.handle_count;
        if (init.ioctl(g.fd, init.drmIowr(0x40, init.SubmitCl), &cl) != .SUCCESS) {
            g.rejected += 1;
            return false;
        }
        var w: init.WaitSeqno = .{ .seqno = cl.seqno, .timeout_ns = 10_000_000_000 };
        init.must(init.ioctl(g.fd, init.drmIowr(0x41, init.WaitSeqno), &w), "VC4_WAIT_SEQNO");
        return true;
    }

    /// Draws a frame (`draw` writes its state and primitives) and reports it as `name`.
    fn frame(g: *Gl, r: *Result, name: []const u8, ctx: anytype, comptime draw: anytype) void {
        g.frameWith(r, name, ctx, draw, .{});
    }

    fn frameWith(g: *Gl, r: *Result, name: []const u8, ctx: anytype, comptime draw: anytype, s: Surfaces) void {
        g.begin();
        draw(ctx, g);
        @memset(g.target.bytes, 0);
        _ = g.submit(s);
        r.add(name, checksum(g.target.bytes));
    }
};

fn config(forward: bool, reverse: bool, clockwise: bool, depth_func: u3, z_updates: bool) u24 {
    return @as(u24, @intFromBool(forward)) | @as(u24, @intFromBool(reverse)) << 1 | @as(u24, @intFromBool(clockwise)) << 2 |
        @as(u24, depth_func) << 12 | @as(u24, @intFromBool(z_updates)) << 15;
}

/// The scene, without the surfaces' buffers (only `surfaces` needs them: CMA memory is short).
fn openGl(p: Params) Gl {
    return .createWith(init.openCard(), @min(p.width, 2048), @min(p.height, 2048), false);
}

/// Primitives (each mode, from arrays and 8 and 16-bit index buffers; point sizes, line widths),
/// rasterizer state (culling, each depth test, depth offset, flat shading, oversampling, clip
/// windows and viewports), and fragment shaders writing depth and the stencil, discarding, and
/// reading the rasterizer's data.
pub fn pipeline(p: Params, r: *Result) void {
    var g = openGl(p);
    const w: f32 = @floatFromInt(g.width);
    const h: f32 = @floatFromInt(g.height);
    var seed: u32 = 201;
    // Each mode's band: a zigzag of 24 vertices.
    const band = h / 7;
    for (0..7) |m| {
        for (0..24) |i| {
            const fi: f32 = @floatFromInt(i);
            const y0 = band * @as(f32, @floatFromInt(m));
            _ = g.vertex(8 + fi * (w - 16) / 23, y0 + if (m == 6 and i == 0) band / 2 else if (i % 2 == 0) band * 0.15 else band * 0.85, 0.5, colour(&seed));
        }
    }
    const idx8 = g.idx.bytes;
    for (0..g.n) |i| idx8[i] = @intCast(i);
    const Prims = struct {
        fn arrays(_: void, gl: *Gl) void {
            gl.packetF32(98, 4);
            gl.shaderState(gl.flat, 3, &.{}, .{});
            for (0..7) |m| gl.arrays(@intCast(m), 24, @intCast(m * 24));
        }
        fn indexed8(_: void, gl: *Gl) void {
            gl.packetF32(98, 4);
            gl.shaderState(gl.flat, 3, &.{}, .{});
            for (0..7) |m| gl.indexed(@intCast(m), false, 24, @intCast(m * 24), @intCast(m * 24 + 23));
        }
        fn indexed16(_: void, gl: *Gl) void {
            gl.packetF32(98, 4);
            gl.shaderState(gl.flat, 3, &.{}, .{});
            for (0..7) |m| gl.indexed(@intCast(m), true, 24, 512 + @as(u32, @intCast(m * 48)), @intCast(m * 24 + 23));
        }
        fn widths(_: void, gl: *Gl) void {
            gl.shaderState(gl.flat, 3, &.{}, .{});
            for (0..7) |k| {
                gl.packetF32(99, @floatFromInt(k + 1));
                gl.packetF32(98, @floatFromInt(k * 4 + 1));
                gl.arrays(1, 24, @intCast(k * 24));
                gl.arrays(0, 24, @intCast(k * 24));
            }
        }
    };
    const idx16 = std.mem.bytesAsSlice(u16, g.idx.bytes[512..][0 .. g.n * 2]);
    for (idx16, 0..) |*v, i| v.* = @intCast(i);
    g.frame(r, "arrays", {}, Prims.arrays);
    g.frame(r, "indices8", {}, Prims.indexed8);
    g.frame(r, "indices16", {}, Prims.indexed16);
    g.frame(r, "widths_sizes", {}, Prims.widths);

    // Triangles, overlapping at random depths, for the rasterizer's state.
    g.n = 0;
    for (0..2) |way| {
        for (0..60) |_| {
            const x = rand(&seed) * w;
            const y = rand(&seed) * h;
            const c = colour(&seed);
            _ = g.vertex(x, y, rand(&seed), c);
            if (way == 0) {
                _ = g.vertex(x + 150, y + 20, rand(&seed), c);
                _ = g.vertex(x + 30, y + 130, rand(&seed), c);
            } else {
                _ = g.vertex(x + 30, y + 130, rand(&seed), c);
                _ = g.vertex(x + 150, y + 20, rand(&seed), c);
            }
        }
    }
    const Raster = struct {
        fn culling(_: void, gl: *Gl) void {
            gl.shaderState(gl.flat, 3, &.{}, .{});
            for (0..8) |k| {
                gl.config(config(k & 1 != 0, k & 2 != 0, k & 4 != 0, 7, false));
                gl.clipWindow(@intCast(k * gl.width / 8), 0, @intCast(gl.width / 8), @intCast(gl.height));
                gl.arrays(4, gl.n, 0);
            }
        }
        fn depth(updates: bool, gl: *Gl) void {
            gl.shaderState(gl.flat, 3, &.{}, .{});
            for (0..8) |f| {
                gl.config(config(true, true, false, @intCast(f), updates));
                gl.clipWindow(0, @intCast(f * gl.height / 8), @intCast(gl.width), @intCast(gl.height / 8));
                gl.arrays(4, gl.n, 0);
            }
        }
        fn misc(_: void, gl: *Gl) void {
            gl.shaderState(gl.flat, 3, &.{}, .{});
            const third = gl.n / 9 * 3;
            gl.config(config(true, true, false, 1, true));
            gl.arrays(4, third, 0);
            gl.byte(101);
            gl.half(@truncate(@as(u32, @bitCast(@as(f32, -1.5))) >> 16));
            gl.half(@truncate(@as(u32, @bitCast(@as(f32, -4))) >> 16));
            gl.config(config(true, true, false, 1, true) | 1 << 3);
            gl.packetU32(97, 0b101);
            gl.arrays(4, third, third);
            gl.packetU32(97, 0);
            gl.config(config(true, true, false, 7, false) | 1 << 6);
            gl.viewport(@intCast(gl.width * 8 - 16 * 40), @intCast(gl.height * 8 - 16 * 25));
            gl.arrays(4, third, third * 2);
        }
    };
    g.frame(r, "culling", {}, Raster.culling);
    g.frame(r, "depth_tests", true, Raster.depth);
    g.frame(r, "depth_no_updates", false, Raster.depth);
    g.frame(r, "offset_flat_viewport", {}, Raster.misc);

    // Fragment shaders: depth from a varying, the stencil, discards, the rasterizer's data.
    const Frag = struct {
        fs: u32,
        varyings: u8,
        unifs: []const u32,
        cfg: u24,
        fn draw(ctx: @This(), gl: *Gl) void {
            gl.config(ctx.cfg);
            gl.shaderState(ctx.fs, ctx.varyings, ctx.unifs, .{});
            gl.arrays(4, gl.n, 0);
        }
    };
    const stencil_setup = [_]u32{ 3 << 30 | 3 << 28 | 3 << 25 | 2 << 22 | 1 << 19 | 7 << 16 | 0x5a << 8 | 0xff, 0xffff };
    const frags = [_]struct { name: []const u8, code: programs.Prog, varyings: u8, unifs: []const u32, cfg: u24 }{
        .{ .name = "shader_depth", .code = programs.depthFragmentShader(true), .varyings = 4, .unifs = &.{}, .cfg = config(true, true, false, 1, true) },
        .{ .name = "tlb_z", .code = programs.depthFragmentShader(false), .varyings = 3, .unifs = &.{}, .cfg = config(true, true, false, 1, true) },
        .{ .name = "stencil", .code = programs.stencilFragmentShader(2), .varyings = 3, .unifs = &stencil_setup, .cfg = config(true, true, false, 7, false) },
        .{ .name = "discard", .code = programs.discardFragmentShader(), .varyings = 4, .unifs = &.{}, .cfg = config(true, true, false, 7, false) },
        .{ .name = "payload", .code = programs.payloadFragmentShader(), .varyings = 0, .unifs = &.{}, .cfg = config(true, true, false, 7, false) },
    };
    var shaders_rejected: u64 = 0;
    for (frags) |f| {
        if (tryShader(g.fd, f.code.code())) |fs| {
            g.frame(r, f.name, Frag{ .fs = fs, .varyings = f.varyings, .unifs = f.unifs, .cfg = f.cfg }, Frag.draw);
        } else shaders_rejected += 1;
    }
    r.add("shaders_rejected", shaders_rejected);
    r.add("jobs_rejected", g.rejected);
}

/// Textures through the kernel (which checks each against its buffer): every type, wrap modes,
/// filters with mipmaps, both TMUs, two textures together.
pub fn textures(p: Params, r: *Result) void {
    var g = openGl(p);
    const w: f32 = @floatFromInt(g.width);
    const h: f32 = @floatFromInt(g.height);
    // Pseudo-random texels: 4 MiB, mipmaps before the base at 2 MiB.
    const tex = Bo.create(g.fd, 4 << 20);
    var seed: u32 = 202;
    for (std.mem.bytesAsSlice(u32, tex.bytes)) |*v| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        v.* = seed;
    }
    const base: u32 = 2 << 20;
    const plain = tryShader(g.fd, programs.textureFragmentShader(.{}).code()) orelse init.fail("the kernel rejected a texture shader", .{});
    // Quads with s, t across them.
    const Quad = struct {
        fn add(gl: *Gl, x0: f32, y0: f32, x1: f32, y1: f32, s1: f32, t1: f32) void {
            for ([6][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } }) |k| {
                _ = gl.vertex4(x0 + k[0] * (x1 - x0), y0 + k[1] * (y1 - y0), 0.5, 1, .{ k[0] * s1, k[1] * t1, 0, 0 });
            }
        }
    };
    const Band = struct {
        fs: u32,
        p0: u32,
        p1: u32,
        tex: u32,
        first: u32,
        fn draw(b: @This(), gl: *Gl) void {
            gl.shaderState(b.fs, 2, &.{ gl.index(b.tex), b.p0, b.p1 }, .{});
            gl.arrays(4, 6, b.first);
        }
    };
    const names = [18][]const u8{ "rgba8888", "rgbx8888", "rgba4444", "rgba5551", "rgb565", "luminance", "alpha", "lumalpha", "etc1", "s16f", "s8", "s16", "bw1", "a4", "a1", "rgba64", "rgba32r", "yuyv422r" };
    const rgba64 = tryShader(g.fd, programs.textureFragmentShader(.{ .two_reads = true }).code());
    var rejected: u64 = 0;
    for (names, 0..) |name, ty| {
        g.n = 0;
        Quad.add(&g, 0, 0, w, h, 3, 2);
        const fs = if (ty == 15) rgba64 orelse plain else plain;
        const p0 = base | @as(u32, @intCast(ty & 15)) << 4;
        const p1 = @as(u32, @intCast(ty >> 4)) << 31 | 64 << 20 | 128 << 8;
        const before = g.rejected;
        g.frame(r, name, Band{ .fs = fs, .p0 = p0, .p1 = p1, .tex = tex.handle, .first = 0 }, Band.draw);
        rejected += g.rejected - before;
    }
    // Wraps, filters (minified with mipmaps), and nearest magnification.
    const modes = [_]struct { name: []const u8, p0: u32, p1: u32, s: f32 }{
        .{ .name = "wrap_clamp", .p0 = base, .p1 = 64 << 20 | 128 << 8 | 1 << 2 | 1, .s = 3 },
        .{ .name = "wrap_mirror", .p0 = base, .p1 = 64 << 20 | 128 << 8 | 2 << 2 | 2, .s = 3 },
        .{ .name = "trilinear", .p0 = base | 8, .p1 = 256 << 20 | 256 << 8 | 5 << 4, .s = 8 },
        .{ .name = "mip_nearest", .p0 = base | 8, .p1 = 256 << 20 | 256 << 8 | 2 << 4, .s = 8 },
        .{ .name = "mag_nearest", .p0 = base, .p1 = 64 << 20 | 128 << 8 | 1 << 7, .s = 0.1 },
    };
    for (modes) |m| {
        g.n = 0;
        Quad.add(&g, 0, 0, w, h, m.s, m.s);
        const before = g.rejected;
        g.frame(r, m.name, Band{ .fs = plain, .p0 = m.p0, .p1 = m.p1, .tex = tex.handle, .first = 0 }, Band.draw);
        rejected += g.rejected - before;
    }
    r.add("jobs_rejected", rejected);
}

/// The QPU instruction groups (as fragment shaders, a band each) the kernel's validator accepts.
pub fn qpu(p: Params, r: *Result) void {
    var g = openGl(p);
    const w: f32 = @floatFromInt(g.width);
    const groups = std.enums.values(programs.AluGroup);
    const band = @as(f32, @floatFromInt(g.height)) / @as(f32, @floatFromInt(groups.len));
    var fs: [groups.len]?u32 = undefined;
    var rejected: u64 = 0;
    for (groups, 0..) |group, i| {
        const y0 = band * @as(f32, @floatFromInt(i));
        for ([6][2]f32{ .{ 0, y0 }, .{ w, y0 }, .{ 0, y0 + band }, .{ w, y0 }, .{ w, y0 + band }, .{ 0, y0 + band } }) |c| _ = g.vertex4(c[0], c[1], 0.5, 1, .{ 0, 0, 0, 0 });
        fs[i] = tryShader(g.fd, programs.aluFragmentShader(group).code());
        if (fs[i] == null) rejected += 1;
    }
    const Ctx = struct {
        fs: []const ?u32,
        fn draw(ctx: @This(), gl: *Gl) void {
            for (ctx.fs, 0..) |f, i| {
                const code = f orelse continue;
                // Only the special registers' group reads uniforms (the kernel steps through them by
                // what each shader reads).
                const group = std.enums.values(programs.AluGroup)[i];
                const unifs: []const u32 = if (group == .special_registers) &.{ 0x12345678, 0 } else &.{};
                gl.shaderState(code, 0, unifs, .{ .single_threaded = group != .threads });
                gl.arrays(4, 6, @intCast(i * 6));
            }
        }
    };
    g.frame(r, "frame", Ctx{ .fs = &fs }, Ctx.draw);
    for (groups, 0..) |group, i| {
        const y0: u32 = @intFromFloat(band * @as(f32, @floatFromInt(i)));
        const y1: u32 = @intFromFloat(band * @as(f32, @floatFromInt(i + 1)));
        r.add(@tagName(group), if (fs[i] == null) 0 else checksum(g.target.bytes[y0 * g.width * 4 .. y1 * g.width * 4]));
    }
    r.add("shaders_rejected", rejected);
    r.add("jobs_rejected", g.rejected);
}

/// The tile buffer through SUBMIT_CL's surfaces: each colour format and memory layout, depth and
/// stencil written then read back (tested against), multisampled full-resolution colour and
/// depth writes and a full-resolution colour read, clear values, and a partial frame (some
/// tiles).
pub fn surfaces(p: Params, r: *Result) void {
    var g = Gl.create(init.openCard(), @min(p.width, 2048), @min(p.height, 2048));
    const w: f32 = @floatFromInt(g.width);
    const h: f32 = @floatFromInt(g.height);
    var seed: u32 = 203;
    for (0..150) |_| {
        const x = rand(&seed) * w;
        const y = rand(&seed) * h;
        _ = g.vertex(x, y, rand(&seed), colour(&seed));
        _ = g.vertex(x + 200, y + 30, rand(&seed), colour(&seed));
        _ = g.vertex(x + 50, y + 170, rand(&seed), colour(&seed));
    }
    const Scene = struct {
        fn draw(_: void, gl: *Gl) void {
            gl.config(config(true, true, false, 1, true));
            gl.shaderState(gl.flat, 3, &.{}, .{});
            gl.arrays(4, gl.n, 0);
        }
    };
    const layouts = [_]struct { name: []const u8, bits: u16 }{
        .{ .name = "rgba8888_linear", .bits = 1 << 2 },
        .{ .name = "rgba8888_t", .bits = 1 << 2 | 1 << 6 },
        .{ .name = "rgba8888_lt", .bits = 1 << 2 | 2 << 6 },
        .{ .name = "bgr565_dither", .bits = 0 << 2 },
        .{ .name = "bgr565", .bits = 2 << 2 },
        .{ .name = "bgr565_t", .bits = 2 << 2 | 1 << 6 },
    };
    for (layouts) |f| g.frameWith(r, f.name, {}, Scene.draw, .{ .color_bits = f.bits });
    // Depth and stencil written, then a second frame reading them.
    g.frameWith(r, "zs_write", {}, Scene.draw, .{ .zs_write = true, .clear_s = 0x5a });
    r.add("zs_written", checksum(g.surface.bytes));
    g.frameWith(r, "zs_read", {}, Scene.draw, .{ .zs_read = true });
    // Multisampled: full-resolution colour and depth written too, then the colour read back.
    g.msaa = true;
    g.frameWith(r, "msaa", {}, Scene.draw, .{ .color_bits = 1 << 2 | 1 | 1 << 4, .msaa_color = true, .msaa_zs = true });
    r.add("msaa_full_res", checksum(g.surface.bytes) ^ checksum(g.surface2.bytes));
    g.frameWith(r, "msaa_reloaded", {}, Scene.draw, .{ .color_bits = 1 << 2 | 1 | 1 << 4, .color_read_full = true });
    g.msaa = false;
    // Clear values, and only some tiles.
    g.frameWith(r, "clear_values", {}, Scene.draw, .{ .clear_color = 0xff336699, .clear_z = 0x400000 });
    g.frameWith(r, "partial_tiles", {}, Scene.draw, .{ .tiles = .{ 2, 1, 5, 4 } });
    r.add("jobs_rejected", g.rejected);
}

/// Stress through the kernel: a half-million-triangle indexed mesh, the largest offscreen frame
/// (2048 square, multisampled), and thousands of draws each with its own record.
pub fn stress(p: Params, r: *Result) void {
    var g = openGl(p);
    const w: f32 = @floatFromInt(g.width);
    const h: f32 = @floatFromInt(g.height);
    var seed: u32 = 204;
    // A 512 x 256 grid (the most vertices one 16-bit index list reaches), drawn twice.
    const cols = 512;
    const rows = 128;
    for (0..rows) |y| {
        for (0..cols) |x| {
            const fx: f32 = @floatFromInt(x);
            const fy: f32 = @floatFromInt(y);
            _ = g.vertex4(fx * w / cols, h - fy * h / rows, 0.3 + 0.6 * fy / rows, 1 + 2 * fy / rows, .{ rand(&seed), rand(&seed), rand(&seed), 0 });
        }
    }
    const idx = std.mem.bytesAsSlice(u16, g.idx.bytes);
    var n: u32 = 0;
    for (0..rows - 1) |y| {
        for (0..cols - 1) |x| {
            const a: u16 = @intCast(y * cols + x);
            for ([6]u16{ a, a + cols, a + 1, a + 1, a + cols, a + cols + 1 }) |ix| {
                idx[n] = ix;
                n += 1;
            }
        }
    }
    const Mesh = struct {
        n: u32,
        fn draw(ctx: @This(), gl: *Gl) void {
            gl.config(config(true, false, false, 1, true));
            gl.shaderState(gl.flat, 3, &.{}, .{});
            for (0..4) |_| gl.indexed(4, true, ctx.n, 0, rows * cols - 1);
        }
    };
    const frames = p.amount(3);
    for (0..frames) |_| g.frame(r, "mesh", Mesh{ .n = n }, Mesh.draw);
    r.add("triangles", @as(u64, n / 3) * 4 * frames);

    // Thousands of draws, each its own record and state.
    g.n = 0;
    const draws: u32 = @intCast(@min(p.amount(4000), 8000));
    for (0..draws) |_| {
        const x = rand(&seed) * w;
        const y = rand(&seed) * h;
        _ = g.vertex(x, y, rand(&seed), colour(&seed));
        _ = g.vertex(x + 60, y + 10, rand(&seed), colour(&seed));
        _ = g.vertex(x + 20, y + 50, rand(&seed), colour(&seed));
    }
    const Draws = struct {
        n: u32,
        fn draw(ctx: @This(), gl: *Gl) void {
            for (0..ctx.n) |i| {
                const k: u32 = @intCast(i);
                gl.config(config(true, k % 3 != 0, false, @intCast(k % 8), k % 2 == 0));
                gl.clipWindow(@intCast(k * 37 % (gl.width / 2)), @intCast(k * 23 % (gl.height / 2)), @intCast(gl.width / 2), @intCast(gl.height / 2));
                gl.shaderState(gl.flat, 3, &.{}, .{});
                gl.arrays(4, 3, k * 3);
            }
        }
    };
    for (0..frames) |_| g.frame(r, "draws", Draws{ .n = draws }, Draws.draw);

    // The largest frame, offscreen: 2048 square, multisampled.
    var big = Gl.createWith(g.fd, 2048, 2048, false);
    big.msaa = true;
    for (0..300) |_| {
        const x = rand(&seed) * 1800;
        const y = rand(&seed) * 1800;
        _ = big.vertex(x, y, rand(&seed), colour(&seed));
        _ = big.vertex(x + 500, y + 60, rand(&seed), colour(&seed));
        _ = big.vertex(x + 100, y + 450, rand(&seed), colour(&seed));
    }
    for (0..frames) |_| big.frameWith(r, "big_frame", {}, struct {
        fn draw(_: void, gl: *Gl) void {
            gl.config(config(true, true, false, 1, true));
            gl.shaderState(gl.flat, 3, &.{}, .{});
            gl.arrays(4, gl.n, 0);
        }
    }.draw, .{ .color_bits = 1 << 2 | 1 | 1 << 4 });
    r.add("jobs_rejected", g.rejected + big.rejected);
}

// --- The HVS through KMS ---------------------------------------------------------------------

const SetClientCap = extern struct { capability: u64, value: u64 };
const PlaneRes = extern struct { plane_id_ptr: u64 = 0, count_planes: u32 = 0 };
const GetPlane = extern struct { plane_id: u32, crtc_id: u32 = 0, fb_id: u32 = 0, possible_crtcs: u32 = 0, gamma_size: u32 = 0, count_format_types: u32 = 0, format_type_ptr: u64 = 0 };
const SetPlane = extern struct { plane_id: u32, crtc_id: u32, fb_id: u32, flags: u32 = 0, crtc_x: i32, crtc_y: i32, crtc_w: u32, crtc_h: u32, src_x: u32 = 0, src_y: u32 = 0, src_h: u32, src_w: u32 };
const ObjProps = extern struct { props_ptr: u64, prop_values_ptr: u64, count_props: u32, obj_id: u32, obj_type: u32 };
const GetProperty = extern struct { values_ptr: u64 = 0, enum_blob_ptr: u64 = 0, prop_id: u32, flags: u32 = 0, name: [32]u8 = @splat(0), count_values: u32 = 0, count_enum_blobs: u32 = 0 };
const SetProperty = extern struct { value: u64, prop_id: u32, obj_id: u32, obj_type: u32 };
const RmFb = u32;

const obj_plane: u32 = 0xeeeeeeee;

fn fourcc(comptime s: *const [4]u8) u32 {
    return @as(u32, s[0]) | @as(u32, s[1]) << 8 | @as(u32, s[2]) << 16 | @as(u32, s[3]) << 24;
}

const mod_linear: u64 = 0;
const mod_t_tiled: u64 = 0x07 << 56 | 1;
fn modSand(code: u64, col_height: u64) u64 {
    return 0x07 << 56 | col_height << 8 | code;
}

/// A format: its planes' bytes per pixel, and its chroma subsampling.
const Format = struct { code: u32, bpp: [3]u8, hsub: u8 = 1, vsub: u8 = 1 };

const formats = [_]Format{
    .{ .code = fourcc("XR24"), .bpp = .{ 4, 0, 0 } },                       .{ .code = fourcc("AR24"), .bpp = .{ 4, 0, 0 } },
    .{ .code = fourcc("XB24"), .bpp = .{ 4, 0, 0 } },                       .{ .code = fourcc("AB24"), .bpp = .{ 4, 0, 0 } },
    .{ .code = fourcc("RX24"), .bpp = .{ 4, 0, 0 } },                       .{ .code = fourcc("RA24"), .bpp = .{ 4, 0, 0 } },
    .{ .code = fourcc("BX24"), .bpp = .{ 4, 0, 0 } },                       .{ .code = fourcc("BA24"), .bpp = .{ 4, 0, 0 } },
    .{ .code = fourcc("RG16"), .bpp = .{ 2, 0, 0 } },                       .{ .code = fourcc("BG16"), .bpp = .{ 2, 0, 0 } },
    .{ .code = fourcc("AR15"), .bpp = .{ 2, 0, 0 } },                       .{ .code = fourcc("XR15"), .bpp = .{ 2, 0, 0 } },
    .{ .code = fourcc("RG24"), .bpp = .{ 3, 0, 0 } },                       .{ .code = fourcc("BG24"), .bpp = .{ 3, 0, 0 } },
    .{ .code = fourcc("XR30"), .bpp = .{ 4, 0, 0 } },                       .{ .code = fourcc("AR30"), .bpp = .{ 4, 0, 0 } },
    .{ .code = fourcc("AB30"), .bpp = .{ 4, 0, 0 } },                       .{ .code = fourcc("XB30"), .bpp = .{ 4, 0, 0 } },
    .{ .code = fourcc("RGB8"), .bpp = .{ 1, 0, 0 } },                       .{ .code = fourcc("BGR8"), .bpp = .{ 1, 0, 0 } },
    .{ .code = fourcc("XR12"), .bpp = .{ 2, 0, 0 } },                       .{ .code = fourcc("AR12"), .bpp = .{ 2, 0, 0 } },
    .{ .code = fourcc("XB12"), .bpp = .{ 2, 0, 0 } },                       .{ .code = fourcc("AB12"), .bpp = .{ 2, 0, 0 } },
    .{ .code = fourcc("BX12"), .bpp = .{ 2, 0, 0 } },                       .{ .code = fourcc("BA12"), .bpp = .{ 2, 0, 0 } },
    .{ .code = fourcc("RX12"), .bpp = .{ 2, 0, 0 } },                       .{ .code = fourcc("RA12"), .bpp = .{ 2, 0, 0 } },
    .{ .code = fourcc("YU16"), .bpp = .{ 1, 1, 1 }, .hsub = 2 },            .{ .code = fourcc("YV16"), .bpp = .{ 1, 1, 1 }, .hsub = 2 },
    .{ .code = fourcc("YU24"), .bpp = .{ 1, 1, 1 } },                       .{ .code = fourcc("YV24"), .bpp = .{ 1, 1, 1 } },
    .{ .code = fourcc("YU12"), .bpp = .{ 1, 1, 1 }, .hsub = 2, .vsub = 2 }, .{ .code = fourcc("YV12"), .bpp = .{ 1, 1, 1 }, .hsub = 2, .vsub = 2 },
    .{ .code = fourcc("NV12"), .bpp = .{ 1, 2, 0 }, .hsub = 2, .vsub = 2 }, .{ .code = fourcc("NV21"), .bpp = .{ 1, 2, 0 }, .hsub = 2, .vsub = 2 },
    .{ .code = fourcc("NV16"), .bpp = .{ 1, 2, 0 }, .hsub = 2 },            .{ .code = fourcc("NV61"), .bpp = .{ 1, 2, 0 }, .hsub = 2 },
};

/// A framebuffer of `f` (`w` by `h`, with `modifier`) over pseudo-random bytes, or null if the
/// kernel won't make it.
fn makeFb(fd: i32, f: Format, w: u32, h: u32, modifier: u64, bo: *const Bo) ?u32 {
    var cmd: init.FbCmd2 = .{ .width = w, .height = h, .pixel_format = f.code, .flags = 2 };
    var offset: u32 = 0;
    for (f.bpp, 0..) |bpp, i| {
        if (bpp == 0) break;
        const pw = if (i == 0) w else w / f.hsub;
        const ph = if (i == 0) h else h / f.vsub;
        cmd.handles[i] = bo.handle;
        cmd.pitches[i] = if (modifier == mod_t_tiled) std.mem.alignForward(u32, pw * bpp, 128) else pw * bpp;
        cmd.offsets[i] = offset;
        cmd.modifier[i] = modifier;
        offset += std.mem.alignForward(u32, cmd.pitches[i] * std.mem.alignForward(u32, ph, 64), 4096);
    }
    if (init.ioctl(fd, init.drmIowr(0xB8, init.FbCmd2), &cmd) != .SUCCESS) return null;
    return cmd.fb_id;
}

/// A plane's property's id by name, or null.
fn planeProperty(fd: i32, plane: u32, name: []const u8) ?u32 {
    var ids: [32]u32 = undefined;
    var values: [32]u64 = undefined;
    var props: ObjProps = .{ .props_ptr = @intFromPtr(&ids), .prop_values_ptr = @intFromPtr(&values), .count_props = 32, .obj_id = plane, .obj_type = obj_plane };
    if (init.ioctl(fd, init.drmIowr(0xB9, ObjProps), &props) != .SUCCESS) return null;
    for (ids[0..@min(props.count_props, 32)]) |id| {
        var gp: GetProperty = .{ .prop_id = id };
        if (init.ioctl(fd, init.drmIowr(0xAA, GetProperty), &gp) != .SUCCESS) continue;
        if (std.mem.eql(u8, std.mem.sliceTo(&gp.name, 0), name)) return id;
    }
    return null;
}

/// A plane's property's value by name, or null.
fn planePropertyValue(fd: i32, plane: u32, name: []const u8) ?u64 {
    var ids: [32]u32 = undefined;
    var values: [32]u64 = undefined;
    var props: ObjProps = .{ .props_ptr = @intFromPtr(&ids), .prop_values_ptr = @intFromPtr(&values), .count_props = 32, .obj_id = plane, .obj_type = obj_plane };
    if (init.ioctl(fd, init.drmIowr(0xB9, ObjProps), &props) != .SUCCESS) return null;
    for (ids[0..@min(props.count_props, 32)], values[0..@min(props.count_props, 32)]) |id, v| {
        var gp: GetProperty = .{ .prop_id = id };
        if (init.ioctl(fd, init.drmIowr(0xAA, GetProperty), &gp) != .SUCCESS) continue;
        if (std.mem.eql(u8, std.mem.sliceTo(&gp.name, 0), name)) return v;
    }
    return null;
}

fn setProperty(fd: i32, plane: u32, id: ?u32, value: u64) bool {
    var sp: SetProperty = .{ .value = value, .prop_id = id orelse return false, .obj_id = plane, .obj_type = obj_plane };
    return init.ioctl(fd, init.drmIowr(0xBA, SetProperty), &sp) == .SUCCESS;
}

/// The HVS through KMS: overlay planes showing every pixel format Linux's vc4 driver takes, each
/// linear and (those that can be) T-tiled or SAND-tiled, scaled up and down, reflected and
/// rotated, with plane alpha and each blend mode; each shown for some frames.
pub fn planes(p: Params, r: *Result) void {
    var d = init.Display.init();
    const fd = d.fd;
    var cap: SetClientCap = .{ .capability = 2, .value = 1 };
    _ = init.ioctl(fd, linux.IOCTL.IOW('d', 0x0d, SetClientCap), &cap);
    var ids: [16]u32 = undefined;
    var res: PlaneRes = .{ .plane_id_ptr = @intFromPtr(&ids), .count_planes = 16 };
    init.must(init.ioctl(fd, init.drmIowr(0xB5, PlaneRes), &res), "MODE_GETPLANERESOURCES");
    // The CRTC's index (its bit in planes' possible CRTCs).
    var crtcs: [8]u32 = undefined;
    var card: init.CardRes = .{ .crtc_id_ptr = @intFromPtr(&crtcs), .count_crtcs = 8 };
    init.must(init.ioctl(fd, init.drmIowr(0xA0, init.CardRes), &card), "MODE_GETRESOURCES");
    const crtc_bit = for (crtcs[0..@min(card.count_crtcs, 8)], 0..) |c, i| {
        if (c == d.crtc) break @as(u32, 1) << @intCast(i);
    } else 1;
    // Its overlay planes (their "type" property 0).
    var overlays: [8]u32 = undefined;
    var n_overlays: usize = 0;
    for (ids[0..@min(res.count_planes, 16)]) |id| {
        var gp: GetPlane = .{ .plane_id = id };
        if (init.ioctl(fd, init.drmIowr(0xB6, GetPlane), &gp) != .SUCCESS) continue;
        if (gp.possible_crtcs & crtc_bit == 0 or planePropertyValue(fd, id, "type") != 0) continue;
        if (n_overlays < overlays.len) {
            overlays[n_overlays] = id;
            n_overlays += 1;
        }
    }
    if (n_overlays == 0) init.fail("no overlay planes", .{});
    const bo = Bo.create(fd, 16 << 20);
    var seed: u32 = 205;
    for (std.mem.bytesAsSlice(u32, bo.bytes)) |*v| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        v.* = seed;
    }
    const per = p.amount(10);
    var shown: u64 = 0;
    var rejected: u64 = 0;
    const plane = overlays[0];
    const rotation = planeProperty(fd, plane, "rotation");
    const alpha = planeProperty(fd, plane, "alpha");
    const blend = planeProperty(fd, plane, "pixel blend mode");
    const Show = struct {
        fn f(disp: *init.Display, pl: u32, fb: u32, x: i32, y: i32, dw: u32, dh: u32, sw: u32, sh: u32, frames: usize) bool {
            var sp: SetPlane = .{ .plane_id = pl, .crtc_id = disp.crtc, .fb_id = fb, .crtc_x = x, .crtc_y = y, .crtc_w = dw, .crtc_h = dh, .src_w = sw << 16, .src_h = sh << 16 };
            if (init.ioctl(disp.fd, init.drmIowr(0xB7, SetPlane), &sp) != .SUCCESS) return false;
            for (0..frames) |_| disp.flip(true);
            return true;
        }
    };
    // Every format, linear, then T-tiled (the RGB ones) or SAND128 (the 2-plane YUV ones).
    for (formats) |f| {
        for ([_]u64{ mod_linear, mod_t_tiled, modSand(4, 96) }, 0..) |m, k| {
            if (k == 1 and f.bpp[1] != 0) continue;
            if (k == 2 and !(f.bpp[1] == 2 and f.bpp[2] == 0)) continue;
            const fb = makeFb(fd, f, 256, 192, m, &bo) orelse {
                rejected += 1;
                continue;
            };
            if (Show.f(&d, plane, fb, 100, 80, 256, 192, 256, 192, per)) shown += 1 else rejected += 1;
            var id = fb;
            _ = init.ioctl(fd, init.drmIowr(0xAF, RmFb), &id);
        }
    }
    // Scaling (up, down, each way), reflections and rotation, plane alpha and blend modes, of
    // ARGB8888 and NV12.
    const scaled = [_][4]u32{ .{ 512, 384, 256, 192 }, .{ 128, 96, 256, 192 }, .{ 600, 100, 256, 192 }, .{ 100, 500, 256, 192 } };
    for ([_]Format{ formats[1], formats[34] }) |f| {
        const fb = makeFb(fd, f, 256, 192, mod_linear, &bo) orelse {
            rejected += 1;
            continue;
        };
        for (scaled) |s| {
            if (Show.f(&d, plane, fb, 50, 40, s[0], s[1], s[2], s[3], per)) shown += 1 else rejected += 1;
        }
        // Reflect X, reflect Y, rotate 180 (bits 4, 5 and 2 of the rotation property, with 0 = 1).
        for ([_]u64{ 1 | 1 << 4, 1 | 1 << 5, 1 << 2 }) |rot| {
            if (setProperty(fd, plane, rotation, rot) and Show.f(&d, plane, fb, 60, 60, 256, 192, 256, 192, per)) shown += 1 else rejected += 1;
        }
        _ = setProperty(fd, plane, rotation, 1);
        for ([_]u64{ 0x8000, 0x4000 }) |a| {
            for (0..3) |mode| {
                if (setProperty(fd, plane, alpha, a) and setProperty(fd, plane, blend, mode) and Show.f(&d, plane, fb, 70, 70, 256, 192, 256, 192, per)) shown += 1 else rejected += 1;
            }
        }
        _ = setProperty(fd, plane, alpha, 0xffff);
        var id = fb;
        _ = init.ioctl(fd, init.drmIowr(0xAF, RmFb), &id);
    }
    // Every overlay at once, overlapping.
    {
        const fb = makeFb(fd, formats[1], 256, 192, mod_linear, &bo) orelse 0;
        var all = true;
        for (overlays[0..n_overlays], 0..) |pl, i| {
            var sp: SetPlane = .{ .plane_id = pl, .crtc_id = d.crtc, .fb_id = fb, .crtc_x = @intCast(i * 60), .crtc_y = @intCast(i * 40), .crtc_w = 256, .crtc_h = 192, .src_w = 256 << 16, .src_h = 192 << 16 };
            if (init.ioctl(fd, init.drmIowr(0xB7, SetPlane), &sp) != .SUCCESS) all = false;
        }
        for (0..per) |_| d.flip(true);
        if (all) shown += 1 else rejected += 1;
    }
    r.add("planes_shown", shown);
    r.add("rejected", rejected);
    r.add("overlays", n_overlays);
    r.add("flips", d.flips);
}
