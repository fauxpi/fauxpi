//! The BCM2835's devices the benchmark uses, at their ARM physical addresses (no MMU): the serial
//! port, the system timer, the power manager's watchdog (to end the run), the DMA engine, and
//! memory for the tests.

const std = @import("std");

pub const peripherals: usize = 0x2000_0000;

pub inline fn read(addr: usize) u32 {
    return @as(*const volatile u32, @ptrFromInt(addr)).*;
}

pub inline fn write(addr: usize, v: u32) void {
    @as(*volatile u32, @ptrFromInt(addr)).* = v;
}

/// What the GPU and DMA engine call an address in RAM: the uncached alias (the ARM's data cache
/// is off, so nothing is waiting to be written back).
pub fn bus(ptr: anytype) u32 {
    const addr: usize = switch (@typeInfo(@TypeOf(ptr))) {
        .pointer => |info| if (info.size == .slice) @intFromPtr(ptr.ptr) else @intFromPtr(ptr),
        else => ptr,
    };
    return @as(u32, @intCast(addr)) | 0xc000_0000;
}

/// `v`, as far as the compiler knows, anything: what a test computes is kept.
pub fn opaque32(v: anytype) @TypeOf(v) {
    var x = v;
    asm volatile (""
        : [x] "+r" (x),
    );
    return x;
}

/// The PL011 serial port (UART0), at the speed the firmware set.
const uart_dr = peripherals + 0x20_1000;
const uart_fr = peripherals + 0x20_1018;

fn putc(c: u8) void {
    // Wait while the transmit FIFO is full.
    while (read(uart_fr) & (1 << 5) != 0) {}
    write(uart_dr, c);
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
    for (s) |c| {
        if (c == '\n') putc('\r');
        putc(c);
    }
}

/// The 1 MHz system timer.
pub const timer = struct {
    const clo = peripherals + 0x3004;
    const chi = peripherals + 0x3008;

    /// Microseconds since the board started.
    pub fn now() u64 {
        while (true) {
            const hi = read(chi);
            const lo = read(clo);
            if (read(chi) == hi) return (@as(u64, hi) << 32) | lo;
        }
    }

    pub fn waitUntil(us: u64) void {
        while (now() < us) {}
    }
};

/// Resets the board (the watchdog, at once): how the run ends.
pub fn reset() noreturn {
    const password: u32 = 0x5a00_0000;
    write(peripherals + 0x10_0024, password | 10); // PM_WDOG: 10 ticks
    write(peripherals + 0x10_001c, password | 0x20); // PM_RSTC: full reset
    while (true) asm volatile ("wfe");
}

/// Memory for the tests, above what the firmware loads (the kernel at 0x8000, the device tree at
/// 63 MiB, an initramfs at 64 MiB), handed out in order and taken back between tests.
pub const heap = struct {
    const start: usize = 0x0500_0000;
    const limit: usize = 0x1c00_0000;
    var next: usize = start;

    pub fn reset() void {
        next = start;
    }

    /// `n` `T`s at `alignment` bytes (at least 16).
    pub fn alloc(comptime T: type, n: usize, alignment: usize) []T {
        const a = @max(alignment, 16);
        const addr = std.mem.alignForward(usize, next, a);
        const end = addr + n * @sizeOf(T);
        if (end > limit) @panic("out of benchmark memory");
        next = end;
        return @as([*]T, @ptrFromInt(addr))[0..n];
    }
};

/// The DMA engine's channel 0.
pub const dma = struct {
    const base = peripherals + 0x7000;
    const cs = base + 0x00;
    const conblk_ad = base + 0x04;
    const enable = base + 0xff0;

    const ControlBlock = extern struct {
        ti: u32,
        source_ad: u32,
        dest_ad: u32,
        txfr_len: u32,
        stride: u32 = 0,
        nextconbk: u32 = 0,
        reserved: [2]u32 = @splat(0),
    };

    var block: ControlBlock align(32) = undefined;

    /// Copies `src` to `dst` (the same length, at most 1 GiB), waiting until it is done.
    pub fn copy(dst: []u8, src: []const u8) void {
        write(enable, read(enable) | 1);
        // Source and destination incrementing, bursts of 8, waiting for writes.
        block = .{
            .ti = (1 << 8) | (1 << 4) | (1 << 3) | (7 << 12),
            .source_ad = bus(src),
            .dest_ad = bus(dst),
            .txfr_len = @intCast(@min(dst.len, src.len)),
        };
        // END (written 1 to clear), then go.
        write(cs, 1 << 1);
        write(conblk_ad, bus(&block));
        write(cs, 1);
        while (read(cs) & 1 != 0) {}
        write(cs, 1 << 1);
    }
};
