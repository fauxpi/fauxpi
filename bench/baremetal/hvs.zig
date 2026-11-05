//! The HVS test: a display of a full-screen plane and translucent planes moving over it, a new
//! display list each 60th of a second. FauxPi composes the display on the host's vblank, so what
//! this costs is in FauxPi's report (`hvs_compose`), not the test's time, which the timer paces.

const std = @import("std");
const hw = @import("hw.zig");
const main = @import("main.zig");

const base = hw.peripherals + 0x40_0000;
const dispctrl = base + 0x00;
const displist1 = base + 0x24;
const dlist = base + 0x2000;

const ctl0_valid: u32 = 1 << 30;
const ctl0_end: u32 = 1 << 31;
const ctl0_unity: u32 = 1 << 4;
const format_rgba8888: u32 = 7;

/// Writes a unity (unscaled) RGBA8888 plane at `at` in the display list: `w` by `h` pixels at
/// `pixels`, at (x, y), blended by its own alpha (or opaque). The words it took.
fn unityPlane(at: usize, pixels: []const u32, w: u32, h: u32, x: u32, y: u32, opaque_plane: bool) usize {
    const words = [7]u32{
        ctl0_valid | (7 << 24) | ctl0_unity | format_rgba8888,
        (x & 0xfff) | ((y & 0xfff) << 12) | (0xff << 24),
        // Alpha: fixed (opaque), or the pixels' own.
        (if (opaque_plane) @as(u32, 1) << 30 else 0) | ((h & 0xfff) << 16) | (w & 0xfff),
        0,
        hw.bus(pixels.ptr),
        0,
        w * 4,
    };
    for (words, 0..) |v, i| hw.write(dlist + (at + i) * 4, v);
    return words.len;
}

/// Writes a scaled plane: `w` by `h` pixels at `pixels`, shown `dw` by `dh` at (x, y).
fn scaledPlane(at: usize, pixels: []const u32, w: u32, h: u32, x: u32, y: u32, dw: u32, dh: u32) usize {
    const words = [12]u32{
        ctl0_valid | (12 << 24) | format_rgba8888,
        (x & 0xfff) | ((y & 0xfff) << 12) | (0xff << 24),
        (dw & 0xfff) | ((dh & 0xfff) << 16),
        ((h & 0xfff) << 16) | (w & 0xfff),
        0,
        hw.bus(pixels.ptr),
        0,
        w * 4,
        // Line buffer and scaling parameters.
        0,
        0,
        0,
        0,
    };
    for (words, 0..) |v, i| hw.write(dlist + (at + i) * 4, v);
    return words.len;
}

pub fn planes(p: main.Params, r: *main.Result) void {
    // u32s: @min with 2048 alone would be a u12, and multiply as one.
    const w: u32 = @min(p.width, 2048);
    const h: u32 = @min(p.height, 2048);
    const background = hw.heap.alloc(u32, w * h, 4096);
    for (background, 0..) |*px, i| px.* = 0xff000000 | @as(u32, @intCast((i % w) * 255 / w)) << 16 | @as(u32, @intCast((i / w) * 255 / h));
    const size = 256;
    const sprite = hw.heap.alloc(u32, size * size, 4096);
    for (0..size) |y| {
        for (0..size) |x| {
            const dx = @as(i32, @intCast(x)) - 128;
            const dy = @as(i32, @intCast(y)) - 128;
            const inside = dx * dx + dy * dy < 128 * 128;
            sprite[y * size + x] = if (inside) 0x80c04020 | @as(u32, @intCast(x)) << 8 else 0;
        }
    }

    hw.write(dispctrl, hw.read(dispctrl) | (1 << 31));
    const frames = main.Params.amount(p, 300);
    var next = hw.timer.now();
    for (0..frames) |f| {
        // Each frame's list in the other half, so the shown one isn't changed under the HVS.
        const start: usize = if (f % 2 == 0) 0 else 2048;
        var at = start;
        at += unityPlane(at, background, w, h, 0, 0, true);
        for (0..8) |i| {
            const phase = (f * 4 + i * 97) % 1000;
            const x: u32 = @intCast(phase * (w - size) / 1000);
            const y: u32 = @intCast((i * 83 + f * 2) % (h - size));
            at += unityPlane(at, sprite, size, size, x, y, false);
        }
        at += scaledPlane(at, sprite, size, size, 16, 16, size / 2, size / 2);
        hw.write(dlist + at * 4, ctl0_end);
        hw.write(displist1, @intCast(start));
        next += 16_667;
        hw.timer.waitUntil(next);
    }
    r.add("frames", frames);
    r.add("planes", 10);
}
