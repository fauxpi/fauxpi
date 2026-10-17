//! Host-atomic helpers for guest RAM shared between cores running on parallel host threads.
//!
//! Store-exclusives (`STXR` / `STREX` and pairs) are emulated as a host compare-and-swap
//! against the value the matching load-exclusive returned: the store succeeds only if
//! no other core changed the location in between. This is the usual way to emulate
//! LL/SC on hosts (it cannot detect an A-B-A change, which guest locks do not depend on).

const std = @import("std");
const native_endian = @import("builtin").cpu.arch.endian();

/// Atomically replaces the little-endian `T` at `ram[paddr..]` with `desired` if it
/// still holds `expected`. Returns false if the location changed or is out of range.
pub inline fn compareAndSwap(comptime T: type, ram: []u8, paddr: u32, expected: T, desired: T) bool {
    const size = @sizeOf(T);
    if (@as(usize, paddr) + size > ram.len) return false;
    if (paddr % size != 0) {
        // Misaligned exclusives fault on hardware; fall back to a plain check-and-store.
        if (std.mem.readInt(T, ram[paddr..][0..size], .little) != expected) return false;
        std.mem.writeInt(T, ram[paddr..][0..size], desired, .little);
        return true;
    }
    const ptr: *T = @ptrCast(@alignCast(&ram[paddr]));
    const exp = if (native_endian == .little) expected else @byteSwap(expected);
    const des = if (native_endian == .little) desired else @byteSwap(desired);
    return @cmpxchgStrong(T, ptr, exp, des, .seq_cst, .seq_cst) == null;
}

/// True while `bus` runs cores on parallel host threads (buses without an `smp` field never do).
pub inline fn busParallel(bus: anytype) bool {
    const B = @TypeOf(bus.*);
    if (comptime !@hasField(B, "smp")) return false;
    return bus.smp.parallel;
}

/// Full host memory barrier for guest `DMB` / `DSB` and acquire/release accesses.
/// `word` should be private to the calling core so the barrier does not bounce a cache line.
pub inline fn fence(word: *u32) void {
    _ = @atomicRmw(u32, word, .Add, 0, .seq_cst);
}

test "compareAndSwap succeeds only while the location is unchanged" {
    var ram: [32]u8 align(16) = @splat(0);
    std.mem.writeInt(u64, ram[8..16], 5, .little);
    try std.testing.expect(compareAndSwap(u64, &ram, 8, 5, 9));
    try std.testing.expectEqual(@as(u64, 9), std.mem.readInt(u64, ram[8..16], .little));
    try std.testing.expect(!compareAndSwap(u64, &ram, 8, 5, 7));
    try std.testing.expectEqual(@as(u64, 9), std.mem.readInt(u64, ram[8..16], .little));

    std.mem.writeInt(u128, ram[16..32], 0x11_22, .little);
    try std.testing.expect(compareAndSwap(u128, &ram, 16, 0x11_22, 0x33_44));
    try std.testing.expectEqual(@as(u128, 0x33_44), std.mem.readInt(u128, ram[16..32], .little));

    try std.testing.expect(compareAndSwap(u16, &ram, 3, 0, 0xabcd));
    try std.testing.expect(!compareAndSwap(u32, &ram, 30, 0, 1));
}
