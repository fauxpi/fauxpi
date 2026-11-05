//! FauxPi's bare-metal benchmark: a `kernel.img` for the Raspberry Pi Zero (BCM2835) that runs
//! one test (or all of them) straight on the hardware, with no operating system, and resets the
//! board when done. Each test prints, on the serial port (PL011, as the firmware leaves it):
//!
//!     BENCH-BEGIN <test>
//!     BENCH-END <test> guest_us=<µs> <name>=<value> ...
//!
//! and the suite `BENCH-DONE`. `guest_us` is the board's own time (its 1 MHz system timer): on
//! FauxPi, emulated time; the host's time between the lines is for `bench/run.zig` to take.
//!
//! What runs is chosen by patching `config` in `kernel.img` (found by its magic): see `Config`.

const std = @import("std");
const hw = @import("hw.zig");
const v3d = @import("v3d.zig");
const hvs = @import("hvs.zig");
const bench_tests = @import("bench_tests");

/// What to run: patched into kernel.img by the runner (found by `magic`).
pub const Config = extern struct {
    magic: [16]u8 = "FAUXPI-BENCH-CFG".*,
    /// The test's name, or "all", NUL-padded.
    test_name: [32]u8 = padded("all"),
    /// How much work: 100 is each test's usual amount; 1 to 10000.
    scale: u32 = 100,
    /// The framebuffer the GPU tests draw.
    width: u32 = 1280,
    height: u32 = 720,
    reserved: [9]u32 = @splat(0),
};

fn padded(comptime name: []const u8) [32]u8 {
    var out: [32]u8 = @splat(0);
    @memcpy(out[0..name.len], name);
    return out;
}

export const config: Config linksection(".rodata.config") = .{};

/// The config as patched (not what the compiler saw): read a word at a time, each volatile (a
/// volatile read of the whole struct is copied from the compiler's own copy).
fn readConfig() Config {
    var c: Config = undefined;
    const src: [*]const volatile u32 = @ptrCast(&config);
    const dst: [*]u32 = @ptrCast(&c);
    for (0..@sizeOf(Config) / 4) |i| dst[i] = src[i];
    return c;
}

export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
        \\ ldr sp, =0x00800000
        // VFP on: full access to coprocessors 10 and 11, then FPEXC.EN.
        \\ mrc p15, 0, r0, c1, c0, 2
        \\ orr r0, r0, #0x00f00000
        \\ mcr p15, 0, r0, c1, c0, 2
        \\ mov r0, #0
        \\ mcr p15, 0, r0, c7, c5, 4
        \\ mov r0, #0x40000000
        \\ vmsr fpexc, r0
        // The instruction cache and branch prediction on (the data cache needs the MMU), and
        // ARMv6's unaligned loads and stores (U), which the compiler counts on, not ARMv5's
        // rotated words; no alignment faults (A).
        \\ mrc p15, 0, r0, c1, c0, 0
        \\ orr r0, r0, #0x1800
        \\ orr r0, r0, #0x400000
        \\ bic r0, r0, #0x2
        \\ mcr p15, 0, r0, c1, c0, 0
        \\ b kmain
    );
}

extern var __bss_start: u8;
extern var __bss_end: u8;

export fn kmain() noreturn {
    const bss_len = @intFromPtr(&__bss_end) - @intFromPtr(&__bss_start);
    @memset(@as([*]u8, @ptrCast(&__bss_start))[0..bss_len], 0);

    const cfg = readConfig();
    const name = std.mem.sliceTo(&cfg.test_name, 0);
    const scale = std.math.clamp(cfg.scale, 1, 10000);
    hw.print("BENCH-START tests={s} scale={d} size={d}x{d}\n", .{ name, scale, cfg.width, cfg.height });
    var ran: usize = 0;
    for (tests) |t| {
        if (!std.mem.eql(u8, name, "all") and !std.mem.eql(u8, name, t.name)) continue;
        hw.print("BENCH-BEGIN {s}\n", .{t.name});
        hw.heap.reset();
        const start = hw.timer.now();
        var result: Result = .{};
        t.run(.{ .scale = scale, .width = cfg.width, .height = cfg.height }, &result);
        const us = hw.timer.now() - start;
        hw.print("BENCH-END {s} guest_us={d}", .{ t.name, us });
        for (result.values[0..result.len]) |v| hw.print(" {s}={d}", .{ v.name, v.value });
        hw.print("\n", .{});
        ran += 1;
    }
    if (ran == 0) hw.print("BENCH-ERROR no test named {s}\n", .{name});
    hw.print("BENCH-DONE\n", .{});
    hw.reset();
}

/// What a test was given.
pub const Params = struct {
    scale: u32,
    width: u32,
    height: u32,

    /// `usual` times the scale (100 is usual), at least 1.
    pub fn amount(p: Params, usual: u64) usize {
        return @intCast(@max(usual * p.scale / 100, 1));
    }
};

/// What a test reports besides its time: named counts (what it did, and checksums, which also
/// keep the work from being optimized away).
pub const Result = struct {
    values: [8]struct { name: []const u8, value: u64 } = undefined,
    len: usize = 0,

    pub fn add(r: *Result, name: []const u8, value: u64) void {
        if (r.len == r.values.len) return;
        r.values[r.len] = .{ .name = name, .value = value };
        r.len += 1;
    }
};

const Test = struct {
    name: []const u8,
    run: *const fn (Params, *Result) void,
};

comptime {
    // The same tests, in the same order, as the runner knows.
    if (tests.len != bench_tests.all.len) @compileError("bench/tests.zig lists other tests");
    for (tests, bench_tests.all) |t, known| {
        if (!std.mem.eql(u8, t.name, known.name)) @compileError("bench/tests.zig lists " ++ known.name ++ ", not " ++ t.name);
    }
}

const tests = [_]Test{
    .{ .name = "cpu_int", .run = cpuInt },
    .{ .name = "cpu_branch", .run = cpuBranch },
    .{ .name = "cpu_call", .run = cpuCall },
    .{ .name = "cpu_float", .run = cpuFloat },
    .{ .name = "cpu_memcpy", .run = cpuMemcpy },
    .{ .name = "dma_copy", .run = dmaCopy },
    .{ .name = "v3d_clear", .run = v3d.clear },
    .{ .name = "v3d_triangles", .run = v3d.triangles },
    .{ .name = "v3d_fill", .run = v3d.fill },
    .{ .name = "v3d_texture", .run = v3d.texture },
    .{ .name = "v3d_blend", .run = v3d.blend },
    .{ .name = "v3d_draws", .run = v3d.draws },
    .{ .name = "hvs_planes", .run = hvs.planes },
};

/// Integer arithmetic in a tight loop: xorshift.
fn cpuInt(p: Params, r: *Result) void {
    const n = p.amount(20_000_000);
    var x: u32 = 2463534242;
    var sum: u32 = 0;
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        sum +%= x;
    }
    r.add("iterations", n);
    r.add("checksum", hw.opaque32(sum));
}

/// Branchy code over memory: a sieve of Eratosthenes.
fn cpuBranch(p: Params, r: *Result) void {
    const n: usize = @intCast(p.amount(4_000_000));
    const sieve = hw.heap.alloc(u8, n, 4);
    @memset(sieve, 1);
    var primes: u64 = 0;
    var i: usize = 2;
    while (i < n) : (i += 1) {
        if (sieve[i] == 0) continue;
        primes += 1;
        var j = i * i;
        while (j < n) : (j += i) sieve[j] = 0;
    }
    r.add("limit", n);
    r.add("primes", primes);
}

/// Calls and returns: recursive Fibonacci.
fn cpuCall(p: Params, r: *Result) void {
    // About 1.6 times the calls each step: 27 is about 630,000 calls.
    const extra = std.math.log2_int(u64, p.amount(100)) -| std.math.log2_int(u64, 100);
    const n: u32 = @intCast(@min(25 + extra, 34));
    r.add("n", n);
    r.add("fib", fib(hw.opaque32(n)));
}

fn fib(n: u32) u32 {
    return if (n < 2) n else fib(n - 1) +% fib(n - 2);
}

/// VFP floating point: a Mandelbrot set.
fn cpuFloat(p: Params, r: *Result) void {
    const rows: u32 = @intCast(@min(p.amount(240), 4000));
    const cols: u32 = 320;
    var total: u64 = 0;
    for (0..rows) |y| {
        for (0..cols) |x| {
            const cr = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(cols)) * 3.0 - 2.0;
            const ci = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(rows)) * 2.0 - 1.0;
            var zr: f32 = 0;
            var zi: f32 = 0;
            var k: u32 = 0;
            while (k < 64 and zr * zr + zi * zi < 4.0) : (k += 1) {
                const t = zr * zr - zi * zi + cr;
                zi = 2.0 * zr * zi + ci;
                zr = t;
            }
            total += k;
        }
    }
    r.add("pixels", @as(u64, rows) * cols);
    r.add("iterations", total);
}

/// Memory bandwidth: copying 8 MiB, again and again.
fn cpuMemcpy(p: Params, r: *Result) void {
    const size = 8 << 20;
    const src = hw.heap.alloc(u8, size, 64);
    const dst = hw.heap.alloc(u8, size, 64);
    for (src, 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 7);
    const n = p.amount(8);
    for (0..n) |_| @memcpy(dst, src);
    r.add("bytes", size * n);
    r.add("checksum", hw.opaque32(dst[12345] +% dst[size - 1]));
}

/// The DMA engine copying memory, a control block at a time.
fn dmaCopy(p: Params, r: *Result) void {
    const size = 4 << 20;
    const src = hw.heap.alloc(u8, size, 4096);
    const dst = hw.heap.alloc(u8, size, 4096);
    for (src, 0..) |*b, i| b.* = @truncate(i);
    const n = p.amount(16);
    for (0..n) |_| hw.dma.copy(dst, src);
    var ok: u64 = 0;
    for (0..64) |i| {
        if (dst[i * 4093] == src[i * 4093]) ok += 1;
    }
    r.add("bytes", size * n);
    r.add("checked", ok);
}

pub const panic = std.debug.FullPanic(panicked);

fn panicked(msg: []const u8, _: ?usize) noreturn {
    hw.print("BENCH-ERROR panic: {s}\n", .{msg});
    hw.print("BENCH-DONE\n", .{});
    hw.reset();
}
