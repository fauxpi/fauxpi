//! V3D feature tests of the texture and memory lookup units (the guide's section 4): every
//! texture data type, T-format and LT-format sizes and raster formats, filters with mipmaps, wrap
//! modes (with the border colour), cube maps, LOD bias, child images, Y flips, both TMUs (and the
//! swap disable), two textures together, queued lookups, general memory lookups, the cache
//! swizzle, and non-power-of-two mipmapped textures. Texture memory is pseudo-random bytes: each
//! type decodes them its own way, which is what is compared.

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

/// A texture's config parameters 0 and 1 (tables 15 and 16).
const Tex = struct {
    base: u32,
    type: u5 = 0,
    width: u32 = 128,
    height: u32 = 64,
    mip_levels: u4 = 0,
    mag_nearest: bool = false,
    min: u3 = 0,
    wrap_s: u2 = 0,
    wrap_t: u2 = 0,
    cube: bool = false,
    flip_y: bool = false,
    etc_flip: bool = false,
    swizzle: u2 = 0,

    fn p0(t: Tex) u32 {
        return t.base & 0xfffff000 | @as(u32, t.swizzle) << 10 | @as(u32, @intFromBool(t.cube)) << 9 |
            @as(u32, @intFromBool(t.flip_y)) << 8 | @as(u32, t.type & 15) << 4 | t.mip_levels;
    }
    fn p1(t: Tex) u32 {
        return @as(u32, t.type >> 4) << 31 | (t.height & 2047) << 20 | @as(u32, @intFromBool(t.etc_flip)) << 19 |
            (t.width & 2047) << 8 | @as(u32, @intFromBool(t.mag_nearest)) << 7 | @as(u32, t.min) << 4 |
            @as(u32, t.wrap_t) << 2 | t.wrap_s;
    }
};

/// A quad from (x0, y0) to (x1, y1) in pixels, each corner's four varyings given (top left, top
/// right, bottom left, bottom right); its first vertex.
fn quad(g: *Geo, x0: f32, y0: f32, x1: f32, y1: f32, c: [4][4]f32) u32 {
    const first = g.n;
    const corners = [6]usize{ 0, 1, 2, 1, 3, 2 };
    const at = [4][2]f32{ .{ x0, y0 }, .{ x1, y0 }, .{ x0, y1 }, .{ x1, y1 } };
    for (corners) |k| _ = g.vertex4(at[k][0], at[k][1], 0.5, 1, c[k]);
    return first;
}

/// Varyings for a quad: s from `s0` to `s1` across, t from `t0` to `t1` down, and r and the bias
/// as given.
fn st(s0: f32, s1: f32, t0: f32, t1: f32, r: f32, b: f32) [4][4]f32 {
    return .{ .{ s0, t0, r, b }, .{ s1, t0, r, b }, .{ s0, t1, r, b }, .{ s1, t1, r, b } };
}

/// One draw per band: its quad, shader and uniforms.
const Band = struct {
    first: u32,
    fs: u32,
    unifs: u32,
    varyings: u8,
};

const Bands = struct {
    list: [32]Band = undefined,
    n: usize = 0,

    fn draw(b: *const Bands, g: *Geo, cl: *Cl) void {
        for (b.list[0..b.n]) |band| {
            cl.glShaderState(g.recordWith(band.fs, band.unifs, band.varyings, .{}), 2, false);
            cl.arrays(.triangles, 6, band.first);
        }
    }
};

/// The checksum of rows `y0` to `y1` of the frame.
fn rows(g: *const Geo, y0: u32, y1: u32) u64 {
    return gpu.checksum(g.t.fb[y0 * g.t.width * 4 .. y1 * g.t.width * 4]);
}

pub fn tmu(p: Params, r: *Result) void {
    var g: Geo = .init(p);
    const w: f32 = @floatFromInt(g.t.width);
    const h: f32 = @floatFromInt(g.t.height);
    // Texture memory: 4 MiB of pseudo-random bytes, textures based in its middle (mipmaps and cube
    // faces either side).
    const mem = gpu.alloc(u8, 4 << 20, 4096);
    var seed: u32 = 91;
    for (std.mem.bytesAsSlice(u32, mem)) |*word| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        word.* = seed;
    }
    const base = hw.bus(mem.ptr) + (2 << 20);
    const plain = gpu.upload(programs.textureFragmentShader(.{}).code());

    // Every data type, a band each (RGBA64 read as two words).
    {
        g.clear();
        var bands: Bands = .{};
        const band_h = h / 18;
        const rgba64 = gpu.upload(programs.textureFragmentShader(.{ .two_reads = true }).code());
        for (0..18) |ty| {
            const y0 = band_h * @as(f32, @floatFromInt(ty));
            const tex: Tex = .{ .base = base, .type = @intCast(ty), .width = 128, .height = 64 };
            bands.list[bands.n] = .{
                .first = quad(&g, 0, y0, w, y0 + band_h, st(0, 3, 0, 1, 0, 0)),
                .fs = if (ty == 15) rgba64 else plain,
                .unifs = gpu.words(&.{ tex.p0(), tex.p1() }),
                .varyings = 2,
            };
            bands.n += 1;
        }
        g.bin(&bands, Bands.draw);
        _ = gpu.run(&g.bcl, null);
        g.renderTiles(.{ .config = g.t.renderConfig() });
        const names = [18][]const u8{ "rgba8888", "rgbx8888", "rgba4444", "rgba5551", "rgb565", "luminance", "alpha", "lumalpha", "etc1", "s16f", "s8", "s16", "bw1", "a4", "a1", "rgba64", "rgba32r", "yuyv422r" };
        for (names, 0..) |name, ty| {
            const y0: u32 = @intFromFloat(band_h * @as(f32, @floatFromInt(ty)));
            const y1: u32 = @intFromFloat(band_h * @as(f32, @floatFromInt(ty + 1)));
            r.add(name, rows(&g, y0, y1));
        }
    }

    // The rest: a frame each, of bands.
    const Frame = struct {
        fn run(geo: *Geo, res: *Result, name: []const u8, bands: *const Bands) void {
            geo.frame(res, name, bands, Bands.draw);
        }
    };
    var bands: Bands = .{};

    // LT-format sizes (less than a T-format tile across or down), of several types.
    g.clear();
    bands.n = 0;
    for ([_][3]u32{ .{ 0, 16, 16 }, .{ 0, 8, 64 }, .{ 4, 32, 8 }, .{ 5, 16, 16 }, .{ 8, 16, 16 }, .{ 6, 64, 4 }, .{ 2, 4, 4 }, .{ 15, 8, 8 } }, 0..) |c, i| {
        const y0 = h / 8 * @as(f32, @floatFromInt(i));
        const tex: Tex = .{ .base = base, .type = @intCast(c[0]), .width = c[1], .height = c[2] };
        bands.list[i] = .{ .first = quad(&g, 0, y0, w, y0 + h / 8, st(0, 4, 0, 2, 0, 0)), .fs = plain, .unifs = gpu.words(&.{ tex.p0(), tex.p1() }), .varyings = 2 };
        bands.n += 1;
    }
    Frame.run(&g, r, "lt_sizes", &bands);

    // Filters: magnified (nearest, bilinear), and minified with each filter, of a mipmapped 256
    // square (8 levels below, before it in memory).
    g.clear();
    bands.n = 0;
    for (0..8) |i| {
        const y0 = h / 8 * @as(f32, @floatFromInt(i));
        const magnified = i < 2;
        const tex: Tex = .{ .base = base, .width = 256, .height = 256, .mip_levels = 8, .mag_nearest = i == 1, .min = if (magnified) 0 else @intCast(i - 2) };
        const range: f32 = if (magnified) 0.1 else 6;
        bands.list[i] = .{ .first = quad(&g, 0, y0, w, y0 + h / 8, st(0, range, 0, range * h / 8 / w, 0, 0)), .fs = plain, .unifs = gpu.words(&.{ tex.p0(), tex.p1() }), .varyings = 2 };
        bands.n += 1;
    }
    Frame.run(&g, r, "filters", &bands);

    // Wrap modes: repeat, clamp, mirror, and border (its colour the r coordinate's word).
    g.clear();
    bands.n = 0;
    {
        const border = gpu.upload(programs.textureFragmentShader(.{ .coords = 3 }).code());
        for (0..4) |m| {
            const y0 = h / 4 * @as(f32, @floatFromInt(m));
            const tex: Tex = .{ .base = base, .wrap_s = @intCast(m), .wrap_t = @intCast(3 - m) };
            const border_colour: f32 = @bitCast(@as(u32, 0xff20a0e0));
            bands.list[m] = .{
                .first = quad(&g, 0, y0, w, y0 + h / 4, st(-1.5, 2.5, -1, 2, border_colour, 0)),
                .fs = border,
                .unifs = gpu.words(&.{ tex.p0(), tex.p1(), 0 }),
                .varyings = 3,
            };
            bands.n += 1;
        }
    }
    Frame.run(&g, r, "wraps", &bands);

    // Cube maps: directions (s, t, r scaled so the largest is 1) through each face; faces 64 KiB
    // apart (the cube map stride).
    g.clear();
    bands.n = 0;
    {
        const cube = gpu.upload(programs.textureFragmentShader(.{ .coords = 3 }).code());
        const faces = [6][3]f32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };
        for (faces, 0..) |d, i| {
            const y0 = h / 6 * @as(f32, @floatFromInt(i));
            const tex: Tex = .{ .base = base, .width = 64, .height = 64, .cube = true };
            const stride: u32 = 1 << 30 | (64 << 10 >> 12) << 12;
            // Corners off the major axis by -0.9 to 0.9.
            var c: [4][4]f32 = undefined;
            for (&c, [4][2]f32{ .{ -0.9, -0.9 }, .{ 0.9, -0.9 }, .{ -0.9, 0.9 }, .{ 0.9, 0.9 } }) |*corner, o| {
                var v = d;
                const major: usize = if (d[0] != 0) 0 else if (d[1] != 0) 1 else 2;
                v[(major + 1) % 3] = o[0];
                v[(major + 2) % 3] = o[1];
                corner.* = .{ v[0], v[1], v[2], 0 };
            }
            bands.list[i] = .{ .first = quad(&g, 0, y0, w, y0 + h / 6, c), .fs = cube, .unifs = gpu.words(&.{ tex.p0(), tex.p1(), stride }), .varyings = 3 };
            bands.n += 1;
        }
    }
    Frame.run(&g, r, "cube_map", &bands);

    // LOD bias: -2 to +3 across the band, with automatic LOD, and with the bias alone (BSLOD).
    g.clear();
    bands.n = 0;
    {
        const biased = gpu.upload(programs.textureFragmentShader(.{ .bias = true }).code());
        for (0..2) |i| {
            const y0 = h / 2 * @as(f32, @floatFromInt(i));
            const tex: Tex = .{ .base = base, .width = 256, .height = 256, .mip_levels = 8, .min = 5 };
            var c = st(0, 3, 0, 3, 0, -2);
            c[1][3] = 3;
            c[3][3] = 3;
            bands.list[i] = .{ .first = quad(&g, 0, y0, w, y0 + h / 2, c), .fs = biased, .unifs = gpu.words(&.{ tex.p0(), tex.p1(), if (i == 1) 1 << 30 | 1 else 0 }), .varyings = 4 };
            bands.n += 1;
        }
    }
    Frame.run(&g, r, "lod_bias", &bands);

    // Child images: a window (its size, then its offset) of a 256 square.
    g.clear();
    bands.n = 0;
    {
        const child = gpu.upload(programs.textureFragmentShader(.{ .child = true }).code());
        for ([_][4]u32{ .{ 64, 32, 10, 20 }, .{ 100, 100, 128, 64 }, .{ 17, 200, 3, 50 } }, 0..) |c, i| {
            const y0 = h / 3 * @as(f32, @floatFromInt(i));
            const tex: Tex = .{ .base = base, .width = 256, .height = 256 };
            bands.list[i] = .{
                .first = quad(&g, 0, y0, w, y0 + h / 3, st(-0.5, 1.5, -0.5, 1.5, 0, 0)),
                .fs = child,
                .unifs = gpu.words(&.{ tex.p0(), tex.p1(), 2 << 30 | c[1] << 12 | c[0], 3 << 30 | c[3] << 12 | c[2] }),
                .varyings = 2,
            };
            bands.n += 1;
        }
    }
    Frame.run(&g, r, "child_image", &bands);

    // Y flips: of an RGBA8888 texture, and of ETC1 blocks.
    g.clear();
    bands.n = 0;
    for ([_]Tex{ .{ .base = base, .flip_y = true }, .{ .base = base, .type = 8, .etc_flip = true }, .{ .base = base, .type = 8, .flip_y = true, .etc_flip = true } }, 0..) |tex, i| {
        const y0 = h / 3 * @as(f32, @floatFromInt(i));
        bands.list[i] = .{ .first = quad(&g, 0, y0, w, y0 + h / 3, st(0, 2, 0, 1, 0, 0)), .fs = plain, .unifs = gpu.words(&.{ tex.p0(), tex.p1() }), .varyings = 2 };
        bands.n += 1;
    }
    Frame.run(&g, r, "flips", &bands);

    // TMU 1, with and without the swap disabled; two textures on both units, multiplied; four
    // lookups queued; the cache swizzle; a non-power-of-two mipmapped texture.
    g.clear();
    bands.n = 0;
    {
        const progs = [_]programs.TextureSample{ .{ .unit = 1 }, .{ .unit = 1, .noswap = true }, .{ .noswap = true }, .{ .modulate = true }, .{ .queued = true } };
        for (progs, 0..) |ps, i| {
            const y0 = h / 8 * @as(f32, @floatFromInt(i));
            const t1: Tex = .{ .base = base };
            const t2: Tex = .{ .base = base + 0x40000, .type = 4, .width = 64, .height = 32 };
            const unifs = if (ps.modulate)
                gpu.words(&.{ t1.p0(), t1.p1(), t2.p0(), t2.p1() })
            else if (ps.queued)
                gpu.words(&.{ t1.p0(), t1.p1(), t2.p0(), t2.p1(), t1.p0(), t2.p1(), t2.p0(), t1.p1() })
            else
                gpu.words(&.{ t1.p0(), t1.p1() });
            bands.list[i] = .{ .first = quad(&g, 0, y0, w, y0 + h / 8, st(0, 2, 0, 1, 0, 0)), .fs = gpu.upload(programs.textureFragmentShader(ps).code()), .unifs = unifs, .varyings = 2 };
            bands.n += 1;
        }
        for (0..2) |k| {
            const i = 5 + k;
            const y0 = h / 8 * @as(f32, @floatFromInt(i));
            const tex: Tex = .{ .base = base, .swizzle = @intCast(k * 2 + 1) };
            bands.list[i] = .{ .first = quad(&g, 0, y0, w, y0 + h / 8, st(0, 2, 0, 1, 0, 0)), .fs = plain, .unifs = gpu.words(&.{ tex.p0(), tex.p1() }), .varyings = 2 };
            bands.n += 1;
        }
        const npot: Tex = .{ .base = base, .width = 100, .height = 60, .mip_levels = 6, .min = 5 };
        bands.list[7] = .{ .first = quad(&g, 0, h / 8 * 7, w, h, st(0, 9, 0, 3, 0, 0)), .fs = plain, .unifs = gpu.words(&.{ npot.p0(), npot.p1() }), .varyings = 2 };
        bands.n += 1;
    }
    g.frame(r, "units_queue_swizzle", &bands, Bands.draw);
    r.add("tmu1", rows(&g, 0, @intFromFloat(h / 8)));
    r.add("tmu1_noswap", rows(&g, @intFromFloat(h / 8), @intFromFloat(h / 4)));
    r.add("two_textures", rows(&g, @intFromFloat(h / 8 * 3), @intFromFloat(h / 2)));
    r.add("queued_lookups", rows(&g, @intFromFloat(h / 2), @intFromFloat(h / 8 * 5)));
    r.add("npot_mips", rows(&g, @intFromFloat(h / 8 * 7), g.t.height));

    // General memory lookups: words at addresses, no texture config.
    g.clear();
    bands.n = 0;
    bands.list[0] = .{ .first = quad(&g, 0, 0, w, h, st(0, 1, 0, 1, 0, 0)), .fs = gpu.upload(programs.directLookupFragmentShader().code()), .unifs = gpu.words(&.{base}), .varyings = 0 };
    bands.n = 1;
    Frame.run(&g, r, "direct_lookups", &bands);
    r.add("timeouts", g.timeouts);
}
