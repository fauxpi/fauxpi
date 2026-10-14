//! BCM2835 1 MHz 64-bit System Timer (`brcm,bcm2835-system-timer` at `0x20003000`).
//!
//! Implements the 64-bit free-running counter (`CLO`/`CHI`) and 4 compare
//! channels (`C0..C3`) with match status bits in `CS` (driving Bank 1 IRQs `0..3`).
//! Also supports fast-forwarding to the next armed compare match when the
//! ARM CPU executes `WFI`.

const std = @import("std");
const IntController = @import("intc.zig").IntController;

pub const SystemTimer = struct {
    /// Control / Status register (`0x00`, bits 3:0 = M3..M0 match flags, write-1-to-clear)
    cs: u32 = 0,
    /// 64-bit 1 MHz counter (microseconds since boot)
    counter: u64 = 0,
    /// 4 32-bit compare registers (`C0..C3` at `0x0c..0x18`)
    compare: [4]u32 = @splat(0),
    /// Tracks which compare channels have been written and are awaiting match
    armed: [4]bool = @splat(false),

    /// Advances the 1 MHz timer by `delta_us` microseconds and updates IRQs `1:0..3`.
    pub fn advance(self: *SystemTimer, delta_us: u64, intc: *IntController) void {
        if (delta_us == 0) return;
        const prev_lo: u32 = @truncate(self.counter);
        self.counter +%= delta_us;
        const cur_lo: u32 = @truncate(self.counter);

        inline for (0..4) |i| {
            if (self.armed[i]) {
                const cmp = self.compare[i];
                const diff_before = cmp -% prev_lo;
                const matched = if (delta_us >= 0x1_0000_0000)
                    true
                else if (diff_before > 0 and diff_before <= @as(u32, @truncate(delta_us)))
                    true
                else
                    (cur_lo == cmp);

                if (matched) {
                    self.cs |= (@as(u32, 1) << @intCast(i));
                    self.armed[i] = false;
                }
            }
        }
        self.syncIrqs(intc);
    }

    /// Returns the number of microseconds until the next armed compare channel fires
    /// (capped at `max_us`). Used to fast-forward idle time when the CPU executes `WFI`.
    pub fn usUntilNextMatch(self: *const SystemTimer, max_us: u64) u64 {
        var min_wait: u64 = max_us;
        const cur_lo: u32 = @truncate(self.counter);
        inline for (0..4) |i| {
            if (self.armed[i]) {
                const diff: u32 = self.compare[i] -% cur_lo;
                const wait: u64 = if (diff == 0) 1 else diff;
                if (wait < min_wait) min_wait = wait;
            }
        }
        return min_wait;
    }

    pub fn syncIrqs(self: *const SystemTimer, intc: *IntController) void {
        inline for (0..4) |i| {
            intc.setIrq(1, @intCast(i), (self.cs & (@as(u32, 1) << @intCast(i))) != 0);
        }
    }

    pub fn read32(self: *const SystemTimer, offset: u32) u32 {
        return switch (offset) {
            0x00 => self.cs,
            0x04 => @truncate(self.counter), // CLO
            0x08 => @truncate(self.counter >> 32), // CHI
            0x0c => self.compare[0],
            0x10 => self.compare[1],
            0x14 => self.compare[2],
            0x18 => self.compare[3],
            else => 0,
        };
    }

    pub fn write32(self: *SystemTimer, offset: u32, val: u32, intc: *IntController) void {
        switch (offset) {
            0x00 => {
                // Write 1 to clear match status bits 3:0
                self.cs &= ~(val & 0xf);
                self.syncIrqs(intc);
            },
            0x0c, 0x10, 0x14, 0x18 => {
                const idx = (offset - 0x0c) >> 2;
                self.compare[idx] = val;
                self.armed[idx] = true;
                // If written with current CLO, fire on next tick
            },
            else => {},
        }
    }
};

test "BCM2835 System Timer compare match and WFI fast-forward" {
    var intc: IntController = .{};
    intc.write32(0x10, 1 << 3); // Enable Timer 3 IRQ

    var timer: SystemTimer = .{};
    timer.write32(0x18, 500, &intc); // Arm C3 at 500 us
    try std.testing.expectEqual(@as(u64, 500), timer.usUntilNextMatch(10000));

    timer.advance(500, &intc);
    try std.testing.expectEqual(@as(u32, 1 << 3), timer.read32(0x00));
    try std.testing.expect(intc.hasPendingIrq());

    // Clear match flag
    timer.write32(0x00, 1 << 3, &intc);
    try std.testing.expect(!intc.hasPendingIrq());
}
