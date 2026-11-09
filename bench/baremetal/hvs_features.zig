//! HVS feature tests: display lists of planes in every pixel format (and each pixel order and
//! alpha expansion), T-format and SAND tiling, flips, each alpha mode (fixed, premultiplied,
//! mixed), every scaling mode (PPF and TPZ, each way, with the line buffer and a filter kernel),
//! YUV in 3 and 2 planes (4:2:0 and 4:2:2, with colour space conversion), 4:4:4, background fill
//! colours, and lists of many planes. Each is shown for a number of frames. The HVS's output
//! can't be read back (it goes to the display), so what these measure is composing them: in
//! FauxPi's report, `hvs_compose`. The display list words are laid out as Linux's vc4 driver lays
//! them out (vc4_plane.c).

const std = @import("std");
const hw = @import("hw.zig");
const main = @import("main.zig");

const base = hw.peripherals + 0x40_0000;
const dispctrl = base + 0x00;
const dispbkgnd1 = base + 0x54;
const displist1 = base + 0x24;
const dlist = base + 0x2000;

/// Where the PPF filter kernel goes in display list memory (11 words), past the lists.
const kernel_at: u32 = 4064;

/// Mitchell-Netravali (B = C = 1/3), as the vc4 driver uploads it: 32 coefficients, 3 a word.
const filter_kernel = blk: {
    const c = [32]i32{ 0, -1, -4, -7, -9, -9, -6, 1, 14, 36, 66, 101, 137, 171, 200, 220, 228, 220, 200, 171, 137, 101, 66, 36, 14, 1, -6, -9, -9, -7, -4, -1 };
    const word = struct {
        fn f(a: i32, b: i32, d: i32) u32 {
            return @as(u32, @bitCast(a)) & 0x1ff | (@as(u32, @bitCast(b)) & 0x1ff) << 9 | (@as(u32, @bitCast(d)) & 0x1ff) << 18;
        }
    }.f;
    break :blk [11]u32{ word(c[0], c[1], c[2]), word(c[3], c[4], c[5]), word(c[6], c[7], c[8]), word(c[9], c[10], c[11]), word(c[12], c[13], c[14]), word(c[15], c[16], 0), word(c[19], c[18], c[17]), word(c[22], c[21], c[20]), word(c[25], c[24], c[23]), word(c[28], c[27], c[26]), word(c[31], c[30], c[29]) };
};

const Scale = enum { none, ppf, tpz };

const Plane = struct {
    format: u4 = 7,
    order: u2 = 0,
    expand: u2 = 3,
    /// 0 linear, 1-2 SAND 64/128-byte columns, 3 T-format (or SAND 256).
    tiling: u2 = 0,
    hflip: bool = false,
    vflip: bool = false,
    alpha_mode: u2 = 0,
    premult: bool = false,
    mix: bool = false,
    fixed_alpha: u8 = 0xff,
    x: u32,
    y: u32,
    src_w: u32,
    src_h: u32,
    dst_w: u32 = 0,
    dst_h: u32 = 0,
    ptrs: [3]u32,
    pitches: [3]u32,
    planes: u2 = 1,
    yuv: bool = false,
    /// Each channel's horizontal and vertical scaling (channel 1: chroma, for YUV).
    scale: [2][2]Scale = .{ .{ .none, .none }, .{ .none, .none } },
};

fn scl(s: [2]Scale) u3 {
    return switch (s[0]) {
        .ppf => switch (s[1]) {
            .ppf => 0,
            .tpz => 2,
            .none => 4,
        },
        .tpz => switch (s[1]) {
            .ppf => 1,
            .tpz => 3,
            .none => 7,
        },
        .none => switch (s[1]) {
            .ppf => 5,
            .tpz => 6,
            .none => 0,
        },
    };
}

/// Writes `p` at word `at` of display list memory: the words it took.
fn writePlane(at: u32, p: Plane) u32 {
    var words: [48]u32 = undefined;
    var n: usize = 0;
    const put = struct {
        fn f(ws: *[48]u32, i: *usize, v: u32) void {
            ws[i.*] = v;
            i.* += 1;
        }
    }.f;
    const unity = p.scale[0][0] == .none and p.scale[0][1] == .none and p.scale[1][0] == .none and p.scale[1][1] == .none;
    put(&words, &n, 1 << 30 | @as(u32, @intFromBool(p.hflip)) << 16 | @as(u32, @intFromBool(p.vflip)) << 15 |
        @as(u32, p.expand) << 11 | @as(u32, p.order) << 13 | p.format | @as(u32, p.tiling) << 20 |
        @as(u32, @intFromBool(unity)) << 4 | @as(u32, scl(p.scale[0])) << 5 | @as(u32, scl(p.scale[1])) << 8);
    put(&words, &n, @as(u32, p.fixed_alpha) << 24 | (p.y & 0xfff) << 12 | (p.x & 0xfff));
    if (!unity) put(&words, &n, (p.dst_h & 0xfff) << 16 | (p.dst_w & 0xfff));
    put(&words, &n, @as(u32, p.alpha_mode) << 30 | @as(u32, @intFromBool(p.premult)) << 29 | @as(u32, @intFromBool(p.mix)) << 28 | (p.src_h & 0xfff) << 16 | (p.src_w & 0xfff));
    put(&words, &n, 0xc0c0c0c0);
    for (0..p.planes) |i| put(&words, &n, p.ptrs[i]);
    for (0..p.planes) |_| put(&words, &n, 0xc0c0c0c0);
    for (0..p.planes) |i| put(&words, &n, p.pitches[i]);
    if (p.yuv) {
        // BT.601, limited range.
        put(&words, &n, 0x00f00000);
        put(&words, &n, 0xe73304a8);
        put(&words, &n, 0x00066604);
    }
    if (!unity) {
        const vertical = p.scale[0][1] != .none or p.scale[1][1] != .none;
        // The line buffer, at its start.
        if (vertical) put(&words, &n, 0);
        var ppf = false;
        const channels: usize = if (p.planes > 1) 2 else 1;
        var ch = channels;
        while (ch > 0) {
            ch -= 1;
            // Chroma is half the luma's size in a subsampled plane.
            const sub: u32 = if (ch == 1 and p.planes > 1) 2 else 1;
            const sizes = [2][2]u32{ .{ p.src_w / sub, p.dst_w }, .{ p.src_h / sub, p.dst_h } };
            for (0..2) |axis| {
                const s = sizes[axis];
                switch (p.scale[ch][axis]) {
                    .ppf => {
                        ppf = true;
                        put(&words, &n, 1 << 30 | (((s[0] << 16) / s[1]) & 0x1ffff) << 8);
                        if (axis == 1) put(&words, &n, 0xc0c0c0c0);
                    },
                    .tpz => {
                        const scale = (s[0] << 16) / s[1];
                        put(&words, &n, (scale & 0x1fffff) << 8);
                        put(&words, &n, (0xffffffff / scale) & 0xffff);
                        if (axis == 1) put(&words, &n, 0xc0c0c0c0);
                    },
                    .none => {},
                }
            }
        }
        if (ppf) for (0..4) |_| put(&words, &n, kernel_at);
    }
    words[0] |= @as(u32, @intCast(n)) << 24;
    for (words[0..n], 0..) |v, i| hw.write(dlist + (at + i) * 4, v);
    return @intCast(n);
}

/// Shows the planes `build` lays out (into the half of display list memory not on show) for
/// `frames` vblanks.
fn show(f: *u64, frames: usize, ctx: anytype, comptime build: anytype) void {
    var next = hw.timer.now();
    for (0..frames) |_| {
        const start: u32 = if (f.* % 2 == 0) 0 else 2000;
        f.* += 1;
        const end = build(ctx, start);
        hw.write(dlist + end * 4, 1 << 31);
        hw.write(displist1, start);
        next += 16_667;
        hw.timer.waitUntil(next);
    }
}

pub fn features(p: main.Params, r: *main.Result) void {
    const w: u32 = @min(p.width, 2048);
    const h: u32 = @min(p.height, 2048);
    // Pixels: pseudo-random bytes, enough for any plane here.
    const mem = hw.heap.alloc(u32, 4 << 20 >> 2, 4096);
    var seed: u32 = 0x9e3779b9;
    for (mem) |*v| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        v.* = seed;
    }
    const at = hw.bus(mem.ptr);
    for (filter_kernel, 0..) |v, i| hw.write(dlist + (kernel_at + i) * 4, v);
    hw.write(dispctrl, hw.read(dispctrl) | 1 << 31);
    const per = p.amount(30);
    var flips: u64 = 0;
    var planes: u64 = 0;

    // Every RGB format, in each pixel order, and each alpha expansion: a grid of 64-pixel planes.
    const Ctx = struct { w: u32, h: u32, at: u32, planes: *u64 };
    const ctx: Ctx = .{ .w = w, .h = h, .at = at, .planes = &planes };
    show(&flips, per, ctx, struct {
        fn b(c: Ctx, start: u32) u32 {
            var a = start;
            for (0..8) |fmt| {
                const bpp: u32 = switch (fmt) {
                    0 => 1,
                    1, 2, 3, 4 => 2,
                    5 => 3,
                    else => 4,
                };
                for (0..4) |order| {
                    for (0..2) |ex| {
                        const x: u32 = @intCast((order * 2 + ex) * 70);
                        a += writePlane(a, .{ .format = @intCast(fmt), .order = @intCast(order), .expand = @intCast(ex * 3), .x = x, .y = @intCast(fmt * 70), .src_w = 64, .src_h = 64, .ptrs = .{ c.at, 0, 0 }, .pitches = .{ 64 * bpp, 0, 0 } });
                        c.planes.* += 1;
                    }
                }
            }
            return a;
        }
    }.b);

    // Tiled (T-format RGBA8888 and RGB565, a whole plane's tiles), flipped each way, and each alpha
    // mode (premultiplied, mixed with a fixed alpha).
    show(&flips, per, ctx, struct {
        fn b(c: Ctx, start: u32) u32 {
            var a = start;
            // T-format: 32-pixel (RGBA8888) or 64-pixel (RGB565) tiles; pitch 0 gives tiles left
            // and right of the start.
            a += writePlane(a, .{ .format = 7, .tiling = 3, .x = 0, .y = 0, .src_w = 256, .src_h = 256, .ptrs = .{ c.at, 0, 0 }, .pitches = .{ 8, 0, 0 } });
            a += writePlane(a, .{ .format = 4, .tiling = 3, .x = 260, .y = 0, .src_w = 256, .src_h = 256, .ptrs = .{ c.at, 0, 0 }, .pitches = .{ 4, 0, 0 } });
            for (0..3) |k| {
                a += writePlane(a, .{ .hflip = k != 1, .vflip = k != 0, .x = @intCast(520 + k * 140), .y = 0, .src_w = 128, .src_h = 128, .ptrs = .{ c.at, 0, 0 }, .pitches = .{ 512, 0, 0 } });
            }
            for (0..4) |mode| {
                for (0..4) |v| {
                    a += writePlane(a, .{ .alpha_mode = @intCast(mode), .premult = v & 1 != 0, .mix = v & 2 != 0, .fixed_alpha = 0x80, .x = @intCast(v * 140), .y = @intCast(300 + mode * 70), .src_w = 128, .src_h = 64, .ptrs = .{ c.at + 4096, 0, 0 }, .pitches = .{ 512, 0, 0 } });
                }
            }
            c.planes.* += 21;
            return a;
        }
    }.b);

    // Scaling: each mode (PPF up, TPZ down, each way and mixed), of RGBA8888.
    show(&flips, per, ctx, struct {
        fn b(c: Ctx, start: u32) u32 {
            var a = start;
            const modes = [8][2]Scale{ .{ .ppf, .ppf }, .{ .tpz, .ppf }, .{ .ppf, .tpz }, .{ .tpz, .tpz }, .{ .ppf, .none }, .{ .none, .ppf }, .{ .none, .tpz }, .{ .tpz, .none } };
            for (modes, 0..) |m, i| {
                const dw: u32 = switch (m[0]) {
                    .ppf => 300,
                    .tpz => 60,
                    .none => 128,
                };
                const dh: u32 = switch (m[1]) {
                    .ppf => 200,
                    .tpz => 40,
                    .none => 96,
                };
                a += writePlane(a, .{ .x = @intCast((i % 4) * 310), .y = @intCast((i / 4) * 210), .src_w = 128, .src_h = 96, .dst_w = dw, .dst_h = dh, .ptrs = .{ c.at, 0, 0 }, .pitches = .{ 512, 0, 0 }, .scale = .{ m, .{ .none, .none } } });
            }
            c.planes.* += 8;
            return a;
        }
    }.b);

    // YUV: 4:2:0 and 4:2:2 in 3 and 2 planes (chroma scaled up to the luma), SAND-tiled 2-plane,
    // 4:4:4 as RGB, and scaled YUV.
    show(&flips, per, ctx, struct {
        fn b(c: Ctx, start: u32) u32 {
            var a = start;
            const yuv = [_]struct { fmt: u4, planes: u2, vsub: bool, tiling: u2 = 0 }{
                .{ .fmt = 8, .planes = 3, .vsub = true },
                .{ .fmt = 9, .planes = 2, .vsub = true },
                .{ .fmt = 10, .planes = 3, .vsub = false },
                .{ .fmt = 11, .planes = 2, .vsub = false },
                .{ .fmt = 9, .planes = 2, .vsub = true, .tiling = 2 },
            };
            for (yuv, 0..) |y, i| {
                const chroma_pitch: u32 = if (y.planes == 3) 64 else 128;
                a += writePlane(a, .{
                    .format = y.fmt,
                    .tiling = y.tiling,
                    .yuv = true,
                    .planes = y.planes,
                    .x = @intCast(i * 140),
                    .y = 0,
                    .src_w = 128,
                    .src_h = 128,
                    .dst_w = 128,
                    .dst_h = 128,
                    .ptrs = .{ c.at, c.at + 0x10000, c.at + 0x20000 },
                    .pitches = .{ if (y.tiling == 0) 128 else 256, chroma_pitch, chroma_pitch },
                    .scale = .{ .{ .none, .none }, .{ .ppf, if (y.vsub) .ppf else .none } },
                });
            }
            a += writePlane(a, .{ .format = 14, .x = 0, .y = 200, .src_w = 128, .src_h = 128, .ptrs = .{ c.at, 0, 0 }, .pitches = .{ 384, 0, 0 } });
            a += writePlane(a, .{ .format = 15, .x = 140, .y = 200, .src_w = 128, .src_h = 128, .ptrs = .{ c.at, 0, 0 }, .pitches = .{ 512, 0, 0 } });
            a += writePlane(a, .{ .format = 8, .yuv = true, .planes = 3, .x = 280, .y = 200, .src_w = 128, .src_h = 128, .dst_w = 400, .dst_h = 300, .ptrs = .{ c.at, c.at + 0x10000, c.at + 0x20000 }, .pitches = .{ 128, 64, 64 }, .scale = .{ .{ .ppf, .ppf }, .{ .ppf, .ppf } } });
            c.planes.* += 8;
            return a;
        }
    }.b);

    // Background fill colours (over a partly covered display), changing each frame.
    {
        var next = hw.timer.now();
        for (0..per) |i| {
            hw.write(dispbkgnd1, 1 << 24 | @as(u32, @intCast(i * 0x050301 & 0xffffff)));
            next += 16_667;
            hw.timer.waitUntil(next);
        }
        hw.write(dispbkgnd1, 1 << 24);
    }

    // Many planes: a list of 100 small ones.
    show(&flips, per, ctx, struct {
        fn b(c: Ctx, start: u32) u32 {
            var a = start;
            for (0..100) |i| {
                a += writePlane(a, .{ .alpha_mode = 0, .x = @intCast((i % 20) * (c.w / 20)), .y = @intCast((i / 20) * (c.h / 5)), .src_w = 48, .src_h = 48, .ptrs = .{ c.at + @as(u32, @intCast(i)) * 256, 0, 0 }, .pitches = .{ 192, 0, 0 } });
            }
            c.planes.* += 100;
            return a;
        }
    }.b);

    r.add("frames", flips + per);
    r.add("planes", planes);
}
