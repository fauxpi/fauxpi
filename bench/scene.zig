//! What the benchmark's GPU tests draw, the same bare-metal (bench/baremetal) and through Linux's
//! vc4 driver (bench/linux): the QPU shaders (made with FauxPi's encoder, src/vc4/qpu.zig) and the
//! vertices and texture of each scene. Vertices are floats: x and y in clip space, z, then what the
//! fragment shader is given.

const std = @import("std");
const qpu = @import("qpu");

/// How a draw is shaded.
pub const Shading = enum {
    flat,
    textured,
    blended,
    /// Lines in flat colours.
    line,
    /// Points, each its own size, coloured by where in it (red across, green down) and their blue.
    point,

    /// The varyings the vertex shader gives its fragment shader (as the shader record counts
    /// them): red, green and blue; s and t; red, green, blue and alpha.
    pub fn varyings(s: Shading) u8 {
        return switch (s) {
            .flat, .line, .point => 3,
            .textured => 2,
            .blended => 4,
        };
    }

    /// Whether its vertex shader writes each point's size (from the vertex's fourth word), as its
    /// shader record says.
    pub fn pointSize(s: Shading) bool {
        return s == .point;
    }

    /// A vertex's words: x, y, z, a point's size, and the varyings.
    pub fn words(s: Shading) u8 {
        return 3 + @as(u8, @intFromBool(s.pointSize())) + s.varyings();
    }

    pub fn fragmentShader(s: Shading) []const qpu.Inst {
        return switch (s) {
            // A line's first varying is the rasterizer's, its coordinate along it; a point's
            // first two its coordinates across it (s and t), then the vertex shader's.
            .flat => colourShader(&.{ 0, 1, 2 }),
            .line => colourShader(&.{ null, 0, 1, 2 }),
            .point => colourShader(&.{ 0, 1, null, null, 2 }),
            .textured => textureShader(),
            .blended => blendShader(),
        };
    }
};

/// The vertex shader for `shading` (or, `coordinates`, the coordinate shader binning uses): x and y
/// scaled to pixels (by the uniforms) and packed as 12.4 fixed point, z, 1/W of 1, the point's
/// size if it writes one, then the varyings as given.
pub fn vertexShader(shading: Shading, coordinates: bool) []const qpu.Inst {
    const words = shading.words();
    const first_varying: usize = if (shading.pointSize()) 4 else 3;
    const S = struct {
        var p: qpu.Program(64) = .{};
    };
    const p = &S.p;
    p.* = .{};
    build: {
        p.emit(qpu.loadImm(.{ .add_dst = qpu.vpm_write_setup, .value = 0x00001a00 }) catch break :build);
        p.emit(qpu.loadImm(.{ .add_dst = qpu.vpm_read_setup, .value = (@as(u32, words) << 20) | 0x1a00 }) catch break :build);
        // x, y, z into r0, r1, ra3; the rest (a point's size, the varyings) into ra4...
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
        if (shading.pointSize()) p.emit(qpu.mov(qpu.vpm_write, qpu.ra(4)) catch break :build);
        if (!coordinates) {
            for (first_varying..words) |k| p.emit(qpu.mov(qpu.vpm_write, qpu.ra(@intCast(4 + k - 3))) catch break :build);
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

/// An opaque colour, its red, green and blue in r0, r1 and r2: the varyings, each interpolated
/// into the accumulator `dsts` gives it, or read and dropped (null).
fn colourShader(dsts: []const ?u3) []const qpu.Inst {
    const S = struct {
        var p: qpu.Program(32) = .{};
    };
    const p = &S.p;
    p.* = .{};
    build: {
        for (dsts) |dst| {
            const acc = dst orelse 3;
            p.emit(qpu.alu(.{ .mul = .{ .op = .fmul, .dst = qpu.wr(acc), .a = qpu.vary, .b = qpu.frag_w } }) catch break :build);
            if (dst != null) p.emit(qpu.alu(.{ .add = .{ .op = .fadd, .dst = qpu.wr(acc), .a = qpu.r(acc), .b = qpu.r(5) } }) catch break :build);
        }
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

/// A quad (two triangles) from (x0, y0) to (x1, y1) in clip space, at depth z, its vertices
/// given `extra` (the same at every corner, or per corner if `per_corner`).
pub fn quad(out: []f32, x0: f32, y0: f32, x1: f32, y1: f32, z: f32, extra: []const f32, per_corner: ?[4][2]f32) void {
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
pub fn rand(state: *u32) f32 {
    state.* ^= state.* << 13;
    state.* ^= state.* >> 17;
    state.* ^= state.* << 5;
    return @as(f32, @floatFromInt(state.* >> 8)) / 16777216.0;
}

/// Where texel (x, y) of a `size` by `size` RGBA8888 texture is in T-format: 4 KiB tiles of 32
/// by 32 texels, rows of them going left and right in turn, each of four 1 KiB sub-tiles (in an
/// order that turns with the rows), each of 16 micro-tiles of 4 by 4 texels.
pub fn tFormatOffset(size: u32, x: u32, y: u32) u32 {
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

/// The texture the textured scenes sample: a checker of colours, `texture_size` square, RGBA8888
/// in T-format (`texture_size * texture_size * 4` bytes).
pub const texture_size: u32 = 256;

pub fn textureTexels(out: []u8) void {
    for (0..texture_size) |y| {
        for (0..texture_size) |x| {
            const c: u32 = if ((x / 16 + y / 16) % 2 == 0) 0xff2060c0 else 0xffe0a020;
            const off = tFormatOffset(texture_size, @intCast(x), @intCast(y));
            std.mem.writeInt(u32, out[off..][0..4], c ^ @as(u32, @intCast(x * 3 + y)), .little);
        }
    }
}

/// `n` small flat-coloured triangles, scattered (`n * 3 * 6` floats).
pub fn triangleVertices(out: []f32, n: u32) void {
    var seed: u32 = 1;
    for (0..n) |i| {
        const cx = rand(&seed) * 2 - 1;
        const cy = rand(&seed) * 2 - 1;
        const size: f32 = 0.02;
        const colour = [3]f32{ rand(&seed), rand(&seed), rand(&seed) };
        const v = out[i * 18 ..][0..18];
        const pts = [3][2]f32{ .{ cx - size, cy - size }, .{ cx + size, cy - size }, .{ cx, cy + size } };
        for (pts, 0..) |pt, k| {
            v[k * 6 + 0] = pt[0];
            v[k * 6 + 1] = pt[1];
            v[k * 6 + 2] = 0.5;
            @memcpy(v[k * 6 + 3 ..][0..3], &colour);
        }
    }
}

/// `fill_quads` full-screen flat-coloured quads at random depths (`fill_quads * 6 * 6` floats).
pub const fill_quads: u32 = 32;

pub fn fillVertices(out: []f32) void {
    var seed: u32 = 2;
    for (0..fill_quads) |i| {
        const z = rand(&seed);
        quad(out[i * 36 ..][0..36], -1, -1, 1, 1, z, &.{ rand(&seed), rand(&seed), rand(&seed) }, null);
    }
}

/// `n` textured quads, the texture twice over each (`n * 6 * 5` floats).
pub fn textureVertices(out: []f32, n: u32) void {
    var seed: u32 = 3;
    for (0..n) |i| {
        const x = rand(&seed) * 1.8 - 1;
        const y = rand(&seed) * 1.8 - 1;
        const uv = [4][2]f32{ .{ 0, 0 }, .{ 2, 0 }, .{ 0, 2 }, .{ 2, 2 } };
        quad(out[i * 30 ..][0..30], x, y, x + 0.2, y + 0.3, 0.5, &.{ 0, 0 }, uv);
    }
}

/// `n` half-transparent quads (`n * 6 * 7` floats).
pub fn blendVertices(out: []f32, n: u32) void {
    var seed: u32 = 4;
    for (0..n) |i| {
        const x = rand(&seed) * 1.6 - 1;
        const y = rand(&seed) * 1.6 - 1;
        quad(out[i * 42 ..][0..42], x, y, x + 0.4, y + 0.4, 0.5, &.{ rand(&seed), rand(&seed), rand(&seed), 0.5 }, null);
    }
}

/// The small flat-coloured quad of draw `i` of the draws scene (`6 * 6` floats).
pub fn drawQuad(out: []f32, i: u32) void {
    var seed: u32 = 5 + i * 7919;
    _ = rand(&seed);
    const x = rand(&seed) * 1.9 - 1;
    const y = rand(&seed) * 1.9 - 1;
    quad(out, x, y, x + 0.1, y + 0.1, 0.5, &.{ rand(&seed), rand(&seed), rand(&seed) }, null);
}

/// `n` flat-coloured lines (`n * 2 * 6` floats), most short and scattered, and one in 64 far past
/// the screen's edges, where the clipper cuts it.
pub fn lineVertices(out: []f32, n: u32) void {
    var seed: u32 = 6;
    for (0..n) |i| {
        const cx = rand(&seed) * 2 - 1;
        const cy = rand(&seed) * 2 - 1;
        const angle = rand(&seed) * 2 * std.math.pi;
        const half: f32 = if (i % 64 == 0) 16 else 0.02 + rand(&seed) * 0.2;
        const colour = [3]f32{ rand(&seed), rand(&seed), rand(&seed) };
        const v = out[i * 12 ..][0..12];
        for ([2]f32{ -1, 1 }, 0..) |side, k| {
            v[k * 6 + 0] = cx + side * half * @cos(angle);
            v[k * 6 + 1] = cy + side * half * @sin(angle);
            v[k * 6 + 2] = 0.5;
            @memcpy(v[k * 6 + 3 ..][0..3], &colour);
        }
    }
}

/// How wide the lines scenes' lines are, in pixels (LINE_WIDTH).
pub const line_width: f32 = 2;

/// `n` points, scattered, from 1 to 16 pixels wide (`n * 7` floats: x, y, z, size, then red, green
/// and blue).
pub fn pointVertices(out: []f32, n: u32) void {
    var seed: u32 = 7;
    for (0..n) |i| {
        const v = out[i * 7 ..][0..7];
        v[0] = rand(&seed) * 2 - 1;
        v[1] = rand(&seed) * 2 - 1;
        v[2] = 0.5;
        v[3] = 1 + @floor(rand(&seed) * 16);
        for (v[4..7]) |*c| c.* = rand(&seed);
    }
}
