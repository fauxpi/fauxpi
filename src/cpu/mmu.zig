//! ARM1176JZF-S & ARM Cortex-A53 CP15 System Control Coprocessor,
//! ARMv6 / ARMv7 Short-Descriptor MMU, LPAE 3-Level Long-Descriptor MMU,
//! and ARMv7 Generic Timer (`c14`) with Software TLB.
//!
//! Implements both:
//! - ARMv6 / ARMv7 Short-descriptor VMSA (16 MB Supersections, 1 MB Sections,
//!   64 KB Large Pages, 4 KB Small Pages, Domain Access Control, APX/AP[1:0]/XN)
//! - ARMv7-A LPAE 3-level Long-descriptor VMSA (`TTBCR.EAE == 1`: 64-bit descriptors,
//!   1 GB L1 blocks, 2 MB L2 blocks, 4 KB L3 pages, `T0SZ`/`T1SZ` split including
//!   `T1SZ >= 2` direct L2 lookup for `TTBR1_OFFSET`, `APTable`, `AF`, `PXN`/`XN`)
//! - ARMv7 Generic Timer (`CNTFRQ`, `CNTKCTL`, `CNTPCT`, `CNTVCT`, `CNTP_*`,
//!   `CNTV_*`, `CNTPS_*`, `CNTHP_*`) running at 19.2 MHz (`bcm2836-l1-intc`).

const std = @import("std");

pub const AccessKind = enum {
    read,
    write,
    fetch,
};

pub const FaultKind = enum {
    prefetch_abort,
    data_abort,
};

pub const Mmu = struct {
    /// Core index (`0..3`) for `MPIDR` and per-core local timer routing
    core_id: u2 = 0,
    /// True when emulating an ARMv7-A / Cortex-A53 core (BCM2837)
    is_cortex_a53: bool = false,

    /// CP15 c1: System Control Register (SCTLR)
    /// Reset value on ARM1176JZF-S has bits [6:4] = 0b111 (0x00050078)
    sctlr: u32 = 0x00050078,
    /// CP15 c1: Auxiliary Control Register (ACTLR)
    actlr: u32 = 0x00000007,
    /// CP15 c1: Coprocessor Access Control Register (CPACR)
    cpacr: u32 = 0x00000000,

    /// CP15 c2: Translation Table Base Registers (32-bit and 64-bit LPAE)
    ttbr0: u32 = 0,
    ttbr1: u32 = 0,
    ttbr0_64: u64 = 0,
    ttbr1_64: u64 = 0,
    ttbcr: u32 = 0,

    /// CP15 c3: Domain Access Control Register
    dacr: u32 = 0,

    /// CP15 c5: Fault Status Registers
    dfsr: u32 = 0,
    ifsr: u32 = 0,

    /// CP15 c6: Fault Address Registers
    dfar: u32 = 0,
    ifar: u32 = 0,

    /// CP15 c7: Physical Address Register (PAR)
    par_64: u64 = 0,

    /// CP15 c10: Memory Attribute Indirection Registers (PRRR / NMRR / MAIR0 / MAIR1)
    mair0: u32 = 0,
    mair1: u32 = 0,

    /// CP15 c12: Vector Base Address Register (VBAR)
    vbar: u32 = 0,

    /// CP15 c13: Process / Thread ID Registers
    fcseidr: u32 = 0,
    contextidr: u32 = 0,
    tpidrurw: u32 = 0,
    tpidruro: u32 = 0,
    tpidrprw: u32 = 0,

    /// CP15 opc1=2, c0, c0, 0: Cache Size Selection Register (CSSELR)
    csselr: u32 = 0,

    /// CP15 c14: ARMv7 Generic Timer (19.2 MHz on BCM2836/BCM2837)
    cntfrq: u32 = 19_200_000,
    cntkctl: u32 = 0,
    cntpct: u64 = 0,
    last_cntpct_read: u64 = 0xffff_ffff_ffff_ffff,
    cntpct_same_reads: u8 = 0,
    cntvoff: u64 = 0,
    cntp_cval: u64 = 0,
    cntp_ctl: u32 = 0,
    cntv_cval: u64 = 0,
    cntv_ctl: u32 = 0,
    cntps_cval: u64 = 0,
    cntps_ctl: u32 = 0,
    cnthp_cval: u64 = 0,
    cnthp_ctl: u32 = 0,
    timer_irq_lines: u4 = 0,

    /// CP15 c15: Performance monitor control / cycle counter & Cortex-A53 CPUECTLR
    pmcr: u32 = 0,
    pmccntr: u32 = 0,
    cpuectlr_64: u64 = 0,

    /// AArch64 (VMSAv8-64) EL1/EL2/EL3 System Registers
    sctlr_el1: u64 = 0x30d00800,
    sctlr_el2: u64 = 0x30c50830,
    sctlr_el3: u64 = 0x30c50830,
    tcr_el1: u64 = 0,
    tcr_el2: u64 = 0,
    ttbr0_el2: u64 = 0,
    mair_el1: u64 = 0,
    mair_el2: u64 = 0,
    amair_el1: u64 = 0,
    vbar_el1: u64 = 0,
    vbar_el2: u64 = 0,
    vbar_el3: u64 = 0,
    esr_el1: u32 = 0,
    esr_el2: u32 = 0,
    far_el1: u64 = 0,
    far_el2: u64 = 0,
    hcr_el2: u64 = 1 << 31, // RW=1 (EL1 is AArch64)
    scr_el3: u64 = (1 << 10) | (1 << 8) | (1 << 0), // RW=1, HCE=1, NS=1
    cptr_el2: u64 = 0,
    cptr_el3: u64 = 0,
    cpacr_el1: u64 = 3 << 20, // FPEN=0b11
    tpidr_el0: u64 = 0,
    tpidrro_el0: u64 = 0,
    tpidr_el1: u64 = 0,
    tpidr_el2: u64 = 0,
    vpidr_el2: u32 = 0x410fd034,
    vmpidr_el2: u64 = 0x80000000,
    cnthctl_el2: u32 = 3,
    mdcr_el2: u32 = 0,
    oslar_el1: u32 = 0,
    pmuserenr_el0: u32 = 0,

    /// Set to true when the guest executes WFI (`mcr p15, 0, rX, c7, c0, 4` or `wfi`)
    halted_wfi: bool = false,

    /// Direct-mapped software TLB (4096 entries covering 4 KB pages)
    tlb: [tlb_size]TlbEntry = @splat(.{}),
    /// Current TLB generation counter (incremented on full TLB flush to avoid 48 KB memset)
    tlb_gen: u32 = 1,

    /// Direct-indexed SoftMMU RAM fast-path tables banked by privilege (`[0]` = User/EL0, `[1]` = Priv/EL1..3).
    /// Entries are populated only for 4 KB pages backed by main RAM (`pbase + 4096 <= ram.len`).
    soft_tlb32: [2][soft_tlb_size]SoftTlbSlot32 = @splat(@splat(.{})),
    soft_tlb64: [2][soft_tlb_size]SoftTlbSlot64 = @splat(@splat(.{})),
    /// 64-bit bitmaps tracking which 64-entry chunks (`0..63`) in `soft_tlb32` / `soft_tlb64` have been populated since the last `flushTlb()`.
    soft_tlb32_dirty_chunks: u64 = 0,
    soft_tlb64_dirty_chunks: u64 = 0,
    tlb_broadcast_full: bool = false,
    tlb_broadcast_va_count: u16 = 0,
    tlb_broadcast_vas: [256]u64 = @splat(0),

    pub const tlb_bits = 12;
    pub const tlb_size = 1 << tlb_bits;
    pub const tlb_mask = tlb_size - 1;

    pub const soft_tlb_bits = 12;
    pub const soft_tlb_size = 1 << soft_tlb_bits;
    pub const soft_tlb_mask = soft_tlb_size - 1;
    pub const soft_tlb_chunk_shift = 6;
    pub const soft_tlb_chunk_size = 1 << soft_tlb_chunk_shift;

    pub const SoftTlbSlot32 = struct {
        r_vbase: u32 = 0xffff_ffff,
        w_vbase: u32 = 0xffff_ffff,
        x_vbase: u32 = 0xffff_ffff,
        pbase: u32 = 0,
    };

    pub const SoftTlbSlot64 = struct {
        r_vbase: u64 = 0xffff_ffff_ffff_ffff,
        w_vbase: u64 = 0xffff_ffff_ffff_ffff,
        x_vbase: u64 = 0xffff_ffff_ffff_ffff,
        pbase: u32 = 0,
        _pad: u32 = 0,
    };

    pub const perm_priv_r: u8 = 1 << 0;
    pub const perm_priv_w: u8 = 1 << 1;
    pub const perm_priv_x: u8 = 1 << 2;
    pub const perm_user_r: u8 = 1 << 3;
    pub const perm_user_w: u8 = 1 << 4;
    pub const perm_user_x: u8 = 1 << 5;

    pub const TlbEntry = struct {
        gen: u32 = 0,
        vpn: u52 = 0,
        perms: u8 = 0,
        domain: u4 = 0,
        is_page: bool = false,
        level: u2 = 2,
        ppn_base: u32 = 0, // Physical page base (top 20 bits, low 12 bits 0)
    };

    pub inline fn isMmuEnabled(self: *const Mmu) bool {
        return (self.sctlr & 1) != 0;
    }

    pub inline fn highVectors(self: *const Mmu) bool {
        return (self.sctlr & (1 << 13)) != 0;
    }

    pub inline fn extendedPageTables(self: *const Mmu) bool {
        return self.is_cortex_a53 or (self.sctlr & (1 << 23)) != 0;
    }

    pub inline fn isLpae(self: *const Mmu) bool {
        return (self.ttbcr & (1 << 31)) != 0;
    }

    pub fn flushTlb(self: *Mmu) void {
        self.tlb_gen +%= 1;
        if (self.tlb_gen == 0) {
            @memset(&self.tlb, .{});
            self.tlb_gen = 1;
        }
        var mask32 = self.soft_tlb32_dirty_chunks;
        if (mask32 != 0) {
            while (mask32 != 0) {
                const chunk: usize = @ctz(mask32);
                mask32 &= mask32 - 1;
                const base = chunk * soft_tlb_chunk_size;
                @memset(self.soft_tlb32[0][base..][0..soft_tlb_chunk_size], .{});
                @memset(self.soft_tlb32[1][base..][0..soft_tlb_chunk_size], .{});
            }
            self.soft_tlb32_dirty_chunks = 0;
        }
        var mask64 = self.soft_tlb64_dirty_chunks;
        if (mask64 != 0) {
            while (mask64 != 0) {
                const chunk: usize = @ctz(mask64);
                mask64 &= mask64 - 1;
                const base = chunk * soft_tlb_chunk_size;
                @memset(self.soft_tlb64[0][base..][0..soft_tlb_chunk_size], .{});
                @memset(self.soft_tlb64[1][base..][0..soft_tlb_chunk_size], .{});
            }
            self.soft_tlb64_dirty_chunks = 0;
        }
    }

    pub fn flushTlbMva(self: *Mmu, mva: u32) void {
        const vpn: u52 = @truncate(mva >> 12);
        const idx: usize = @as(usize, @truncate(vpn)) & tlb_mask;
        if (self.tlb[idx].gen == self.tlb_gen and self.tlb[idx].vpn == vpn) {
            self.tlb[idx].gen = 0;
        }
        const s_idx: usize = @as(usize, @truncate(vpn)) & soft_tlb_mask;
        self.soft_tlb32[0][s_idx] = .{};
        self.soft_tlb32[1][s_idx] = .{};
    }

    pub fn flushTlbVa64(self: *Mmu, va_page_shifted: u64) void {
        const vpn: u52 = @truncate(va_page_shifted & 0x0000_0fff_ffff_ffff);
        const idx: usize = @as(usize, @truncate(vpn)) & tlb_mask;
        if (self.tlb[idx].gen == self.tlb_gen and self.tlb[idx].vpn == vpn) {
            self.tlb[idx].gen = 0;
        }
        const s_idx: usize = @as(usize, @truncate(vpn)) & soft_tlb_mask;
        self.soft_tlb64[0][s_idx] = .{};
        self.soft_tlb64[1][s_idx] = .{};
    }

    pub inline fn lookupPbase32NoFault(self: *const Mmu, vaddr: u32) ?u32 {
        if (!self.isMmuEnabled()) return vaddr & 0xffff_f000;
        const vpn: u52 = @truncate(vaddr >> 12);
        const entry = &self.tlb[@as(usize, @truncate(vpn)) & tlb_mask];
        if (entry.gen == self.tlb_gen and entry.vpn == vpn) return entry.ppn_base;
        return null;
    }

    pub inline fn lookupPbase64NoFault(self: *const Mmu, vaddr: u64) ?u32 {
        if ((self.sctlr_el1 & 1) == 0 and (self.sctlr_el2 & 1) == 0) return @as(u32, @truncate(vaddr)) & 0xffff_f000;
        const vpn: u52 = @truncate((vaddr & 0x00ff_ffff_ffff_ffff) >> 12);
        const entry = &self.tlb[@as(usize, @truncate(vpn)) & tlb_mask];
        if (entry.gen == self.tlb_gen and entry.vpn == vpn) return entry.ppn_base;
        return null;
    }

    pub inline fn populateSoftTlb32(self: *Mmu, ram_len: usize, vaddr: u32, pbase: u32, perms: u8) void {
        if (@as(usize, pbase) + 4096 <= ram_len) {
            const vbase = vaddr & 0xffff_f000;
            const s_idx: usize = @as(usize, vaddr >> 12) & soft_tlb_mask;
            self.soft_tlb32[1][s_idx] = .{
                .r_vbase = if ((perms & perm_priv_r) != 0) vbase else 0xffff_ffff,
                .w_vbase = if ((perms & perm_priv_w) != 0) vbase else 0xffff_ffff,
                .x_vbase = if ((perms & perm_priv_x) != 0) vbase else 0xffff_ffff,
                .pbase = pbase,
            };
            self.soft_tlb32[0][s_idx] = .{
                .r_vbase = if ((perms & perm_user_r) != 0) vbase else 0xffff_ffff,
                .w_vbase = if ((perms & perm_user_w) != 0) vbase else 0xffff_ffff,
                .x_vbase = if ((perms & perm_user_x) != 0) vbase else 0xffff_ffff,
                .pbase = pbase,
            };
            const chunk: u6 = @intCast(s_idx >> soft_tlb_chunk_shift);
            self.soft_tlb32_dirty_chunks |= (@as(u64, 1) << chunk);
        }
    }

    pub inline fn populateSoftTlb64(self: *Mmu, ram_len: usize, vaddr: u64, pbase: u32, perms: u8, is_el2: bool) void {
        if (@as(usize, pbase) + 4096 <= ram_len) {
            const vbase = vaddr & ~@as(u64, 0xfff);
            const s_idx: usize = @as(usize, @truncate(vaddr >> 12)) & soft_tlb_mask;
            self.soft_tlb64[1][s_idx] = .{
                .r_vbase = if ((perms & perm_priv_r) != 0) vbase else 0xffff_ffff_ffff_ffff,
                .w_vbase = if ((perms & perm_priv_w) != 0) vbase else 0xffff_ffff_ffff_ffff,
                .x_vbase = if ((perms & perm_priv_x) != 0) vbase else 0xffff_ffff_ffff_ffff,
                .pbase = pbase,
            };
            if (!is_el2) {
                self.soft_tlb64[0][s_idx] = .{
                    .r_vbase = if ((perms & perm_user_r) != 0) vbase else 0xffff_ffff_ffff_ffff,
                    .w_vbase = if ((perms & perm_user_w) != 0) vbase else 0xffff_ffff_ffff_ffff,
                    .x_vbase = if ((perms & perm_user_x) != 0) vbase else 0xffff_ffff_ffff_ffff,
                    .pbase = pbase,
                };
            }
            const chunk: u6 = @intCast(s_idx >> soft_tlb_chunk_shift);
            self.soft_tlb64_dirty_chunks |= (@as(u64, 1) << chunk);
        }
    }

    /// Updates `cntpct` from the 1 MHz system timer counter (`sys_timer_us * 19.2`)
    /// and returns the 4 active Generic Timer interrupt lines (`[0]=CNTPS`, `[1]=CNTPNS`, `[2]=CNTHP`, `[3]=CNTV`).
    pub inline fn syncGenericTimer(self: *Mmu, sys_timer_us: u64) u4 {
        return self.syncGenericTimerWithCntpct((sys_timer_us * 96) / 5);
    }

    /// Updates `cntpct` from a precomputed 19.2 MHz counter value and evaluates timer interrupt lines.
    pub inline fn syncGenericTimerWithCntpct(self: *Mmu, next_cntpct: u64) u4 {
        if (self.cntpct != next_cntpct) {
            self.cntpct = next_cntpct;
            self.cntpct_same_reads = 0;
        }
        return self.timerIrqLines();
    }

    /// Records a guest read of `CNTPCT` / `CNTVCT` and returns `true` when the core is polling
    /// a stationary counter value so the current slice can yield and advance guest time.
    pub inline fn noteTimerCounterRead(self: *Mmu) bool {
        if (self.cntpct == self.last_cntpct_read) {
            self.cntpct_same_reads +|= 1;
            return self.cntpct_same_reads >= 2;
        }
        self.last_cntpct_read = self.cntpct;
        self.cntpct_same_reads = 0;
        return false;
    }

    pub fn timerIrqLines(self: *Mmu) u4 {
        if (((self.cntps_ctl | self.cntp_ctl | self.cnthp_ctl | self.cntv_ctl) & 1) == 0) {
            self.cntps_ctl &= ~@as(u32, 4);
            self.cntp_ctl &= ~@as(u32, 4);
            self.cnthp_ctl &= ~@as(u32, 4);
            self.cntv_ctl &= ~@as(u32, 4);
            self.timer_irq_lines = 0;
            return 0;
        }
        var lines: u4 = 0;
        if (evalTimer(&self.cntps_ctl, self.cntpct, self.cntps_cval)) lines |= (1 << 0);
        if (evalTimer(&self.cntp_ctl, self.cntpct, self.cntp_cval)) lines |= (1 << 1);
        if (evalTimer(&self.cnthp_ctl, self.cntpct, self.cnthp_cval)) lines |= (1 << 2);
        const cntvct = self.cntpct -% self.cntvoff;
        if (evalTimer(&self.cntv_ctl, cntvct, self.cntv_cval)) lines |= (1 << 3);
        self.timer_irq_lines = lines;
        return lines;
    }

    fn evalTimer(ctl: *u32, counter: u64, cval: u64) bool {
        if ((ctl.* & 1) == 0) {
            ctl.* &= ~@as(u32, 4);
            return false;
        }
        const fired = @as(i64, @bitCast(counter -% cval)) >= 0;
        if (fired) {
            ctl.* |= 4;
            return (ctl.* & 2) == 0; // IMASK == 0
        } else {
            ctl.* &= ~@as(u32, 4);
            return false;
        }
    }

    /// Returns the number of microseconds until the next enabled Generic Timer expires (capped at `max_us`).
    pub fn usUntilNextGenericTimer(self: *const Mmu, max_us: u64) u64 {
        var best_us: u64 = max_us;
        const cntvct = self.cntpct -% self.cntvoff;
        const timers = [_]struct { ctl: u32, cur: u64, cval: u64 }{
            .{ .ctl = self.cntps_ctl, .cur = self.cntpct, .cval = self.cntps_cval },
            .{ .ctl = self.cntp_ctl, .cur = self.cntpct, .cval = self.cntp_cval },
            .{ .ctl = self.cnthp_ctl, .cur = self.cntpct, .cval = self.cnthp_cval },
            .{ .ctl = self.cntv_ctl, .cur = cntvct, .cval = self.cntv_cval },
        };
        for (timers) |t| {
            if ((t.ctl & 3) == 1) { // ENABLE=1, IMASK=0
                const diff = @as(i64, @bitCast(t.cval -% t.cur));
                if (diff <= 0) return 0;
                const ticks: u64 = @intCast(diff);
                const us = @max((ticks * 5 + 95) / 96, 1);
                if (us < best_us) best_us = us;
            }
        }
        return best_us;
    }

    /// Translates virtual address `vaddr` to a physical address.
    /// On fault, updates `DFSR`/`DFAR` (for read/write) or `IFSR`/`IFAR` (for fetch)
    /// and returns `error.Abort`.
    pub inline fn translate(
        self: *Mmu,
        ram: []const u8,
        vaddr: u32,
        access: AccessKind,
        is_priv: bool,
    ) error{Abort}!u32 {
        if (!self.isMmuEnabled()) {
            self.populateSoftTlb32(ram.len, vaddr, vaddr & 0xffff_f000, 0x3f);
            return vaddr;
        }

        const vpn: u52 = @truncate(vaddr >> 12);
        const idx: usize = @as(usize, @truncate(vpn)) & tlb_mask;
        const entry = &self.tlb[idx];

        const req_perm: u8 = switch (access) {
            .read => if (is_priv) perm_priv_r else perm_user_r,
            .write => if (is_priv) perm_priv_w else perm_user_w,
            .fetch => if (is_priv) perm_priv_x else perm_user_x,
        };

        if (entry.gen == self.tlb_gen and entry.vpn == vpn) {
            if ((entry.perms & req_perm) != 0) {
                self.populateSoftTlb32(ram.len, vaddr, entry.ppn_base, entry.perms);
                return entry.ppn_base | (vaddr & 0xfff);
            }
            // Permission fault on cached TLB entry
            const fs: u6 = if (self.isLpae())
                (0b001100 | @as(u6, entry.level))
            else if (entry.is_page)
                0x0f
            else
                0x0d;
            self.recordFault(vaddr, access, fs, entry.domain);
            return error.Abort;
        }

        return self.walkAndFillTlb(ram, vaddr, access, is_priv, req_perm);
    }

    /// Translates 64-bit virtual address `vaddr` using VMSAv8-64 4-level/3-level page tables
    /// for the `EL1&0` translation regime.
    /// On fault, updates `FAR_EL1` and `ESR_EL1` and returns `error.Abort`.
    pub fn translate64(
        self: *Mmu,
        ram: []const u8,
        vaddr: u64,
        access: AccessKind,
        is_priv: bool,
    ) error{Abort}!u32 {
        return self.translate64AtEl(ram, vaddr, access, if (is_priv) 1 else 0);
    }

    /// Translates 64-bit virtual address `vaddr` at Exception Level `el` (`0..3`).
    pub fn translate64AtEl(
        self: *Mmu,
        ram: []const u8,
        vaddr: u64,
        access: AccessKind,
        el: u2,
    ) error{Abort}!u32 {
        const is_el2 = (el == 2) and ((self.hcr_el2 & (@as(u64, 1) << 34)) == 0);
        const mmu_enabled = switch (el) {
            0, 1 => (self.sctlr_el1 & 1) != 0 and self.isMmuEnabled(),
            2 => if (is_el2) (self.sctlr_el2 & 1) != 0 else (self.sctlr_el1 & 1) != 0,
            3 => (self.sctlr_el3 & 1) != 0,
        };
        if (!mmu_enabled) {
            const paddr: u32 = @truncate(vaddr);
            self.populateSoftTlb64(ram.len, vaddr, paddr & 0xffff_f000, 0x3f, is_el2);
            return paddr;
        }

        const is_priv = el != 0;
        const vpn: u52 = @truncate((vaddr & 0x00ff_ffff_ffff_ffff) >> 12);
        const idx: usize = @as(usize, @truncate(vpn)) & tlb_mask;
        const entry = &self.tlb[idx];

        const req_perm: u8 = switch (access) {
            .read => if (is_priv) perm_priv_r else perm_user_r,
            .write => if (is_priv) perm_priv_w else perm_user_w,
            .fetch => if (is_priv) perm_priv_x else perm_user_x,
        };

        if (entry.gen == self.tlb_gen and entry.vpn == vpn) {
            if ((entry.perms & req_perm) != 0) {
                self.populateSoftTlb64(ram.len, vaddr, entry.ppn_base, entry.perms, is_el2);
                return entry.ppn_base | @as(u32, @truncate(vaddr & 0xfff));
            }
            self.recordFault64AtEl(vaddr, access, el, 0b001100 | @as(u6, entry.level));
            return error.Abort;
        }

        return self.walkAndFillTlb64(ram, vaddr, vpn, access, el, req_perm);
    }

    noinline fn walkAndFillTlb(
        self: *Mmu,
        ram: []const u8,
        vaddr: u32,
        access: AccessKind,
        is_priv: bool,
        req_perm: u8,
    ) error{Abort}!u32 {
        _ = is_priv;
        if (self.isLpae()) {
            return self.walkAndFillTlbLpae(ram, vaddr, access, req_perm);
        }

        // 1. Choose TTBR0 vs TTBR1 based on TTBCR.N
        const n: u5 = @truncate(self.ttbcr & 7);
        const use_ttbr1 = if (n == 0) false else (vaddr >> @as(u5, @truncate(@as(u6, 32) -% n))) != 0;
        const table_base: u32 = if (use_ttbr1)
            (self.ttbr1 & 0xffff_c000)
        else blk: {
            const mask: u32 = (@as(u32, 0xffff_ffff) << (@as(u5, 14) -% n));
            break :blk self.ttbr0 & mask;
        };

        const l1_index: u32 = vaddr >> 20;
        const l1_ShiftMask: u32 = if (use_ttbr1) 0xfff else (@as(u32, 0xfff) >> n);
        const l1_addr: u32 = (table_base | ((l1_index & l1_ShiftMask) << 2)) & 0x3fff_ffff;
        if (l1_addr + 4 > ram.len) {
            self.recordFault(vaddr, access, 0x05, 0);
            return error.Abort;
        }
        const l1_desc = std.mem.readInt(u32, ram[l1_addr..][0..4], .little);

        const xp = self.extendedPageTables();
        var phys_page_base: u32 = 0;
        var domain: u4 = 0;
        var ap: u2 = 0;
        var apx: u1 = 0;
        var xn: bool = false;
        var is_page: bool = false;

        switch (@as(u2, @truncate(l1_desc))) {
            0b00 => {
                // Section Translation Fault (FS = 0x05)
                self.recordFault(vaddr, access, 0x05, 0);
                return error.Abort;
            },
            0b10 => {
                // Section (1 MB) or Supersection (16 MB)
                is_page = false;
                if ((l1_desc & (1 << 18)) != 0) {
                    // 16 MB Supersection
                    domain = 0;
                    phys_page_base = (l1_desc & 0xff00_0000) | (vaddr & 0x00ff_f000);
                } else {
                    // 1 MB Section
                    domain = @truncate(l1_desc >> 5);
                    phys_page_base = (l1_desc & 0xfff0_0000) | (vaddr & 0x000f_f000);
                }
                ap = @truncate(l1_desc >> 10);
                apx = if (xp) @truncate(l1_desc >> 15) else 0;
                xn = if (xp) ((l1_desc & (1 << 4)) != 0) else false;
            },
            0b01 => {
                // Coarse Page Table (1 KB, 256 entries of 4 KB / 64 KB pages)
                is_page = true;
                domain = @truncate(l1_desc >> 5);
                const l2_base = l1_desc & 0xffff_fc00;
                const l2_index = (vaddr >> 12) & 0xff;
                const l2_addr = (l2_base | (l2_index << 2)) & 0x3fff_ffff;
                if (l2_addr + 4 > ram.len) {
                    self.recordFault(vaddr, access, 0x07, domain);
                    return error.Abort;
                }
                const l2_desc = std.mem.readInt(u32, ram[l2_addr..][0..4], .little);
                switch (@as(u2, @truncate(l2_desc))) {
                    0b00 => {
                        // Page Translation Fault (FS = 0x07)
                        self.recordFault(vaddr, access, 0x07, domain);
                        return error.Abort;
                    },
                    0b01 => {
                        // 64 KB Large Page
                        phys_page_base = (l2_desc & 0xffff_0000) | (vaddr & 0x0000_f000);
                        ap = @truncate(l2_desc >> 4);
                        apx = if (xp) @truncate(l2_desc >> 9) else 0;
                        xn = if (xp) ((l2_desc & (1 << 15)) != 0) else false;
                    },
                    0b10, 0b11 => {
                        // 4 KB Small Page
                        phys_page_base = l2_desc & 0xffff_f000;
                        ap = @truncate(l2_desc >> 4);
                        apx = if (xp) @truncate(l2_desc >> 9) else 0;
                        xn = if (xp) ((l2_desc & 1) != 0) else false;
                    },
                }
            },
            0b11 => {
                // Reserved / Fine page table fault
                self.recordFault(vaddr, access, 0x05, 0);
                return error.Abort;
            },
        }

        // Check Domain Access Control Register (DACR)
        const dom_shift: u5 = @as(u5, domain) * 2;
        const dom_mode: u2 = @truncate(self.dacr >> dom_shift);
        var perms: u8 = 0;

        switch (dom_mode) {
            0b00, 0b10 => {
                // Domain Fault (Section = 0x09, Page = 0x0b)
                const fs: u6 = if (is_page) 0x0b else 0x09;
                self.recordFault(vaddr, access, fs, domain);
                return error.Abort;
            },
            0b11 => {
                // Manager domain: all permissions granted regardless of AP
                perms = perm_priv_r | perm_priv_w | perm_priv_x |
                    perm_user_r | perm_user_w | perm_user_x;
            },
            0b01 => {
                // Client domain: evaluate APX and AP[1:0]
                perms = computeClientPerms(apx, ap, xn, self.sctlr, xp);
            },
        }

        // Fill software TLB entry
        const vpn: u52 = @truncate(vaddr >> 12);
        self.tlb[@as(usize, @truncate(vpn)) & tlb_mask] = .{
            .gen = self.tlb_gen,
            .vpn = vpn,
            .ppn_base = phys_page_base,
            .perms = perms,
            .domain = domain,
            .is_page = is_page,
            .level = if (is_page) 2 else 1,
        };

        if ((perms & req_perm) == 0) {
            // Permission Fault (Section = 0x0d, Page = 0x0f)
            const fs: u6 = if (is_page) 0x0f else 0x0d;
            self.recordFault(vaddr, access, fs, domain);
            return error.Abort;
        }

        self.populateSoftTlb32(ram.len, vaddr, phys_page_base, perms);
        return phys_page_base | (vaddr & 0xfff);
    }

    fn walkAndFillTlbLpae(
        self: *Mmu,
        ram: []const u8,
        vaddr: u32,
        access: AccessKind,
        req_perm: u8,
    ) error{Abort}!u32 {
        const t0sz: u3 = @truncate(self.ttbcr);
        const t1sz: u3 = @truncate(self.ttbcr >> 16);

        const below_ttbr0: bool = if (t0sz == 0)
            true
        else blk: {
            const shift: u5 = @intCast(@as(u6, 32) - @as(u6, t0sz));
            const ttbr0_limit: u32 = @as(u32, 1) << shift;
            break :blk (vaddr < ttbr0_limit);
        };

        const above_ttbr1: bool = if (t1sz == 0)
            (t0sz > 0 and !below_ttbr0)
        else blk: {
            const shift: u5 = @intCast(@as(u6, 32) - @as(u6, t1sz));
            const ttbr1_min: u32 = @as(u32, 0xffff_ffff) << shift;
            break :blk (vaddr >= ttbr1_min);
        };

        if (!below_ttbr0 and !above_ttbr1) {
            self.recordFault(vaddr, access, 0b000101, 0);
            return error.Abort;
        }
        const use_ttbr1 = above_ttbr1;

        const epd: u1 = if (use_ttbr1) @truncate(self.ttbcr >> 23) else @truncate(self.ttbcr >> 7);
        if (epd != 0) {
            self.recordFault(vaddr, access, 0b000101, 0);
            return error.Abort;
        }

        const ttbr: u64 = if (use_ttbr1) self.ttbr1_64 else self.ttbr0_64;
        const sz: u3 = if (use_ttbr1) t1sz else t0sz;

        var ap_table: u2 = 0;
        var pxn_table: bool = false;
        var xn_table: bool = false;
        var l2_table_base: u32 = 0;
        var l2_idx: u32 = (vaddr >> 21) & 0x1ff;
        var leaf_level: u2 = 2;
        var leaf_desc: u64 = 0;
        var phys_page_base: u32 = 0;

        if (sz >= 2) {
            // ARMv7 LPAE: when TnSZ >= 2, initial lookup starts directly at Level 2
            const idx_bits: u5 = @intCast(11 - @as(u5, sz));
            l2_idx = (vaddr >> 21) & ((@as(u32, 1) << idx_bits) - 1);
            const align_mask: u32 = ~((@as(u32, 8) << idx_bits) - 1);
            l2_table_base = @as(u32, @truncate(ttbr)) & align_mask;
        } else {
            // Initial lookup starts at Level 1 (PGD)
            const l1_bits: u5 = @intCast(2 - @as(u5, sz));
            const l1_idx: u32 = (vaddr >> 30) & ((@as(u32, 1) << l1_bits) - 1);
            const l1_base: u32 = @as(u32, @truncate(ttbr)) & 0xffff_ffe0;
            const l1_addr: u32 = (l1_base + l1_idx * 8) & 0x3fff_ffff;
            if (l1_addr + 8 > ram.len) {
                self.recordFault(vaddr, access, 0b000101, 0);
                return error.Abort;
            }
            const l1_desc = std.mem.readInt(u64, ram[l1_addr..][0..8], .little);
            switch (@as(u2, @truncate(l1_desc))) {
                0b00, 0b10 => {
                    self.recordFault(vaddr, access, 0b000101, 0);
                    return error.Abort;
                },
                0b01 => {
                    // 1 GB Block at Level 1
                    leaf_level = 1;
                    leaf_desc = l1_desc;
                    phys_page_base = (@as(u32, @truncate(l1_desc)) & 0xc000_0000) | (vaddr & 0x3fff_f000);
                },
                0b11 => {
                    // Level 1 Table Descriptor -> Level 2
                    l2_table_base = @as(u32, @truncate(l1_desc)) & 0xffff_f000;
                    ap_table |= @truncate(l1_desc >> 61);
                    if ((l1_desc & (1 << 59)) != 0) pxn_table = true;
                    if ((l1_desc & (1 << 60)) != 0) xn_table = true;
                },
            }
        }

        if (leaf_level != 1) {
            const l2_addr: u32 = (l2_table_base + l2_idx * 8) & 0x3fff_ffff;
            if (l2_addr + 8 > ram.len) {
                self.recordFault(vaddr, access, 0b000110, 0);
                return error.Abort;
            }
            const l2_desc = std.mem.readInt(u64, ram[l2_addr..][0..8], .little);
            switch (@as(u2, @truncate(l2_desc))) {
                0b00, 0b10 => {
                    // Level 2 Translation Fault (0b000110 = 6)
                    self.recordFault(vaddr, access, 0b000110, 0);
                    return error.Abort;
                },
                0b01 => {
                    // 2 MB Block at Level 2
                    leaf_level = 2;
                    leaf_desc = l2_desc;
                    phys_page_base = (@as(u32, @truncate(l2_desc)) & 0xffe0_0000) | (vaddr & 0x001f_f000);
                },
                0b11 => {
                    // Level 2 Table Descriptor -> Level 3 (PTE)
                    leaf_level = 3;
                    ap_table |= @truncate(l2_desc >> 61);
                    if ((l2_desc & (1 << 59)) != 0) pxn_table = true;
                    if ((l2_desc & (1 << 60)) != 0) xn_table = true;

                    const l3_table_base: u32 = @as(u32, @truncate(l2_desc)) & 0xffff_f000;
                    const l3_idx: u32 = (vaddr >> 12) & 0x1ff;
                    const l3_addr: u32 = (l3_table_base + l3_idx * 8) & 0x3fff_ffff;
                    if (l3_addr + 8 > ram.len) {
                        self.recordFault(vaddr, access, 0b000111, 0);
                        return error.Abort;
                    }
                    const l3_desc = std.mem.readInt(u64, ram[l3_addr..][0..8], .little);
                    if (@as(u2, @truncate(l3_desc)) != 0b11) {
                        // Level 3 Translation Fault (0b000111 = 7)
                        self.recordFault(vaddr, access, 0b000111, 0);
                        return error.Abort;
                    }
                    leaf_desc = l3_desc;
                    phys_page_base = @as(u32, @truncate(l3_desc)) & 0xffff_f000;
                },
            }
        }

        // Check Access Flag (AF = bit 10)
        if ((leaf_desc & (1 << 10)) == 0) {
            self.recordFault(vaddr, access, 0b001000 | @as(u6, leaf_level), 0);
            return error.Abort;
        }

        // Compute permissions from AP[2:1] (bits [7:6]) and table restrictions
        const ap21: u2 = @truncate(leaf_desc >> 6);
        var perms: u8 = switch (ap21) {
            0b00 => perm_priv_r | perm_priv_w,
            0b01 => perm_priv_r | perm_priv_w | perm_user_r | perm_user_w,
            0b10 => perm_priv_r,
            0b11 => perm_priv_r | perm_user_r,
        };
        if ((ap_table & 0b01) != 0) {
            perms &= ~(perm_user_r | perm_user_w | perm_user_x);
        }
        if ((ap_table & 0b10) != 0) {
            perms &= ~(perm_priv_w | perm_user_w);
        }

        const pxn = pxn_table or ((leaf_desc & (@as(u64, 1) << 53)) != 0);
        const xn = xn_table or ((leaf_desc & (@as(u64, 1) << 54)) != 0);
        const wxn = (self.sctlr & (1 << 19)) != 0 and ((perms & (perm_priv_w | perm_user_w)) != 0);
        const uwxn = (self.sctlr & (1 << 20)) != 0 and ((perms & perm_user_w) != 0);

        if (!xn and !pxn and !wxn and !uwxn and (perms & perm_priv_r) != 0) {
            perms |= perm_priv_x;
        }
        if (!xn and !wxn and (perms & perm_user_r) != 0) {
            perms |= perm_user_x;
        }

        const vpn: u52 = @truncate(vaddr >> 12);
        self.tlb[@as(usize, @truncate(vpn)) & tlb_mask] = .{
            .gen = self.tlb_gen,
            .vpn = vpn,
            .ppn_base = phys_page_base,
            .perms = perms,
            .domain = 0,
            .is_page = (leaf_level >= 2),
            .level = leaf_level,
        };

        if ((perms & req_perm) == 0) {
            self.recordFault(vaddr, access, 0b001100 | @as(u6, leaf_level), 0);
            return error.Abort;
        }

        self.populateSoftTlb32(ram.len, vaddr, phys_page_base, perms);
        return phys_page_base | (vaddr & 0xfff);
    }

    noinline fn walkAndFillTlb64(
        self: *Mmu,
        ram: []const u8,
        vaddr: u64,
        vpn: u52,
        access: AccessKind,
        el: u2,
        req_perm: u8,
    ) error{Abort}!u32 {
        const is_el2 = (el == 2) and ((self.hcr_el2 & (@as(u64, 1) << 34)) == 0);
        const use_ttbr1 = !is_el2 and (((vaddr >> 55) & 1) != 0);
        const tcr = if (is_el2) self.tcr_el2 else self.tcr_el1;
        const tnsz_raw: u6 = if (use_ttbr1) @truncate(tcr >> 16) else @truncate(tcr);
        const epd: u1 = if (is_el2) 0 else if (use_ttbr1) @truncate(tcr >> 23) else @truncate(tcr >> 7);
        if (epd != 0 or tnsz_raw < 16 or tnsz_raw > 39) {
            self.recordFault64AtEl(vaddr, access, el, 0b000100);
            return error.Abort;
        }

        // Canonical address check (ignoring top byte [63:56] when TBI or bit 55 sign-extended)
        const va_bits: u6 = @intCast(@as(u7, 64) - @as(u7, tnsz_raw));
        const clean_va: u64 = if (use_ttbr1) (vaddr | 0xff00_0000_0000_0000) else (vaddr & 0x00ff_ffff_ffff_ffff);
        const top_shifted = clean_va >> va_bits;
        const expected_top: u64 = if (use_ttbr1) ((@as(u64, 1) << tnsz_raw) - 1) else 0;
        if (top_shifted != expected_top) {
            self.recordFault64AtEl(vaddr, access, el, 0b000100);
            return error.Abort;
        }

        const ttbr: u64 = if (is_el2) self.ttbr0_el2 else if (use_ttbr1) self.ttbr1_64 else self.ttbr0_64;
        var table_base: u32 = @as(u32, @truncate(ttbr)) & 0xffff_f000;
        const start_level: u2 = if (tnsz_raw <= 24) 0 else if (tnsz_raw <= 33) 1 else 2;

        var ap_table: u2 = 0;
        var pxn_table: bool = false;
        var xn_table: bool = false;
        var leaf_level: u2 = 3;
        var leaf_desc: u64 = 0;
        var phys_page_base: u32 = 0;

        var level: u2 = start_level;
        while (true) {
            const shift: u6 = switch (level) {
                0 => 39,
                1 => 30,
                2 => 21,
                3 => 12,
            };
            const idx_mask: u64 = if (level == start_level) blk: {
                const idx_bits: u6 = va_bits - shift;
                break :blk if (idx_bits >= 9) 0x1ff else ((@as(u64, 1) << idx_bits) - 1);
            } else 0x1ff;
            const idx: u32 = @truncate((clean_va >> shift) & idx_mask);
            const desc_addr: u32 = (table_base + idx * 8) & 0x3fff_ffff;
            if (desc_addr + 8 > ram.len) {
                self.recordFault64AtEl(vaddr, access, el, 0b000100 | @as(u6, level));
                return error.Abort;
            }
            const desc = std.mem.readInt(u64, ram[desc_addr..][0..8], .little);
            const dtype: u2 = @truncate(desc);

            if (dtype == 0b00 or dtype == 0b10) {
                self.recordFault64AtEl(vaddr, access, el, 0b000100 | @as(u6, level));
                return error.Abort;
            }

            if (level == 3) {
                // At level 3, 0b11 is a 4 KB Page Descriptor
                leaf_level = 3;
                leaf_desc = desc;
                phys_page_base = @as(u32, @truncate(desc)) & 0xffff_f000;
                break;
            }

            if (dtype == 0b01) {
                if (level == 0) {
                    // Block descriptors are not permitted at level 0 with 4 KB granule
                    self.recordFault64AtEl(vaddr, access, el, 0b000100);
                    return error.Abort;
                }
                leaf_level = level;
                leaf_desc = desc;
                if (level == 1) {
                    phys_page_base = (@as(u32, @truncate(desc)) & 0xc000_0000) | (@as(u32, @truncate(clean_va)) & 0x3fff_f000);
                } else {
                    phys_page_base = (@as(u32, @truncate(desc)) & 0xffe0_0000) | (@as(u32, @truncate(clean_va)) & 0x001f_f000);
                }
                break;
            }

            // Table descriptor (0b11 at level 0, 1, or 2)
            ap_table |= @truncate(desc >> 61);
            if ((desc & (@as(u64, 1) << 59)) != 0) pxn_table = true;
            if ((desc & (@as(u64, 1) << 60)) != 0) xn_table = true;
            table_base = @as(u32, @truncate(desc)) & 0xffff_f000;
            level += 1;
        }

        // Check Access Flag (AF = bit 10)
        if ((leaf_desc & (1 << 10)) == 0) {
            self.recordFault64AtEl(vaddr, access, el, 0b001000 | @as(u6, leaf_level));
            return error.Abort;
        }

        const ap21: u2 = @truncate(leaf_desc >> 6);
        var perms: u8 = switch (ap21) {
            0b00 => perm_priv_r | perm_priv_w,
            0b01 => perm_priv_r | perm_priv_w | perm_user_r | perm_user_w,
            0b10 => perm_priv_r,
            0b11 => perm_priv_r | perm_user_r,
        };
        if ((ap_table & 0b01) != 0) {
            perms &= ~(perm_user_r | perm_user_w | perm_user_x);
        }
        if ((ap_table & 0b10) != 0) {
            perms &= ~(perm_priv_w | perm_user_w);
        }

        const sctlr = if (is_el2) self.sctlr_el2 else self.sctlr_el1;
        const pxn = pxn_table or ((leaf_desc & (@as(u64, 1) << 53)) != 0);
        const uxn = xn_table or ((leaf_desc & (@as(u64, 1) << 54)) != 0);
        const wxn = (sctlr & (1 << 19)) != 0 and ((perms & (perm_priv_w | perm_user_w)) != 0);

        if (!pxn and !wxn and ((perms & perm_user_w) == 0) and (perms & perm_priv_r) != 0) {
            perms |= perm_priv_x;
        }
        if (!uxn and !wxn and (perms & perm_user_r) != 0) {
            perms |= perm_user_x;
        }

        self.tlb[@as(usize, @truncate(vpn)) & tlb_mask] = .{
            .gen = self.tlb_gen,
            .vpn = vpn,
            .ppn_base = phys_page_base,
            .perms = perms,
            .domain = 0,
            .is_page = (leaf_level >= 2),
            .level = leaf_level,
        };

        if ((perms & req_perm) == 0) {
            self.recordFault64AtEl(vaddr, access, el, 0b001100 | @as(u6, leaf_level));
            return error.Abort;
        }

        self.populateSoftTlb64(ram.len, vaddr, phys_page_base, perms, is_el2);
        return phys_page_base | @as(u32, @truncate(vaddr & 0xfff));
    }

    pub fn recordFault64(self: *Mmu, vaddr: u64, access: AccessKind, is_priv: bool, fsc: u6) void {
        self.recordFault64AtEl(vaddr, access, if (is_priv) 1 else 0, fsc);
    }

    pub fn recordFault64AtEl(self: *Mmu, vaddr: u64, access: AccessKind, el: u2, fsc: u6) void {
        const is_priv = el != 0;
        const ec: u32 = switch (access) {
            .fetch => if (is_priv) 0b100001 else 0b100000, // Instruction Abort (same/lower EL)
            .read, .write => if (is_priv) 0b100101 else 0b100100, // Data Abort (same/lower EL)
        };
        const wnr: u32 = if (access == .write) (1 << 6) else 0;
        const esr = (ec << 26) | (1 << 25) | wnr | @as(u32, fsc);
        if (el >= 2) {
            self.far_el2 = vaddr;
            self.esr_el2 = esr;
        } else {
            self.far_el1 = vaddr;
            self.dfar = @truncate(vaddr);
            self.esr_el1 = esr;
        }
    }

    fn computeClientPerms(apx: u1, ap: u2, xn: bool, sctlr: u32, xp: bool) u8 {
        var p: u8 = 0;
        const ap3: u3 = (@as(u3, apx) << 2) | ap;
        switch (ap3) {
            0b000 => {
                // When XP=0, check legacy S (bit 8) and R (bit 9) bits
                if (!xp) {
                    const s = (sctlr & (1 << 8)) != 0;
                    const r = (sctlr & (1 << 9)) != 0;
                    if (s and !r) p = perm_priv_r;
                    if (!s and r) p = perm_priv_r | perm_user_r;
                }
            },
            0b001 => p = perm_priv_r | perm_priv_w,
            0b010 => p = perm_priv_r | perm_priv_w | perm_user_r,
            0b011 => p = perm_priv_r | perm_priv_w | perm_user_r | perm_user_w,
            0b100 => {},
            0b101 => p = perm_priv_r,
            0b110, 0b111 => p = perm_priv_r | perm_user_r,
        }
        if (!xn) {
            if ((p & perm_priv_r) != 0) p |= perm_priv_x;
            if ((p & perm_user_r) != 0) p |= perm_user_x;
        }
        return p;
    }

    pub fn recordFault(self: *Mmu, vaddr: u32, access: AccessKind, fs: u6, domain: u4) void {
        if (self.isLpae()) {
            const lpae_bit: u32 = 1 << 9;
            const status: u32 = fs;
            switch (access) {
                .fetch => {
                    self.ifar = vaddr;
                    self.ifsr = lpae_bit | status;
                },
                .read, .write => {
                    const wnr: u32 = if (access == .write) (1 << 11) else 0;
                    self.dfar = vaddr;
                    self.dfsr = wnr | lpae_bit | status;
                },
            }
            return;
        }

        const fs_lo: u32 = fs & 0xf;
        const fs_hi: u32 = (@as(u32, fs >> 4) & 1) << 10;
        switch (access) {
            .fetch => {
                self.ifar = vaddr;
                self.ifsr = fs_hi | fs_lo;
            },
            .read, .write => {
                const wnr: u32 = if (access == .write) (1 << 11) else 0;
                const dom: u32 = @as(u32, domain) << 4;
                self.dfar = vaddr;
                self.dfsr = wnr | fs_hi | dom | fs_lo;
            },
        }
    }

    /// Reads a 64-bit CP15 register (`MRRC p15, opc1, Rt, Rt2, CRm`).
    pub fn readCp15_64(self: *Mmu, opc1: u4, crm: u4) u64 {
        return switch (crm) {
            2 => switch (opc1) {
                0 => self.ttbr0_64,
                1 => self.ttbr1_64,
                else => 0,
            },
            7 => self.par_64,
            14 => switch (opc1) {
                0 => self.cntpct, // CNTPCT
                1 => self.cntpct -% self.cntvoff, // CNTVCT
                2 => self.cntp_cval, // CNTP_CVAL
                3 => self.cntv_cval, // CNTV_CVAL
                4 => self.cntvoff, // CNTVOFF
                else => 0,
            },
            15 => self.cpuectlr_64,
            else => 0,
        };
    }

    /// Writes a 64-bit CP15 register (`MCRR p15, opc1, Rt, Rt2, CRm`).
    pub fn writeCp15_64(self: *Mmu, opc1: u4, crm: u4, val: u64) void {
        switch (crm) {
            2 => {
                switch (opc1) {
                    0 => {
                        self.ttbr0_64 = val;
                        self.ttbr0 = @truncate(val);
                    },
                    1 => {
                        self.ttbr1_64 = val;
                        self.ttbr1 = @truncate(val);
                    },
                    else => {},
                }
                self.flushTlb();
            },
            7 => self.par_64 = val,
            14 => switch (opc1) {
                2 => {
                    self.cntp_cval = val;
                    _ = self.timerIrqLines();
                },
                3 => {
                    self.cntv_cval = val;
                    _ = self.timerIrqLines();
                },
                4 => {
                    self.cntvoff = val;
                    _ = self.timerIrqLines();
                },
                else => {},
            },
            15 => self.cpuectlr_64 = val,
            else => {},
        }
    }

    /// Reads a CP15 register (`MRC p15, opc1, Rt, CRn, CRm, opc2`).
    pub fn readCp15(self: *Mmu, opc1: u3, crn: u4, crm: u4, opc2: u3) u32 {
        if (crn == 0 and opc1 == 1) {
            // CCSIDR (opc2=0), CLIDR (opc2=1), AIDR (opc2=7): return 0 (LoC=0, single-step cache ops)
            return 0;
        }
        if (crn == 0 and opc1 == 2 and crm == 0 and opc2 == 0) {
            return self.csselr;
        }
        return switch (crn) {
            0 => switch (crm) {
                0 => switch (opc2) {
                    0 => if (self.is_cortex_a53) 0x410fd034 else 0x410fb767, // MIDR: Cortex-A53 r0p4 vs ARM1176JZF-S r0p7
                    1 => if (self.is_cortex_a53) 0x84448004 else 0x1d152152, // CTR
                    2 => 0x00000000, // TCMTR: no TCM
                    3 => 0x00000800, // TLBTR: 64-entry unified TLB
                    5 => if (self.is_cortex_a53) (0x80000000 | @as(u32, self.core_id)) else 0x00000000, // MPIDR
                    6 => 0x00000000, // REVIDR
                    else => 0,
                },
                1 => switch (opc2) {
                    0 => if (self.is_cortex_a53) 0x00000131 else 0x00000111, // ID_PFR0
                    1 => if (self.is_cortex_a53) 0x00011011 else 0x00000011, // ID_PFR1 (Generic Timer + Virt + Sec)
                    2 => if (self.is_cortex_a53) 0x03010066 else 0x00000033, // ID_DFR0
                    3 => 0x00000000, // ID_AFR0
                    4 => if (self.is_cortex_a53) 0x10201105 else 0x01130003, // ID_MMFR0 (5 = VMSA v7 + LPAE)
                    5 => if (self.is_cortex_a53) 0x40010000 else 0x10030302, // ID_MMFR1
                    6 => if (self.is_cortex_a53) 0x01260000 else 0x01222100, // ID_MMFR2
                    7 => if (self.is_cortex_a53) 0x02102211 else 0x00000000, // ID_MMFR3
                },
                2 => switch (opc2) {
                    0 => if (self.is_cortex_a53) 0x02101110 else 0x00140011, // ID_ISAR0 (SDIV/UDIV)
                    1 => if (self.is_cortex_a53) 0x13112111 else 0x12002111, // ID_ISAR1
                    2 => if (self.is_cortex_a53) 0x21232042 else 0x11231111, // ID_ISAR2
                    3 => if (self.is_cortex_a53) 0x01112131 else 0x01102131, // ID_ISAR3
                    4 => if (self.is_cortex_a53) 0x00011142 else 0x00000141, // ID_ISAR4
                    5 => if (self.is_cortex_a53) 0x00010001 else 0x00000000, // ID_ISAR5 (SEVL, CRC32; BCM2837 has no Crypto)
                    else => 0,
                },
                else => 0,
            },
            1 => switch (opc2) {
                0 => self.sctlr,
                1 => self.actlr,
                2 => self.cpacr,
                else => 0,
            },
            2 => switch (opc2) {
                0 => self.ttbr0,
                1 => self.ttbr1,
                2 => self.ttbcr,
                else => 0,
            },
            3 => self.dacr,
            5 => switch (opc2) {
                0 => self.dfsr,
                1 => self.ifsr,
                else => 0,
            },
            6 => switch (opc2) {
                0 => self.dfar,
                2 => self.ifar,
                else => 0,
            },
            7 => switch (crm) {
                4 => @truncate(self.par_64),
                14 => 0, // DCCISW / cache dirty status (0 = clean)
                10 => 0, // Cache status
                else => 0,
            },
            10 => switch (crm) {
                2 => switch (opc2) {
                    0 => self.mair0,
                    1 => self.mair1,
                    else => 0,
                },
                else => 0,
            },
            12 => switch (crm) {
                0 => switch (opc2) {
                    0 => self.vbar,
                    else => 0,
                },
                else => 0,
            },
            13 => switch (opc2) {
                0 => self.fcseidr,
                1 => self.contextidr,
                2 => self.tpidrurw,
                3 => self.tpidruro,
                4 => self.tpidrprw,
                else => 0,
            },
            14 => blk: {
                _ = self.timerIrqLines();
                if (opc1 == 4 and crm == 2) {
                    break :blk switch (opc2) {
                        0 => @bitCast(@as(i32, @truncate(@as(i64, @bitCast(self.cnthp_cval -% self.cntpct))))),
                        1 => self.cnthp_ctl,
                        else => 0,
                    };
                }
                break :blk switch (crm) {
                    0 => self.cntfrq,
                    1 => self.cntkctl,
                    2 => switch (opc2) {
                        0 => @bitCast(@as(i32, @truncate(@as(i64, @bitCast(self.cntp_cval -% self.cntpct))))),
                        1 => self.cntp_ctl,
                        2 => @truncate(self.cntp_cval),
                        else => 0,
                    },
                    3 => switch (opc2) {
                        0 => @bitCast(@as(i32, @truncate(@as(i64, @bitCast(self.cntv_cval -% (self.cntpct -% self.cntvoff)))))),
                        1 => self.cntv_ctl,
                        2 => @truncate(self.cntv_cval),
                        else => 0,
                    },
                    else => 0,
                };
            },
            15 => switch (crm) {
                0 => if (self.is_cortex_a53) 0x4000_0000 else 0, // CBAR (PERIPHBASE)
                12 => switch (opc2) {
                    0 => self.pmcr,
                    1 => self.pmccntr,
                    else => 0,
                },
                else => 0,
            },
            else => 0,
        };
    }

    /// Writes a CP15 register (`MCR p15, opc1, Rt, CRn, CRm, opc2`).
    pub fn writeCp15(self: *Mmu, opc1: u3, crn: u4, crm: u4, opc2: u3, val: u32) void {
        if (crn == 0 and opc1 == 2 and crm == 0 and opc2 == 0) {
            self.csselr = val;
            return;
        }
        switch (crn) {
            1 => switch (opc2) {
                0 => {
                    const diff = self.sctlr ^ val;
                    self.sctlr = val | 0x00050070;
                    if (diff != 0) self.flushTlb();
                },
                1 => self.actlr = val,
                2 => self.cpacr = val,
                else => {},
            },
            2 => {
                switch (opc2) {
                    0 => {
                        self.ttbr0 = val;
                        self.ttbr0_64 = (self.ttbr0_64 & 0xffff_ffff_0000_0000) | @as(u64, val);
                    },
                    1 => {
                        self.ttbr1 = val;
                        self.ttbr1_64 = (self.ttbr1_64 & 0xffff_ffff_0000_0000) | @as(u64, val);
                    },
                    2 => self.ttbcr = val,
                    else => {},
                }
                self.flushTlb();
            },
            3 => {
                self.dacr = val;
                self.flushTlb();
            },
            5 => switch (opc2) {
                0 => self.dfsr = val,
                1 => self.ifsr = val,
                else => {},
            },
            6 => switch (opc2) {
                0 => self.dfar = val,
                2 => self.ifar = val,
                else => {},
            },
            7 => {
                if (crm == 4 and opc2 == 0) {
                    self.par_64 = (self.par_64 & 0xffff_ffff_0000_0000) | @as(u64, val);
                } else if (crm == 0 and opc2 == 4) {
                    // c7, c0, 4 is Wait For Interrupt (WFI)
                    self.halted_wfi = true;
                }
            },
            8 => {
                // TLB maintenance operations
                if (opc2 == 1 or opc2 == 3) {
                    self.flushTlbMva(val);
                } else {
                    self.flushTlb();
                }
                if (crm == 3) self.tlb_broadcast_full = true;
            },
            10 => switch (crm) {
                2 => switch (opc2) {
                    0 => self.mair0 = val,
                    1 => self.mair1 = val,
                    else => {},
                },
                else => {},
            },
            12 => switch (crm) {
                0 => switch (opc2) {
                    0 => self.vbar = val & ~@as(u32, 0x1f),
                    else => {},
                },
                else => {},
            },
            13 => switch (opc2) {
                0 => {
                    self.fcseidr = val;
                    self.flushTlb();
                },
                1 => {
                    self.contextidr = val;
                    self.flushTlb();
                },
                2 => self.tpidrurw = val,
                3 => self.tpidruro = val,
                4 => self.tpidrprw = val,
                else => {},
            },
            14 => {
                if (opc1 == 4 and crm == 2) {
                    switch (opc2) {
                        0 => {
                            const signed_tval: i64 = @as(i32, @bitCast(val));
                            self.cnthp_cval = self.cntpct +% @as(u64, @bitCast(signed_tval));
                        },
                        1 => self.cnthp_ctl = (self.cnthp_ctl & 4) | (val & 3),
                        else => {},
                    }
                    _ = self.timerIrqLines();
                    return;
                }
                switch (crm) {
                    0 => self.cntfrq = val,
                    1 => self.cntkctl = val,
                    2 => switch (opc2) {
                        0 => {
                            const signed_tval: i64 = @as(i32, @bitCast(val));
                            self.cntp_cval = self.cntpct +% @as(u64, @bitCast(signed_tval));
                        },
                        1 => self.cntp_ctl = (self.cntp_ctl & 4) | (val & 3),
                        else => {},
                    },
                    3 => switch (opc2) {
                        0 => {
                            const signed_tval: i64 = @as(i32, @bitCast(val));
                            const cntvct = self.cntpct -% self.cntvoff;
                            self.cntv_cval = cntvct +% @as(u64, @bitCast(signed_tval));
                        },
                        1 => self.cntv_ctl = (self.cntv_ctl & 4) | (val & 3),
                        else => {},
                    },
                    else => {},
                }
                _ = self.timerIrqLines();
            },
            15 => switch (crm) {
                12 => switch (opc2) {
                    0 => self.pmcr = val,
                    1 => self.pmccntr = val,
                    else => {},
                },
                else => {},
            },
            else => {},
        }
    }
};

test "ARMv6 MMU section and 4KB page translation and fault status" {
    const allocator = std.testing.allocator;
    const ram = try allocator.alloc(u8, 2 * 1024 * 1024);
    defer allocator.free(ram);
    @memset(ram, 0);

    var mmu: Mmu = .{};
    // Enable MMU (bit 0) + Extended Page Tables XP (bit 23)
    mmu.writeCp15(0, 1, 0, 0, (1 << 0) | (1 << 23));
    // Set TTBR0 to 0x00004000, DACR domain 0 = Client (0b01)
    mmu.writeCp15(0, 2, 0, 0, 0x00004000);
    mmu.writeCp15(0, 3, 0, 0, 0x00000001);

    // 1. Map VA 0xc0000000 -> PA 0x00000000 as 1 MB Section, AP=01 (priv RW, user no access), domain 0
    const l1_sec_idx: usize = 0xc00;
    const sec_desc: u32 = 0x00000000 | (0b01 << 10) | (0 << 5) | 0b10;
    std.mem.writeInt(u32, ram[0x4000 + l1_sec_idx * 4 ..][0..4], sec_desc, .little);

    const pa1 = try mmu.translate(ram, 0xc0012345, .write, true);
    try std.testing.expectEqual(@as(u32, 0x00012345), pa1);

    // User read to priv-only section should fault with Section Permission Fault (0x0d)
    try std.testing.expectError(error.Abort, mmu.translate(ram, 0xc0012345, .read, false));
    try std.testing.expectEqual(@as(u32, 0xc0012345), mmu.dfar);
    try std.testing.expectEqual(@as(u32, 0x0d), mmu.dfsr & 0x40f);

    // 2. Map VA 0x00010000 -> PA 0x00105000 via Coarse Page Table at 0x00008000, User RO (APX=1, AP=10)
    const l1_pt_desc: u32 = 0x00008000 | (0 << 5) | 0b01;
    std.mem.writeInt(u32, ram[0x4000 + 0 * 4 ..][0..4], l1_pt_desc, .little);
    const l2_pte: u32 = 0x00105000 | (1 << 9) | (0b10 << 4) | 0b10;
    std.mem.writeInt(u32, ram[0x8000 + 0x10 * 4 ..][0..4], l2_pte, .little);
    mmu.flushTlb();

    const pa2 = try mmu.translate(ram, 0x00010abc, .read, false);
    try std.testing.expectEqual(@as(u32, 0x00105abc), pa2);

    // User write to RO page should fault with Page Permission Fault (0x0f) and WnR (bit 11) set
    try std.testing.expectError(error.Abort, mmu.translate(ram, 0x00010abc, .write, false));
    try std.testing.expectEqual(@as(u32, 0x00010abc), mmu.dfar);
    try std.testing.expectEqual(@as(u32, (1 << 11) | 0x0f), mmu.dfsr);
}

test "Cortex-A53 LPAE 3-level MMU translation (T1SZ=2 TTBR1_OFFSET, 2MB block, 4KB page) and Generic Timer" {
    const allocator = std.testing.allocator;
    const ram = try allocator.alloc(u8, 4 * 1024 * 1024);
    defer allocator.free(ram);
    @memset(ram, 0);

    var mmu: Mmu = .{ .is_cortex_a53 = true, .core_id = 2 };
    try std.testing.expectEqual(@as(u32, 0x410fd034), mmu.readCp15(0, 0, 0, 0));
    try std.testing.expectEqual(@as(u32, 0x80000002), mmu.readCp15(0, 0, 0, 5));
    try std.testing.expectEqual(@as(u32, 5), mmu.readCp15(0, 0, 1, 4) & 0xf); // LPAE support

    // Enable LPAE (EAE=1, T1SZ=2 for 3G/1G split, T0SZ=0) and MMU
    mmu.writeCp15(0, 2, 0, 2, (1 << 31) | (2 << 16));
    mmu.writeCp15_64(0, 2, 0x0000_3000); // TTBR0 -> PGD at 0x3000
    mmu.writeCp15_64(1, 2, 0x0000_7000); // TTBR1 -> L2 PMD3 directly at 0x7000 (TTBR1_OFFSET = 0x4000)
    mmu.writeCp15(0, 1, 0, 0, 1); // SCTLR.M = 1

    // Map kernel 2 MB block at VA 0xc0200000 (PMD3 index 1) -> PA 0x00200000, AF=1, AP[2:1]=00 (priv RW)
    const l2_block_desc: u64 = 0x0020_0000 | (1 << 10) | 0b01;
    std.mem.writeInt(u64, ram[0x7000 + 1 * 8 ..][0..8], l2_block_desc, .little);

    const k_pa = try mmu.translate(ram, 0xc023_4567, .write, true);
    try std.testing.expectEqual(@as(u32, 0x0023_4567), k_pa);

    // Map user 4 KB page at VA 0x0000_5000 via TTBR0 (L1 at 0x3000 -> L2 at 0x4000 -> L3 at 0x8000) -> PA 0x0012_3000, AF=1, AP[2:1]=11 (user RO)
    std.mem.writeInt(u64, ram[0x3000..][0..8], 0x0000_4000 | 0b11, .little);
    std.mem.writeInt(u64, ram[0x4000..][0..8], 0x0000_8000 | 0b11, .little);
    std.mem.writeInt(u64, ram[0x8000 + 5 * 8 ..][0..8], 0x0012_3000 | (1 << 10) | (0b11 << 6) | 0b11, .little);
    mmu.flushTlb();

    const u_pa = try mmu.translate(ram, 0x0000_5678, .read, false);
    try std.testing.expectEqual(@as(u32, 0x0012_3678), u_pa);

    // User write to RO L3 page -> LPAE Level 3 Permission Fault (LPAE bit 9 | WnR bit 11 | 0x0f)
    try std.testing.expectError(error.Abort, mmu.translate(ram, 0x0000_5678, .write, false));
    try std.testing.expectEqual(@as(u32, (1 << 11) | (1 << 9) | 0x0f), mmu.dfsr);

    // ARMv7 Generic Timer test: arm CNTP with TVAL = 192 ticks (10 us at 19.2 MHz)
    _ = mmu.syncGenericTimer(100);
    mmu.writeCp15(0, 14, 2, 0, 192); // CNTP_TVAL = 192
    mmu.writeCp15(0, 14, 2, 1, 1); // CNTP_CTL = ENABLE
    try std.testing.expectEqual(@as(u4, 0), mmu.syncGenericTimer(105));
    try std.testing.expectEqual(@as(u4, 0b0010), mmu.syncGenericTimer(110));
    try std.testing.expectEqual(@as(u4, 0b0010), mmu.timer_irq_lines);
    // Re-arming CNTP_TVAL immediately clears cached timer_irq_lines
    mmu.writeCp15(0, 14, 2, 0, 192);
    try std.testing.expectEqual(@as(u4, 0), mmu.timer_irq_lines);
}

test "AArch64 VMSAv8-64 4-level (48-bit VA) and 3-level (39-bit VA) page table translation" {
    const allocator = std.testing.allocator;
    const ram = try allocator.alloc(u8, 4 * 1024 * 1024);
    defer allocator.free(ram);
    @memset(ram, 0);

    var mmu: Mmu = .{ .is_cortex_a53 = true };
    // Configure 48-bit VA for TTBR1 (T1SZ=16 -> 4-level L0..L3) and 39-bit VA for TTBR0 (T0SZ=25 -> 3-level L1..L3)
    mmu.tcr_el1 = (16 << 16) | 25;
    mmu.ttbr0_64 = 0x0000_2000; // L1 table for TTBR0
    mmu.ttbr1_64 = 0x0000_6000; // L0 table for TTBR1
    mmu.sctlr_el1 |= 1;
    mmu.sctlr |= 1;

    // 1. TTBR1 4-level walk: VA 0xffff_8000_0020_1234 (L0[256] -> L1[0] -> L2[1] 2MB block -> PA 0x0020_1234)
    std.mem.writeInt(u64, ram[0x6000 + 256 * 8 ..][0..8], 0x0000_7000 | 0b11, .little); // L0[256] -> L1 at 0x7000
    std.mem.writeInt(u64, ram[0x7000 + 0 * 8 ..][0..8], 0x0000_8000 | 0b11, .little); // L1[0] -> L2 at 0x8000
    std.mem.writeInt(u64, ram[0x8000 + 1 * 8 ..][0..8], 0x0020_0000 | (1 << 10) | 0b01, .little); // L2[1] -> 2MB block PA 0x200000, AF=1, Priv RW

    const kpa = try mmu.translate64(ram, 0xffff_8000_0020_1234, .write, true);
    try std.testing.expectEqual(@as(u32, 0x0020_1234), kpa);

    // 2. TTBR0 3-level walk: VA 0x0000_0000_0000_4abc (L1[0] at 0x2000 -> L2[0] at 0x3000 -> L3[4] at 0x4000 -> PA 0x0015_0abc, User RO)
    std.mem.writeInt(u64, ram[0x2000 + 0 * 8 ..][0..8], 0x0000_3000 | 0b11, .little);
    std.mem.writeInt(u64, ram[0x3000 + 0 * 8 ..][0..8], 0x0000_4000 | 0b11, .little);
    std.mem.writeInt(u64, ram[0x4000 + 4 * 8 ..][0..8], 0x0015_0000 | (1 << 10) | (0b11 << 6) | 0b11, .little);
    mmu.flushTlb();

    const upa = try mmu.translate64(ram, 0x0000_0000_0000_4abc, .read, false);
    try std.testing.expectEqual(@as(u32, 0x0015_0abc), upa);

    // User write to RO page faults and populates FAR_EL1 and ESR_EL1 (EC=0b100100 Data Abort lower EL, WnR=1, DFSC=0x0f)
    try std.testing.expectError(error.Abort, mmu.translate64(ram, 0x0000_0000_0000_4abc, .write, false));
    try std.testing.expectEqual(@as(u64, 0x0000_0000_0000_4abc), mmu.far_el1);
    try std.testing.expectEqual(@as(u32, (0b100100 << 26) | (1 << 25) | (1 << 6) | 0x0f), mmu.esr_el1);

    // Verify 4096-entry SoftTLB chunk-bitmap tracking and selective flush
    try std.testing.expect(mmu.soft_tlb64_dirty_chunks != 0);
    mmu.flushTlb();
    try std.testing.expectEqual(@as(u64, 0), mmu.soft_tlb64_dirty_chunks);
    try std.testing.expectEqual(@as(u64, 0xffff_ffff_ffff_ffff), mmu.soft_tlb64[0][4].r_vbase);
}
