//! V3D stress tests: the most data, and the most complex work, a frame can have: meshes of half
//! a million triangles, the largest (multisampled) frame, the largest textures (mipmapped, and
//! compressed), the longest shaders with the most varyings, and tens of thousands of draws each
//! changing state.

const std = @import("std");
const scene = @import("scene");
const hw = @import("hw.zig");
const gpu = @import("gpu.zig");
const main = @import("main.zig");
const features = @import("v3d_features.zig");

const programs = scene.programs;
const Cl = gpu.Cl;
const Geo = features.Geo;
const Params = main.Params;
const Result = main.Result;

/// A mesh of half a million triangles: 8 grids of 512 by 64 vertices (each its own record and
/// 16-bit index list), in perspective, depth-tested and back faces culled.
pub fn geometry(p: Params, r: *Result) void {
    var g: Geo = .init(p);
    const w: f32 = @floatFromInt(g.t.width);
    const h: f32 = @floatFromInt(g.t.height);
    const cols = 512;
    const rows = 64;
    var seed: u32 = 101;
    for (0..8) |chunk| {
        for (0..rows) |y| {
            for (0..cols) |x| {
                const fx: f32 = @floatFromInt(x);
                const fy: f32 = @floatFromInt(chunk * rows + y);
                // Further away (larger w) towards the top, rippled in depth.
                const depth = 0.3 + 0.6 * fy / (8 * rows) + 0.05 * @sin(fx * 0.05);
                _ = g.vertexW(fx * w / cols, h - fy * h / (8 * rows), depth, 1 + 3 * fy / (8 * rows), features.colour(&seed));
            }
        }
    }
    const indices = gpu.alloc(u16, (rows - 1) * (cols - 1) * 6, 16);
    var n: usize = 0;
    for (0..rows - 1) |y| {
        for (0..cols - 1) |x| {
            const a: u16 = @intCast(y * cols + x);
            // Facing forward (anticlockwise on screen, rows going up).
            for ([6]u16{ a, a + cols, a + 1, a + 1, a + cols, a + cols + 1 }) |ix| {
                indices[n] = ix;
                n += 1;
            }
        }
    }
    var recs: [8]u32 = undefined;
    for (&recs, 0..) |*rec, chunk| {
        const off: u32 = @intCast(chunk * rows * cols);
        const attrs = [_]gpu.GlRecord.Attr{
            .{ .addr = hw.bus(g.pos.ptr) + off * 16, .bytes = 16, .stride = 16 },
            .{ .addr = hw.bus(g.col.ptr) + off * 16, .bytes = 12, .stride = 16, .vs_offset = 16, .cs_offset = 16 },
        };
        rec.* = (gpu.GlRecord{
            .fs_varyings = 3,
            .fs_code = g.flat,
            .fs_unifs = gpu.words(&.{}),
            .vs_attr_mask = 0b11,
            .vs_attr_size = 28,
            .vs_code = g.vs[3],
            .vs_unifs = g.unifs,
            .cs_attr_mask = 0b01,
            .cs_attr_size = 16,
            .cs_code = g.cs,
            .cs_unifs = g.unifs,
            .attrs = &attrs,
        }).write();
    }
    const Mesh = struct {
        recs: [8]u32,
        idx: u32,
        count: u32,
        fn draw(ctx: @This(), _: *Geo, cl: *Cl) void {
            cl.config(.{ .reverse = false, .depth_func = 1, .z_updates = true });
            for (ctx.recs) |rec| {
                cl.glShaderState(rec, 2, false);
                cl.indexed(.triangles, true, ctx.count, ctx.idx, rows * cols - 1);
            }
        }
    };
    const frames = p.amount(3);
    for (0..frames) |_| g.frame(r, "mesh", Mesh{ .recs = recs, .idx = hw.bus(indices.ptr), .count = @intCast(n) }, Mesh.draw);
    r.add("triangles", @as(u64, n / 3) * 8 * frames);
    r.add("timeouts", g.timeouts);
}

/// The largest frame: 2048 square, 4x multisampled (4096 tiles of 32 pixels), 200 overlapping
/// quads depth-tested and each sample written on its own.
pub fn frame(p: Params, r: *Result) void {
    var g: Geo = .init(.{ .scale = p.scale, .width = 2048, .height = 2048 });
    g.t.msaa = true;
    var seed: u32 = 102;
    for (0..200) |_| {
        const x = scene.rand(&seed) * 1800;
        const y = scene.rand(&seed) * 1800;
        const z = scene.rand(&seed);
        const c = features.colour(&seed);
        for ([6][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } }) |k| _ = g.vertex(x + k[0] * 600, y + k[1] * 500 + k[0] * 37, z, c);
    }
    const fs = gpu.upload(programs.sampleWritesFragmentShader().code());
    const Big = struct {
        fs: u32,
        fn draw(ctx: @This(), geo: *Geo, cl: *Cl) void {
            cl.config(.{ .depth_func = 3, .z_updates = true });
            cl.glShaderState(geo.recordWith(ctx.fs, gpu.words(&.{}), 3, .{}), 2, false);
            cl.arrays(.triangles, geo.n, 0);
        }
    };
    const frames = p.amount(3);
    for (0..frames) |_| g.frame(r, "frame", Big{ .fs = fs }, Big.draw);
    r.add("pixels", @as(u64, 2048 * 2048) * frames);
    r.add("timeouts", g.timeouts);
}

/// The largest textures: 2048 square RGBA8888 with all 12 mipmap levels, sampled trilinearly at
/// random scales, and 2048 square ETC1; 2000 quads of each.
pub fn textures(p: Params, r: *Result) void {
    var g: Geo = .init(p);
    const w: f32 = @floatFromInt(g.t.width);
    const h: f32 = @floatFromInt(g.t.height);
    // 32 MiB: the mipmaps (a third of the base more) before the base.
    const mem = gpu.alloc(u8, 32 << 20, 4096);
    var seed: u32 = 103;
    for (std.mem.bytesAsSlice(u32, mem)) |*v| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        v.* = seed;
    }
    const base = hw.bus(mem.ptr) + (8 << 20);
    const fs = gpu.upload(programs.textureFragmentShader(.{}).code());
    const rgba = gpu.words(&.{ base | 11, (2048 & 2047) << 20 | (2048 & 2047) << 8 | 5 << 4 });
    const etc1 = gpu.words(&.{ base | 8 << 4, 0 << 20 | 0 << 8 | 0 << 4 });
    for (0..4000) |_| {
        const x = scene.rand(&seed) * w;
        const y = scene.rand(&seed) * h;
        const s = 0.5 + scene.rand(&seed) * 20;
        const s0 = scene.rand(&seed);
        const t0 = scene.rand(&seed);
        for ([6][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } }) |k| {
            _ = g.vertex4(x + k[0] * 120, y + k[1] * 90, 0.5, 1, .{ s0 + k[0] * s * 0.06, t0 + k[1] * s * 0.045, 0, 0 });
        }
    }
    const Tex = struct {
        fs: u32,
        rgba: u32,
        etc1: u32,
        fn draw(ctx: @This(), geo: *Geo, cl: *Cl) void {
            cl.glShaderState(geo.recordWith(ctx.fs, ctx.rgba, 2, .{}), 2, false);
            cl.arrays(.triangles, geo.n / 2, 0);
            cl.glShaderState(geo.recordWith(ctx.fs, ctx.etc1, 2, .{}), 2, false);
            cl.arrays(.triangles, geo.n / 2, geo.n / 2);
        }
    };
    const frames = p.amount(3);
    for (0..frames) |_| g.frame(r, "textures", Tex{ .fs = fs, .rgba = rgba, .etc1 = etc1 }, Tex.draw);
    r.add("quads", 4000 * frames);
    r.add("timeouts", g.timeouts);
}

/// The longest shaders: a fragment shader of thousands of instructions (in loops, with the SFU)
/// over the frame four times; and draws with 20 varyings (from 7 attribute arrays).
pub fn shaders(p: Params, r: *Result) void {
    var g: Geo = .init(p);
    const w: f32 = @floatFromInt(g.t.width);
    const h: f32 = @floatFromInt(g.t.height);
    var seed: u32 = 104;
    const long_fs = gpu.upload(programs.longFragmentShader(400).code());
    for (0..4) |_| {
        for ([6][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } }) |k| _ = g.vertex(k[0] * w, k[1] * h, 0.5, features.colour(&seed));
    }
    const Long = struct {
        fs: u32,
        fn draw(ctx: @This(), geo: *Geo, cl: *Cl) void {
            cl.glShaderState(geo.recordWith(ctx.fs, gpu.words(&.{}), 3, .{}), 2, false);
            cl.arrays(.triangles, geo.n, 0);
        }
    };
    const frames = p.amount(3);
    for (0..frames) |_| g.frame(r, "long_shader", Long{ .fs = long_fs }, Long.draw);

    // 20 varyings: the position, then 5 arrays of 4 words (the colours, read at offsets).
    g.clear();
    for (0..600) |_| {
        const x = scene.rand(&seed) * w;
        const y = scene.rand(&seed) * h;
        _ = g.vertex4(x, y, 0.5, 1, .{ scene.rand(&seed), scene.rand(&seed), scene.rand(&seed), scene.rand(&seed) });
        _ = g.vertex4(x + 150, y + 20, 0.5, 1, .{ scene.rand(&seed), scene.rand(&seed), scene.rand(&seed), scene.rand(&seed) });
        _ = g.vertex4(x + 40, y + 140, 0.5, 1, .{ scene.rand(&seed), scene.rand(&seed), scene.rand(&seed), scene.rand(&seed) });
    }
    var attrs: [6]gpu.GlRecord.Attr = undefined;
    attrs[0] = .{ .addr = hw.bus(g.pos.ptr), .bytes = 16, .stride = 16 };
    for (1..6) |k| attrs[k] = .{ .addr = hw.bus(g.col.ptr) + @as(u32, @intCast(k - 1)) * 4, .bytes = 16, .stride = 16, .vs_offset = @intCast(k * 16), .cs_offset = @intCast(k * 16) };
    const rec = (gpu.GlRecord{
        .fs_varyings = 20,
        .fs_code = gpu.upload(programs.manyVaryingsFragmentShader(20).code()),
        .fs_unifs = gpu.words(&.{}),
        .vs_attr_mask = 0x3f,
        .vs_attr_size = 96,
        .vs_code = gpu.upload(programs.clipVertexShader(.{ .varyings = 20 }, false).code()),
        .vs_unifs = g.unifs,
        .cs_attr_mask = 0x01,
        .cs_attr_size = 16,
        .cs_code = g.cs,
        .cs_unifs = g.unifs,
        .attrs = &attrs,
    }).write();
    const Many = struct {
        rec: u32,
        fn draw(ctx: @This(), geo: *Geo, cl: *Cl) void {
            cl.glShaderState(ctx.rec, 6, false);
            cl.arrays(.triangles, geo.n, 0);
        }
    };
    for (0..frames) |_| g.frame(r, "varyings20", Many{ .rec = rec }, Many.draw);
    r.add("timeouts", g.timeouts);
}

/// Ten thousand draws a frame, each changing the configuration bits, clip window and flat
/// shading flags, from a thousand shader records.
pub fn draws(p: Params, r: *Result) void {
    var g: Geo = .init(p);
    const w: f32 = @floatFromInt(g.t.width);
    const h: f32 = @floatFromInt(g.t.height);
    var seed: u32 = 105;
    const n: u32 = @intCast(p.amount(10_000));
    for (0..n) |_| {
        const x = scene.rand(&seed) * w;
        const y = scene.rand(&seed) * h;
        _ = g.vertex(x, y, scene.rand(&seed), features.colour(&seed));
        _ = g.vertex(x + 60, y + 10, scene.rand(&seed), features.colour(&seed));
        _ = g.vertex(x + 20, y + 50, scene.rand(&seed), features.colour(&seed));
    }
    const recs = gpu.alloc(u32, 1000, 16);
    for (recs) |*rec| rec.* = g.record();
    const Draws = struct {
        recs: []const u32,
        n: u32,
        fn draw(ctx: @This(), geo: *Geo, cl: *Cl) void {
            const tw: u32 = geo.t.width;
            const th: u32 = geo.t.height;
            for (0..ctx.n) |i| {
                const k: u32 = @intCast(i);
                cl.config(.{ .forward = true, .reverse = k % 3 != 0, .depth_func = @intCast(k % 8), .z_updates = k % 2 == 0 });
                cl.clipWindow(@intCast(k * 37 % (tw / 2)), @intCast(k * 23 % (th / 2)), @intCast(tw / 2), @intCast(th / 2));
                cl.flatShadeFlags(k & 7);
                cl.glShaderState(ctx.recs[i % ctx.recs.len], 2, false);
                cl.arrays(.triangles, 3, k * 3);
            }
        }
    };
    const frames = p.amount(3);
    for (0..frames) |_| g.frame(r, "frame", Draws{ .recs = recs, .n = n }, Draws.draw);
    r.add("draws", @as(u64, n) * frames);
    r.add("timeouts", g.timeouts);
}
