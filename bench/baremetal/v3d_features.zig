//! V3D feature tests: each draws frames exercising one part of the hardware (the VideoCore IV 3D
//! Architecture Reference Guide's features, whether FauxPi has them or not), and reports a
//! checksum of each frame (named for what it shows), so a difference from the Pi's points at the
//! feature. A frame V3D doesn't finish in time reports `timeouts`.

const std = @import("std");
const qpu = @import("qpu");
const scene = @import("scene");
const hw = @import("hw.zig");
const gpu = @import("gpu.zig");
const main = @import("main.zig");

const programs = scene.programs;
const Cl = gpu.Cl;
const Params = main.Params;
const Result = main.Result;

/// A scene of clip-space vertices (positions and colours in two attribute arrays), drawn with the
/// clip-space shaders into a target.
pub const Geo = struct {
    t: gpu.Target,
    bcl: Cl,
    rcl: Cl,
    /// Vertex shaders passing on 0 to 4 varyings (of the colours' 4 words), with the point
    /// size or not; the coordinate shaders, with it or not.
    vs: [5]u32,
    vs_ps: [5]u32,
    cs: u32,
    cs_ps: u32,
    flat: u32,
    unifs: u32,
    timeouts: u64 = 0,
    /// Binned since the last rendering waited for binning.
    unwaited: bool = false,
    /// The vertices: x, y, z, w and r, g, b, and a fourth (for depth, or discards).
    pos: []f32,
    col: []f32,
    n: u32 = 0,

    pub fn init(p: Params) Geo {
        const w: u32 = @min(p.width, 2048);
        const h: u32 = @min(p.height, 2048);
        const t: gpu.Target = .init(w, h, 4);
        const s = t.scales();
        const max = 1 << 18;
        return .{
            .t = t,
            .bcl = .init(1 << 20),
            .rcl = .init(64 + 2048 * 32),
            .vs = vertexShaders(false),
            .vs_ps = vertexShaders(true),
            .cs = gpu.upload(programs.clipVertexShader(.{ .varyings = 0 }, true).code()),
            .cs_ps = gpu.upload(programs.clipVertexShader(.{ .varyings = 0, .point_size = true }, true).code()),
            .flat = gpu.upload(programs.flatFragmentShader().code()),
            .unifs = gpu.words(&.{ s[0], s[1], gpu.floatBits(0.5), gpu.floatBits(0.5) }),
            .pos = gpu.alloc(f32, max * 4, 16),
            .col = gpu.alloc(f32, max * 4, 16),
        };
    }

    pub fn vertexShaders(point_size: bool) [5]u32 {
        var out: [5]u32 = undefined;
        for (&out, 0..) |*v, k| v.* = gpu.upload(programs.clipVertexShader(.{ .varyings = @intCast(k), .point_size = point_size }, false).code());
        return out;
    }

    pub fn clear(g: *Geo) void {
        g.n = 0;
    }

    /// A vertex at pixel (`px`, `py`), depth `z` (0 near to 1 far), scaled by `w` (clip space is
    /// pixel space times w), coloured; its index.
    pub fn vertexW(g: *Geo, px: f32, py: f32, z: f32, w: f32, rgb: [3]f32) u32 {
        return g.vertex4(px, py, z, w, .{ rgb[0], rgb[1], rgb[2], z });
    }

    /// A vertex with its fourth colour word given.
    pub fn vertex4(g: *Geo, px: f32, py: f32, z: f32, w: f32, c: [4]f32) u32 {
        const hw_ = @as(f32, @floatFromInt(g.t.width)) / 2;
        const hh = @as(f32, @floatFromInt(g.t.height)) / 2;
        const i = g.n;
        g.pos[i * 4 ..][0..4].* = .{ (px - hw_) / hw_ * w, -(py - hh) / hh * w, (z * 2 - 1) * w, w };
        g.col[i * 4 ..][0..4].* = c;
        g.n += 1;
        return i;
    }

    pub fn vertex(g: *Geo, px: f32, py: f32, z: f32, rgb: [3]f32) u32 {
        return g.vertexW(px, py, z, 1, rgb);
    }

    /// A record drawing these vertices with fragment shader `fs` (its uniforms `fs_unifs`).
    pub fn recordWith(g: *const Geo, fs: u32, fs_unifs: u32, varyings: u8, opts: struct { clipping: bool = true, point_size: bool = false }) u32 {
        const attrs = [_]gpu.GlRecord.Attr{
            .{ .addr = hw.bus(g.pos.ptr), .bytes = 16, .stride = 16, .vs_offset = 0, .cs_offset = 0 },
            .{ .addr = hw.bus(g.col.ptr), .bytes = @max(varyings, 1) * 4, .stride = 16, .vs_offset = 16, .cs_offset = 16 },
        };
        return (gpu.GlRecord{
            .clipping = opts.clipping,
            .point_size = opts.point_size,
            .fs_varyings = varyings,
            .fs_code = fs,
            .fs_unifs = fs_unifs,
            .vs_attr_mask = if (varyings > 0) 0b11 else 0b01,
            .vs_attr_size = 16 + varyings * 4,
            .vs_code = if (opts.point_size) g.vs_ps[varyings] else g.vs[varyings],
            .vs_unifs = g.unifs,
            .cs_attr_mask = 0b01,
            .cs_attr_size = 16,
            .cs_code = if (opts.point_size) g.cs_ps else g.cs,
            .cs_unifs = g.unifs,
            .attrs = &attrs,
        }).write();
    }

    pub fn record(g: *const Geo) u32 {
        return g.recordWith(g.flat, gpu.words(&.{}), 3, .{});
    }

    /// Draws a frame: `draws` writes the binning list's state and primitives (after the usual
    /// prefix); then the tiles are rendered with `render` (or the default), and the frame's
    /// checksum is reported as `name`.
    pub fn frame(g: *Geo, r: *Result, name: []const u8, ctx: anytype, comptime draws: anytype) void {
        g.frameWith(r, name, ctx, draws, .{ .config = g.t.renderConfig() });
    }

    pub fn frameWith(g: *Geo, r: *Result, name: []const u8, ctx: anytype, comptime draws: anytype, render: gpu.Target.Render) void {
        g.bin(ctx, draws);
        if (!gpu.run(&g.bcl, null)) g.timeouts += 1;
        g.renderTiles(render);
        r.add(name, g.t.checksum());
    }

    /// Bins `draws` (writing the binning list and running it).
    pub fn bin(g: *Geo, ctx: anytype, comptime draws: anytype) void {
        g.bcl.reset();
        g.t.beginBinning(&g.bcl);
        draws(ctx, g, &g.bcl);
        g.bcl.incrementSemaphore();
        g.bcl.flush();
        g.unwaited = true;
    }

    /// Renders the tiles binned last (or, `render.binned` false, without them): waiting for the
    /// binning the first time only (it increments the semaphore once).
    pub fn renderTiles(g: *Geo, render_in: gpu.Target.Render) void {
        var render = render_in;
        render.wait = render.binned and g.unwaited;
        if (render.wait) g.unwaited = false;
        g.rcl.reset();
        g.t.renderList(&g.rcl, render);
        if (!gpu.run(null, &g.rcl)) g.timeouts += 1;
    }
};

pub fn colour(seed: *u32) [3]f32 {
    return .{ scene.rand(seed), scene.rand(seed), scene.rand(seed) };
}

/// Each primitive mode (points, lines, line loops and strips, triangles, strips and fans), in a
/// band of the frame each, from vertex arrays, 8-bit and 16-bit index lists; then from eight
/// attribute arrays with 32-bit strides (an extended shader record); and points sized by the
/// vertex shader, and lines of several widths.
pub fn primitives(p: Params, r: *Result) void {
    var g: Geo = .init(p);
    const Prims = struct {
        /// The vertices of each mode's band: a zigzag of `n` vertices across it.
        fn build(geo: *Geo) [7][2]u32 {
            geo.clear();
            var seed: u32 = 11;
            var ranges: [7][2]u32 = undefined;
            const band = @as(f32, @floatFromInt(geo.t.height)) / 7;
            const width = @as(f32, @floatFromInt(geo.t.width));
            for (0..7) |m| {
                const first = geo.n;
                const n: u32 = 24;
                const y0 = band * @as(f32, @floatFromInt(m));
                for (0..n) |i| {
                    const fi: f32 = @floatFromInt(i);
                    const x = 8 + fi * (width - 16) / @as(f32, @floatFromInt(n - 1));
                    const y = y0 + if (m == 6 and i == 0) band / 2 else if (i % 2 == 0) band * 0.15 else band * 0.85;
                    _ = geo.vertex(x, y, 0.5, colour(&seed));
                }
                ranges[m] = .{ first, n };
            }
            return ranges;
        }
        fn arrays(ranges: [7][2]u32, geo: *Geo, cl: *Cl) void {
            cl.pointSize(4);
            cl.glShaderState(geo.record(), 2, false);
            for (ranges, 0..) |rg, m| cl.arrays(@fromBackingInt(@intCast(m)), rg[1], rg[0]);
        }
        fn indexed(ctx: anytype, geo: *Geo, cl: *Cl) void {
            cl.pointSize(4);
            cl.glShaderState(geo.record(), 2, false);
            const size: u32 = if (ctx.sixteen) 2 else 1;
            for (ctx.ranges, 0..) |rg, m| cl.indexed(@fromBackingInt(@intCast(m)), ctx.sixteen, rg[1], ctx.idx + rg[0] * size, rg[0] + rg[1] - 1);
        }
    };
    const ranges = Prims.build(&g);
    g.frame(r, "arrays", ranges, Prims.arrays);
    // Index lists: the same vertices, listed (each mode's from where its vertices start).
    const idx8 = gpu.alloc(u8, g.n, 16);
    const idx16 = gpu.alloc(u16, g.n, 16);
    for (0..g.n) |i| {
        idx8[i] = @intCast(i);
        idx16[i] = @intCast(i);
    }
    g.frame(r, "indices8", .{ .ranges = ranges, .idx = hw.bus(idx8.ptr), .sixteen = false }, Prims.indexed);
    g.frame(r, "indices16", .{ .ranges = ranges, .idx = hw.bus(idx16.ptr), .sixteen = true }, Prims.indexed);

    // Eight attribute arrays (x, y, z, w, r, g, b and an unused one), each its own stride (over
    // 255 bytes: the extended record).
    const Eight = struct {
        rec: u32,
        fn draw(ctx: @This(), geo: *Geo, cl: *Cl) void {
            _ = geo;
            cl.glShaderState(ctx.rec, 0, true);
            cl.arrays(.triangles, 21, 0);
        }
    };
    {
        g.clear();
        var seed: u32 = 12;
        for (0..7) |i| {
            const fi: f32 = @floatFromInt(i);
            const x = 40 + fi * @as(f32, @floatFromInt(g.t.width - 80)) / 7;
            _ = g.vertex(x, 40, 0.5, colour(&seed));
            _ = g.vertex(x + 120, 60, 0.5, colour(&seed));
            _ = g.vertex(x + 40, @as(f32, @floatFromInt(g.t.height)) - 40, 0.5, colour(&seed));
        }
        const strides = [8]u32{ 260, 300, 512, 1024, 268, 400, 256, 4 };
        var attrs: [8]gpu.GlRecord.Attr = undefined;
        for (&attrs, strides, 0..) |*a, stride, k| {
            const mem = gpu.alloc(u8, stride * 21 + 4, 16);
            for (0..21) |v| {
                const value: f32 = if (k < 4) g.pos[v * 4 + k] else if (k < 7) g.col[v * 4 + k - 4] else 0;
                std.mem.writeInt(u32, mem[v * stride ..][0..4], @bitCast(value), .little);
            }
            a.* = .{ .addr = hw.bus(mem.ptr), .bytes = 4, .stride = stride, .vs_offset = @intCast(k * 4), .cs_offset = @intCast(k * 4) };
        }
        const rec = (gpu.GlRecord{
            .fs_varyings = 3,
            .fs_code = g.flat,
            .fs_unifs = gpu.words(&.{}),
            .vs_attr_mask = 0x7f,
            .vs_attr_size = 28,
            .vs_code = g.vs[3],
            .vs_unifs = g.unifs,
            .cs_attr_mask = 0x0f,
            .cs_attr_size = 16,
            .cs_code = g.cs,
            .cs_unifs = g.unifs,
            .attrs = &attrs,
            .extended = true,
        }).write();
        g.frame(r, "attributes8", Eight{ .rec = rec }, Eight.draw);
    }

    // Points sized by the vertex shader (the record's flag), 1 to 32 pixels; lines 1 to 8 wide.
    const Sizes = struct {
        fn points(_: void, geo: *Geo, cl: *Cl) void {
            cl.glShaderState(geo.recordWith(geo.flat, gpu.words(&.{}), 3, .{ .point_size = true }), 2, false);
            cl.arrays(.points, geo.n, 0);
        }
        fn lines(ctx: u32, geo: *Geo, cl: *Cl) void {
            cl.glShaderState(geo.record(), 2, false);
            for (0..8) |k| {
                cl.lineWidth(@floatFromInt(k + 1));
                cl.arrays(.lines, ctx, @intCast(k * ctx));
            }
        }
    };
    {
        // Point vertices carry their size after w: built in their own arrays.
        g.clear();
        var seed: u32 = 13;
        const ps_pos = gpu.alloc(f32, 400 * 5, 16);
        for (0..400) |i| {
            const v = g.vertex(scene.rand(&seed) * @as(f32, @floatFromInt(g.t.width)), scene.rand(&seed) * @as(f32, @floatFromInt(g.t.height)), 0.5, colour(&seed));
            ps_pos[i * 5 ..][0..4].* = g.pos[v * 4 ..][0..4].*;
            ps_pos[i * 5 + 4] = 1 + @floor(scene.rand(&seed) * 32);
        }
        // The record reads x, y, z, w, size from the first array.
        const attrs = [_]gpu.GlRecord.Attr{
            .{ .addr = hw.bus(ps_pos.ptr), .bytes = 20, .stride = 20, .vs_offset = 0, .cs_offset = 0 },
            .{ .addr = hw.bus(g.col.ptr), .bytes = 12, .stride = 16, .vs_offset = 20, .cs_offset = 20 },
        };
        const rec = (gpu.GlRecord{
            .point_size = true,
            .fs_varyings = 3,
            .fs_code = g.flat,
            .fs_unifs = gpu.words(&.{}),
            .vs_attr_mask = 0b11,
            .vs_attr_size = 32,
            .vs_code = g.vs_ps[3],
            .vs_unifs = g.unifs,
            .cs_attr_mask = 0b01,
            .cs_attr_size = 20,
            .cs_code = g.cs_ps,
            .cs_unifs = g.unifs,
            .attrs = &attrs,
        }).write();
        const Points = struct {
            rec: u32,
            fn draw(ctx: @This(), geo: *Geo, cl: *Cl) void {
                cl.glShaderState(ctx.rec, 2, false);
                cl.arrays(.points, geo.n, 0);
            }
        };
        g.frame(r, "point_sizes", Points{ .rec = rec }, Points.draw);
        _ = Sizes.points;
    }
    {
        g.clear();
        var seed: u32 = 14;
        const per: u32 = 40;
        for (0..8 * per) |_| _ = g.vertex(scene.rand(&seed) * @as(f32, @floatFromInt(g.t.width)), scene.rand(&seed) * @as(f32, @floatFromInt(g.t.height)), 0.5, colour(&seed));
        g.frame(r, "line_widths", per, Sizes.lines);
    }
    r.add("timeouts", g.timeouts);
}

/// Clipping: triangles crossing the near plane (W from 2 to -1), far past the guard band, and
/// through the Z clipping planes (and the clipper's Z scale and offset); the same with the
/// record's clipping off; and draws under several viewport offsets and clip windows.
pub fn clipping(p: Params, r: *Result) void {
    var g: Geo = .init(p);
    const w: f32 = @floatFromInt(g.t.width);
    const h: f32 = @floatFromInt(g.t.height);
    const Clip = struct {
        fn draw(ctx: anytype, geo: *Geo, cl: *Cl) void {
            if (ctx.zplanes) {
                cl.zClippingPlanes(0.25, 0.75);
                cl.clipperZScaling(0.4, 0.55);
            }
            cl.glShaderState(geo.recordWith(geo.flat, gpu.words(&.{}), 3, .{ .clipping = ctx.clipping }), 2, false);
            cl.arrays(.triangles, geo.n, 0);
        }
    };
    var seed: u32 = 21;
    // Near: each triangle with a corner behind the eye (w < 0) or near it.
    g.clear();
    for (0..32) |i| {
        const fi: f32 = @floatFromInt(i);
        const x = 20 + fi * (w - 40) / 32;
        _ = g.vertexW(x, h * 0.2, 0.5, 2, colour(&seed));
        _ = g.vertexW(x + w / 16, h * 0.3, 0.5, 1, colour(&seed));
        _ = g.vertexW(x + w / 32, h * 0.9, 0.5, -1 + 0.1 * fi, colour(&seed));
    }
    g.frame(r, "near_plane", .{ .clipping = true, .zplanes = false }, Clip.draw);
    g.frame(r, "near_unclipped", .{ .clipping = false, .zplanes = false }, Clip.draw);
    // Guard band: corners thousands of pixels away.
    g.clear();
    for (0..16) |i| {
        const fi: f32 = @floatFromInt(i);
        _ = g.vertex(w / 2 + fi * 10, h / 2, 0.5, colour(&seed));
        _ = g.vertex(-20000 + fi * 3000, -9000, 0.5, colour(&seed));
        _ = g.vertex(30000 - fi * 2500, 15000 + fi * 100, 0.5, colour(&seed));
    }
    g.frame(r, "guard_band", .{ .clipping = true, .zplanes = false }, Clip.draw);
    g.frame(r, "guard_unclipped", .{ .clipping = false, .zplanes = false }, Clip.draw);
    // Z: triangles from near (z -0.5) to far (1.5), cut by the planes.
    g.clear();
    for (0..24) |i| {
        const fi: f32 = @floatFromInt(i);
        const x = 10 + fi * (w - 20) / 24;
        _ = g.vertex(x, 20, -0.5 + fi * 0.08, colour(&seed));
        _ = g.vertex(x + w / 12, h / 2, 0.5, colour(&seed));
        _ = g.vertex(x, h - 20, 1.5 - fi * 0.08, colour(&seed));
    }
    g.frame(r, "z_planes", .{ .clipping = true, .zplanes = true }, Clip.draw);

    // Viewports and clip windows: one triangle set drawn under each.
    const Views = struct {
        fn draw(_: void, geo: *Geo, cl: *Cl) void {
            cl.glShaderState(geo.record(), 2, false);
            const tw: u16 = @intCast(geo.t.width);
            const th: u16 = @intCast(geo.t.height);
            for (0..6) |k| {
                const kk: u16 = @intCast(k);
                cl.viewportOffset(@intCast(@as(u32, tw) * 8 - @as(u32, kk) * 16 * 37), @intCast(@as(u32, th) * 8 - @as(u32, kk) * 16 * 23));
                cl.clipWindow(kk * tw / 12, kk * th / 14, tw / 2, th / 2 + kk * 10);
                cl.arrays(.triangles, geo.n, 0);
            }
        }
    };
    g.clear();
    for (0..12) |_| {
        _ = g.vertex(scene.rand(&seed) * w, scene.rand(&seed) * h, 0.5, colour(&seed));
        _ = g.vertex(scene.rand(&seed) * w, scene.rand(&seed) * h, 0.5, colour(&seed));
        _ = g.vertex(scene.rand(&seed) * w, scene.rand(&seed) * h, 0.5, colour(&seed));
    }
    g.frame(r, "viewports_windows", {}, Views.draw);
    r.add("timeouts", g.timeouts);
}

/// Rasterizer state (Configuration Bits and friends): culling by facing (each combination, and
/// clockwise), every depth test, depth updates on and off, early Z, depth offset, flat shading
/// flags, the oversample modes, and the (unsupported) antialiased points and lines bit.
pub fn rasterizer(p: Params, r: *Result) void {
    var g: Geo = .init(p);
    const w: f32 = @floatFromInt(g.t.width);
    const h: f32 = @floatFromInt(g.t.height);
    var seed: u32 = 31;

    // Facing: a column of triangles each way round, drawn under each culling setting.
    const Cull = struct {
        fn draw(_: void, geo: *Geo, cl: *Cl) void {
            const rec = geo.record();
            const half = geo.n / 2;
            for (0..8) |k| {
                const kk: u3 = @intCast(k);
                cl.config(.{ .forward = kk & 1 != 0, .reverse = kk & 2 != 0, .clockwise = kk & 4 != 0 });
                cl.glShaderState(rec, 2, false);
                cl.clipWindow(@intCast(k * geo.t.width / 8), 0, @intCast(geo.t.width / 8), @intCast(geo.t.height));
                cl.arrays(.triangles, half, 0);
                cl.arrays(.triangles, half, half);
            }
        }
    };
    g.clear();
    for (0..2) |way| {
        for (0..40) |_| {
            const x = scene.rand(&seed) * w;
            const y = scene.rand(&seed) * h;
            const c = colour(&seed);
            _ = g.vertex(x, y, 0.5, c);
            if (way == 0) {
                _ = g.vertex(x + 60, y, 0.5, c);
                _ = g.vertex(x, y + 60, 0.5, c);
            } else {
                _ = g.vertex(x, y + 60, 0.5, c);
                _ = g.vertex(x + 60, y, 0.5, c);
            }
        }
    }
    g.frame(r, "culling", {}, Cull.draw);

    // Depth: overlapping triangles at random depths, under each test (a band each), written or
    // not; with early Z, and its updates.
    const Depth = struct {
        fn draw(ctx: anytype, geo: *Geo, cl: *Cl) void {
            const rec = geo.record();
            cl.glShaderState(rec, 2, false);
            for (0..8) |f| {
                cl.config(.{ .depth_func = @intCast(f), .z_updates = ctx.updates, .early_z = ctx.early, .early_z_updates = ctx.early and ctx.updates });
                cl.clipWindow(0, @intCast(f * geo.t.height / 8), @intCast(geo.t.width), @intCast(geo.t.height / 8));
                cl.arrays(.triangles, geo.n, 0);
            }
        }
    };
    g.clear();
    for (0..90) |_| {
        const x = scene.rand(&seed) * w;
        const y = scene.rand(&seed) * h;
        const z = scene.rand(&seed);
        const c = colour(&seed);
        _ = g.vertex(x, y, z, c);
        _ = g.vertex(x + 200, y + 20, z, c);
        _ = g.vertex(x + 60, y + 160, 1 - z, c);
    }
    g.frame(r, "depth_tests", .{ .updates = true, .early = false }, Depth.draw);
    g.frame(r, "depth_no_updates", .{ .updates = false, .early = false }, Depth.draw);
    g.frame(r, "early_z", .{ .updates = true, .early = true }, Depth.draw);
    {
        var cfg = g.t.renderConfig();
        cfg.early_z_gt = true;
        g.frameWith(r, "early_z_gt", .{ .updates = true, .early = true }, Depth.draw, .{ .config = cfg });
        cfg.early_z_gt = false;
        cfg.early_z_disable = true;
        g.frameWith(r, "early_z_disabled", .{ .updates = true, .early = true }, Depth.draw, .{ .config = cfg });
    }

    // Depth offset: pairs of coplanar triangles, the second offset by factor and units.
    const Offset = struct {
        fn draw(_: void, geo: *Geo, cl: *Cl) void {
            const rec = geo.record();
            const half = geo.n / 2;
            cl.config(.{ .depth_func = 1, .z_updates = true });
            cl.glShaderState(rec, 2, false);
            cl.arrays(.triangles, half, 0);
            cl.depthOffset(-1.5, -4);
            cl.config(.{ .depth_func = 1, .z_updates = true, .depth_offset = true });
            cl.arrays(.triangles, half, half);
        }
    };
    g.clear();
    for (0..2) |pass| {
        var s2: u32 = 32;
        for (0..30) |_| {
            const x = scene.rand(&s2) * w;
            const y = scene.rand(&s2) * h;
            const z0 = scene.rand(&s2);
            const c = if (pass == 0) [3]f32{ 1, 0, 0 } else [3]f32{ 0, 1, 0 };
            _ = g.vertex(x, y, z0, c);
            _ = g.vertex(x + 150, y + 30, z0 * 0.5, c);
            _ = g.vertex(x + 40, y + 140, z0 * 0.8 + 0.1, c);
        }
    }
    g.frame(r, "depth_offset", {}, Offset.draw);

    // Flat shading: triangles with a colour at each corner, each varying flat or not.
    const Flat = struct {
        fn draw(_: void, geo: *Geo, cl: *Cl) void {
            const rec = geo.record();
            cl.glShaderState(rec, 2, false);
            const per = geo.n / 8;
            for (0..8) |k| {
                cl.flatShadeFlags(@intCast(k));
                cl.arrays(.triangles, per, @intCast(k * per));
            }
            cl.flatShadeFlags(0);
        }
    };
    g.clear();
    for (0..8 * 6) |_| {
        _ = g.vertex(scene.rand(&seed) * w, scene.rand(&seed) * h, 0.5, colour(&seed));
        _ = g.vertex(scene.rand(&seed) * w, scene.rand(&seed) * h, 0.5, colour(&seed));
        _ = g.vertex(scene.rand(&seed) * w, scene.rand(&seed) * h, 0.5, colour(&seed));
    }
    g.frame(r, "flat_shading", {}, Flat.draw);

    // Oversampling (none, 4x, 16x), and antialiased points and lines asked for.
    const Over = struct {
        fn draw(_: void, geo: *Geo, cl: *Cl) void {
            const rec = geo.record();
            cl.glShaderState(rec, 2, false);
            const per = geo.n / 3 / 3 * 3;
            for (0..3) |k| {
                cl.config(.{ .oversample = @intCast(k), .antialiased_points_lines = k == 2 });
                cl.arrays(.triangles, per, @intCast(k * per));
                cl.arrays(.lines, per, @intCast(k * per));
            }
        }
    };
    g.frame(r, "oversample", {}, Over.draw);
    r.add("timeouts", g.timeouts);
}

/// Depth and stencil written by fragment shaders: depth from a varying (TLB_Z); the stencil test
/// set up by the shader (front and back functions, ops, masks), a pass writing it and one
/// testing it; discards (MS_FLAGS cleared); and the rasterizer's per-fragment data read back
/// (pixel coordinates, facing, multisample mask).
pub fn depthStencil(p: Params, r: *Result) void {
    var g: Geo = .init(p);
    const w: f32 = @floatFromInt(g.t.width);
    const h: f32 = @floatFromInt(g.t.height);
    var seed: u32 = 41;

    // Overlapping triangles, each corner at its own depth (also the fourth varying).
    g.clear();
    for (0..60) |_| {
        const x = scene.rand(&seed) * w;
        const y = scene.rand(&seed) * h;
        const c = colour(&seed);
        _ = g.vertex(x, y, scene.rand(&seed), c);
        _ = g.vertex(x + 240, y + 30, scene.rand(&seed), c);
        _ = g.vertex(x + 50, y + 200, scene.rand(&seed), c);
    }
    // The fourth varying (the vertices' depth): the fragment's depth, or whether to discard.
    const Zs = struct {
        fs: u32,
        varyings: u8,
        fs_unifs: u32,
        cfg: Cl.Config,
        fn draw(ctx: @This(), geo: *Geo, cl: *Cl) void {
            cl.config(ctx.cfg);
            cl.glShaderState(geo.recordWith(ctx.fs, ctx.fs_unifs, ctx.varyings, .{}), 2, false);
            cl.arrays(.triangles, geo.n, 0);
        }
    };
    const depth_fs = gpu.upload(programs.depthFragmentShader(true).code());
    const rast_z_fs = gpu.upload(programs.depthFragmentShader(false).code());
    g.frame(r, "shader_depth", Zs{ .fs = depth_fs, .varyings = 4, .fs_unifs = gpu.words(&.{}), .cfg = .{ .depth_func = 1, .z_updates = true } }, Zs.draw);
    g.frame(r, "tlb_z", Zs{ .fs = rast_z_fs, .varyings = 3, .fs_unifs = gpu.words(&.{}), .cfg = .{ .depth_func = 1, .z_updates = true } }, Zs.draw);

    // Stencil: the first half writes a stencil (replace with 0x5a where drawn, incrementing
    // elsewhere on depth fail), the second draws only where it equals (front) or not (back).
    const Stencil = struct {
        write: u32,
        test_: u32,
        w_unifs: u32,
        t_unifs: u32,
        fn draw(ctx: @This(), geo: *Geo, cl: *Cl) void {
            const half = geo.n / 2;
            cl.config(.{ .depth_func = 7 });
            cl.glShaderState(geo.recordWith(ctx.write, ctx.w_unifs, 3, .{}), 2, false);
            cl.arrays(.triangles, half, 0);
            cl.glShaderState(geo.recordWith(ctx.test_, ctx.t_unifs, 3, .{}), 2, false);
            cl.arrays(.triangles, half, half);
        }
    };
    const stencil2 = gpu.upload(programs.stencilFragmentShader(2).code());
    const stencil3 = gpu.upload(programs.stencilFragmentShader(3).code());
    // Front and back: write mask 0xff, z-fail incsat, z-pass replace, s-fail keep, always, ref 0x5a.
    const write_setup: u32 = 3 << 30 | 3 << 28 | 3 << 25 | 2 << 22 | 1 << 19 | 7 << 16 | 0x5a << 8 | 0xff;
    const full_masks: u32 = 0 << 30 | 0xff << 8 | 0xff;
    // Front: equal to 0x5a, keep everything; back: not equal, invert on pass.
    const front_test: u32 = 1 << 30 | 3 << 28 | 1 << 25 | 1 << 22 | 1 << 19 | 2 << 16 | 0x5a << 8 | 0xff;
    const back_test: u32 = 2 << 30 | 2 << 28 | 1 << 25 | 5 << 22 | 0 << 19 | 5 << 16 | 0x5a << 8 | 0x0f;
    g.frame(r, "stencil", Stencil{
        .write = stencil2,
        .test_ = stencil3,
        .w_unifs = gpu.words(&.{ write_setup, full_masks }),
        .t_unifs = gpu.words(&.{ front_test, back_test, full_masks }),
    }, Stencil.draw);

    // Discards: the fragments with the fourth varying under a half (the nearer ones) not drawn.
    const discard_fs = gpu.upload(programs.discardFragmentShader().code());
    g.frame(r, "discard", Zs{ .fs = discard_fs, .varyings = 4, .fs_unifs = gpu.words(&.{}), .cfg = .{} }, Zs.draw);

    // The rasterizer's data, front and back facing, multisampled and not.
    const payload_fs = gpu.upload(programs.payloadFragmentShader().code());
    g.frame(r, "payload", Zs{ .fs = payload_fs, .varyings = 0, .fs_unifs = gpu.words(&.{}), .cfg = .{} }, Zs.draw);
    r.add("timeouts", g.timeouts);
}
