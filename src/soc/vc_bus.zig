//! VideoCore bus addresses of SDRAM. Bits 31:30 pick a cache alias; the rest address SDRAM, wrapping
//! at the board's RAM size, so a bus master never reaches past the RAM that is fitted.

const std = @import("std");

/// The bits of a bus address that select a byte of a board's `ram_len` bytes of SDRAM.
pub inline fn ramMask(ram_len: usize) u32 {
    const size = std.math.ceilPowerOfTwoAssert(usize, @max(ram_len, 1));
    return @intCast(@min(size, 1 << 30) - 1);
}

test "bus addresses wrap at the board's RAM size" {
    try std.testing.expectEqual(@as(u32, 0x1fff_ffff), ramMask(512 * 1024 * 1024));
    try std.testing.expectEqual(@as(u32, 0x3fff_ffff), ramMask(1024 * 1024 * 1024));
    try std.testing.expectEqual(@as(u32, 0x1000), 0xe000_1000 & ramMask(512 * 1024 * 1024));
}
