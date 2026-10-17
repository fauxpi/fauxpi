//! Anti-aliased rasterization of outlines into 8-bit coverage masks.
//!
//! Each line segment adds the signed area it covers to an accumulation
//! buffer, cell by cell, and a running sum over the buffer then gives every
//! pixel's exact coverage. Curves are flattened into short lines first.
//! This is the approach of Raph Levien's font-rs: no sorting or edge lists,
//! and exact area coverage rather than sampled supersampling.
//!
//! Coordinates are in pixels with y pointing down. The non-zero winding
//! rule is approximated by clamping |winding| to 1, which is exact for the
//! well-formed outlines fonts contain.

const std = @import("std");

pub const Rasterizer = struct {
    width: u32,
    height: u32,
    /// width * height cells plus slack: a segment touching the right edge
    /// adds to the first cell of the next row, which the running sum cancels.
    acc: []f32,
    cursor: [2]f32 = .{ 0, 0 },
    start: [2]f32 = .{ 0, 0 },

    pub fn init(gpa: std.mem.Allocator, width: u32, height: u32) !Rasterizer {
        const acc = try gpa.alloc(f32, @as(usize, width) * height + 4);
        @memset(acc, 0);
        return .{ .width = width, .height = height, .acc = acc };
    }

    pub fn deinit(r: *Rasterizer, gpa: std.mem.Allocator) void {
        gpa.free(r.acc);
    }

    pub fn moveTo(r: *Rasterizer, x: f32, y: f32) void {
        r.cursor = .{ x, y };
        r.start = r.cursor;
    }

    pub fn lineTo(r: *Rasterizer, x: f32, y: f32) void {
        r.line(r.cursor, .{ x, y });
        r.cursor = .{ x, y };
    }

    pub fn quadTo(r: *Rasterizer, cx: f32, cy: f32, x: f32, y: f32) void {
        const p0 = r.cursor;
        // Enough segments that the curve stays within 1/20 pixel of the
        // lines: a quadratic strays at most |p0 - 2c + p2| / 4 from its
        // chord, and splitting it into n pieces divides that by n^2.
        const ddx = p0[0] - 2 * cx + x;
        const ddy = p0[1] - 2 * cy + y;
        const dev = @sqrt(ddx * ddx + ddy * ddy);
        const n: u32 = if (dev < 0.2) 1 else @intFromFloat(@min(@ceil(@sqrt(dev * 5)), 64));
        var prev = p0;
        for (1..n + 1) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            const mt = 1 - t;
            const p: [2]f32 = .{
                mt * mt * p0[0] + 2 * mt * t * cx + t * t * x,
                mt * mt * p0[1] + 2 * mt * t * cy + t * t * y,
            };
            r.line(prev, p);
            prev = p;
        }
        r.cursor = .{ x, y };
    }

    /// Closes the current contour.
    pub fn close(r: *Rasterizer) void {
        if (r.cursor[0] != r.start[0] or r.cursor[1] != r.start[1]) r.lineTo(r.start[0], r.start[1]);
    }

    fn line(r: *Rasterizer, from: [2]f32, to: [2]f32) void {
        if (from[1] == to[1]) return;
        const w: f32 = @floatFromInt(r.width);
        // Clamp x into the buffer; area outside it would only spill into
        // neighbouring rows. (Glyph masks are sized to fit, so this is a
        // safety net.)
        const p0: [2]f32 = .{ std.math.clamp(from[0], 0, w), from[1] };
        const p1: [2]f32 = .{ std.math.clamp(to[0], 0, w), to[1] };
        const dir: f32, const a: [2]f32, const b: [2]f32 = if (p0[1] < p1[1]) .{ 1, p0, p1 } else .{ -1, p1, p0 };
        const dxdy = (b[0] - a[0]) / (b[1] - a[1]);
        var x = a[0];
        if (a[1] < 0) x -= a[1] * dxdy;
        const y_start: u32 = @intFromFloat(@max(0, @floor(a[1])));
        const y_end: u32 = @intFromFloat(std.math.clamp(@ceil(b[1]), 0, @as(f32, @floatFromInt(r.height))));
        var y = y_start;
        while (y < y_end) : (y += 1) {
            const row = @as(usize, y) * r.width;
            const fy: f32 = @floatFromInt(y);
            const dy = @min(fy + 1, b[1]) - @max(fy, a[1]);
            const x_next = x + dxdy * dy;
            const d = dy * dir;
            const x0 = @min(x, x_next);
            const x1 = @max(x, x_next);
            const x0_floor = @floor(x0);
            const x0i: usize = @intFromFloat(x0_floor);
            const x1_ceil = @ceil(x1);
            const x1i: usize = @intFromFloat(x1_ceil);
            if (x1i <= x0i + 1) {
                // Within one cell: split the area by the segment's mean x.
                const xmf = 0.5 * (x + x_next) - x0_floor;
                r.acc[row + x0i] += d - d * xmf;
                r.acc[row + x0i + 1] += d * xmf;
            } else {
                // Across several cells: a triangle in the first, full cells
                // in between and a triangle in the last.
                const s = 1 / (x1 - x0);
                const x0f = x0 - x0_floor;
                const a0 = 0.5 * s * (1 - x0f) * (1 - x0f);
                const x1f = x1 - x1_ceil + 1;
                const am = 0.5 * s * x1f * x1f;
                r.acc[row + x0i] += d * a0;
                if (x1i == x0i + 2) {
                    r.acc[row + x0i + 1] += d * (1 - a0 - am);
                } else {
                    const a1 = s * (1.5 - x0f);
                    r.acc[row + x0i + 1] += d * (a1 - a0);
                    for (x0i + 2..x1i - 1) |xi| r.acc[row + xi] += d * s;
                    const a2 = a1 + @as(f32, @floatFromInt(x1i - x0i - 3)) * s;
                    r.acc[row + x1i - 1] += d * (1 - a2 - am);
                }
                r.acc[row + x1i] += d * am;
            }
            x = x_next;
        }
    }

    /// Writes the coverage of every pixel (0-255) to `out`, row by row.
    pub fn coverage(r: *const Rasterizer, out: []u8) void {
        const len = @as(usize, r.width) * r.height;
        const out_slice = out[0..len];
        const acc_slice = r.acc[0..len];
        var sum: f32 = 0;
        var i: usize = 0;
        while (i + 4 <= len) : (i += 4) {
            const s0 = sum + acc_slice[i + 0];
            const s1 = s0 + acc_slice[i + 1];
            const s2 = s1 + acc_slice[i + 2];
            const s3 = s2 + acc_slice[i + 3];
            sum = s3;
            const v_sum = @Vector(4, f32){ s0, s1, s2, s3 };
            const v_clamped = @min(@abs(v_sum), @as(@Vector(4, f32), @splat(1.0)));
            const v_cov: @Vector(4, u8) = @intFromFloat(v_clamped * @as(@Vector(4, f32), @splat(255.0)) + @as(@Vector(4, f32), @splat(0.5)));
            out_slice[i..][0..4].* = v_cov;
        }
        while (i < len) : (i += 1) {
            sum += acc_slice[i];
            out_slice[i] = @intFromFloat(@min(@abs(sum), 1.0) * 255.0 + 0.5);
        }
    }
};

const testing = std.testing;

fn rasterize(width: u32, height: u32, path: []const [2]f32, out: []u8) !void {
    var r = try Rasterizer.init(testing.allocator, width, height);
    defer r.deinit(testing.allocator);
    r.moveTo(path[0][0], path[0][1]);
    for (path[1..]) |p| r.lineTo(p[0], p[1]);
    r.close();
    r.coverage(out);
}

test "a pixel-aligned square is fully covered inside and empty outside" {
    var out: [16]u8 = undefined;
    try rasterize(4, 4, &.{ .{ 1, 1 }, .{ 3, 1 }, .{ 3, 3 }, .{ 1, 3 } }, &out);
    try testing.expectEqualSlices(u8, &.{
        0, 0,   0,   0,
        0, 255, 255, 0,
        0, 255, 255, 0,
        0, 0,   0,   0,
    }, &out);
}

test "edges between pixels give partial coverage, either winding" {
    var a: [16]u8 = undefined;
    var b: [16]u8 = undefined;
    try rasterize(4, 4, &.{ .{ 0.5, 0.5 }, .{ 2.5, 0.5 }, .{ 2.5, 2.5 }, .{ 0.5, 2.5 } }, &a);
    try rasterize(4, 4, &.{ .{ 0.5, 0.5 }, .{ 0.5, 2.5 }, .{ 2.5, 2.5 }, .{ 2.5, 0.5 } }, &b);
    try testing.expectEqualSlices(u8, &a, &b);
    try testing.expectEqual(@as(u8, 64), a[0]); // a quarter of the corner pixel
    try testing.expectEqual(@as(u8, 128), a[1]); // half of an edge pixel
    try testing.expectEqual(@as(u8, 255), a[5]);
}

test "a diagonal halves the pixels it crosses" {
    var out: [16]u8 = undefined;
    try rasterize(4, 4, &.{ .{ 0, 0 }, .{ 4, 4 }, .{ 0, 4 } }, &out);
    for (0..4) |i| {
        try testing.expectEqual(@as(u8, 128), out[i * 4 + i]);
        if (i > 0) try testing.expectEqual(@as(u8, 255), out[i * 4]);
        if (i < 3) try testing.expectEqual(@as(u8, 0), out[i * 4 + 3]);
    }
}

test "total coverage equals the shape's area" {
    var r = try Rasterizer.init(testing.allocator, 20, 20);
    defer r.deinit(testing.allocator);
    // A circle of radius 8 made of quadratic arcs.
    const n = 16;
    const c: [2]f32 = .{ 10.3, 9.7 };
    const rad: f32 = 8;
    r.moveTo(c[0] + rad, c[1]);
    for (1..n + 1) |i| {
        const a0 = std.math.tau * @as(f32, @floatFromInt(i - 1)) / n;
        const a1 = std.math.tau * @as(f32, @floatFromInt(i)) / n;
        const am = (a0 + a1) / 2;
        const k = rad / @cos((a1 - a0) / 2);
        r.quadTo(c[0] + k * @cos(am), c[1] + k * @sin(am), c[0] + rad * @cos(a1), c[1] + rad * @sin(a1));
    }
    var out: [400]u8 = undefined;
    r.coverage(&out);
    var total: f32 = 0;
    for (out) |v| total += @as(f32, @floatFromInt(v)) / 255;
    // Flattening each arc into chords loses a sliver along it, at most the
    // flattening tolerance (1/20 pixel) times the perimeter.
    const perimeter = std.math.tau * rad;
    try testing.expect(total <= std.math.pi * rad * rad + 0.5);
    try testing.expect(total >= std.math.pi * rad * rad - perimeter / 20);
}

fn polygonArea(pts: []const [2]f32) f32 {
    var a: f32 = 0;
    for (pts, 0..) |p, i| {
        const q = pts[(i + 1) % pts.len];
        a += p[0] * q[1] - q[0] * p[1];
    }
    return @abs(a) / 2;
}

test "polygons are covered exactly" {
    const shapes = [_][]const [2]f32{
        &.{ .{ 10, 2 }, .{ 18, 10 }, .{ 10, 18 }, .{ 2, 10 } },
        &.{ .{ 10.3, 2.2 }, .{ 17.1, 10.7 }, .{ 9.6, 17.4 }, .{ 2.9, 9.1 } },
        &.{ .{ 2.5, 3.5 }, .{ 17.2, 4.1 }, .{ 3.3, 16.8 } },
        &.{ .{ 2.5, 3.5 }, .{ 17.2, 3.9 }, .{ 16.3, 16.8 } },
    };
    for (shapes) |shape| {
        var out: [400]u8 = undefined;
        try rasterize(20, 20, shape, &out);
        var total: f32 = 0;
        for (out) |v| total += @as(f32, @floatFromInt(v)) / 255;
        // Within the rounding of 8-bit coverage.
        try testing.expectApproxEqAbs(polygonArea(shape), total, 0.1);
    }
}
