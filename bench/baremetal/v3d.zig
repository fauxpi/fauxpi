//! The V3D tests: frames drawn straight through the V3D's registers, as the vc4 driver has it
//! draw them. Each frame: a binning control list (BCL) of draws, binned into a tile per 64 by 64
//! pixels, then a rendering control list (RCL) drawing each tile into the framebuffer (RGBA8888,
//! linear). The shaders are made with FauxPi's QPU encoder (`src/vc4/qpu.zig`).

const std = @import("std");
const qpu = @import("qpu");
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

/// How a draw is shaded.
const Shading = enum { flat, textured, blended };

/// The shaders for a kind of draw, and what their vertices hold (floats: x and y in clip space, z,
/// then what the fragment shader is given).
const Shaders = struct {
    vs: u32,
    cs: u32,
    fs: u32,
    /// The vertex's words, and those that are varyings.
    words: u8,
    varyings: u8,

    fn make(shading: Shading) Shaders {
        const varyings: u8 = switch (shading) {
            .flat => 3,
            .textured => 2,
            .blended => 4,
        };
        return .{
            .vs = upload(vertexShader(3 + varyings, false)),
            .cs = upload(vertexShader(3 + varyings, true)),
            .fs = upload(switch (shading) {
                .flat => flatShader(),
                .textured => textureShader(),
                .blended => blendShader(),
            }),
            .words = 3 + varyings,
            .varyings = varyings,
        };
    }
};

/// The vertex shader (or, `coordinates`, the coordinate shader binning uses): x and y scaled to
/// pixels (by the uniforms) and packed as 12.4 fixed point, z, 1/W of 1, then the varyings as given.
fn vertexShader(words: u8, coordinates: bool) []const qpu.Inst {
    const S = struct {
        var p: qpu.Program(64) = .{};
    };
    const p = &S.p;
    p.* = .{};
    build: {
        p.emit(qpu.loadImm(.{ .add_dst = qpu.vpm_write_setup, .value = 0x00001a00 }) catch break :build);
        p.emit(qpu.loadImm(.{ .add_dst = qpu.vpm_read_setup, .value = (@as(u32, words) << 20) | 0x1a00 }) catch break :build);
        // x, y, z into r0, r1, ra3; the varyings into ra4...
        p.emit(qpu.mov(qpu.wr(0), qpu.vpm_read) catch break :build);
        p.emit(qpu.mov(qpu.wr(1), qpu.vpm_read) catch break :build);
        p.emit(qpu.mov(qpu.wa(3), qpu.vpm_read) catch break :build);
        for (3..words) |k| p.emit(qpu.mov(qpu.wa(@intCast(4 + k - 3)), qpu.vpm_read) catch break :build);
        if (coordinates) {
            // Clip coordinates: x, y, z, W of 1.
            p.emit(qpu.mov(qpu.vpm_write, qpu.r(0)) catch break :build);
            p.emit(qpu.mov(qpu.vpm_write, qpu.r(1)) catch break :build);
            p.emit(qpu.mov(qpu.vpm_write, qpu.ra(3)) catch break :build);
            p.emit(qpu.loadImm(.{ .add_dst = qpu.vpm_write, .value = @bitCast(@as(f32, 1.0)) }) catch break :build);
        }
        p.emit(qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(0), .a = qpu.r(0), .b = qpu.unif } }) catch break :build);
        p.emit(qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(1), .a = qpu.r(1), .b = qpu.unif } }) catch break :build);
        p.emit(qpu.alu(.{ .add = .{ .op = .ftoi, .dst = qpu.wa(1), .a = qpu.r(0), .b = qpu.r(0) }, .pack = .{ .regfile_a = .@"16a" } }) catch break :build);
        p.emit(qpu.alu(.{ .add = .{ .op = .ftoi, .dst = qpu.wa(1), .a = qpu.r(1), .b = qpu.r(1) }, .pack = .{ .regfile_a = .@"16b" } }) catch break :build);
        p.emit(qpu.mov(qpu.vpm_write, qpu.ra(1)) catch break :build);
        p.emit(qpu.mov(qpu.vpm_write, qpu.ra(3)) catch break :build);
        p.emit(qpu.loadImm(.{ .add_dst = qpu.vpm_write, .value = @bitCast(@as(f32, 1.0)) }) catch break :build);
        if (!coordinates) {
            for (3..words) |k| p.emit(qpu.mov(qpu.vpm_write, qpu.ra(@intCast(4 + k - 3))) catch break :build);
        }
        p.end(.vertex);
        return p.code();
    }
    @panic("encoding a vertex shader");
}

/// The fragment shader's varyings, interpolated, into r0 to r(n-1).
fn interpolate(p: anytype, n: u3) qpu.EncodeError!void {
    for (0..n) |i| {
        const acc: u3 = @intCast(i);
        p.emit(try qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(acc), .a = qpu.vary, .b = qpu.frag_w } }));
        p.emit(try qpu.alu(.{ .add = .{ .op = .fadd, .dst = qpu.wr(acc), .a = qpu.r(acc), .b = qpu.r(5) } }));
    }
}

/// A colour: the varyings red, green and blue, opaque.
fn flatShader() []const qpu.Inst {
    const S = struct {
        var p: qpu.Program(32) = .{};
    };
    const p = &S.p;
    p.* = .{};
    build: {
        interpolate(p, 3) catch break :build;
        const one = qpu.smallImmFloat(1.0);
        p.emit(qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = qpu.r(2), .b = one }, .pack = .{ .mul = .@"8a" } }) catch break :build);
        p.emit(qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = qpu.r(1), .b = one }, .pack = .{ .mul = .@"8b" } }) catch break :build);
        p.emit(qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = qpu.r(0), .b = one }, .pack = .{ .mul = .@"8c" } }) catch break :build);
        p.emit(qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(3), .a = one, .b = one }, .pack = .{ .mul = .@"8d" } }) catch break :build);
        // A small immediate is a signal: the scoreboard wait is one of its own.
        p.emit(qpu.nop(.wait_scoreboard));
        p.emit(qpu.mov(qpu.tlb_color_all, qpu.r(3)) catch break :build);
        p.end(.fragment);
        return p.code();
    }
    @panic("encoding a fragment shader");
}

/// A texture (its parameters the uniforms), at the varyings s and t.
fn textureShader() []const qpu.Inst {
    const S = struct {
        var p: qpu.Program(32) = .{};
    };
    const p = &S.p;
    p.* = .{};
    build: {
        interpolate(p, 2) catch break :build;
        p.emit(qpu.mov(.{ .periph = qpu.W.tmu0_t }, qpu.r(1)) catch break :build);
        p.emit(qpu.mov(.{ .periph = qpu.W.tmu0_s }, qpu.r(0)) catch break :build);
        p.emit(qpu.nop(.load_tmu0));
        p.emit(qpu.nop(.wait_scoreboard));
        p.emit(qpu.mov(qpu.tlb_color_all, qpu.r(4)) catch break :build);
        p.end(.fragment);
        return p.code();
    }
    @panic("encoding a fragment shader");
}

/// A colour (the varyings red, green, blue and alpha) blended over the tile's: src * a +
/// dst * (1 - a), a byte at a time.
fn blendShader() []const qpu.Inst {
    const S = struct {
        var p: qpu.Program(48) = .{};
    };
    const p = &S.p;
    p.* = .{};
    build: {
        interpolate(p, 4) catch break :build;
        const one = qpu.smallImmFloat(1.0);
        // The colour into ra4, and its alpha in every byte of rb5.
        p.emit(qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wa(4), .a = qpu.r(2), .b = one }, .pack = .{ .mul = .@"8a" } }) catch break :build);
        p.emit(qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wa(4), .a = qpu.r(1), .b = one }, .pack = .{ .mul = .@"8b" } }) catch break :build);
        p.emit(qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wa(4), .a = qpu.r(0), .b = one }, .pack = .{ .mul = .@"8c" } }) catch break :build);
        p.emit(qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wa(4), .a = qpu.r(3), .b = one }, .pack = .{ .mul = .@"8d" } }) catch break :build);
        p.emit(qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wb(5), .a = qpu.r(3), .b = one }, .pack = .{ .mul = .@"8888" } }) catch break :build);
        // 1 - alpha, and the tile's colour.
        p.emit(qpu.loadImm(.{ .add_dst = qpu.wr(1), .value = 0xffffffff }) catch break :build);
        p.emit(qpu.alu(.{ .add = .{ .op = .v8subs, .dst = qpu.wr(2), .a = qpu.r(1), .b = qpu.rb(5) }, .sig = .wait_scoreboard }) catch break :build);
        p.emit(qpu.nop(.color_load));
        p.emit(qpu.alu(.{ .mul = .{ .op = .v8muld, .dst = qpu.wr(0), .a = qpu.ra(4), .b = qpu.rb(5) } }) catch break :build);
        p.emit(qpu.alu(.{ .mul = .{ .op = .v8muld, .dst = qpu.wr(1), .a = qpu.r(4), .b = qpu.r(2) } }) catch break :build);
        p.emit(qpu.alu(.{ .add = .{ .op = .v8adds, .dst = qpu.wr(3), .a = qpu.r(0), .b = qpu.r(1) } }) catch break :build);
        p.emit(qpu.mov(qpu.tlb_color_all, qpu.r(3)) catch break :build);
        p.end(.fragment);
        return p.code();
    }
    @panic("encoding a fragment shader");
}

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

/// A quad (two triangles) from (x0, y0) to (x1, y1) in clip space, at depth z, its vertices
/// given `extra` (the same at every corner, or per corner if `per_corner`).
fn quad(out: []f32, x0: f32, y0: f32, x1: f32, y1: f32, z: f32, extra: []const f32, per_corner: ?[4][2]f32) void {
    const corners = [6][2]f32{ .{ x0, y0 }, .{ x1, y0 }, .{ x0, y1 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 } };
    const uv = [6]usize{ 0, 1, 2, 1, 3, 2 };
    const stride = 3 + extra.len;
    for (corners, 0..) |c, i| {
        const v = out[i * stride ..][0..stride];
        v[0] = c[0];
        v[1] = c[1];
        v[2] = z;
        if (per_corner) |pc| {
            v[3] = pc[uv[i]][0];
            v[4] = pc[uv[i]][1];
        } else {
            @memcpy(v[3..], extra);
        }
    }
}

/// A small pseudo-random number in [0, 1).
fn rand(state: *u32) f32 {
    state.* ^= state.* << 13;
    state.* ^= state.* >> 17;
    state.* ^= state.* << 5;
    return @as(f32, @floatFromInt(state.* >> 8)) / 16777216.0;
}

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
    var seed: u32 = 1;
    for (0..n) |i| {
        const cx = rand(&seed) * 2 - 1;
        const cy = rand(&seed) * 2 - 1;
        const size: f32 = 0.02;
        const colour = [3]f32{ rand(&seed), rand(&seed), rand(&seed) };
        const v = vertices[i * 18 ..][0..18];
        const pts = [3][2]f32{ .{ cx - size, cy - size }, .{ cx + size, cy - size }, .{ cx, cy + size } };
        for (pts, 0..) |pt, k| {
            v[k * 6 + 0] = pt[0];
            v[k * 6 + 1] = pt[1];
            v[k * 6 + 2] = 0.5;
            @memcpy(v[k * 6 + 3 ..][0..3], &colour);
        }
    }
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
    const n: u32 = 32;
    const vertices = hw.heap.alloc(f32, n * 6 * 6, 16);
    var seed: u32 = 2;
    for (0..n) |i| {
        const z = rand(&seed);
        quad(vertices[i * 36 ..][0..36], -1, -1, 1, 1, z, &.{ rand(&seed), rand(&seed), rand(&seed) }, null);
    }
    const list = [_]Draw{.{ .record = shaderRecord(s, vertices, t.vs_unifs, uniforms(&.{})), .count = n * 6, .depth_test = true }};
    const frames = p.amount(30);
    for (0..frames) |_| t.frame(0xff000000, &list);
    r.add("frames", frames);
    r.add("pixels", @as(u64, n) * t.width * t.height * frames);
    r.add("checksum", t.checksum());
}

/// Textured quads: the TMU sampling (bilinear) a 256 by 256 texture.
pub fn texture(p: Params, r: *Result) void {
    var t: Target = .init(p, 1);
    const s: Shaders = .make(.textured);
    // The texture, in T-format (4 KiB tiles of 32 by 32 texels): a checker of colours.
    const size: u32 = 256;
    const tex = hw.heap.alloc(u8, size * size * 4, 4096);
    for (0..size) |y| {
        for (0..size) |x| {
            const c: u32 = if ((x / 16 + y / 16) % 2 == 0) 0xff2060c0 else 0xffe0a020;
            const off = tFormatOffset(size, @intCast(x), @intCast(y));
            std.mem.writeInt(u32, tex[off..][0..4], c ^ @as(u32, @intCast(x * 3 + y)), .little);
        }
    }
    // Parameters: the texture (RGBA8888, T-format), its size, bilinear filtering, repeating.
    const p0 = hw.bus(tex.ptr);
    const p1 = (size << 20) | (size << 8);
    const n: u32 = @intCast(@min(p.amount(2000), 10_000));
    const vertices = hw.heap.alloc(f32, n * 6 * 5, 16);
    var seed: u32 = 3;
    for (0..n) |i| {
        const x = rand(&seed) * 1.8 - 1;
        const y = rand(&seed) * 1.8 - 1;
        const uv = [4][2]f32{ .{ 0, 0 }, .{ 2, 0 }, .{ 0, 2 }, .{ 2, 2 } };
        quad(vertices[i * 30 ..][0..30], x, y, x + 0.2, y + 0.3, 0.5, &.{ 0, 0 }, uv);
    }
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
    var seed: u32 = 4;
    for (0..n) |i| {
        const x = rand(&seed) * 1.6 - 1;
        const y = rand(&seed) * 1.6 - 1;
        quad(vertices[i * 42 ..][0..42], x, y, x + 0.4, y + 0.4, 0.5, &.{ rand(&seed), rand(&seed), rand(&seed), 0.5 }, null);
    }
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
    var seed: u32 = 5;
    for (list) |*d| {
        const vertices = hw.heap.alloc(f32, 6 * 6, 16);
        const x = rand(&seed) * 1.9 - 1;
        const y = rand(&seed) * 1.9 - 1;
        quad(vertices, x, y, x + 0.1, y + 0.1, 0.5, &.{ rand(&seed), rand(&seed), rand(&seed) }, null);
        d.* = .{ .record = shaderRecord(s, vertices, t.vs_unifs, uniforms(&.{})), .count = 6 };
    }
    const frames = p.amount(30);
    for (0..frames) |_| t.frame(0xff000000, list);
    r.add("frames", frames);
    r.add("draws", @as(u64, n) * frames);
    r.add("checksum", t.checksum());
}

/// Where texel (x, y) of a `size` by `size` RGBA8888 texture is in T-format: 4 KiB tiles of 32
/// by 32 texels, rows of them going left and right in turn, each of four 1 KiB sub-tiles (in an
/// order that turns with the rows), each of 16 micro-tiles of 4 by 4 texels.
fn tFormatOffset(size: u32, x: u32, y: u32) u32 {
    const tiles_per_row = (size + 31) / 32;
    const tile_row = y >> 5;
    const tile_col = if (tile_row & 1 == 0) x >> 5 else tiles_per_row - 1 - (x >> 5);
    const tile_base = (tile_row * tiles_per_row + tile_col) << 12;
    const stile = (((y >> 4) & 1) << 1) | ((x >> 4) & 1);
    const even = [4]u32{ 0, 3, 1, 2 };
    const odd = [4]u32{ 2, 1, 3, 0 };
    const sub = if (tile_row & 1 == 0) even[stile] else odd[stile];
    const utile = (((y >> 2) & 3) << 2) | ((x >> 2) & 3);
    const in_utile = (((y & 3) << 2) | (x & 3)) << 2;
    return tile_base + (sub << 10) + (utile << 6) + in_utile;
}
