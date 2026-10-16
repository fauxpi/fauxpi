//! BCM2836 / BCM2837 ARM Local Peripherals & L1 Interrupt Controller (`bcm2836-l1-intc`)
//! mapped at physical address `0x40000000..0x40000fff`.
//!
//! Routes per-core ARMv7 Generic Timer interrupts (`CNTPSIRQ`, `CNTPNSIRQ`,
//! `CNTHPIRQ`, `CNTVIRQ`), per-core SMP IPI mailboxes (`Mailbox 0..3`), secondary
//! core wakeup addresses (`Mailbox 3`), and the VideoCore/BCM2835 peripheral
//! interrupt controller (`LOCAL_IRQ_GPU_FAST`, bit 8) to the 4 Cortex-A53 cores.

const std = @import("std");

pub const LocalIntc = struct {
    pub const BASE_ADDR: u32 = 0x4000_0000;
    pub const SIZE: u32 = 0x0000_1000;

    pub const LOCAL_CONTROL: u32 = 0x000;
    pub const LOCAL_PRESCALER: u32 = 0x008;
    pub const LOCAL_GPU_ROUTING: u32 = 0x00c;
    pub const LOCAL_PM_ROUTING_SET: u32 = 0x010;
    pub const LOCAL_PM_ROUTING_CLR: u32 = 0x014;
    pub const LOCAL_TIMER_LS: u32 = 0x01c;
    pub const LOCAL_TIMER_MS: u32 = 0x020;
    pub const LOCAL_INT_ROUTING: u32 = 0x024;
    pub const LOCAL_TIMER_CTRL: u32 = 0x034;
    pub const LOCAL_TIMER_FLAGS: u32 = 0x038;
    pub const LOCAL_TIMER_INT_CONTROL0: u32 = 0x040;
    pub const LOCAL_MAILBOX_INT_CONTROL0: u32 = 0x050;
    pub const LOCAL_IRQ_PENDING0: u32 = 0x060;
    pub const LOCAL_FIQ_PENDING0: u32 = 0x070;
    pub const LOCAL_MAILBOX0_SET0: u32 = 0x080;
    pub const LOCAL_MAILBOX0_CLR0: u32 = 0x0c0;

    control: u32 = 0,
    prescaler: u32 = 0x8000_0000,
    gpu_routing: u32 = 0,
    pm_routing: u32 = 0,
    int_routing: u32 = 0,
    local_timer_ctrl: u32 = 0,

    timer_int_control: [4]u32 = @splat(0),
    mailbox_int_control: [4]u32 = @splat(0),
    mailboxes: [4][4]u32 = @splat(@splat(0)),
    mailbox_nonzero_mask: [4]u4 = @splat(0),

    /// Latched per-core ARMv7 Generic Timer output lines (`[0]=CNTPS`, `[1]=CNTPNS`, `[2]=CNTHP`, `[3]=CNTV`).
    core_timer_lines: [4]u4 = @splat(0),

    /// Secondary core (`1..3`) entry address written via `LOCAL_MAILBOX3_SET1..3`.
    core_wakeup_addr: [4]u32 = @splat(0),

    pub inline fn irqPendingForCore(
        self: *const LocalIntc,
        cpu: u2,
        gpu_irq_pending: bool,
    ) u32 {
        var pending: u32 = (@as(u32, self.core_timer_lines[cpu]) & (self.timer_int_control[cpu] & 0x0f)) |
            ((@as(u32, self.mailbox_nonzero_mask[cpu]) & (self.mailbox_int_control[cpu] & 0x0f)) << 4);

        const gpu_irq_cpu: u2 = @truncate(self.gpu_routing);
        if (gpu_irq_pending and gpu_irq_cpu == cpu) {
            pending |= (1 << 8);
        }
        return pending;
    }

    pub inline fn fiqPendingForCore(
        self: *const LocalIntc,
        cpu: u2,
        gpu_fiq_pending: bool,
    ) u32 {
        var pending: u32 = (@as(u32, self.core_timer_lines[cpu]) & ((self.timer_int_control[cpu] >> 4) & 0x0f)) |
            ((@as(u32, self.mailbox_nonzero_mask[cpu]) & ((self.mailbox_int_control[cpu] >> 4) & 0x0f)) << 4);

        const gpu_fiq_cpu: u2 = @truncate(self.gpu_routing >> 2);
        if (gpu_fiq_pending and gpu_fiq_cpu == cpu) {
            pending |= (1 << 8);
        }
        return pending;
    }

    pub fn takeCoreWakeup(self: *LocalIntc, cpu: u2) ?u32 {
        const addr = self.core_wakeup_addr[cpu];
        if (addr != 0) {
            self.core_wakeup_addr[cpu] = 0;
            self.mailboxes[cpu][3] = 0;
            self.mailbox_nonzero_mask[cpu] &= ~(@as(u4, 1) << 3);
            return addr;
        }
        return null;
    }

    pub fn read32(
        self: *const LocalIntc,
        offset: u32,
        sys_timer_us: u64,
        gpu_irq_pending: bool,
        gpu_fiq_pending: bool,
    ) u32 {
        const cntpct: u64 = (sys_timer_us * 96) / 5; // 19.2 MHz physical counter
        return switch (offset) {
            LOCAL_CONTROL => self.control,
            LOCAL_PRESCALER => self.prescaler,
            LOCAL_GPU_ROUTING => self.gpu_routing,
            LOCAL_PM_ROUTING_SET, LOCAL_PM_ROUTING_CLR => self.pm_routing,
            LOCAL_TIMER_LS => @truncate(cntpct),
            LOCAL_TIMER_MS => @truncate(cntpct >> 32),
            LOCAL_INT_ROUTING => self.int_routing,
            LOCAL_TIMER_CTRL => self.local_timer_ctrl,
            0x040, 0x044, 0x048, 0x04c => self.timer_int_control[(offset - 0x040) / 4],
            0x050, 0x054, 0x058, 0x05c => self.mailbox_int_control[(offset - 0x050) / 4],
            0x060, 0x064, 0x068, 0x06c => self.irqPendingForCore(
                @intCast((offset - 0x060) / 4),
                gpu_irq_pending,
            ),
            0x070, 0x074, 0x078, 0x07c => self.fiqPendingForCore(
                @intCast((offset - 0x070) / 4),
                gpu_fiq_pending,
            ),
            0x080...0x0bc => blk: {
                const rel = offset - 0x080;
                const cpu: usize = rel / 16;
                const mb: usize = (rel / 4) % 4;
                break :blk self.mailboxes[cpu][mb];
            },
            0x0c0...0x0fc => blk: {
                const rel = offset - 0x0c0;
                const cpu: usize = rel / 16;
                const mb: usize = (rel / 4) % 4;
                break :blk self.mailboxes[cpu][mb];
            },
            else => 0,
        };
    }

    pub fn write32(self: *LocalIntc, offset: u32, val: u32) void {
        switch (offset) {
            LOCAL_CONTROL => self.control = val,
            LOCAL_PRESCALER => self.prescaler = val,
            LOCAL_GPU_ROUTING => self.gpu_routing = val & 0x0f,
            LOCAL_PM_ROUTING_SET => self.pm_routing |= val,
            LOCAL_PM_ROUTING_CLR => self.pm_routing &= ~val,
            LOCAL_INT_ROUTING => self.int_routing = val,
            LOCAL_TIMER_CTRL => self.local_timer_ctrl = val,
            LOCAL_TIMER_FLAGS => {
                if ((val & (1 << 31)) != 0) {
                    self.local_timer_ctrl &= ~(@as(u32, 1) << 31);
                }
            },
            0x040, 0x044, 0x048, 0x04c => {
                self.timer_int_control[(offset - 0x040) / 4] = val & 0xff;
            },
            0x050, 0x054, 0x058, 0x05c => {
                self.mailbox_int_control[(offset - 0x050) / 4] = val & 0xff;
            },
            0x080...0x0bc => {
                const rel = offset - 0x080;
                const cpu: usize = rel / 16;
                const mb: usize = (rel / 4) % 4;
                self.mailboxes[cpu][mb] |= val;
                if (self.mailboxes[cpu][mb] != 0) {
                    self.mailbox_nonzero_mask[cpu] |= (@as(u4, 1) << @intCast(mb));
                }
                if (cpu > 0 and mb == 3 and self.mailboxes[cpu][3] != 0) {
                    self.core_wakeup_addr[cpu] = self.mailboxes[cpu][3];
                }
            },
            0x0c0...0x0fc => {
                const rel = offset - 0x0c0;
                const cpu: usize = rel / 16;
                const mb: usize = (rel / 4) % 4;
                self.mailboxes[cpu][mb] &= ~val;
                if (self.mailboxes[cpu][mb] == 0) {
                    self.mailbox_nonzero_mask[cpu] &= ~(@as(u4, 1) << @intCast(mb));
                }
            },
            else => {},
        }
    }
};

test "LocalIntc timer IRQ, IPI mailbox, GPU routing, and secondary CPU wakeup" {
    var l1: LocalIntc = .{};

    // Route GPU IRQ to CPU 2
    l1.write32(LocalIntc.LOCAL_GPU_ROUTING, 0b00_10);
    try std.testing.expectEqual(@as(u32, 0), l1.read32(LocalIntc.LOCAL_IRQ_PENDING0 + 0, 0, true, false));
    try std.testing.expectEqual(@as(u32, 1 << 8), l1.read32(LocalIntc.LOCAL_IRQ_PENDING0 + 8, 0, true, false));

    // Enable CNTPNSIRQ (bit 1) on CPU 0
    l1.write32(LocalIntc.LOCAL_TIMER_INT_CONTROL0, 1 << 1);
    l1.core_timer_lines[0] = 0b0010;
    try std.testing.expectEqual(@as(u32, 1 << 1), l1.read32(LocalIntc.LOCAL_IRQ_PENDING0, 0, false, false));

    // Enable Mailbox 0 IRQ (bit 0) on CPU 1 and raise IPI bit 3
    l1.write32(LocalIntc.LOCAL_MAILBOX_INT_CONTROL0 + 4, 1 << 0);
    l1.write32(LocalIntc.LOCAL_MAILBOX0_SET0 + 16, 1 << 3);
    try std.testing.expectEqual(@as(u32, 1 << 4), l1.read32(LocalIntc.LOCAL_IRQ_PENDING0 + 4, 0, false, false));
    try std.testing.expectEqual(@as(u32, 1 << 3), l1.read32(LocalIntc.LOCAL_MAILBOX0_CLR0 + 16, 0, false, false));
    l1.write32(LocalIntc.LOCAL_MAILBOX0_CLR0 + 16, 1 << 3);
    try std.testing.expectEqual(@as(u32, 0), l1.read32(LocalIntc.LOCAL_IRQ_PENDING0 + 4, 0, false, false));

    // Secondary CPU 1 wakeup via Mailbox 3 SET (0x80 + 16*1 + 4*3 = 0x9c)
    l1.write32(0x09c, 0x0010_8000);
    try std.testing.expectEqual(@as(?u32, 0x0010_8000), l1.takeCoreWakeup(1));
    try std.testing.expectEqual(@as(?u32, null), l1.takeCoreWakeup(1));
}
