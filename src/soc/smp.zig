//! Cross-core coordination for running guest cores on parallel host threads.
//!
//! Cores execute their scheduler slices concurrently and meet at a barrier in
//! the main loop, which owns every peripheral between slices. While a slice
//! is running (`Smp.parallel`):
//! - CPU MMIO accesses are serialised by `device_lock` (re-entrant, because DMA
//!   handlers call back into the bus while an access is in progress).
//! - Interrupt lines are read from `irq_summary`, republished after every
//!   locked access instead of being recomputed from device state that another
//!   core may be changing.
//! - Inner Shareable TLB invalidations are posted to the other cores' inboxes
//!   when the issuing core reaches a `DSB`, and the issuer waits until every
//!   core still running its slice has applied them (the CPU run loops poll
//!   their inbox every 256 instructions). Cores that are not running are
//!   drained by the main loop before the next slice.

const std = @import("std");
const host_posix = @import("../host/posix.zig");
const Mmu = @import("../cpu/mmu.zig").Mmu;

pub const max_cores = 4;

threadlocal var device_lock_depth: u32 = 0;

/// Spin lock that the owning host thread may take recursively.
/// The recursion depth is thread-local and shared by all instances, so only
/// one `DeviceLock` may be in use per process.
pub const DeviceLock = struct {
    state: std.atomic.Value(u32) = .init(0),

    pub fn lock(self: *DeviceLock) void {
        if (device_lock_depth > 0) {
            device_lock_depth += 1;
            return;
        }
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            while (self.state.load(.monotonic) != 0) std.atomic.spinLoopHint();
        }
        device_lock_depth = 1;
    }

    pub fn unlock(self: *DeviceLock) void {
        device_lock_depth -= 1;
        if (device_lock_depth == 0) self.state.store(0, .release);
    }
};

const TlbInbox = struct {
    lock: std.atomic.Value(u32) = .init(0),
    pending: std.atomic.Value(u32) = .init(0),
    full: bool = false,
    count: u16 = 0,
    vas: [64]u64 = @splat(0),

    fn acquire(self: *TlbInbox) void {
        while (self.lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            while (self.lock.load(.monotonic) != 0) std.atomic.spinLoopHint();
        }
    }

    fn release(self: *TlbInbox) void {
        self.lock.store(0, .release);
    }
};

pub const Smp = struct {
    /// True while cores execute a slice on parallel host threads. Only changed
    /// by the main loop while every worker thread is parked.
    parallel: bool = false,
    device_lock: DeviceLock = .{},
    /// Bits `0..3`: IRQ pending for core `n`; bits `4..7`: FIQ pending for core `n`.
    irq_summary: std.atomic.Value(u32) = .init(0),
    /// True while core `n` is executing its slice.
    running: [max_cores]std.atomic.Value(bool) = @splat(.init(false)),
    tlb: [max_cores]TlbInbox = @splat(.{}),

    /// Posts the TLB invalidations `mmu` (core `from`) queued with `TLBI ...IS`
    /// to every other core, then waits until each core still running its slice
    /// has applied them.
    pub fn broadcastTlb(self: *Smp, from: u2, mmu: *Mmu) void {
        if (!mmu.tlb_broadcast_full and mmu.tlb_broadcast_va_count == 0) return;
        const vas = mmu.tlb_broadcast_vas[0..mmu.tlb_broadcast_va_count];
        for (0..max_cores) |t| {
            if (t == from) continue;
            const box = &self.tlb[t];
            box.acquire();
            if (mmu.tlb_broadcast_full or box.full or box.count + vas.len > box.vas.len) {
                box.full = true;
            } else {
                @memcpy(box.vas[box.count..][0..vas.len], vas);
                box.count += @intCast(vas.len);
            }
            box.pending.store(1, .release);
            box.release();
        }
        mmu.tlb_broadcast_full = false;
        mmu.tlb_broadcast_va_count = 0;

        for (0..max_cores) |t| {
            if (t == from) continue;
            while (self.running[t].load(.acquire) and self.tlb[t].pending.load(.acquire) != 0) {
                // Apply our own inbox so two cores broadcasting at once cannot wait on each other.
                _ = self.serviceTlb(from, mmu);
                std.atomic.spinLoopHint();
            }
        }
    }

    /// Applies any invalidations posted to `core`. Returns true if `mmu` was flushed.
    pub fn serviceTlb(self: *Smp, core: u2, mmu: *Mmu) bool {
        const box = &self.tlb[core];
        if (box.pending.load(.acquire) == 0) return false;
        box.acquire();
        if (box.full) {
            mmu.flushTlb();
        } else {
            for (box.vas[0..box.count]) |va| mmu.flushTlbVa64(va);
        }
        box.full = false;
        box.count = 0;
        box.pending.store(0, .release);
        box.release();
        return true;
    }
};

/// Runs the scheduler slices of cores `1..3` on host worker threads while the
/// calling (main) thread runs core 0, then waits for all of them: a barrier per slice.
pub fn Runner(comptime Cpu: type, comptime Bus: type) type {
    return struct {
        const Self = @This();

        /// Busy-wait iterations before a waiting thread sleeps on its futex.
        const spin_limit = 20_000;

        const Worker = struct {
            thread: ?std.Thread = null,
            /// Incremented by the main thread to start a slice (futex word).
            go: std.atomic.Value(u32) = .init(0),
            sleeping: std.atomic.Value(u32) = .init(0),
            ran: usize = 0,
        };

        cpus: *[max_cores]Cpu,
        bus: *Bus,
        workers: [max_cores]Worker = @splat(.{}),
        /// Workers that finished the current slice (futex word for the main thread).
        done: std.atomic.Value(u32) = .init(0),
        main_sleeping: std.atomic.Value(u32) = .init(0),
        expected: u32 = 0,
        batch: usize = 0,
        stop: std.atomic.Value(bool) = .init(false),

        pub fn init(cpus: *[max_cores]Cpu, bus: *Bus) Self {
            return .{ .cpus = cpus, .bus = bus };
        }

        /// Spawns the worker threads. On failure the runner keeps running cores sequentially.
        pub fn start(self: *Self) void {
            for (1..max_cores) |k| {
                self.workers[k].thread = std.Thread.spawn(.{}, workerMain, .{ self, k }) catch null;
            }
        }

        pub fn deinit(self: *Self) void {
            self.stop.store(true, .seq_cst);
            for (1..max_cores) |k| {
                const w = &self.workers[k];
                if (w.thread) |t| {
                    _ = w.go.fetchAdd(1, .seq_cst);
                    host_posix.futexWake(&w.go.raw);
                    t.join();
                    w.thread = null;
                }
            }
        }

        /// Runs one slice of `batch` instructions on every core in `active` (bit `n` = core `n`)
        /// and returns the most instructions any core executed.
        pub fn runSlice(self: *Self, active: u4, batch: usize) usize {
            var parallel_mask: u4 = 0;
            for (1..max_cores) |k| {
                if ((active >> @intCast(k)) & 1 != 0 and self.workers[k].thread != null) parallel_mask |= @as(u4, 1) << @intCast(k);
            }
            // Handing a slice to another thread only pays off when two or more cores have work.
            if (@popCount(parallel_mask) == 0 or @popCount(active) < 2) {
                var max_ran: usize = 0;
                for (0..max_cores) |i| {
                    if ((active >> @intCast(i)) & 1 == 0) continue;
                    max_ran = @max(max_ran, self.cpus[i].runSteps(self.bus, batch));
                    // Complete this core's TLBI ...IS before the next core runs.
                    self.applyQueuedBroadcast(i);
                }
                return max_ran;
            }

            const smp = &self.bus.smp;
            self.bus.publishIrqSummary();
            smp.parallel = true;
            self.batch = batch;
            self.expected = @popCount(parallel_mask);
            self.done.store(0, .monotonic);
            for (0..max_cores) |i| {
                smp.running[i].store((active >> @intCast(i)) & 1 != 0, .seq_cst);
            }
            for (1..max_cores) |k| {
                if ((parallel_mask >> @intCast(k)) & 1 == 0) continue;
                const w = &self.workers[k];
                _ = w.go.fetchAdd(1, .seq_cst);
                if (w.sleeping.load(.seq_cst) != 0) host_posix.futexWake(&w.go.raw);
            }

            var max_ran: usize = 0;
            for (0..max_cores) |i| {
                // Cores without a worker thread (core 0, or a failed spawn) run here.
                if ((active >> @intCast(i)) & 1 == 0 or (parallel_mask >> @intCast(i)) & 1 != 0) continue;
                max_ran = @max(max_ran, self.cpus[i].runSteps(self.bus, batch));
                smp.running[i].store(false, .release);
            }

            var spins: u32 = 0;
            while (true) {
                const d = self.done.load(.acquire);
                if (d == self.expected) break;
                if (spins < spin_limit) {
                    spins += 1;
                    std.atomic.spinLoopHint();
                    continue;
                }
                self.main_sleeping.store(1, .seq_cst);
                if (self.done.load(.seq_cst) == d) host_posix.futexWait(&self.done.raw, d);
                self.main_sleeping.store(0, .release);
            }
            smp.parallel = false;

            for (1..max_cores) |k| {
                if ((parallel_mask >> @intCast(k)) & 1 != 0) max_ran = @max(max_ran, self.workers[k].ran);
            }
            // Cores that stopped early may still hold invalidations posted during the slice,
            // and cores whose slice ended before a `DSB` still hold their own queue.
            for (0..max_cores) |i| {
                _ = smp.serviceTlb(@intCast(i), &self.cpus[i].mmu);
            }
            for (0..max_cores) |i| self.applyQueuedBroadcast(i);
            return max_ran;
        }

        /// Applies the `TLBI ...IS` invalidations core `i` queued to every other core's TLB.
        /// Only called while no other core is running.
        fn applyQueuedBroadcast(self: *Self, i: usize) void {
            const m = &self.cpus[i].mmu;
            if (m.tlb_broadcast_full) {
                for (0..max_cores) |j| {
                    if (j != i) self.cpus[j].mmu.flushTlb();
                }
            } else if (m.tlb_broadcast_va_count > 0) {
                for (0..max_cores) |j| {
                    if (j == i) continue;
                    for (m.tlb_broadcast_vas[0..m.tlb_broadcast_va_count]) |va| self.cpus[j].mmu.flushTlbVa64(va);
                }
            }
            m.tlb_broadcast_full = false;
            m.tlb_broadcast_va_count = 0;
        }

        fn workerMain(self: *Self, k: usize) void {
            const w = &self.workers[k];
            // `go` is 0 when the thread is spawned; reading it here instead could miss a
            // slice the main thread dispatched before this thread got scheduled.
            var seen: u32 = 0;
            while (true) {
                var spins: u32 = 0;
                while (w.go.load(.acquire) == seen) {
                    if (spins < spin_limit) {
                        spins += 1;
                        std.atomic.spinLoopHint();
                        continue;
                    }
                    w.sleeping.store(1, .seq_cst);
                    if (w.go.load(.seq_cst) == seen) host_posix.futexWait(&w.go.raw, seen);
                    w.sleeping.store(0, .release);
                }
                seen = w.go.load(.acquire);
                if (self.stop.load(.acquire)) return;

                w.ran = self.cpus[k].runSteps(self.bus, self.batch);
                self.bus.smp.running[k].store(false, .release);
                const d = self.done.fetchAdd(1, .seq_cst) + 1;
                if (d == self.expected and self.main_sleeping.load(.seq_cst) != 0) {
                    host_posix.futexWake(&self.done.raw);
                }
            }
        }
    };
}

test "TLB broadcast reaches other cores and skips the issuer" {
    var smp: Smp = .{};
    var mmus: [max_cores]Mmu = @splat(.{});

    mmus[1].tlb_broadcast_vas[0] = 0x1234;
    mmus[1].tlb_broadcast_va_count = 1;
    smp.broadcastTlb(1, &mmus[1]);
    try std.testing.expectEqual(@as(u16, 0), mmus[1].tlb_broadcast_va_count);
    try std.testing.expectEqual(@as(u32, 0), smp.tlb[1].pending.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), smp.tlb[0].pending.load(.monotonic));
    try std.testing.expectEqual(@as(u16, 1), smp.tlb[2].count);

    // A full flush supersedes queued addresses.
    mmus[3].tlb_broadcast_full = true;
    smp.broadcastTlb(3, &mmus[3]);
    try std.testing.expect(smp.tlb[2].full);

    const gen = mmus[2].tlb_gen;
    try std.testing.expect(smp.serviceTlb(2, &mmus[2]));
    try std.testing.expect(mmus[2].tlb_gen != gen);
    try std.testing.expect(!smp.serviceTlb(2, &mmus[2]));
}

test "DeviceLock is re-entrant on the owning thread" {
    var l: DeviceLock = .{};
    l.lock();
    l.lock();
    l.unlock();
    try std.testing.expectEqual(@as(u32, 1), l.state.load(.monotonic));
    l.unlock();
    try std.testing.expectEqual(@as(u32, 0), l.state.load(.monotonic));
}

test "Runner keeps LDXR/STXR atomic and spinlocks exclusive across parallel cores" {
    const arm1176 = @import("../cpu/arm1176.zig");
    const TestBus = struct {
        ram: []u8,
        smp: Smp = .{},
        pub fn publishIrqSummary(_: *@This()) void {}
        pub fn hasPendingIrq(_: *const @This()) bool {
            return false;
        }
        pub fn hasPendingFiq(_: *const @This()) bool {
            return false;
        }
        pub fn read32(self: *@This(), paddr: u32) u32 {
            return std.mem.readInt(u32, self.ram[paddr..][0..4], .little);
        }
        pub fn write32(self: *@This(), paddr: u32, val: u32) void {
            std.mem.writeInt(u32, self.ram[paddr..][0..4], val, .little);
        }
        pub fn read16(self: *@This(), paddr: u32) u16 {
            return std.mem.readInt(u16, self.ram[paddr..][0..2], .little);
        }
        pub fn write16(self: *@This(), paddr: u32, val: u16) void {
            std.mem.writeInt(u16, self.ram[paddr..][0..2], val, .little);
        }
        pub fn read8(self: *@This(), paddr: u32) u8 {
            return self.ram[paddr];
        }
        pub fn write8(self: *@This(), paddr: u32, val: u8) void {
            self.ram[paddr] = val;
        }
    };
    const Cpu = arm1176.Arm1176(TestBus);

    // 0x1000: atomic_inc: ldxr x3, [x1]; add x3, x3, #1; stxr w4, x3, [x1]; cbnz w4, atomic_inc
    // 0x1010: lock: ldaxr w3, [x5]; cbnz w3, lock; mov w3, #1; stxr w4, w3, [x5]; cbnz w4, lock
    // 0x1024: ldr x6, [x7]; add x6, x6, #1; str x6, [x7]   (plain increment under the lock)
    // 0x1030: stlr wzr, [x5]                                (unlock with a plain store-release)
    // 0x1034: subs x2, x2, #1; b.ne atomic_inc
    // 0x103c: done: wfi; b done
    const prog = [_]u32{
        0xc85f7c23, 0x91000463, 0xc8047c23, 0x35ffffa4,
        0x885ffca3, 0x35ffffe3, 0x52800023, 0x88047ca3,
        0x35ffff84, 0xf94000e6, 0x910004c6, 0xf90000e6,
        0x889ffcbf, 0xf1000442, 0x54fffe41, 0xd503207f,
        0x17ffffff,
    };
    const iterations = 20_000;
    const atomic_counter = 0x8000;
    const lock_word = 0x8040;
    const locked_counter = 0x8080;

    for ([_]bool{ true, false }) |threaded| {
        const ram = try std.testing.allocator.alignedAlloc(u8, .@"16", 64 * 1024);
        defer std.testing.allocator.free(ram);
        @memset(ram, 0);
        for (prog, 0..) |inst, i| std.mem.writeInt(u32, ram[0x1000 + i * 4 ..][0..4], inst, .little);

        var bus: TestBus = .{ .ram = ram };
        var cpus: [max_cores]Cpu = @splat(.{});
        for (&cpus, 0..) |*cpu, i| {
            cpu.initReset64(0x1000, 0);
            cpu.mmu.core_id = @intCast(i);
            cpu.x[1] = atomic_counter;
            cpu.x[2] = iterations;
            cpu.x[5] = lock_word;
            cpu.x[7] = locked_counter;
        }

        var runner = Runner(Cpu, TestBus).init(&cpus, &bus);
        if (threaded) runner.start();
        defer runner.deinit();

        var slices: usize = 0;
        while (slices < 1_000_000) : (slices += 1) {
            var active: u4 = 0;
            for (&cpus, 0..) |*cpu, i| {
                if (!cpu.mmu.halted_wfi) active |= @as(u4, 1) << @intCast(i);
            }
            if (active == 0) break;
            _ = runner.runSlice(active, 4096);
        }

        try std.testing.expectEqual(@as(u64, max_cores * iterations), std.mem.readInt(u64, ram[atomic_counter..][0..8], .little));
        try std.testing.expectEqual(@as(u64, max_cores * iterations), std.mem.readInt(u64, ram[locked_counter..][0..8], .little));
        try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, ram[lock_word..][0..4], .little));
    }
}
