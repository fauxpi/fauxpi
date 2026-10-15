//! ARM1176JZF-S CP15 System Control Coprocessor & ARMv6 MMU with Software TLB.
//!
//! Implements the ARMv6 Virtual Memory System Architecture (VMSA):
//! - CP15 registers (c0 IDs, c1 SCTLR/ACTLR/CPACR, c2 TTBR0/TTBR1/TTBCR,
//!   c3 DACR, c5 DFSR/IFSR, c6 DFAR/IFAR, c7 Cache/WFI/Barriers, c8 TLB,
//!   c13 FCSE/CONTEXTIDR/TPIDRURW/TPIDRURO/TPIDRPRW, c15 Performance Monitor)
//! - Two-level hardware page table walker supporting 16 MB Supersections,
//!   1 MB Sections, 64 KB Large Pages, and 4 KB Extended Small Pages
//! - Domain access checks (No Access, Client, Manager) and APX/AP[1:0]/XN
//!   permission checks for Privileged and User modes
//! - Direct-mapped software TLB indexed by 4 KB virtual page number for
//!   single-lookup translation on the hot path.

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
    /// CP15 c1: System Control Register (SCTLR)
    /// Reset value on ARM1176JZF-S has bits [6:4] = 0b111 (0x00050078)
    sctlr: u32 = 0x00050078,
    /// CP15 c1: Auxiliary Control Register (ACTLR)
    actlr: u32 = 0x00000007,
    /// CP15 c1: Coprocessor Access Control Register (CPACR)
    cpacr: u32 = 0x00000000,

    /// CP15 c2: Translation Table Base Registers
    ttbr0: u32 = 0,
    ttbr1: u32 = 0,
    ttbcr: u32 = 0,

    /// CP15 c3: Domain Access Control Register
    dacr: u32 = 0,

    /// CP15 c5: Fault Status Registers
    dfsr: u32 = 0,
    ifsr: u32 = 0,

    /// CP15 c6: Fault Address Registers
    dfar: u32 = 0,
    ifar: u32 = 0,

    /// CP15 c13: Process / Thread ID Registers
    fcseidr: u32 = 0,
    contextidr: u32 = 0,
    tpidrurw: u32 = 0,
    tpidruro: u32 = 0,
    tpidrprw: u32 = 0,

    /// CP15 c15: Performance monitor control / cycle counter
    pmcr: u32 = 0,
    pmccntr: u32 = 0,

    /// Set to true when the guest executes WFI (`mcr p15, 0, rX, c7, c0, 4`)
    halted_wfi: bool = false,

    /// Direct-mapped software TLB (4096 entries covering 4 KB pages)
    tlb: [tlb_size]TlbEntry = @splat(.{}),
    /// Current TLB generation counter (incremented on full TLB flush to avoid 48 KB memset)
    tlb_gen: u32 = 1,

    pub const tlb_bits = 12;
    pub const tlb_size = 1 << tlb_bits;
    pub const tlb_mask = tlb_size - 1;

    pub const perm_priv_r: u8 = 1 << 0;
    pub const perm_priv_w: u8 = 1 << 1;
    pub const perm_priv_x: u8 = 1 << 2;
    pub const perm_user_r: u8 = 1 << 3;
    pub const perm_user_w: u8 = 1 << 4;
    pub const perm_user_x: u8 = 1 << 5;

    pub const TlbEntry = struct {
        gen: u32 = 0,
        vpn: u20 = 0,
        perms: u8 = 0,
        domain: u4 = 0,
        is_page: bool = false,
        ppn_base: u32 = 0, // Physical page base (top 20 bits, low 12 bits 0)
    };

    pub inline fn isMmuEnabled(self: *const Mmu) bool {
        return (self.sctlr & 1) != 0;
    }

    pub inline fn highVectors(self: *const Mmu) bool {
        return (self.sctlr & (1 << 13)) != 0;
    }

    pub inline fn extendedPageTables(self: *const Mmu) bool {
        return (self.sctlr & (1 << 23)) != 0;
    }

    pub fn flushTlb(self: *Mmu) void {
        self.tlb_gen +%= 1;
        if (self.tlb_gen == 0) {
            @memset(&self.tlb, .{});
            self.tlb_gen = 1;
        }
    }

    pub fn flushTlbMva(self: *Mmu, mva: u32) void {
        const vpn: u20 = @truncate(mva >> 12);
        const idx = vpn & tlb_mask;
        if (self.tlb[idx].gen == self.tlb_gen and self.tlb[idx].vpn == vpn) {
            self.tlb[idx].gen = 0;
        }
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
            return vaddr;
        }

        const vpn: u20 = @truncate(vaddr >> 12);
        const idx = vpn & tlb_mask;
        const entry = &self.tlb[idx];

        const req_perm: u8 = switch (access) {
            .read => if (is_priv) perm_priv_r else perm_user_r,
            .write => if (is_priv) perm_priv_w else perm_user_w,
            .fetch => if (is_priv) perm_priv_x else perm_user_x,
        };

        if (entry.gen == self.tlb_gen and entry.vpn == vpn) {
            if ((entry.perms & req_perm) != 0) {
                return entry.ppn_base | (vaddr & 0xfff);
            }
            // Permission fault on cached TLB entry
            const fs: u5 = if (entry.is_page) 0x0f else 0x0d;
            self.recordFault(vaddr, access, fs, entry.domain);
            return error.Abort;
        }

        return self.walkAndFillTlb(ram, vaddr, access, is_priv, req_perm);
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
        const l1_addr: u32 = (table_base | ((l1_index & l1_ShiftMask) << 2)) & 0x1fff_ffff;
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
                const l2_addr = (l2_base | (l2_index << 2)) & 0x1fff_ffff;
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
                const fs: u5 = if (is_page) 0x0b else 0x09;
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
                perms = computeClientPerms(apx, ap, xn, self.sctlr);
            },
        }

        // Fill software TLB entry
        const vpn: u20 = @truncate(vaddr >> 12);
        self.tlb[vpn & tlb_mask] = .{
            .gen = self.tlb_gen,
            .vpn = vpn,
            .ppn_base = phys_page_base,
            .perms = perms,
            .domain = domain,
            .is_page = is_page,
        };

        if ((perms & req_perm) == 0) {
            // Permission Fault (Section = 0x0d, Page = 0x0f)
            const fs: u5 = if (is_page) 0x0f else 0x0d;
            self.recordFault(vaddr, access, fs, domain);
            return error.Abort;
        }

        return phys_page_base | (vaddr & 0xfff);
    }

    fn computeClientPerms(apx: u1, ap: u2, xn: bool, sctlr: u32) u8 {
        var p: u8 = 0;
        const ap3: u3 = (@as(u3, apx) << 2) | ap;
        switch (ap3) {
            0b000 => {
                // When XP=0, check legacy S (bit 8) and R (bit 9) bits
                if ((sctlr & (1 << 23)) == 0) {
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

    pub fn recordFault(self: *Mmu, vaddr: u32, access: AccessKind, fs: u5, domain: u4) void {
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

    /// Reads a CP15 register (`MRC p15, opc1, Rt, CRn, CRm, opc2`).
    pub fn readCp15(self: *const Mmu, opc1: u3, crn: u4, crm: u4, opc2: u3) u32 {
        _ = opc1;
        return switch (crn) {
            0 => switch (crm) {
                0 => switch (opc2) {
                    0 => 0x410fb767, // MIDR: ARM1176JZF-S r0p7
                    1 => 0x1d152152, // CTR: 16KB I/D cache, 32B line, VIPT
                    2 => 0x00000000, // TCMTR: no TCM
                    3 => 0x00000800, // TLBTR: 64-entry unified TLB
                    5 => 0x00000000, // MPIDR: CPU 0
                    else => 0,
                },
                1 => switch (opc2) {
                    0 => 0x00000111, // ID_PFR0
                    1 => 0x00000011, // ID_PFR1
                    2 => 0x00000033, // ID_DFR0
                    3 => 0x00000000, // ID_AFR0
                    4 => 0x01130003, // ID_MMFR0
                    5 => 0x10030302, // ID_MMFR1
                    6 => 0x01222100, // ID_MMFR2
                    7 => 0x00000000, // ID_MMFR3
                },
                2 => switch (opc2) {
                    0 => 0x00140011, // ID_ISAR0
                    1 => 0x12002111, // ID_ISAR1
                    2 => 0x11231111, // ID_ISAR2
                    3 => 0x01102131, // ID_ISAR3
                    4 => 0x00000141, // ID_ISAR4
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
                14 => 0, // DCCISW / cache dirty status (0 = clean)
                10 => 0, // Cache status
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
            15 => switch (crm) {
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
        _ = opc1;
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
                    0 => self.ttbr0 = val,
                    1 => self.ttbr1 = val,
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
                // c7, c0, 4 is Wait For Interrupt (WFI)
                if (crm == 0 and opc2 == 4) {
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
