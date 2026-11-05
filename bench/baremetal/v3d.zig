//! The V3D tests: frames drawn straight through the V3D's registers, as the vc4 driver has it
//! draw them. Each frame: a binning control list (BCL) of draws, binned into a tile per 64 by 64
//! pixels, then a rendering control list (RCL) drawing each tile into the framebuffer (RGBA8888,
//! linear). What they draw is bench/scene.zig's.

const std = @import("std");
const qpu = @import("qpu");
const scene = @import("scene");
const hw = @import("hw.zig");
const main = @import("main.zig");

const Params = main.Params;
const Result = main.Result;

const base = hw.peripherals + 0xc0_0000;
const ct0ea = base + 0x108;
const ct1ea = base + 0x10c;
const ct0ca = base + 0x110;
const ct1ca = base + 0x114;
const bfc = base + 0x134;
const rfc = base + 0x138;
const bpoa = base + 0x308;
const bpos = base + 0x30c;

/// A control list being written.
const Cl = struct {
    buf: []u8,
    len: usize = 0,

    fn init(size: usize) Cl {
        return .{ .buf = hw.heap.alloc(u8, size, 16) };
    }

    fn byte(c: *Cl, v: u8) void {
        c.buf[c.len] = v;
        c.len += 1;
    }

    fn half(c: *Cl, v: u16) void {
        std.mem.writeInt(u16, c.buf[c.len..][0..2], v, .little);
        c.len += 2;
    }

    fn word(c: *Cl, v: u32) void {
        std.mem.writeInt(u32, c.buf[c.len..][0..4], v, .little);
        c.len += 4;
    }

    fn float(c: *Cl, v: f32) void {
        c.word(@bitCast(v));
    }

    fn start(c: *const Cl) u32 {
        return hw.bus(c.buf.ptr);
    }

    fn end(c: *const Cl) u32 {
        return hw.bus(c.buf.ptr) + @as(u32, @intCast(c.len));
    }
};

/// A shader in memory the QPUs read.
fn upload(code: []const qpu.Inst) u32 {
    const mem = hw.heap.alloc(qpu.Inst, code.len, 16);
    @memcpy(mem, code);
    return hw.bus(mem.ptr);
}

fn uniforms(values: []const u32) u32 {
    const mem = hw.heap.alloc(u32, @max(values.len, 1), 16);
    @memcpy(mem[0..values.len], values);
    return hw.bus(mem.ptr);
}

/// The shaders for a kind of draw, in memory.
const Shaders = struct {
    vs: u32,
    cs: u32,
    fs: u32,
    words: u8,
    varyings: u8,

    fn make(shading: scene.Shading) Shaders {
        return .{
            .vs = upload(scene.vertexShader(shading.words(), false)),
            .cs = upload(scene.vertexShader(shading.words(), true)),
            .fs = upload(shading.fragmentShader()),
            .words = shading.words(),
            .varyings = shading.varyings(),
        };
    }
};

/// A draw: `count` vertices (3 a triangle) of `vertices`, shaded so.
const Draw = struct {
    record: u32,
    first: u32 = 0,
    count: u32,
    /// The configuration bits: drawing both faces, and the depth test.
    depth_test: bool = false,
};

/// A shader record: the shaders, their uniforms, and the vertices (one attribute of all their
/// words).
fn shaderRecord(s: Shaders, vertices: []const f32, vs_unifs: u32, fs_unifs: u32) u32 {
    const rec = hw.heap.alloc(u8, 36 + 8, 16);
    var c: Cl = .{ .buf = rec };
    const stride = @as(u8, s.words) * 4;
    // Flags: the fragment shader single-threaded.
    c.half(1);
    c.byte(0);
    c.byte(s.varyings);
    c.word(s.fs);
    c.word(fs_unifs);
    // The vertex shader: attribute 0, all of it.
    c.half(0);
    c.byte(1);
    c.byte(stride);
    c.word(s.vs);
    c.word(vs_unifs);
    // The coordinate shader, the same.
    c.half(0);
    c.byte(1);
    c.byte(stride);
    c.word(s.cs);
    c.word(vs_unifs);
    // Attribute 0.
    c.word(hw.bus(vertices.ptr));
    c.byte(stride - 1);
    c.byte(stride);
    c.byte(0);
    c.byte(0);
    return hw.bus(rec.ptr);
}

/// Where frames are drawn, and the memory V3D bins into.
const Target = struct {
    width: u32,
    height: u32,
    tiles_w: u32,
    tiles_h: u32,
    fb: []u32,
    tile_alloc: []u8,
    tile_state: []u8,
    bcl: Cl,
    rcl: Cl,
    /// The vertex shader's uniforms: clip space to pixels (12.4 fixed point).
    vs_unifs: u32,

    fn init(p: Params, max_draws: usize) Target {
        // u32s: @min with 2048 alone would be a u12, and multiply as one.
        const w: u32 = @min(p.width, 2048);
        const h: u32 = @min(p.height, 2048);
        const tiles_w = (w + 63) / 64;
        const tiles_h = (h + 63) / 64;
        const tile_alloc = hw.heap.alloc(u8, 16 << 20, 4096);
        hw.write(bpoa, hw.bus(tile_alloc.ptr) + (8 << 20));
        hw.write(bpos, 8 << 20);
        return .{
            .width = w,
            .height = h,
            .tiles_w = tiles_w,
            .tiles_h = tiles_h,
            .fb = hw.heap.alloc(u32, w * h, 4096),
            .tile_alloc = tile_alloc,
            .tile_state = hw.heap.alloc(u8, tiles_w * tiles_h * 48, 16),
            .bcl = .init(64 + max_draws * 32),
            .rcl = .init(64 + tiles_w * tiles_h * 16),
            .vs_unifs = uniforms(&.{ @bitCast(@as(f32, @floatFromInt(w)) * 8.0), @bitCast(-@as(f32, @floatFromInt(h)) * 8.0) }),
        };
    }

    /// Draws `draws` over `clear`, and waits until it is done.
    fn frame(t: *Target, clear_color: u32, list: []const Draw) void {
        const bcl = &t.bcl;
        bcl.len = 0;
        // TILE_BINNING_MODE_CONFIG: tile allocation (the lists' first blocks taken as they are
        // needed), tile state, the tiles, and the tile state initialised.
        bcl.byte(112);
        bcl.word(hw.bus(t.tile_alloc.ptr));
        bcl.word(8 << 20);
        bcl.word(hw.bus(t.tile_state.ptr));
        bcl.byte(@intCast(t.tiles_w));
        bcl.byte(@intCast(t.tiles_h));
        bcl.byte(1 << 2);
        bcl.byte(6); // START_TILE_BINNING
        bcl.byte(102); // CLIP_WINDOW
        bcl.half(0);
        bcl.half(0);
        bcl.half(@intCast(t.width));
        bcl.half(@intCast(t.height));
        bcl.byte(103); // VIEWPORT_OFFSET: the centre, in 12.4 fixed point
        bcl.half(@intCast(t.width * 8));
        bcl.half(@intCast(t.height * 8));
        bcl.byte(105); // CLIPPER_XY_SCALING
        bcl.float(@as(f32, @floatFromInt(t.width)) * 8.0);
        bcl.float(-@as(f32, @floatFromInt(t.height)) * 8.0);
        bcl.byte(106); // CLIPPER_Z_SCALING
        bcl.float(0.5);
        bcl.float(0.5);
        var depth: ?bool = null;
        for (list) |d| {
            if (depth != d.depth_test) {
                depth = d.depth_test;
                // CONFIGURATION_BITS: both faces; depth less-or-equal and written, or always.
                bcl.byte(96);
                bcl.byte(0x03);
                bcl.byte(if (d.depth_test) 0x80 | (3 << 4) else 7 << 4);
                bcl.byte(0);
            }
            bcl.byte(64); // GL_SHADER_STATE: the record, with 1 attribute
            bcl.word(d.record | 1);
            bcl.byte(33); // GL_ARRAY_PRIMITIVE: triangles
            bcl.byte(4);
            bcl.word(d.count);
            bcl.word(d.first);
        }
        bcl.byte(7); // INCREMENT_SEMAPHORE: the RCL may start
        bcl.byte(4); // FLUSH

        const rcl = &t.rcl;
        rcl.len = 0;
        rcl.byte(114); // CLEAR_COLORS: colour, colour, depth (far) and stencil
        rcl.word(clear_color);
        rcl.word(clear_color);
        rcl.word(0x00ffffff);
        rcl.byte(0);
        rcl.byte(113); // TILE_RENDERING_MODE_CONFIG: RGBA8888, linear
        rcl.word(hw.bus(t.fb.ptr));
        rcl.half(@intCast(t.width));
        rcl.half(@intCast(t.height));
        rcl.half(1 << 2);
        rcl.byte(8); // WAIT_SEMAPHORE: for the binning
        for (0..t.tiles_h) |ty| {
            for (0..t.tiles_w) |tx| {
                rcl.byte(115); // TILE_COORDINATES
                rcl.byte(@intCast(tx));
                rcl.byte(@intCast(ty));
                rcl.byte(17); // BRANCH_TO_SUB_LIST: the tile's list
                rcl.word(hw.bus(t.tile_alloc.ptr) + @as(u32, @intCast((ty * t.tiles_w + tx) * 32)));
                const last = ty + 1 == t.tiles_h and tx + 1 == t.tiles_w;
                rcl.byte(if (last) 25 else 24); // STORE_MS_TILE_BUFFER(_AND_EOF)
            }
        }

        const bins = hw.read(bfc);
        const renders = hw.read(rfc);
        hw.write(ct0ca, bcl.start());
        hw.write(ct0ea, bcl.end());
        hw.write(ct1ca, rcl.start());
        hw.write(ct1ea, rcl.end());
        while (hw.read(bfc) & 0xff == bins & 0xff) {}
        while (hw.read(rfc) & 0xff == renders & 0xff) {}
    }

    /// A checksum of what was drawn (a sample of the pixels).
    fn checksum(t: *const Target) u64 {
        var sum: u64 = 0;
        var i: usize = 0;
        while (i < t.fb.len) : (i += 997) sum +%= t.fb[i];
        return sum;
    }
};

/// Frames with no draws: the tiles cleared and stored (their loads and stores).
pub fn clear(p: Params, r: *Result) void {
    var t: Target = .init(p, 1);
    const frames = p.amount(120);
    for (0..frames) |f| t.frame(0xff000000 | @as(u32, @intCast(f * 0x010203 & 0xffffff)), &.{});
    r.add("frames", frames);
    r.add("checksum", t.checksum());
}

/// Many small triangles, flat colours: vertex shading and binning.
pub fn triangles(p: Params, r: *Result) void {
    var t: Target = .init(p, 1);
    const s: Shaders = .make(.flat);
    const n: u32 = @intCast(@min(p.amount(20_000), 21_000));
    const vertices = hw.heap.alloc(f32, n * 3 * 6, 16);
    scene.triangleVertices(vertices, n);
    const list = [_]Draw{.{ .record = shaderRecord(s, vertices, t.vs_unifs, uniforms(&.{})), .count = n * 3 }};
    const frames = p.amount(30);
    for (0..frames) |_| t.frame(0xff102030, &list);
    r.add("frames", frames);
    r.add("triangles", @as(u64, n) * frames);
    r.add("checksum", t.checksum());
}

/// Big overlapping quads, depth-tested: filling pixels.
pub fn fill(p: Params, r: *Result) void {
    var t: Target = .init(p, 1);
    const s: Shaders = .make(.flat);
    const vertices = hw.heap.alloc(f32, scene.fill_quads * 6 * 6, 16);
    scene.fillVertices(vertices);
    const list = [_]Draw{.{ .record = shaderRecord(s, vertices, t.vs_unifs, uniforms(&.{})), .count = scene.fill_quads * 6, .depth_test = true }};
    const frames = p.amount(30);
    for (0..frames) |_| t.frame(0xff000000, &list);
    r.add("frames", frames);
    r.add("pixels", @as(u64, scene.fill_quads) * t.width * t.height * frames);
    r.add("checksum", t.checksum());
}

/// Textured quads: the TMU sampling (bilinear) the scene's texture.
pub fn texture(p: Params, r: *Result) void {
    var t: Target = .init(p, 1);
    const s: Shaders = .make(.textured);
    const size = scene.texture_size;
    const tex = hw.heap.alloc(u8, size * size * 4, 4096);
    scene.textureTexels(tex);
    // Parameters: the texture (RGBA8888, T-format), its size, bilinear filtering, repeating.
    const p0 = hw.bus(tex.ptr);
    const p1 = (size << 20) | (size << 8);
    const n: u32 = @intCast(@min(p.amount(2000), 10_000));
    const vertices = hw.heap.alloc(f32, n * 6 * 5, 16);
    scene.textureVertices(vertices, n);
    const list = [_]Draw{.{ .record = shaderRecord(s, vertices, t.vs_unifs, uniforms(&.{ p0, p1 })), .count = n * 6 }};
    const frames = p.amount(30);
    for (0..frames) |_| t.frame(0xff000000, &list);
    r.add("frames", frames);
    r.add("quads", @as(u64, n) * frames);
    r.add("checksum", t.checksum());
}

/// Translucent quads, blended in the fragment shader (reading the tile's colour).
pub fn blend(p: Params, r: *Result) void {
    var t: Target = .init(p, 1);
    const s: Shaders = .make(.blended);
    const n: u32 = @intCast(@min(p.amount(500), 5000));
    const vertices = hw.heap.alloc(f32, n * 6 * 7, 16);
    scene.blendVertices(vertices, n);
    const list = [_]Draw{.{ .record = shaderRecord(s, vertices, t.vs_unifs, uniforms(&.{})), .count = n * 6 }};
    const frames = p.amount(30);
    for (0..frames) |_| t.frame(0xff204060, &list);
    r.add("frames", frames);
    r.add("quads", @as(u64, n) * frames);
    r.add("checksum", t.checksum());
}

/// Many draws of a quad each, each with its own record: the cost of a draw.
pub fn draws(p: Params, r: *Result) void {
    const n: u32 = @intCast(@min(p.amount(1000), 4000));
    var t: Target = .init(p, n);
    const s: Shaders = .make(.flat);
    const list = hw.heap.alloc(Draw, n, 16);
    for (list, 0..) |*d, i| {
        const vertices = hw.heap.alloc(f32, 6 * 6, 16);
        scene.drawQuad(vertices, @intCast(i));
        d.* = .{ .record = shaderRecord(s, vertices, t.vs_unifs, uniforms(&.{})), .count = 6 };
    }
    const frames = p.amount(30);
    for (0..frames) |_| t.frame(0xff000000, list);
    r.add("frames", frames);
    r.add("draws", @as(u64, n) * frames);
    r.add("checksum", t.checksum());
}
