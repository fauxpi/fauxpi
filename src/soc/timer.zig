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

/// BCM2835 ARM Timer (`0x2000b400` / `0x3f00b400`, modified ARM SP804 driving Basic IRQ `0:0`).
///
/// Register map (BCM2835 ARM Peripherals Section 14, pp. 196–199):
/// - `0x00` `LOAD`: 32-bit Load register (writing also immediately reloads `VALUE`)
/// - `0x04` `VALUE`: 32-bit Current Value register (read-only)
/// - `0x08` `CONTROL`: Control register (bit 1 = 23/32-bit width, bits 3:2 = prescale `1`/`16`/`256`,
///   bit 5 = IRQ enable, bit 7 = timer enable, bit 9 = free-running counter enable, bits 23:16 = free-run pre-scaler)
/// - `0x0c` `IRQCLR`: IRQ Clear/Acknowledge (write-only, any write clears pending interrupt)
/// - `0x10` `RAWIRQ`: Raw IRQ status (`0` or `1`)
/// - `0x14` `MSKIRQ`: Masked IRQ status (`RAWIRQ & IRQ_EN`)
/// - `0x18` `RELOAD`: Reload register (updates `LOAD` without immediately overwriting `VALUE`)
/// - `0x1c` `PREDIV`: Pre-divider (`10-bit`, divides 250 MHz APB clock by `prediv + 1`, reset `0x7d`)
/// - `0x20` `CNT`: 32-bit free-running counter
pub const ArmTimer = struct {
    pub const BASE_ADDR: u32 = 0x2000b400;
    pub const SIZE: u32 = 0x40;
    pub const APB_CLOCK_PER_US: u64 = 250; // 250 MHz core/APB clock

    load: u32 = 0,
    value: u32 = 0xffff_ffff,
    control: u32 = 0x003e_0020,
    raw_irq: bool = false,
    reload: u32 = 0,
    prediv: u32 = 0x0000_007d,
    free_counter: u32 = 0,

    tick_rem_apb: u64 = 0,
    freerun_rem_apb: u64 = 0,

    pub inline fn isWideCounter(self: *const ArmTimer) bool {
        return (self.control & (1 << 1)) != 0;
    }

    pub inline fn isIrqEnabled(self: *const ArmTimer) bool {
        return (self.control & (1 << 5)) != 0;
    }

    pub inline fn isTimerEnabled(self: *const ArmTimer) bool {
        return (self.control & (1 << 7)) != 0;
    }

    pub inline fn isFreeRunEnabled(self: *const ArmTimer) bool {
        return (self.control & (1 << 9)) != 0;
    }

    pub inline fn irqPending(self: *const ArmTimer) bool {
        return self.raw_irq and self.isIrqEnabled();
    }

    pub fn prescaleFactor(self: *const ArmTimer) u64 {
        return switch (@as(u2, @truncate(self.control >> 2))) {
            0b00 => 1,
            0b01 => 16,
            0b10 => 256,
            0b11 => 1,
        };
    }

    pub fn totalDivider(self: *const ArmTimer) u64 {
        const pdiv: u64 = @as(u64, self.prediv & 0x3ff) + 1;
        return pdiv * self.prescaleFactor();
    }

    /// Advances the ARM Timer and its optional free-running counter by `delta_us` microseconds.
    pub fn advance(self: *ArmTimer, delta_us: u64, intc: *IntController) void {
        if (delta_us == 0) return;
        const apb_cycles: u64 = delta_us * APB_CLOCK_PER_US;

        if (self.isFreeRunEnabled()) {
            const fdiv: u64 = @as(u64, (self.control >> 16) & 0xff) + 1;
            self.freerun_rem_apb +%= apb_cycles;
            const fticks = self.freerun_rem_apb / fdiv;
            self.freerun_rem_apb %= fdiv;
            self.free_counter +%= @truncate(fticks);
        }

        if (self.isTimerEnabled()) {
            const div = self.totalDivider();
            self.tick_rem_apb +%= apb_cycles;
            const ticks = self.tick_rem_apb / div;
            self.tick_rem_apb %= div;

            if (ticks > 0) {
                const mask: u32 = if (self.isWideCounter()) 0xffff_ffff else 0x0000_ffff;
                const cur: u64 = self.value & mask;
                const rel: u64 = self.reload & mask;
                if (ticks <= cur) {
                    self.value = @intCast((cur - ticks) & mask);
                } else {
                    // Countdown reached 0 and wraps/reloads from `reload`
                    self.raw_irq = true;
                    const rem_after_zero = ticks - (cur + 1);
                    const period: u64 = rel + 1;
                    const offset_in_period = rem_after_zero % period;
                    self.value = @intCast((rel - offset_in_period) & mask);
                }
            }
        }
        intc.setIrq(0, 0, self.irqPending());
    }

    /// Returns the number of microseconds until the ARM Timer next asserts its IRQ (capped at `max_us`).
    pub fn usUntilNextMatch(self: *const ArmTimer, max_us: u64) u64 {
        if (!self.isTimerEnabled() or !self.isIrqEnabled()) return max_us;
        if (self.raw_irq) return 1;

        const mask: u32 = if (self.isWideCounter()) 0xffff_ffff else 0x0000_ffff;
        const ticks_until_wrap: u64 = @as(u64, self.value & mask) + 1;
        const div = self.totalDivider();
        const apb_needed = (ticks_until_wrap *| div) -| self.tick_rem_apb;
        const us_needed = @max((apb_needed + (APB_CLOCK_PER_US - 1)) / APB_CLOCK_PER_US, 1);
        return @min(us_needed, max_us);
    }

    pub fn read32(self: *const ArmTimer, offset: u32) u32 {
        return switch (offset) {
            0x00 => self.load,
            0x04 => if (self.isWideCounter()) self.value else (self.value & 0xffff),
            0x08 => self.control,
            0x0c => 0x544d_5241, // "ARMT" readback on write-only IRQCLR
            0x10 => @intFromBool(self.raw_irq),
            0x14 => @intFromBool(self.irqPending()),
            0x18 => self.reload,
            0x1c => self.prediv & 0x3ff,
            0x20 => self.free_counter,
            else => 0,
        };
    }

    pub fn write32(self: *ArmTimer, offset: u32, val: u32, intc: *IntController) void {
        switch (offset) {
            0x00 => { // LOAD
                self.load = val;
                self.reload = val;
                self.value = val;
                self.tick_rem_apb = 0;
            },
            0x08 => { // CONTROL
                self.control = val & 0x00ff_03ee;
            },
            0x0c => { // IRQCLR
                self.raw_irq = false;
            },
            0x18 => { // RELOAD
                self.load = val;
                self.reload = val;
            },
            0x1c => { // PREDIV
                self.prediv = val & 0x3ff;
            },
            else => {},
        }
        intc.setIrq(0, 0, self.irqPending());
    }
};

test "BCM2835 ArmTimer countdown, reload, free-running counter, and Basic IRQ 0" {
    var intc: IntController = .{};
    // Enable Basic IRQ 0 (ARM Timer)
    intc.write32(0x18, 1 << 0);

    var arm_timer: ArmTimer = .{};
    // Configure PREDIV = 249 (250 MHz / 250 = 1 MHz = 1 tick/us)
    arm_timer.write32(0x1c, 249, &intc);
    // Load 100 ticks (100 us until wrap from 0 -> reload)
    arm_timer.write32(0x00, 99, &intc);
    // Enable 32-bit counter (bit 1), IRQ enable (bit 5), Timer enable (bit 7), Free-run enable (bit 9) with div=249 (bits 23:16)
    arm_timer.write32(0x08, (249 << 16) | (1 << 9) | (1 << 7) | (1 << 5) | (1 << 1), &intc);

    try std.testing.expectEqual(@as(u64, 100), arm_timer.usUntilNextMatch(10000));
    try std.testing.expect(!intc.hasPendingIrq());

    // Advance 60 us -> value should be 39, free_counter = 60, no IRQ yet
    arm_timer.advance(60, &intc);
    try std.testing.expectEqual(@as(u32, 39), arm_timer.read32(0x04));
    try std.testing.expectEqual(@as(u32, 60), arm_timer.read32(0x20));
    try std.testing.expect(!intc.hasPendingIrq());

    // Advance 40 us -> reaches 0 and wraps to reload (99), latches IRQ
    arm_timer.advance(40, &intc);
    try std.testing.expectEqual(@as(u32, 99), arm_timer.read32(0x04));
    try std.testing.expectEqual(@as(u32, 1), arm_timer.read32(0x10)); // RAWIRQ
    try std.testing.expectEqual(@as(u32, 1), arm_timer.read32(0x14)); // MSKIRQ
    try std.testing.expect(intc.hasPendingIrq());
    try std.testing.expectEqual(@as(u32, 1 << 0), intc.read32(0x00)); // IRQ_BASIC_PENDING bit 0

    // Write IRQCLR (0x0c) -> clears pending IRQ
    arm_timer.write32(0x0c, 1, &intc);
    try std.testing.expectEqual(@as(u32, 0), arm_timer.read32(0x10));
    try std.testing.expect(!intc.hasPendingIrq());
}

