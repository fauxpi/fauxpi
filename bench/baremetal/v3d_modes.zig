//! V3D feature tests of its modes besides GL (vertex shaded): NV mode (pre-shaded vertices in
//! memory), VG mode (screen coordinates in the primitive list), and rendering from tile lists
//! written by hand rather than the binner (compressed primitive lists, clipped primitives).

const std = @import("std");
const scene = @import("scene");
const hw = @import("hw.zig");
const gpu = @import("gpu.zig");
const main = @import("main.zig");

const programs = scene.programs;
const Cl = gpu.Cl;
const Params = main.Params;
const Result = main.Result;

const Frame = struct {
    t: gpu.Target,
    bcl: Cl,
    rcl: Cl,
    timeouts: u64 = 0,

    fn init(p: Params) Frame {
        return .{
            .t = .init(@min(p.width, 2048), @min(p.height, 2048), 4),
            .bcl = .init(1 << 20),
            .rcl = .init(64 + 2048 * 48),
        };
    }

    fn w(f: *const Frame) f32 {
        return @floatFromInt(f.t.width);
    }
    fn h(f: *const Frame) f32 {
        return @floatFromInt(f.t.height);
    }

    /// Bins `draws`' primitives and renders them, reporting the frame as `name`.
    fn binned(f: *Frame, r: *Result, name: []const u8, ctx: anytype, comptime draws: anytype) void {
        f.bcl.reset();
        f.t.beginBinning(&f.bcl);
        draws(ctx, f, &f.bcl);
        f.bcl.incrementSemaphore();
        f.bcl.flush();
        f.rcl.reset();
        f.t.renderList(&f.rcl, .{ .config = f.t.renderConfig() });
        if (!gpu.run(&f.bcl, &f.rcl)) f.timeouts += 1;
        r.add(name, f.t.checksum());
    }

    /// Renders every tile from the tile list at `list` (no binning), reporting it as `name`.
    fn fromTileList(f: *Frame, r: *Result, name: []const u8, list: u32) void {
        const S = struct {
            var addr: u32 = 0;
            fn lists(_: *const gpu.Target, _: u32, _: u32) u32 {
                return addr;
            }
        };
        S.addr = list;
        f.rcl.reset();
        f.t.renderList(&f.rcl, .{ .config = f.t.renderConfig(), .binned = false, .tile_lists = S.lists });
        if (!gpu.run(null, &f.rcl)) f.timeouts += 1;
        r.add(name, f.t.checksum());
    }
};

/// Pre-shaded vertices (NV mode's): Xs|Ys, Zs, 1/Wc (and, as asked, the clip coordinates first
/// and the point size), then red, green and blue.
const NvVertices = struct {
    mem: []u8,
    stride: u32,
    clip_header: bool,
    point_size: bool,
    n: u32 = 0,

    fn init(count: u32, clip_header: bool, point_size: bool) NvVertices {
        const words: u32 = 3 + 3 + @as(u32, if (clip_header) 4 else 0) + @intFromBool(point_size);
        // With the clip header each vertex is 16-byte aligned.
        const stride = if (clip_header) std.mem.alignForward(u32, words * 4, 16) else words * 4;
        return .{ .mem = gpu.alloc(u8, count * stride, 16), .stride = stride, .clip_header = clip_header, .point_size = point_size };
    }

    /// A vertex at pixel (`px`, `py`) of a `width` by `height` frame.
    fn add(v: *NvVertices, width: f32, height: f32, px: f32, py: f32, z: f32, size: f32, rgb: [3]f32) u32 {
        const out = v.mem[v.n * v.stride ..][0..v.stride];
        var k: usize = 0;
        const put = struct {
            fn f(o: []u8, i: *usize, word: u32) void {
                std.mem.writeInt(u32, o[i.* * 4 ..][0..4], word, .little);
                i.* += 1;
            }
        }.f;
        if (v.clip_header) {
            put(out, &k, gpu.floatBits((px - width / 2) / (width / 2)));
            put(out, &k, gpu.floatBits(-(py - height / 2) / (height / 2)));
            put(out, &k, gpu.floatBits(z * 2 - 1));
            put(out, &k, gpu.floatBits(1));
        }
        put(out, &k, gpu.packXy(px - width / 2, py - height / 2));
        put(out, &k, gpu.floatBits(z));
        put(out, &k, gpu.floatBits(1));
        if (v.point_size) put(out, &k, gpu.floatBits(size));
        for (rgb) |c| put(out, &k, gpu.floatBits(c));
        v.n += 1;
        return v.n - 1;
    }

    fn record(v: *const NvVertices, fs: u32, clipping: bool) u32 {
        return (gpu.NvRecord{
            .point_size = v.point_size,
            .clipping = clipping,
            .clip_header = v.clip_header,
            .stride = @intCast(v.stride),
            .fs_varyings = 3,
            .fs_code = fs,
            .fs_unifs = gpu.words(&.{}),
            .vertices = hw.bus(v.mem.ptr),
        }).write();
    }
};

fn colour(seed: *u32) [3]f32 {
    return .{ scene.rand(seed), scene.rand(seed), scene.rand(seed) };
}

/// NV mode (vertices shaded already, in memory): triangles from arrays and index lists, points
/// sized per vertex, and vertices with clip coordinates, clipped. VG mode: coordinate arrays of
/// each primitive type (RHTs and RHT strips, triangles, strips and fans), inline primitives
/// (with padding, and a fan continued in a second list), inline shader records, and the RHT X
/// boundary.
pub fn nvVg(p: Params, r: *Result) void {
    var f: Frame = .init(p);
    const flat = gpu.upload(programs.flatFragmentShader().code());
    var seed: u32 = 51;

    // NV triangles.
    var tri = NvVertices.init(300, false, false);
    for (0..300) |_| _ = tri.add(f.w(), f.h(), scene.rand(&seed) * f.w(), scene.rand(&seed) * f.h(), 0.5, 1, colour(&seed));
    const idx = gpu.alloc(u16, 300, 16);
    for (idx, 0..) |*ix, i| ix.* = @intCast((i * 7) % 300);
    const NvDraw = struct {
        rec: u32,
        idx: u32,
        fn draw(ctx: @This(), _: *Frame, cl: *Cl) void {
            cl.nvShaderState(ctx.rec);
            cl.arrays(.triangles, 150, 0);
            cl.indexed(.triangles, true, 150, ctx.idx, 299);
        }
    };
    f.binned(r, "nv_triangles", NvDraw{ .rec = tri.record(flat, false), .idx = hw.bus(idx.ptr) }, NvDraw.draw);

    // NV points, sized per vertex.
    var pts = NvVertices.init(400, false, true);
    for (0..400) |_| _ = pts.add(f.w(), f.h(), scene.rand(&seed) * f.w(), scene.rand(&seed) * f.h(), 0.5, 1 + @floor(scene.rand(&seed) * 24), colour(&seed));
    const NvPoints = struct {
        rec: u32,
        fn draw(ctx: @This(), _: *Frame, cl: *Cl) void {
            cl.nvShaderState(ctx.rec);
            cl.arrays(.points, 400, 0);
        }
    };
    f.binned(r, "nv_points", NvPoints{ .rec = pts.record(flat, false) }, NvPoints.draw);

    // NV vertices with clip coordinates, some far off screen, clipped.
    var clip = NvVertices.init(96, true, false);
    for (0..32) |_| {
        _ = clip.add(f.w(), f.h(), scene.rand(&seed) * f.w(), scene.rand(&seed) * f.h(), 0.5, 1, colour(&seed));
        _ = clip.add(f.w(), f.h(), -3000 + scene.rand(&seed) * 9000, scene.rand(&seed) * f.h(), 0.5, 1, colour(&seed));
        _ = clip.add(f.w(), f.h(), scene.rand(&seed) * f.w(), -2000 + scene.rand(&seed) * 6000, 0.5, 1, colour(&seed));
    }
    const NvClip = struct {
        rec: u32,
        fn draw(ctx: @This(), _: *Frame, cl: *Cl) void {
            cl.nvShaderState(ctx.rec);
            cl.arrays(.triangles, 96, 0);
        }
    };
    f.binned(r, "nv_clip_header", NvClip{ .rec = clip.record(flat, true) }, NvClip.draw);

    // VG: a record per colour.
    const fs = gpu.upload(programs.uniformColourFragmentShader().code());
    const coords = gpu.alloc(u32, 4096, 16);
    var n_coords: u32 = 0;
    const At = struct {
        fn xy(fr: *const Frame, px: f32, py: f32) u32 {
            return gpu.packXy(px - fr.w() / 2, py - fr.h() / 2);
        }
    };
    // Each type's coordinates, a band each: RHTs (2 a primitive), RHT strip, triangles, strip, fan.
    var starts: [5]u32 = undefined;
    var counts: [5]u32 = undefined;
    const band = f.h() / 5;
    for (0..5) |t| {
        starts[t] = n_coords;
        const y0 = band * @as(f32, @floatFromInt(t));
        const prims: u32 = 12;
        const per: u32 = switch (t) {
            0 => prims * 2,
            1 => prims + 1,
            2 => prims * 3,
            else => prims + 2,
        };
        for (0..per) |i| {
            const fi: f32 = @floatFromInt(i);
            const x = if (t == 4 and i == 0) f.w() / 2 else 8 + fi * (f.w() - 16) / @as(f32, @floatFromInt(per));
            const y = if (t == 4 and i == 0) y0 + band / 2 else y0 + if (i % 2 == 0) band * 0.1 else band * 0.9;
            coords[n_coords] = At.xy(&f, x, y);
            n_coords += 1;
        }
        counts[t] = prims;
    }
    const types = [5]Cl.VgType{ .rhts, .rht_strip, .triangles, .triangle_strip, .triangle_fan };
    var recs: [8]u32 = undefined;
    for (&recs, 0..) |*rec, k| rec.* = gpu.vgRecord(fs, gpu.words(&.{0xff000000 | @as(u32, @intCast(k * 0x1f3a77 & 0xffffff))}), 0, true);
    const VgArrays = struct {
        recs: [8]u32,
        coords: u32,
        starts: [5]u32,
        counts: [5]u32,
        types: [5]Cl.VgType,
        fn draw(ctx: @This(), fr: *Frame, cl: *Cl) void {
            cl.rhtXBoundary(@intCast(fr.t.width / 3));
            for (0..5) |t| {
                cl.vgShaderState(ctx.recs[t]);
                cl.vgCoordinateArray(ctx.types[t], false, ctx.counts[t], ctx.coords + ctx.starts[t] * 4);
            }
        }
    };
    f.binned(r, "vg_arrays", VgArrays{ .recs = recs, .coords = hw.bus(coords.ptr), .starts = starts, .counts = counts, .types = types }, VgArrays.draw);

    // VG inline: triangles (one padded), a fan in two lists, with an inline shader record.
    const VgInline = struct {
        rec: u32,
        fs: u32,
        unifs: u32,
        frame_w: f32,
        frame_h: f32,
        fn draw(ctx: @This(), fr: *Frame, cl: *Cl) void {
            cl.vgShaderState(ctx.rec);
            const tw = ctx.frame_w;
            const th = ctx.frame_h;
            var list: [16]u32 = undefined;
            var n: usize = 0;
            for (0..4) |i| {
                const fi: f32 = @floatFromInt(i);
                list[n] = At.xy(fr, 20 + fi * tw / 5, 20);
                list[n + 1] = At.xy(fr, 20 + fi * tw / 5 + tw / 6, 40);
                // The third triangle is padding.
                list[n + 2] = if (i == 2) Cl.vg_pad else At.xy(fr, 20 + fi * tw / 5 + tw / 12, th / 3);
                n += 3;
            }
            list[n] = At.xy(fr, 0, 0);
            list[n + 1] = At.xy(fr, 0, 0);
            list[n + 2] = Cl.vg_escape;
            n += 3;
            cl.vgInline(.triangles, false, list[0..n]);
            // A fan, ended after two triangles and continued.
            cl.vgInlineShaderRecord(ctx.fs, ctx.unifs, true);
            const cx = tw / 2;
            const cy = th * 0.7;
            const fan1 = [_]u32{ At.xy(fr, cx, cy), At.xy(fr, cx - 200, cy - 100), At.xy(fr, cx, cy - 220), At.xy(fr, cx + 200, cy - 100), At.xy(fr, 0, 0), Cl.vg_escape };
            cl.vgInline(.triangle_fan, false, &fan1);
            const fan2 = [_]u32{ 0, 0, At.xy(fr, cx + 220, cy + 80), At.xy(fr, cx, cy + 200), At.xy(fr, 0, 0), Cl.vg_escape };
            cl.vgInline(.triangle_fan, true, &fan2);
        }
    };
    f.binned(r, "vg_inline", VgInline{
        .rec = recs[5],
        .fs = fs,
        .unifs = gpu.words(&.{0xff40c0a0}),
        .frame_w = f.w(),
        .frame_h = f.h(),
    }, VgInline.draw);
    r.add("timeouts", f.timeouts);
}

/// Compressed primitive list codes (the guide's tables 39-43), written as a tile list has them.
const Coded = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,

    fn byte(c: *Coded, v: u8) void {
        c.buf[c.len] = v;
        c.len += 1;
    }
    fn half(c: *Coded, v: u16) void {
        c.byte(@truncate(v));
        c.byte(@truncate(v >> 8));
    }
    fn word(c: *Coded, v: u32) void {
        c.half(@truncate(v));
        c.half(@truncate(v >> 16));
    }
    fn bytes(c: *const Coded) []const u8 {
        return c.buf[0..c.len];
    }
    /// A triangle of three absolute 16-bit indices (coding 3).
    fn triAbs(c: *Coded, a: u16, b: u16, d: u16) void {
        c.byte(129);
        c.half(a);
        c.half(b);
        c.half(d);
    }
    /// A triangle sharing two of the last one's indices (`share`: 0 its (2,1), 1 its (0,2), 2 its
    /// (1,0)), its third index `d` on from the last one's third (coding 0).
    fn triRel1(c: *Coded, share: u2, d: i6) void {
        c.byte(@as(u8, share) | @as(u8, @as(u6, @bitCast(d))) << 2);
    }
    /// A triangle of three indices each on from the last one's (coding 1).
    fn triRel3(c: *Coded, d0: i4, d1: i4, d2: i4) void {
        c.half(3 | @as(u16, @as(u4, @bitCast(d0))) << 4 | @as(u16, @as(u4, @bitCast(d1))) << 8 | @as(u16, @as(u4, @bitCast(d2))) << 12);
    }
    /// A triangle of one absolute index and two relative to it (coding 2).
    fn triAbsRel(c: *Coded, first: u16, d1: i6, d2: i6) void {
        c.half(15 | @as(u16, @as(u6, @bitCast(d1))) << 4 | @as(u16, @as(u6, @bitCast(d2))) << 10);
        c.half(first);
    }
    fn escape(c: *Coded) void {
        c.byte(128);
    }
};

/// Rendering without binning, from tile lists written by hand: compressed lists of triangles
/// (each coding), lines and points (of NV vertices), a list chained across memory blocks by a
/// relative branch, coordinate (XY) lists in VG mode, a clipped primitive record, and branches
/// and nested sub-lists in the tile lists.
pub fn tileLists(p: Params, r: *Result) void {
    var f: Frame = .init(p);
    const flat = gpu.upload(programs.flatFragmentShader().code());
    var seed: u32 = 61;
    var v = NvVertices.init(256, false, false);
    for (0..256) |_| _ = v.add(f.w(), f.h(), scene.rand(&seed) * f.w(), scene.rand(&seed) * f.h(), 0.5, 1, colour(&seed));
    const nv = v.record(flat, false);

    // Triangles: one of each coding, then a run of relative ones.
    {
        var c: Coded = .{};
        c.triAbs(0, 1, 2);
        c.triRel1(0, 3);
        c.triRel1(1, -1);
        c.triRel1(2, 5);
        c.triRel3(4, 5, 6);
        c.triRel3(-3, 2, 7);
        c.triAbsRel(40, 3, -5);
        c.triAbsRel(200, 10, 20);
        for (0..60) |i| c.triRel1(@intCast(i % 3), @intCast(@as(i32, @intCast(i % 9)) - 4));
        c.triAbs(250, 251, 252);
        c.escape();
        var list: Cl = .init(c.len + 64);
        list.primitiveListFormat(.triangles, false);
        list.nvShaderState(nv);
        list.compressed(c.bytes());
        list.returnFromSubList();
        f.fromTileList(r, "compressed_triangles", list.start());
    }
    // Lines (codings 0-3) and points (codings 0, 1 and 3).
    {
        var c: Coded = .{};
        c.byte(129);
        c.half(3);
        c.half(9);
        for (0..30) |i| c.byte(@as(u8, @intCast(i & 1)) | @as(u8, @as(u6, @bitCast(@as(i6, @intCast(@as(i32, @intCast(i % 7)) - 3))))) << 2);
        c.half(3 | @as(u16, @as(u4, @bitCast(@as(i4, 2)))) << 4 | @as(u16, @as(u4, @bitCast(@as(i4, -3)))) << 8);
        c.byte(2 | @as(u8, @as(u6, @bitCast(@as(i6, 7)))) << 2);
        c.half(100);
        c.escape();
        var pts: Coded = .{};
        pts.byte(129);
        pts.half(0);
        for (0..60) |i| pts.byte(@as(u8, @intCast(i & 1)) | @as(u8, @as(u6, @bitCast(@as(i6, 3)))) << 2);
        pts.half(3 | @as(u16, @as(u14, @bitCast(@as(i14, 37)))) << 2);
        pts.escape();
        var list: Cl = .init(c.len + pts.len + 64);
        list.lineWidth(2);
        list.pointSize(5);
        list.primitiveListFormat(.lines, false);
        list.nvShaderState(nv);
        list.compressed(c.bytes());
        list.primitiveListFormat(.points, false);
        list.nvShaderState(nv);
        list.compressed(pts.bytes());
        list.returnFromSubList();
        f.fromTileList(r, "compressed_lines_points", list.start());
    }
    // A list in two blocks, joined by a relative branch (in 32-byte units, from the 32-byte block
    // the code is in, as the binner chains its blocks), and a tile list branching to another
    // (Branch) and into nested sub-lists.
    {
        var block: Cl = .init(256);
        block.primitiveListFormat(.triangles, false);
        block.nvShaderState(nv);
        var c: Coded = .{};
        c.triAbs(10, 11, 12);
        c.triRel1(0, 1);
        const code_at = block.end() + 1 + @as(u32, @intCast(c.len));
        const next = std.mem.alignForward(u32, code_at + 3, 32) + 64;
        c.byte(130);
        c.half(@truncate((next -% (code_at & ~@as(u32, 31))) >> 5));
        block.compressed(c.bytes());
        // The rest of the list, in the next block.
        const off = next - block.start();
        var rest: Coded = .{};
        rest.triRel1(1, 2);
        rest.triAbs(20, 21, 22);
        rest.escape();
        @memcpy(block.buf[off..][0..rest.len], rest.bytes());
        block.len = off + rest.len;
        block.returnFromSubList();
        f.fromTileList(r, "compressed_branch", block.start());

        // Nested: the tile list calls a sub-list, which calls another (two levels), and branches.
        var inner: Cl = .init(256);
        var ic: Coded = .{};
        ic.triAbs(30, 31, 32);
        ic.triAbs(33, 34, 35);
        ic.escape();
        inner.primitiveListFormat(.triangles, false);
        inner.nvShaderState(nv);
        inner.compressed(ic.bytes());
        inner.returnFromSubList();
        var middle: Cl = .init(64);
        middle.branchToSubList(inner.start());
        middle.returnFromSubList();
        var tail: Cl = .init(256);
        var tc: Coded = .{};
        tc.triAbs(40, 41, 42);
        tc.escape();
        tail.primitiveListFormat(.triangles, false);
        tail.nvShaderState(nv);
        tail.compressed(tc.bytes());
        tail.returnFromSubList();
        var top: Cl = .init(64);
        top.branchToSubList(middle.start());
        top.branch(tail.start());
        f.fromTileList(r, "sub_lists", top.start());
    }
    // VG coordinate lists: triangles and RHTs of XY coordinates.
    {
        const fs = gpu.upload(programs.uniformColourFragmentShader().code());
        const vg = gpu.vgRecord(fs, gpu.words(&.{0xff3080f0}), 0, true);
        var c: Coded = .{};
        const At = struct {
            fn xy(fr: *const Frame, px: f32, py: f32) u32 {
                const v16 = gpu.packXy(px - fr.w() / 2, py - fr.h() / 2);
                return v16;
            }
        };
        for (0..20) |i| {
            const fi: f32 = @floatFromInt(i);
            c.byte(129);
            c.word(At.xy(&f, 30 + fi * 50, 30));
            c.word(At.xy(&f, 70 + fi * 50, 50));
            c.word(At.xy(&f, 40 + fi * 50, 300));
            // Then one sharing two corners, its third 20 pixels on (relative, 2 bytes).
            const dx: u16 = 20 * 16 >> 4;
            c.half(0 | (dx & 0x7f) << 2 | (5 << 9));
        }
        c.escape();
        var rht: Coded = .{};
        for (0..10) |i| {
            const fi: f32 = @floatFromInt(i);
            rht.byte(129);
            rht.word(At.xy(&f, 100 + fi * 60, f.h() / 2));
            rht.word(At.xy(&f, 140 + fi * 60, f.h() / 2 + 80));
        }
        rht.escape();
        var list: Cl = .init(c.len + rht.len + 64);
        list.primitiveListFormat(.triangles, true);
        list.vgShaderState(vg);
        list.compressed(c.bytes());
        list.primitiveListFormat(.rhts, true);
        list.vgShaderState(vg);
        list.compressed(rht.bytes());
        list.returnFromSubList();
        f.fromTileList(r, "compressed_xy", list.start());
    }
    // A clipped primitive: its first vertex replaced by clipped vertex data.
    {
        const data = gpu.alloc(u32, 8, 16);
        data[0] = gpu.packXy(-100, -50);
        data[1] = gpu.floatBits(0.25);
        data[2] = gpu.floatBits(1);
        data[3] = gpu.floatBits(0.2);
        data[4] = gpu.floatBits(0.3);
        data[5] = gpu.floatBits(0.5);
        var c: Coded = .{};
        c.triAbs(50, 51, 52);
        c.triAbs(60, 61, 62);
        c.escape();
        var list: Cl = .init(c.len + 64);
        list.primitiveListFormat(.triangles, false);
        list.nvShaderState(nv);
        list.clippedPrimitive(hw.bus(data.ptr), 0b001, c.bytes());
        list.returnFromSubList();
        f.fromTileList(r, "clipped_primitive", list.start());
    }
    r.add("timeouts", f.timeouts);
}
