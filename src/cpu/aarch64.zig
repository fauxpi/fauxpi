//! ARMv8-A AArch64 (A64) Instruction Set & Exception Level Execution Engine.
//!
//! Supports:
//! - Exception Levels `EL0`, `EL1`, `EL2`, `EL3` with `SP_EL0..SP_EL3`, `ELR_EL1..ELR_EL3`,
//!   `SPSR_EL1..SPSR_EL3`, `VBAR_EL1..VBAR_EL3`, and `PSTATE` (`NZCV`, `DAIF`, `EL`, `SPSel`)
//! - Full A64 integer instruction set (Data Processing Immediate/Register, Branches,
//!   Load/Store single/pair/exclusive/acquire-release/atomic, System/MSR/MRS)
//! - A64 Scalar Floating-Point & Advanced SIMD (NEON) 128-bit vector operations (`V0..V31`)
//! - VMSAv8-64 4-level (48-bit VA) and 3-level (39-bit VA) MMU integration with inline I/D-TLB.

const std = @import("std");
const mmu_mod = @import("mmu.zig");
const atomic_ram = @import("atomic_ram.zig");
const jit_mod = @import("jit.zig");

pub const PstateFlags = struct {
    pub const N: u32 = 1 << 31;
    pub const Z: u32 = 1 << 30;
    pub const C: u32 = 1 << 29;
    pub const V: u32 = 1 << 28;
    pub const D: u32 = 1 << 9;
    pub const A: u32 = 1 << 8;
    pub const I: u32 = 1 << 7;
    pub const F: u32 = 1 << 6;
    pub const M_EL0t: u32 = 0b0000;
    pub const M_EL1t: u32 = 0b0100;
    pub const M_EL1h: u32 = 0b0101;
    pub const M_EL2t: u32 = 0b1000;
    pub const M_EL2h: u32 = 0b1001;
    pub const M_EL3t: u32 = 0b1100;
    pub const M_EL3h: u32 = 0b1101;
};

/// Decodes an ARMv8 A64 logical immediate `(N, imms, immr)` into a 64-bit replicated bitmask.
pub fn decodeLogicalImm(sf: u1, n: u1, imms: u6, immr: u6) ?u64 {
    const not_imms: u7 = (~@as(u7, imms)) & 0x3f;
    const combined: u7 = (@as(u7, n) << 6) | not_imms;
    if (combined == 0) return null;
    const lead_zeros: u7 = @clz(combined);
    const len: u7 = 6 - lead_zeros;
    if (len < 1) return null;

    const esize: u7 = @as(u7, 1) << @intCast(len);
    if (sf == 0 and esize > 32) return null;

    const levels: u6 = @intCast(esize - 1);
    const s: u6 = imms & levels;
    const r: u6 = immr & levels;
    if (s == levels) return null;

    const ones: u7 = @as(u7, s) + 1;
    var welem: u64 = if (ones >= 64) 0xffff_ffff_ffff_ffff else ((@as(u64, 1) << @intCast(ones)) - 1);
    if (r != 0) {
        const esize_mask: u64 = if (esize >= 64) 0xffff_ffff_ffff_ffff else ((@as(u64, 1) << @intCast(esize)) - 1);
        const r_sh: u6 = r;
        const l_sh: u6 = @intCast(esize - @as(u7, r));
        welem = ((welem >> r_sh) | (welem << l_sh)) & esize_mask;
    }

    var result: u64 = 0;
    var shift: u7 = 0;
    while (shift < 64) : (shift += esize) {
        result |= welem << @intCast(shift);
    }
    return if (sf == 0) (result & 0xffff_ffff) else result;
}

const cond_lut64: [16]u16 = blk: {
    var lut: [16]u16 = @splat(0);
    for (0..16) |c_idx| {
        var mask: u16 = 0;
        for (0..16) |nzcv| {
            const n = (nzcv >> 3) & 1;
            const z = (nzcv >> 2) & 1;
            const c = (nzcv >> 1) & 1;
            const v = nzcv & 1;
            const ok = switch (@as(u4, @intCast(c_idx))) {
                0x0 => z == 1, // EQ
                0x1 => z == 0, // NE
                0x2 => c == 1, // CS / HS
                0x3 => c == 0, // CC / LO
                0x4 => n == 1, // MI
                0x5 => n == 0, // PL
                0x6 => v == 1, // VS
                0x7 => v == 0, // VC
                0x8 => c == 1 and z == 0, // HI
                0x9 => c == 0 or z == 1, // LS
                0xa => n == v, // GE
                0xb => n != v, // LT
                0xc => z == 0 and n == v, // GT
                0xd => z == 1 or n != v, // LE
                0xe, 0xf => true, // AL / NV
            };
            if (ok) mask |= (@as(u16, 1) << @intCast(nzcv));
        }
        lut[c_idx] = mask;
    }
    break :blk lut;
};

pub inline fn evalCond(pstate: u32, cond: u4) bool {
    const nzcv: u4 = @truncate(pstate >> 28);
    return ((cond_lut64[cond] >> nzcv) & 1) != 0;
}

pub fn Aarch64Exec(comptime CpuType: type, comptime Bus: type) type {
    return struct {
        pub inline fn currentEl(cpu: *const CpuType) u2 {
            return @truncate((cpu.pstate >> 2) & 3);
        }

        pub inline fn isPrivileged64(cpu: *const CpuType) bool {
            return currentEl(cpu) != 0;
        }

        pub inline fn spIndex(cpu: *const CpuType) u2 {
            return if ((cpu.pstate & 1) != 0) currentEl(cpu) else 0;
        }

        pub inline fn getSp(cpu: *const CpuType) u64 {
            return cpu.sp_el[spIndex(cpu)];
        }

        pub inline fn setSp(cpu: *CpuType, val: u64) void {
            cpu.sp_el[spIndex(cpu)] = val;
        }

        pub inline fn getX(cpu: *const CpuType, reg: u5) u64 {
            return cpu.x[reg];
        }

        pub inline fn getXOrSp(cpu: *const CpuType, reg: u5) u64 {
            return if (reg == 31) getSp(cpu) else cpu.x[reg];
        }

        pub inline fn setX(cpu: *CpuType, reg: u5, val: u64) void {
            if (reg != 31) cpu.x[reg] = val;
        }

        pub inline fn setXOrSp(cpu: *CpuType, reg: u5, val: u64) void {
            if (reg == 31) setSp(cpu, val) else cpu.x[reg] = val;
        }

        pub inline fn getW(cpu: *const CpuType, reg: u5) u32 {
            return @truncate(cpu.x[reg]);
        }

        pub inline fn setW(cpu: *CpuType, reg: u5, val: u32) void {
            if (reg != 31) cpu.x[reg] = @as(u64, val);
        }

        pub inline fn setWOrSp(cpu: *CpuType, reg: u5, val: u32) void {
            if (reg == 31) setSp(cpu, @as(u64, val)) else cpu.x[reg] = @as(u64, val);
        }

        pub inline fn setNzcv(cpu: *CpuType, n: bool, z: bool, c: bool, v: bool) void {
            const flags: u32 = (@as(u32, @intFromBool(n)) << 31) |
                (@as(u32, @intFromBool(z)) << 30) |
                (@as(u32, @intFromBool(c)) << 29) |
                (@as(u32, @intFromBool(v)) << 28);
            cpu.pstate = (cpu.pstate & 0x0fff_ffff) | flags;
        }

        pub noinline fn takeException64(
            cpu: *CpuType,
            target_el: u2,
            vec_offset_same_sp0: u64,
            esr: ?u32,
            far: ?u64,
            preferred_return_pc: u64,
        ) void {
            const from_el = currentEl(cpu);
            const use_sp_elx = (cpu.pstate & 1) != 0;
            const base_off: u64 = if (from_el < target_el)
                0x400 // Lower EL using AArch64
            else if (use_sp_elx)
                0x200 // Current EL with SPx
            else
                0x000; // Current EL with SP0

            const vbar: u64 = switch (target_el) {
                2 => cpu.mmu.vbar_el2,
                3 => cpu.mmu.vbar_el3,
                else => cpu.mmu.vbar_el1,
            };

            cpu.elr_el[target_el] = preferred_return_pc;
            cpu.spsr_el[target_el] = cpu.pstate;
            if (esr) |e| {
                if (target_el == 2) cpu.mmu.esr_el2 = e else cpu.mmu.esr_el1 = e;
            }
            if (far) |f| {
                if (target_el == 2) cpu.mmu.far_el2 = f else cpu.mmu.far_el1 = f;
            }

            // Mask D, A, I, F and enter target_el with SP_ELx (handler mode, bit 0 = 1)
            cpu.pstate = (cpu.pstate & 0xf000_0000) |
                PstateFlags.D | PstateFlags.A | PstateFlags.I | PstateFlags.F |
                (@as(u32, target_el) << 2) | 1;
            cpu.pc64 = (vbar & ~@as(u64, 0x7ff)) +% base_off +% vec_offset_same_sp0;
            cpu.r[15] = @truncate(cpu.pc64);
            cpu.excl_valid = false;
            if ((from_el >= 2) != (target_el >= 2)) cpu.mmu.flushTlb();
        }

        pub inline fn readData8(cpu: *CpuType, bus: *Bus, vaddr: u64) error{Abort}!u8 {
            const vbase = vaddr & ~@as(u64, 0xfff);
            const priv: u1 = @intFromBool(currentEl(cpu) != 0);
            const slot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((vaddr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
            if (vbase == slot.r_vbase) {
                return bus.ram[slot.pbase | @as(u32, @truncate(vaddr & 0xfff))];
            }
            return readData8Slow(cpu, bus, vaddr);
        }

        noinline fn readData8Slow(cpu: *CpuType, bus: *Bus, vaddr: u64) error{Abort}!u8 {
            const paddr = try cpu.mmu.translate64AtEl(bus.ram, vaddr, .read, currentEl(cpu));
            if (paddr < bus.ram.len) {
                return bus.ram[paddr];
            }
            return bus.read8(paddr);
        }

        pub inline fn readData16(cpu: *CpuType, bus: *Bus, vaddr: u64) error{Abort}!u16 {
            if ((vaddr & 0xfff) <= 0xffe) {
                const vbase = vaddr & ~@as(u64, 0xfff);
                const priv: u1 = @intFromBool(currentEl(cpu) != 0);
                const slot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((vaddr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                if (vbase == slot.r_vbase) {
                    const paddr = slot.pbase | @as(u32, @truncate(vaddr & 0xfff));
                    return std.mem.readInt(u16, bus.ram[paddr..][0..2], .little);
                }
            }
            return readData16Slow(cpu, bus, vaddr);
        }

        noinline fn readData16Slow(cpu: *CpuType, bus: *Bus, vaddr: u64) error{Abort}!u16 {
            if ((vaddr & 0xfff) <= 0xffe) {
                const paddr = try cpu.mmu.translate64AtEl(bus.ram, vaddr, .read, currentEl(cpu));
                if (@as(usize, paddr) + 2 <= bus.ram.len) {
                    return std.mem.readInt(u16, bus.ram[paddr..][0..2], .little);
                }
                return bus.read16(paddr);
            }
            const b0: u16 = try readData8(cpu, bus, vaddr);
            const b1: u16 = try readData8(cpu, bus, vaddr +% 1);
            return b0 | (b1 << 8);
        }

        pub inline fn readData32(cpu: *CpuType, bus: *Bus, vaddr: u64) error{Abort}!u32 {
            if ((vaddr & 0xfff) <= 0xffc) {
                const vbase = vaddr & ~@as(u64, 0xfff);
                const priv: u1 = @intFromBool(currentEl(cpu) != 0);
                const slot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((vaddr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                if (vbase == slot.r_vbase) {
                    const paddr = slot.pbase | @as(u32, @truncate(vaddr & 0xfff));
                    return std.mem.readInt(u32, bus.ram[paddr..][0..4], .little);
                }
            }
            return readData32Slow(cpu, bus, vaddr);
        }

        noinline fn readData32Slow(cpu: *CpuType, bus: *Bus, vaddr: u64) error{Abort}!u32 {
            if ((vaddr & 0xfff) <= 0xffc) {
                const paddr = try cpu.mmu.translate64AtEl(bus.ram, vaddr, .read, currentEl(cpu));
                if (@as(usize, paddr) + 4 <= bus.ram.len) {
                    return std.mem.readInt(u32, bus.ram[paddr..][0..4], .little);
                }
                return bus.read32(paddr);
            }
            const lo: u32 = try readData16(cpu, bus, vaddr);
            const hi: u32 = try readData16(cpu, bus, vaddr +% 2);
            return lo | (hi << 16);
        }

        pub inline fn readData64(cpu: *CpuType, bus: *Bus, vaddr: u64) error{Abort}!u64 {
            if ((vaddr & 0xfff) <= 0xff8) {
                const vbase = vaddr & ~@as(u64, 0xfff);
                const priv: u1 = @intFromBool(currentEl(cpu) != 0);
                const slot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((vaddr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                if (vbase == slot.r_vbase) {
                    const paddr = slot.pbase | @as(u32, @truncate(vaddr & 0xfff));
                    return std.mem.readInt(u64, bus.ram[paddr..][0..8], .little);
                }
            }
            return readData64Slow(cpu, bus, vaddr);
        }

        noinline fn readData64Slow(cpu: *CpuType, bus: *Bus, vaddr: u64) error{Abort}!u64 {
            if ((vaddr & 0xfff) <= 0xff8) {
                const paddr = try cpu.mmu.translate64AtEl(bus.ram, vaddr, .read, currentEl(cpu));
                if (@as(usize, paddr) + 8 <= bus.ram.len) {
                    return std.mem.readInt(u64, bus.ram[paddr..][0..8], .little);
                }
            }
            const lo: u64 = try readData32(cpu, bus, vaddr);
            const hi: u64 = try readData32(cpu, bus, vaddr +% 4);
            return lo | (hi << 32);
        }

        pub inline fn writeData8(cpu: *CpuType, bus: *Bus, vaddr: u64, val: u8) error{Abort}!void {
            const vbase = vaddr & ~@as(u64, 0xfff);
            const priv: u1 = @intFromBool(currentEl(cpu) != 0);
            const slot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((vaddr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
            if (vbase == slot.w_vbase) {
                bus.ram[slot.pbase | @as(u32, @truncate(vaddr & 0xfff))] = val;
                return;
            }
            return writeData8Slow(cpu, bus, vaddr, val);
        }

        noinline fn writeData8Slow(cpu: *CpuType, bus: *Bus, vaddr: u64, val: u8) error{Abort}!void {
            const paddr = try cpu.mmu.translate64AtEl(bus.ram, vaddr, .write, currentEl(cpu));
            if (paddr < bus.ram.len) {
                bus.ram[paddr] = val;
                return;
            }
            bus.write8(paddr, val);
        }

        pub inline fn writeData16(cpu: *CpuType, bus: *Bus, vaddr: u64, val: u16) error{Abort}!void {
            if ((vaddr & 0xfff) <= 0xffe) {
                const vbase = vaddr & ~@as(u64, 0xfff);
                const priv: u1 = @intFromBool(currentEl(cpu) != 0);
                const slot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((vaddr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                if (vbase == slot.w_vbase) {
                    const paddr = slot.pbase | @as(u32, @truncate(vaddr & 0xfff));
                    std.mem.writeInt(u16, bus.ram[paddr..][0..2], val, .little);
                    return;
                }
            }
            return writeData16Slow(cpu, bus, vaddr, val);
        }

        noinline fn writeData16Slow(cpu: *CpuType, bus: *Bus, vaddr: u64, val: u16) error{Abort}!void {
            if ((vaddr & 0xfff) <= 0xffe) {
                const paddr = try cpu.mmu.translate64AtEl(bus.ram, vaddr, .write, currentEl(cpu));
                if (@as(usize, paddr) + 2 <= bus.ram.len) {
                    std.mem.writeInt(u16, bus.ram[paddr..][0..2], val, .little);
                    return;
                }
                bus.write16(paddr, val);
                return;
            }
            try writeData8(cpu, bus, vaddr, @truncate(val));
            try writeData8(cpu, bus, vaddr +% 1, @truncate(val >> 8));
        }

        pub inline fn writeData32(cpu: *CpuType, bus: *Bus, vaddr: u64, val: u32) error{Abort}!void {
            if ((vaddr & 0xfff) <= 0xffc) {
                const vbase = vaddr & ~@as(u64, 0xfff);
                const priv: u1 = @intFromBool(currentEl(cpu) != 0);
                const slot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((vaddr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                if (vbase == slot.w_vbase) {
                    const paddr = slot.pbase | @as(u32, @truncate(vaddr & 0xfff));
                    std.mem.writeInt(u32, bus.ram[paddr..][0..4], val, .little);
                    return;
                }
            }
            return writeData32Slow(cpu, bus, vaddr, val);
        }

        noinline fn writeData32Slow(cpu: *CpuType, bus: *Bus, vaddr: u64, val: u32) error{Abort}!void {
            if ((vaddr & 0xfff) <= 0xffc) {
                const paddr = try cpu.mmu.translate64AtEl(bus.ram, vaddr, .write, currentEl(cpu));
                if (@as(usize, paddr) + 4 <= bus.ram.len) {
                    std.mem.writeInt(u32, bus.ram[paddr..][0..4], val, .little);
                    return;
                }
                bus.write32(paddr, val);
                return;
            }
            try writeData16(cpu, bus, vaddr, @truncate(val));
            try writeData16(cpu, bus, vaddr +% 2, @truncate(val >> 16));
        }

        pub inline fn readData128(cpu: *CpuType, bus: *Bus, vaddr: u64) error{Abort}!u128 {
            if ((vaddr & 0xfff) <= 0xff0) {
                const vbase = vaddr & ~@as(u64, 0xfff);
                const priv: u1 = @intFromBool(currentEl(cpu) != 0);
                const slot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((vaddr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                if (vbase == slot.r_vbase) {
                    const paddr = slot.pbase | @as(u32, @truncate(vaddr & 0xfff));
                    return std.mem.readInt(u128, bus.ram[paddr..][0..16], .little);
                }
            }
            return readData128Slow(cpu, bus, vaddr);
        }

        noinline fn readData128Slow(cpu: *CpuType, bus: *Bus, vaddr: u64) error{Abort}!u128 {
            if ((vaddr & 0xfff) <= 0xff0) {
                const paddr = try cpu.mmu.translate64AtEl(bus.ram, vaddr, .read, currentEl(cpu));
                if (@as(usize, paddr) + 16 <= bus.ram.len) {
                    return std.mem.readInt(u128, bus.ram[paddr..][0..16], .little);
                }
            }
            const lo: u128 = try readData64(cpu, bus, vaddr);
            const hi: u128 = try readData64(cpu, bus, vaddr +% 8);
            return lo | (hi << 64);
        }

        pub inline fn writeData64(cpu: *CpuType, bus: *Bus, vaddr: u64, val: u64) error{Abort}!void {
            if ((vaddr & 0xfff) <= 0xff8) {
                const vbase = vaddr & ~@as(u64, 0xfff);
                const priv: u1 = @intFromBool(currentEl(cpu) != 0);
                const slot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((vaddr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                if (vbase == slot.w_vbase) {
                    const paddr = slot.pbase | @as(u32, @truncate(vaddr & 0xfff));
                    std.mem.writeInt(u64, bus.ram[paddr..][0..8], val, .little);
                    return;
                }
            }
            return writeData64Slow(cpu, bus, vaddr, val);
        }

        noinline fn writeData64Slow(cpu: *CpuType, bus: *Bus, vaddr: u64, val: u64) error{Abort}!void {
            if ((vaddr & 0xfff) <= 0xff8) {
                const paddr = try cpu.mmu.translate64AtEl(bus.ram, vaddr, .write, currentEl(cpu));
                if (@as(usize, paddr) + 8 <= bus.ram.len) {
                    std.mem.writeInt(u64, bus.ram[paddr..][0..8], val, .little);
                    return;
                }
            }
            try writeData32(cpu, bus, vaddr, @truncate(val));
            try writeData32(cpu, bus, vaddr +% 4, @truncate(val >> 32));
        }

        pub inline fn writeData128(cpu: *CpuType, bus: *Bus, vaddr: u64, val: u128) error{Abort}!void {
            if ((vaddr & 0xfff) <= 0xff0) {
                const vbase = vaddr & ~@as(u64, 0xfff);
                const priv: u1 = @intFromBool(currentEl(cpu) != 0);
                const slot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((vaddr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                if (vbase == slot.w_vbase) {
                    const paddr = slot.pbase | @as(u32, @truncate(vaddr & 0xfff));
                    std.mem.writeInt(u128, bus.ram[paddr..][0..16], val, .little);
                    return;
                }
            }
            return writeData128Slow(cpu, bus, vaddr, val);
        }

        noinline fn writeData128Slow(cpu: *CpuType, bus: *Bus, vaddr: u64, val: u128) error{Abort}!void {
            if ((vaddr & 0xfff) <= 0xff0) {
                const paddr = try cpu.mmu.translate64AtEl(bus.ram, vaddr, .write, currentEl(cpu));
                if (@as(usize, paddr) + 16 <= bus.ram.len) {
                    std.mem.writeInt(u128, bus.ram[paddr..][0..16], val, .little);
                    return;
                }
            }
            try writeData64(cpu, bus, vaddr, @truncate(val));
            try writeData64(cpu, bus, vaddr +% 8, @truncate(val >> 64));
        }

        pub noinline fn fetchInst64(cpu: *CpuType, bus: *Bus, pc: u64) error{Abort}!u32 {
            const vbase = pc & ~@as(u64, 0xfff);
            const priv: u1 = @intFromBool(currentEl(cpu) != 0);
            const slot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((pc >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
            if (vbase == slot.x_vbase) {
                const paddr = slot.pbase | @as(u32, @truncate(pc & 0xfff));
                return std.mem.readInt(u32, bus.ram[paddr..][0..4], .little);
            }
            const paddr = try cpu.mmu.translate64AtEl(bus.ram, pc, .fetch, currentEl(cpu));
            if (@as(usize, paddr) + 4 <= bus.ram.len) {
                return std.mem.readInt(u32, bus.ram[paddr..][0..4], .little);
            }
            return bus.read32(paddr);
        }

        pub noinline fn checkInterrupts64(cpu: *CpuType, bus: *const Bus) bool {
            const halted = cpu.mmu.halted_wfi;
            const cid = cpu.mmu.core_id;
            if (halted or (cpu.pstate & PstateFlags.F) == 0) {
                const pending_fiq = if (@hasDecl(Bus, "hasPendingFiqForCore"))
                    bus.hasPendingFiqForCore(cid)
                else
                    bus.hasPendingFiq();
                if (pending_fiq) {
                    cpu.mmu.halted_wfi = false;
                    if ((cpu.pstate & PstateFlags.F) == 0) {
                        const target_el: u2 = @max(currentEl(cpu), 1);
                        takeException64(cpu, target_el, 0x100, null, null, cpu.pc64);
                        return true;
                    }
                }
            }
            if (halted or (cpu.pstate & PstateFlags.I) == 0) {
                const pending_irq = if (@hasDecl(Bus, "hasPendingIrqForCore"))
                    bus.hasPendingIrqForCore(cid)
                else
                    bus.hasPendingIrq();
                if (pending_irq) {
                    cpu.mmu.halted_wfi = false;
                    if ((cpu.pstate & PstateFlags.I) == 0) {
                        const target_el: u2 = @max(currentEl(cpu), 1);
                        takeException64(cpu, target_el, 0x080, null, null, cpu.pc64);
                        return true;
                    }
                }
            }
            return false;
        }

        pub const A64Op = enum(u8) {
            adr,
            adrp,
            add_imm64,
            sub_imm64,
            adds_imm64,
            subs_imm64,
            add_imm32,
            sub_imm32,
            adds_imm32,
            subs_imm32,
            and_imm64,
            orr_imm64,
            eor_imm64,
            ands_imm64,
            and_imm32,
            orr_imm32,
            eor_imm32,
            ands_imm32,
            mov_wide,
            movk64,
            movk32,
            ubfm_r,
            ubfm_l,
            sbfm64_r,
            sbfm32_r,
            extr64,
            extr32,
            orr_reg64,
            orr_reg32,
            orn_reg64,
            orn_reg32,
            add_reg64,
            add_reg32,
            adds_reg64,
            adds_reg32,
            sub_reg64,
            sub_reg32,
            subs_reg64,
            subs_reg32,
            and_reg64,
            and_reg32,
            bic_reg64,
            bic_reg32,
            eor_reg64,
            eor_reg32,
            ands_reg64,
            ands_reg32,
            add_lsl64,
            add_lsl32,
            sub_lsl64,
            sub_lsl32,
            orr_lsl64,
            orr_lsr64,
            add_ext64,
            sub_ext64,
            add_sub_ext,
            dp_shift_reg,
            lslv64,
            lsrv64,
            asrv64,
            lslv32,
            lsrv32,
            asrv32,
            udiv64,
            sdiv64,
            udiv32,
            sdiv32,
            clz64,
            clz32,
            rev64,
            rev32,
            csel,
            ccmp,
            madd_msub,
            maddl_mulh,
            ldr64_uimm,
            str64_uimm,
            ldr32_uimm,
            str32_uimm,
            ldrsw_uimm,
            ldr16_uimm,
            str16_uimm,
            ldr8_uimm,
            str8_uimm,
            ldrsb64_uimm,
            ldrsb32_uimm,
            ldrsh64_uimm,
            ldrsh32_uimm,
            ldr_lit32,
            ldr_lit64,
            ldrsw_lit,
            ldr_fp32_lit,
            ldr_fp64_lit,
            ldr_fp128_lit,
            ldr64_pre,
            ldr64_post,
            str64_pre,
            str64_post,
            ldr32_pre,
            ldr32_post,
            str32_pre,
            str32_post,
            ldr64_reg_lsl,
            str64_reg_lsl,
            ldr32_reg_lsl,
            str32_reg_lsl,
            ldr8_reg_lsl,
            str8_reg_lsl,
            ldxr64,
            stxr64,
            ldxr32,
            stxr32,
            ldp64_off,
            stp64_off,
            ldp64_pre,
            stp64_pre,
            ldp64_post,
            stp64_post,
            ldp32_off,
            stp32_off,
            ldp32_pre,
            stp32_pre,
            ldp32_post,
            stp32_post,
            ldpsw_off,
            ldpsw_pre,
            ldpsw_post,
            ldr_fp32_uimm,
            str_fp32_uimm,
            ldr_fp64_uimm,
            str_fp64_uimm,
            ldr_fp128_uimm,
            str_fp128_uimm,
            ldr_fp64_pre,
            ldr_fp64_post,
            str_fp64_pre,
            str_fp64_post,
            ldr_fp128_pre,
            ldr_fp128_post,
            str_fp128_pre,
            str_fp128_post,
            ldr_fp64_reg_lsl,
            str_fp64_reg_lsl,
            ldr_fp128_reg_lsl,
            str_fp128_reg_lsl,
            ldp_fp64_off,
            stp_fp64_off,
            ldp_fp64_pre,
            stp_fp64_pre,
            ldp_fp64_post,
            stp_fp64_post,
            ldp_fp128_off,
            stp_fp128_off,
            ldp_fp128_pre,
            stp_fp128_pre,
            ldp_fp128_post,
            stp_fp128_post,
            simd_ld1_mult,
            simd_st1_mult,
            // Pre-decoded Scalar FP & NEON Vector Ops
            fmov_d_x,
            fmov_x_d,
            fmov_s_w,
            fmov_w_s,
            fmov_d_hi_x,
            fmov_x_d_hi,
            fmov_f64,
            fmov_f32,
            fabs_f64,
            fneg_f64,
            fabs_f32,
            fneg_f32,
            fcvt_s_d,
            fcvt_d_s,
            fadd_f64,
            fsub_f64,
            fmul_f64,
            fdiv_f64,
            fadd_f32,
            fsub_f32,
            fmul_f32,
            fdiv_f32,
            fmadd_f64,
            fmsub_f64,
            fmadd_f32,
            fmsub_f32,
            fcmp_f64,
            fcmpz_f64,
            fcmp_f32,
            fcmpz_f32,
            simd_movi,
            simd_and,
            simd_bic,
            simd_orr,
            simd_orn,
            simd_eor,
            simd_bsl,
            simd_not,
            simd_dup_gpr,
            simd_dup_elem,
            simd_umov32,
            simd_umov64,
            simd_add_8,
            simd_sub_8,
            simd_add_16,
            simd_sub_16,
            simd_add_32,
            simd_sub_32,
            simd_add_64,
            simd_sub_64,
            simd_cmeq_8,
            simd_cmeqz_8,
            simd_cmtst_8,
            simd_ext_q,
            simd_ext_d,
            simd_ushr,
            simd_shl,
            b_imm,
            bl_imm,
            b_cond,
            cbz64,
            cbnz64,
            cbz32,
            cbnz32,
            tbz,
            tbnz,
            br_reg,
            blr_reg,
            ret,
            bfm_r,
            bfm_l,
            adc_sbc,
            mrs_tpidr_el0,
            mrs_sys,
            msr_safe,
            dc_zva,
            fcvt_int,
            fop_misc,
            simd_mul_mla,
            simd_xtn_shrn,
            simd_shll,
            adrp_add,
            adrp_ldr64,
            adrp_ldr32,
            cmp_imm_bcond,
            cmp_reg_bcond,
            tst_imm_bcond,
            tst_reg_bcond,
            ldr_cbz,
            ldr64_pair_uimm,
            dp_imm_other,
            dp_reg_other,
            load_store_other,
            branch_sys_other,
            fp_simd,
            nop,
            jit_trace,
        };

        pub inline fn tryFusePairA64(comptime SlotType: type, d: SlotType, next_inst: u32) ?SlotType {
            const op: A64Op = @enumFromInt(d.op);
            switch (op) {
                .adrp => {
                    if (d.rd != 31) {
                        if ((next_inst & 0xffc0_0000) == 0x9100_0000) {
                            const rd2: u8 = @truncate(next_inst & 0x1f);
                            const rn2: u8 = @truncate((next_inst >> 5) & 0x1f);
                            if (rd2 == d.rd and rn2 == d.rd) {
                                const imm12: u64 = (next_inst >> 10) & 0xfff;
                                return .{
                                    .raw = d.raw,
                                    .op = @intFromEnum(A64Op.adrp_add),
                                    .rd = d.rd,
                                    .imm = d.imm | imm12,
                                };
                            }
                        } else if ((next_inst & 0xbfc0_0000) == 0xb940_0000) {
                            const rn2: u8 = @truncate((next_inst >> 5) & 0x1f);
                            if (rn2 == d.rd) {
                                const is_64 = (next_inst >> 30) == 3;
                                const rt2: u8 = @truncate(next_inst & 0x1f);
                                const imm12: u64 = (next_inst >> 10) & 0xfff;
                                return .{
                                    .raw = d.raw,
                                    .op = @intFromEnum(if (is_64) A64Op.adrp_ldr64 else A64Op.adrp_ldr32),
                                    .rd = rt2,
                                    .rn = d.rd,
                                    .imm = d.imm | imm12,
                                };
                            }
                        }
                    }
                },
                .subs_imm64, .subs_imm32, .adds_imm64, .adds_imm32 => {
                    if ((next_inst & 0xff00_0010) == 0x5400_0000) {
                        const imm19: i32 = @as(i19, @bitCast(@as(u19, @truncate(next_inst >> 5))));
                        const target_off: u32 = @bitCast((imm19 << 2) + 4);
                        const cond: u8 = @truncate(next_inst & 0xf);
                        const sf_bit: u8 = if (op == .subs_imm64 or op == .adds_imm64) 0x20 else 0;
                        const sub_bit: u8 = if (op == .subs_imm64 or op == .subs_imm32) 0x40 else 0;
                        return .{
                            .raw = d.raw,
                            .op = @intFromEnum(A64Op.cmp_imm_bcond),
                            .rd = cond,
                            .rn = d.rn,
                            .rm = (d.rd & 0x1f) | sf_bit | sub_bit,
                            .imm = (@as(u64, target_off) << 32) | @as(u32, @truncate(d.imm)),
                        };
                    }
                },
                .subs_reg64, .subs_reg32 => {
                    if ((next_inst & 0xff00_0010) == 0x5400_0000) {
                        const imm19: i32 = @as(i19, @bitCast(@as(u19, @truncate(next_inst >> 5))));
                        const target_off: u32 = @bitCast((imm19 << 2) + 4);
                        const cond: u8 = @truncate(next_inst & 0xf);
                        const sf_bit: u8 = if (op == .subs_reg64) 0x10 else 0;
                        return .{
                            .raw = d.raw,
                            .op = @intFromEnum(A64Op.cmp_reg_bcond),
                            .rd = cond | sf_bit,
                            .rn = d.rn,
                            .rm = d.rm,
                            .imm = (@as(u64, d.rd & 0x1f) << 32) | target_off,
                        };
                    }
                },
                .ands_imm64, .ands_imm32 => {
                    if (d.rd == 31 and (d.imm >> 32) == 0 and (next_inst & 0xff00_0010) == 0x5400_0000) {
                        const imm19: i32 = @as(i19, @bitCast(@as(u19, @truncate(next_inst >> 5))));
                        const target_off: u32 = @bitCast((imm19 << 2) + 4);
                        const cond: u8 = @truncate(next_inst & 0xf);
                        const sf_bit: u8 = if (op == .ands_imm64) 0x10 else 0;
                        return .{
                            .raw = d.raw,
                            .op = @intFromEnum(A64Op.tst_imm_bcond),
                            .rd = cond | sf_bit,
                            .rn = d.rn,
                            .imm = (@as(u64, target_off) << 32) | @as(u32, @truncate(d.imm)),
                        };
                    }
                },
                .ands_reg64, .ands_reg32 => {
                    if ((next_inst & 0xff00_0010) == 0x5400_0000) {
                        const imm19: i32 = @as(i19, @bitCast(@as(u19, @truncate(next_inst >> 5))));
                        const target_off: u32 = @bitCast((imm19 << 2) + 4);
                        const cond: u8 = @truncate(next_inst & 0xf);
                        const sf_bit: u8 = if (op == .ands_reg64) 0x10 else 0;
                        return .{
                            .raw = d.raw,
                            .op = @intFromEnum(A64Op.tst_reg_bcond),
                            .rd = cond | sf_bit,
                            .rn = d.rn,
                            .rm = d.rm,
                            .imm = (@as(u64, d.rd & 0x1f) << 32) | target_off,
                        };
                    }
                },
                .stp64_pre => {
                    if (d.rn == 31 and next_inst == 0x9100_03fd) {
                        var fused = d;
                        fused.rn = 31 | 0x80;
                        return fused;
                    }
                },
                .ldr64_uimm => {
                    if ((next_inst & 0x7e00_0000) == 0x3400_0000 and d.rd != 31 and (next_inst & 0x1f) == d.rd and (d.imm >> 32) == 0) {
                        const imm19: i32 = @as(i19, @bitCast(@as(u19, @truncate(next_inst >> 5))));
                        const target_off: u32 = @bitCast((imm19 << 2) + 4);
                        const is_cbnz: u8 = @truncate((next_inst >> 24) & 1);
                        const is_32: u8 = if ((next_inst >> 31) == 0) 2 else 0;
                        return .{
                            .raw = d.raw,
                            .op = @intFromEnum(A64Op.ldr_cbz),
                            .rd = d.rd,
                            .rn = d.rn,
                            .rm = is_cbnz | is_32,
                            .imm = (@as(u64, target_off) << 32) | @as(u32, @truncate(d.imm)),
                        };
                    } else if ((next_inst & 0xffc0_0000) == 0xf940_0000) {
                        const rt2: u8 = @truncate(next_inst & 0x1f);
                        const rn2: u8 = @truncate((next_inst >> 5) & 0x1f);
                        const imm2: u64 = ((next_inst >> 10) & 0xfff) << 3;
                        if (rn2 == d.rn and d.rd != d.rn and d.rd != rt2 and (d.imm >> 32) == 0) {
                            return .{
                                .raw = d.raw,
                                .op = @intFromEnum(A64Op.ldr64_pair_uimm),
                                .rd = d.rd,
                                .rn = d.rn,
                                .rm = rt2,
                                .imm = (imm2 << 32) | @as(u32, @truncate(d.imm)),
                            };
                        }
                    }
                },
                .ldr32_uimm => {
                    if ((next_inst & 0xfe00_0000) == 0x3400_0000 and d.rd != 31 and (next_inst & 0x1f) == d.rd and (d.imm >> 32) == 0) {
                        const imm19: i32 = @as(i19, @bitCast(@as(u19, @truncate(next_inst >> 5))));
                        const target_off: u32 = @bitCast((imm19 << 2) + 4);
                        const is_cbnz: u8 = @truncate((next_inst >> 24) & 1);
                        return .{
                            .raw = d.raw,
                            .op = @intFromEnum(A64Op.ldr_cbz),
                            .rd = d.rd,
                            .rn = d.rn,
                            .rm = is_cbnz | 4,
                            .imm = (@as(u64, target_off) << 32) | @as(u32, @truncate(d.imm)),
                        };
                    }
                },
                else => {},
            }
            return null;
        }

        noinline fn decodeAndFuseA64(
            cpu: *CpuType,
            comptime SlotType: type,
            code_page_idx: usize,
            code_icache_ptr: [*]SlotType,
            code_page_ptr: [*]const u8,
            page_word: usize,
            raw_inst: u32,
            has_next: bool,
        ) SlotType {
            var d = decodeA64(SlotType, raw_inst);
            if (has_next and page_word < 1023) {
                const next_inst = std.mem.readInt(u32, code_page_ptr[(page_word + 1) * 4 ..][0..4], .little);
                if (tryFusePairA64(SlotType, d, next_inst)) |fused| {
                    d = fused;
                    if (code_icache_ptr[page_word + 1].raw != next_inst) {
                        code_icache_ptr[page_word + 1] = decodeA64(SlotType, next_inst);
                        cpu.markIcacheDirty(code_page_idx, page_word + 1);
                    }
                }
            }
            code_icache_ptr[page_word] = d;
            cpu.markIcacheDirty(code_page_idx, page_word);
            return d;
        }

        noinline fn populateIcacheSlot64(
            cpu: *CpuType,
            comptime SlotType: type,
            code_page_idx: usize,
            code_icache_ptr: [*]SlotType,
            code_page_ptr: [*]const u8,
            page_word: usize,
        ) void {
            const raw_inst = std.mem.readInt(u32, code_page_ptr[page_word * 4 ..][0..4], .little);
            _ = decodeAndFuseA64(cpu, SlotType, code_page_idx, code_icache_ptr, code_page_ptr, page_word, raw_inst, true);
        }

        noinline fn compileHotLoop64(
            cpu: *CpuType,
            comptime SlotType: type,
            code_page_idx: usize,
            code_icache_ptr: [*]SlotType,
            code_page_ptr: [*]const u8,
            start_word: u10,
            end_word_req: u16,
        ) void {
            if (code_icache_ptr[start_word].op == @intFromEnum(A64Op.jit_trace)) return;
            const tc_idx = jit_mod.JitCodeBuffer.traceCacheIdx(code_page_ptr, start_word, end_word_req);
            const code_hash = jit_mod.JitCodeBuffer.hashLoopWords(code_page_ptr, start_word, end_word_req);
            const entry = &cpu.jit_buf.trace_cache[tc_idx];
            if (entry.page_ptr == @intFromPtr(code_page_ptr) and
                entry.start_word == start_word and
                entry.end_word_req == end_word_req and
                entry.code_hash == code_hash)
            {
                if (entry.failed) return;
                if (entry.fn_ptr) |fn_ptr| {
                    const raw_inst = std.mem.readInt(u32, code_page_ptr[@as(usize, start_word) * 4 ..][0..4], .little);
                    code_icache_ptr[start_word] = .{
                        .raw = raw_inst,
                        .op = @intFromEnum(A64Op.jit_trace),
                        .rd = entry.trace_len,
                        .imm = @intFromPtr(fn_ptr),
                    };
                    cpu.markIcacheDirty(code_page_idx, start_word);
                    return;
                }
            }
            const Jit64 = jit_mod.A64Jit(CpuType, Bus);
            var end_word: u16 = 0;
            if (Jit64.compileTrace(SlotType, &cpu.jit_buf, cpu.mmu.core_id, code_page_ptr, start_word, end_word_req, &end_word)) |fn_ptr| {
                const raw_inst = std.mem.readInt(u32, code_page_ptr[@as(usize, start_word) * 4 ..][0..4], .little);
                const trace_len: u8 = @intCast(end_word - @as(u16, start_word));
                entry.* = .{
                    .page_ptr = @intFromPtr(code_page_ptr),
                    .start_word = start_word,
                    .end_word_req = end_word_req,
                    .trace_len = trace_len,
                    .failed = false,
                    .code_hash = code_hash,
                    .fn_ptr = fn_ptr,
                };
                code_icache_ptr[start_word] = .{
                    .raw = raw_inst,
                    .op = @intFromEnum(A64Op.jit_trace),
                    .rd = trace_len,
                    .imm = @intFromPtr(fn_ptr),
                };
                cpu.markIcacheDirty(code_page_idx, start_word);
            } else {
                entry.* = .{
                    .page_ptr = @intFromPtr(code_page_ptr),
                    .start_word = start_word,
                    .end_word_req = end_word_req,
                    .trace_len = 0,
                    .failed = true,
                    .code_hash = code_hash,
                    .fn_ptr = null,
                };
            }
        }

        inline fn noteBackwardBranch64(
            cpu: *CpuType,
            comptime SlotType: type,
            code_vbase: u64,
            code_page_idx: usize,
            code_icache_ptr: [*]SlotType,
            code_page_ptr: [*]const u8,
            cur_pc: u64,
            target_pc: u64,
            end_word_req: u16,
        ) void {
            if (target_pc <= cur_pc and (target_pc & ~@as(u64, 0xfff)) == code_vbase) {
                const start_word: u10 = @truncate((target_pc >> 2) & 0x3ff);
                if (code_icache_ptr[start_word].op == @intFromEnum(A64Op.jit_trace)) return;
                if (end_word_req > @as(u16, start_word) + 1 and end_word_req - @as(u16, start_word) <= 64) {
                    const h: u8 = @truncate((target_pc >> 2) ^ (target_pc >> 10));
                    const c = cpu.jit_buf.loop_counts[h] +% 1;
                    cpu.jit_buf.loop_counts[h] = c;
                    if ((c & 7) == 0) {
                        compileHotLoop64(cpu, SlotType, code_page_idx, code_icache_ptr, code_page_ptr, start_word, end_word_req);
                    }
                }
            }
        }

        pub noinline fn decodeA64(comptime SlotType: type, inst: u32) SlotType {
            const top4: u4 = @truncate(inst >> 25);
            switch (top4) {
                0b1000, 0b1001 => {
                    const op0: u3 = @truncate(inst >> 23);
                    const rd: u8 = @truncate(inst & 0x1f);
                    const rn: u8 = @truncate((inst >> 5) & 0x1f);
                    const sf: u1 = @truncate(inst >> 31);
                    switch (op0) {
                        0b000, 0b001 => {
                            const immlo: u64 = (inst >> 29) & 3;
                            const immhi: i64 = @as(i19, @bitCast(@as(u19, @truncate(inst >> 5))));
                            const raw_imm: u64 = (@as(u64, @bitCast(immhi)) << 2) | immlo;
                            return if (sf == 0)
                                .{ .raw = inst, .op = @intFromEnum(A64Op.adr), .rd = rd, .imm = raw_imm }
                            else
                                .{ .raw = inst, .op = @intFromEnum(A64Op.adrp), .rd = rd, .imm = raw_imm << 12 };
                        },
                        0b010, 0b011 => {
                            const op_sub = ((inst >> 30) & 1) != 0;
                            const set_flags = ((inst >> 29) & 1) != 0;
                            const sh = ((inst >> 22) & 1) != 0;
                            const imm12: u64 = (inst >> 10) & 0xfff;
                            const imm: u64 = if (sh) (imm12 << 12) else imm12;
                            const op: A64Op = if (sf == 1) (if (set_flags) (if (op_sub) .subs_imm64 else .adds_imm64) else (if (op_sub) .sub_imm64 else .add_imm64)) else (if (set_flags) (if (op_sub) .subs_imm32 else .adds_imm32) else (if (op_sub) .sub_imm32 else .add_imm32));
                            return .{ .raw = inst, .op = @intFromEnum(op), .rd = rd, .rn = rn, .imm = imm };
                        },
                        0b100 => {
                            const opc: u2 = @truncate(inst >> 29);
                            const n: u1 = @truncate(inst >> 22);
                            const immr: u6 = @truncate(inst >> 16);
                            const imms: u6 = @truncate(inst >> 10);
                            const imm = decodeLogicalImm(sf, n, imms, immr) orelse 0;
                            const op: A64Op = if (sf == 1) switch (opc) {
                                0b00 => .and_imm64,
                                0b01 => .orr_imm64,
                                0b10 => .eor_imm64,
                                0b11 => .ands_imm64,
                            } else switch (opc) {
                                0b00 => .and_imm32,
                                0b01 => .orr_imm32,
                                0b10 => .eor_imm32,
                                0b11 => .ands_imm32,
                            };
                            return .{ .raw = inst, .op = @intFromEnum(op), .rd = rd, .rn = rn, .imm = imm };
                        },
                        0b101 => {
                            const opc: u2 = @truncate(inst >> 29);
                            const hw: u2 = @truncate(inst >> 21);
                            const imm16: u64 = (inst >> 5) & 0xffff;
                            const shift: u6 = @as(u6, hw) * 16;
                            if (opc == 0b00 or opc == 0b10) {
                                var val: u64 = if (opc == 0b00) ~(imm16 << shift) else (imm16 << shift);
                                if (sf == 0) val &= 0xffff_ffff;
                                return .{ .raw = inst, .op = @intFromEnum(A64Op.mov_wide), .rd = rd, .imm = val };
                            } else if (opc == 0b11) {
                                return .{
                                    .raw = inst,
                                    .op = @intFromEnum(if (sf == 1) A64Op.movk64 else A64Op.movk32),
                                    .rd = rd,
                                    .rm = shift,
                                    .imm = imm16 << shift,
                                };
                            }
                        },
                        0b110 => {
                            const opc: u2 = @truncate(inst >> 29);
                            const immr: u6 = @truncate(inst >> 16);
                            const imms: u6 = @truncate(inst >> 10);
                            const reg_bits: u7 = if (sf == 1) 64 else 32;
                            const reg_mask: u64 = if (sf == 1) 0xffff_ffff_ffff_ffff else 0xffff_ffff;
                            if (opc == 0b10) {
                                if (imms >= immr) {
                                    const width: u7 = @as(u7, imms - immr) + 1;
                                    const wmask: u64 = if (width >= 64) 0xffff_ffff_ffff_ffff else ((@as(u64, 1) << @intCast(width)) - 1);
                                    return .{ .raw = inst, .op = @intFromEnum(A64Op.ubfm_r), .rd = rd, .rn = rn, .rm = immr, .imm = wmask & reg_mask };
                                } else {
                                    const width: u7 = @as(u7, imms) + 1;
                                    const lshift: u6 = @intCast(reg_bits - @as(u7, immr));
                                    const wmask: u64 = if (width >= 64) 0xffff_ffff_ffff_ffff else ((@as(u64, 1) << @intCast(width)) - 1);
                                    return .{ .raw = inst, .op = @intFromEnum(A64Op.ubfm_l), .rd = rd, .rn = rn, .rm = lshift, .imm = (wmask << lshift) & reg_mask };
                                }
                            } else if (opc == 0b01) {
                                if (imms >= immr) {
                                    const width: u7 = @as(u7, imms - immr) + 1;
                                    const wmask: u64 = if (width >= 64) 0xffff_ffff_ffff_ffff else ((@as(u64, 1) << @intCast(width)) - 1);
                                    return .{ .raw = inst, .op = @intFromEnum(A64Op.bfm_r), .rd = rd, .rn = rn, .rm = immr | (@as(u8, sf) << 6), .imm = wmask & reg_mask };
                                } else {
                                    const width: u7 = @as(u7, imms) + 1;
                                    const lshift: u6 = @intCast(reg_bits - @as(u7, immr));
                                    const wmask: u64 = if (width >= 64) 0xffff_ffff_ffff_ffff else ((@as(u64, 1) << @intCast(width)) - 1);
                                    return .{ .raw = inst, .op = @intFromEnum(A64Op.bfm_l), .rd = rd, .rn = rn, .rm = @as(u8, lshift) | (@as(u8, sf) << 6), .imm = (wmask << lshift) & reg_mask };
                                }
                            } else if (opc == 0b00) {
                                if (imms >= immr) {
                                    if (sf == 1) {
                                        const lsh: u8 = @intCast(63 - imms);
                                        const rsh: u64 = @intCast(63 - (imms - immr));
                                        return .{ .raw = inst, .op = @intFromEnum(A64Op.sbfm64_r), .rd = rd, .rn = rn, .rm = lsh, .imm = rsh };
                                    } else if (imms < 32) {
                                        const lsh: u8 = @intCast(31 - imms);
                                        const rsh: u64 = @intCast(31 - (imms - immr));
                                        return .{ .raw = inst, .op = @intFromEnum(A64Op.sbfm32_r), .rd = rd, .rn = rn, .rm = lsh, .imm = rsh };
                                    }
                                } else {
                                    if (sf == 1) {
                                        const lsh: u8 = @intCast(63 - imms);
                                        const rsh: u64 = @intCast(immr - imms - 1);
                                        return .{ .raw = inst, .op = @intFromEnum(A64Op.sbfm64_r), .rd = rd, .rn = rn, .rm = lsh, .imm = rsh };
                                    } else if (immr < 32) {
                                        const lsh: u8 = @intCast(31 - imms);
                                        const rsh: u64 = @intCast(immr - imms - 1);
                                        return .{ .raw = inst, .op = @intFromEnum(A64Op.sbfm32_r), .rd = rd, .rn = rn, .rm = lsh, .imm = rsh };
                                    }
                                }
                            }
                        },
                        0b111 => {
                            const opc: u2 = @truncate(inst >> 29);
                            const o0: u1 = @truncate(inst >> 21);
                            if (opc == 0b00 and o0 == 0) {
                                const rm: u8 = @truncate((inst >> 16) & 0x1f);
                                const imms: u6 = @truncate(inst >> 10);
                                return .{
                                    .raw = inst,
                                    .op = @intFromEnum(if (sf == 1) A64Op.extr64 else A64Op.extr32),
                                    .rd = rd,
                                    .rn = rn,
                                    .rm = rm,
                                    .imm = imms,
                                };
                            }
                        },
                    }
                    return .{ .raw = inst, .op = @intFromEnum(A64Op.dp_imm_other) };
                },
                0b0101, 0b1101 => {
                    const sf: u1 = @truncate(inst >> 31);
                    const op0: u1 = @truncate(inst >> 30);
                    const s: u1 = @truncate(inst >> 29);
                    const op1: u1 = @truncate(inst >> 28);
                    const op2: u4 = @truncate(inst >> 21);
                    const rm: u8 = @truncate((inst >> 16) & 0x1f);
                    const imm6: u6 = @truncate(inst >> 10);
                    const rn: u8 = @truncate((inst >> 5) & 0x1f);
                    const rd: u8 = @truncate(inst & 0x1f);
                    if (op1 == 0) {
                        if ((op2 & 0b1001) == 0b1001) {
                            // Add/subtract (extended register)
                            const option: u3 = @truncate(inst >> 13);
                            const imm3: u3 = @truncate(inst >> 10);
                            if (imm3 <= 4) {
                                if (s == 0 and sf == 1) {
                                    const packed_imm: u64 = (@as(u64, option) << 3) | imm3;
                                    return .{
                                        .raw = inst,
                                        .op = @intFromEnum(if (op0 == 1) A64Op.sub_ext64 else A64Op.add_ext64),
                                        .rd = rd,
                                        .rn = rn,
                                        .rm = rm,
                                        .imm = packed_imm,
                                    };
                                }
                                const packed_ext: u64 = @as(u64, imm3) | (@as(u64, option) << 3) | (@as(u64, s) << 6) | (@as(u64, op0) << 7) | (@as(u64, sf) << 8);
                                return .{
                                    .raw = inst,
                                    .op = @intFromEnum(A64Op.add_sub_ext),
                                    .rd = rd,
                                    .rn = rn,
                                    .rm = rm,
                                    .imm = packed_ext,
                                };
                            }
                        } else if (imm6 == 0) {
                            if ((op2 & 0b1001) == 0) {
                                // Unshifted non-inverted logical register
                                const opc: u2 = (@as(u2, op0) << 1) | s;
                                const op: A64Op = if (sf == 1) switch (opc) {
                                    0b00 => .and_reg64,
                                    0b01 => .orr_reg64,
                                    0b10 => .eor_reg64,
                                    0b11 => .ands_reg64,
                                } else switch (opc) {
                                    0b00 => .and_reg32,
                                    0b01 => .orr_reg32,
                                    0b10 => .eor_reg32,
                                    0b11 => .ands_reg32,
                                };
                                return .{ .raw = inst, .op = @intFromEnum(op), .rd = rd, .rn = rn, .rm = rm };
                            } else if ((op2 & 0b1001) == 0b0001 and op0 == 0) {
                                // Unshifted BIC (s=0) / ORN (`MVN`, s=1)
                                if (s == 0) {
                                    return .{ .raw = inst, .op = @intFromEnum(if (sf == 1) A64Op.bic_reg64 else A64Op.bic_reg32), .rd = rd, .rn = rn, .rm = rm };
                                } else {
                                    return .{ .raw = inst, .op = @intFromEnum(if (sf == 1) A64Op.orn_reg64 else A64Op.orn_reg32), .rd = rd, .rn = rn, .rm = rm };
                                }
                            } else if ((op2 & 0b1001) == 0b1000) {
                                // Unshifted add/sub register
                                const op: A64Op = if (sf == 1)
                                    (if (s == 1) (if (op0 == 1) .subs_reg64 else .adds_reg64) else (if (op0 == 1) .sub_reg64 else .add_reg64))
                                else
                                    (if (s == 1) (if (op0 == 1) .subs_reg32 else .adds_reg32) else (if (op0 == 1) .sub_reg32 else .add_reg32));
                                return .{ .raw = inst, .op = @intFromEnum(op), .rd = rd, .rn = rn, .rm = rm };
                            }
                        } else {
                            const shift_type: u2 = @truncate(inst >> 22);
                            if (s == 0 and (op2 & 0b1001) == 0b1000 and shift_type == 0b00) {
                                const op: A64Op = if (sf == 1) (if (op0 == 1) .sub_lsl64 else .add_lsl64) else (if (op0 == 1) .sub_lsl32 else .add_lsl32);
                                return .{ .raw = inst, .op = @intFromEnum(op), .rd = rd, .rn = rn, .rm = rm, .imm = imm6 };
                            } else if ((op2 & 0b1001) == 0 and sf == 1 and op0 == 0 and s == 1) {
                                if (shift_type == 0b00) {
                                    return .{ .raw = inst, .op = @intFromEnum(A64Op.orr_lsl64), .rd = rd, .rn = rn, .rm = rm, .imm = imm6 };
                                } else if (shift_type == 0b01) {
                                    return .{ .raw = inst, .op = @intFromEnum(A64Op.orr_lsr64), .rd = rd, .rn = rn, .rm = rm, .imm = imm6 };
                                }
                            }
                        }
                        // General shifted logical or add/sub register
                        const shift_type: u2 = @truncate(inst >> 22);
                        const packed_shift: u64 = @as(u64, imm6) | (@as(u64, shift_type) << 6) | (@as(u64, op2) << 8) | (@as(u64, s) << 12) | (@as(u64, op0) << 13) | (@as(u64, sf) << 14);
                        return .{ .raw = inst, .op = @intFromEnum(A64Op.dp_shift_reg), .rd = rd, .rn = rn, .rm = rm, .imm = packed_shift };
                    } else if (op2 == 0b0000) {
                        // Add/subtract (with carry): ADC, ADCS, SBC, SBCS
                        const packed_adc: u64 = (@as(u64, sf) << 2) | (@as(u64, op0) << 1) | s;
                        return .{ .raw = inst, .op = @intFromEnum(A64Op.adc_sbc), .rd = rd, .rn = rn, .rm = rm, .imm = packed_adc };
                    } else if (s == 1 and op2 == 0b0010) {
                        // Conditional compare (register / immediate): CCMP, CCMN
                        const cond: u64 = (inst >> 12) & 0xf;
                        const nzcv: u64 = inst & 0xf;
                        const is_imm: u64 = (inst >> 11) & 1;
                        const packed_ccmp: u64 = cond | (nzcv << 4) | (is_imm << 8) | (@as(u64, op0) << 9) | (@as(u64, sf) << 10);
                        return .{ .raw = inst, .op = @intFromEnum(A64Op.ccmp), .rn = rn, .rm = rm, .imm = packed_ccmp };
                    } else if (s == 0) {
                        if (op2 == 0b0100) {
                            // CSEL / CSINC / CSINV / CSNEG
                            const cond: u64 = (inst >> 12) & 0xf;
                            const o2: u64 = (inst >> 10) & 1;
                            const packed_imm: u64 = cond | (@as(u64, op0) << 4) | (o2 << 5) | (@as(u64, sf) << 6);
                            return .{ .raw = inst, .op = @intFromEnum(A64Op.csel), .rd = rd, .rn = rn, .rm = rm, .imm = packed_imm };
                        } else if ((op2 & 0b1000) != 0 and op0 == 0) {
                            const op31: u3 = @truncate(inst >> 21);
                            const o0: u64 = (inst >> 15) & 1;
                            const ra: u64 = (inst >> 10) & 0x1f;
                            if (op31 == 0b000) {
                                // MADD / MSUB
                                const packed_imm: u64 = ra | (o0 << 5) | (@as(u64, sf) << 6);
                                return .{ .raw = inst, .op = @intFromEnum(A64Op.madd_msub), .rd = rd, .rn = rn, .rm = rm, .imm = packed_imm };
                            } else if (sf == 1 and (op31 == 0b001 or op31 == 0b010 or op31 == 0b101 or op31 == 0b110)) {
                                // SMADDL, SMSUBL, SMULH, UMADDL, UMSUBL, UMULH
                                const packed_imm: u64 = ra | (o0 << 5) | (@as(u64, op31) << 6);
                                return .{ .raw = inst, .op = @intFromEnum(A64Op.maddl_mulh), .rd = rd, .rn = rn, .rm = rm, .imm = packed_imm };
                            }
                        } else if (op2 == 0b0110) {
                            if (op0 == 0) {
                                const vop: ?A64Op = switch (imm6) {
                                    0b000010 => if (sf == 1) .udiv64 else .udiv32,
                                    0b000011 => if (sf == 1) .sdiv64 else .sdiv32,
                                    0b001000 => if (sf == 1) .lslv64 else .lslv32,
                                    0b001001 => if (sf == 1) .lsrv64 else .lsrv32,
                                    0b001010 => if (sf == 1) .asrv64 else .asrv32,
                                    else => null,
                                };
                                if (vop) |vo| {
                                    return .{ .raw = inst, .op = @intFromEnum(vo), .rd = rd, .rn = rn, .rm = rm };
                                }
                            } else {
                                const op1src: ?A64Op = switch (imm6) {
                                    3 => if (sf == 1) .rev64 else null,
                                    2 => if (sf == 0) .rev32 else null,
                                    4 => if (sf == 1) .clz64 else .clz32,
                                    else => null,
                                };
                                if (op1src) |o1s| {
                                    return .{ .raw = inst, .op = @intFromEnum(o1s), .rd = rd, .rn = rn };
                                }
                            }
                        }
                    }
                    return .{ .raw = inst, .op = @intFromEnum(A64Op.dp_reg_other) };
                },
                0b0100, 0b0110, 0b1100, 0b1110 => {
                    // Check unsigned immediate LDR/STR or unscaled LDUR/STUR (non-FP)
                    if ((inst & 0x3f00_0000) == 0x3900_0000 or (inst & 0x3f20_0c00) == 0x3800_0000) {
                        const size: u2 = @truncate(inst >> 30);
                        const opc: u2 = @truncate(inst >> 22);
                        const is_uimm = ((inst >> 24) & 1) != 0;
                        const rn: u8 = @truncate((inst >> 5) & 0x1f);
                        const rt: u8 = @truncate(inst & 0x1f);
                        const imm: u64 = if (is_uimm)
                            (@as(u64, (inst >> 10) & 0xfff) << size)
                        else
                            @bitCast(@as(i64, @as(i9, @bitCast(@as(u9, @truncate(inst >> 12))))));
                        if (opc == 0b00) {
                            const op: A64Op = switch (size) {
                                0 => .str8_uimm,
                                1 => .str16_uimm,
                                2 => .str32_uimm,
                                3 => .str64_uimm,
                            };
                            return .{ .raw = inst, .op = @intFromEnum(op), .rd = rt, .rn = rn, .imm = imm };
                        } else if (opc == 0b01) {
                            const op: A64Op = switch (size) {
                                0 => .ldr8_uimm,
                                1 => .ldr16_uimm,
                                2 => .ldr32_uimm,
                                3 => .ldr64_uimm,
                            };
                            return .{ .raw = inst, .op = @intFromEnum(op), .rd = rt, .rn = rn, .imm = imm };
                        } else if (opc == 0b10) {
                            const op: A64Op = switch (size) {
                                0 => .ldrsb64_uimm,
                                1 => .ldrsh64_uimm,
                                2 => .ldrsw_uimm,
                                3 => .nop, // PRFM
                            };
                            return .{ .raw = inst, .op = @intFromEnum(op), .rd = rt, .rn = rn, .imm = imm };
                        } else if (size == 0 or size == 1) {
                            const op: A64Op = if (size == 0) .ldrsb32_uimm else .ldrsh32_uimm;
                            return .{ .raw = inst, .op = @intFromEnum(op), .rd = rt, .rn = rn, .imm = imm };
                        }
                    } else if ((inst & 0x3b00_0000) == 0x1800_0000) {
                        // PC-relative Load register (literal)
                        const opc: u2 = @truncate(inst >> 30);
                        const is_fp = ((inst >> 26) & 1) != 0;
                        const imm19: i64 = @as(i19, @bitCast(@as(u19, @truncate(inst >> 5))));
                        const offset: u64 = @bitCast(imm19 << 2);
                        const rt: u8 = @truncate(inst & 0x1f);
                        const op: A64Op = if (!is_fp) switch (opc) {
                            0b00 => .ldr_lit32,
                            0b01 => .ldr_lit64,
                            0b10 => .ldrsw_lit,
                            0b11 => .nop, // PRFM (literal)
                        } else switch (opc) {
                            0b00 => .ldr_fp32_lit,
                            0b01 => .ldr_fp64_lit,
                            0b10 => .ldr_fp128_lit,
                            0b11 => .nop,
                        };
                        return .{ .raw = inst, .op = @intFromEnum(op), .rd = rt, .imm = offset };
                    } else if ((inst & 0x3f20_0400) == 0x3800_0400) {
                        // Pre-index (mode2 == 0b11) or Post-index (mode2 == 0b01) 9-bit signed immediate LDR/STR (non-FP)
                        const size: u2 = @truncate(inst >> 30);
                        const opc: u2 = @truncate(inst >> 22);
                        const is_pre = ((inst >> 11) & 1) != 0;
                        const rn: u8 = @truncate((inst >> 5) & 0x1f);
                        const rt: u8 = @truncate(inst & 0x1f);
                        if (rn != rt and (opc == 0b00 or opc == 0b01) and (size == 2 or size == 3)) {
                            const imm9: i64 = @as(i9, @bitCast(@as(u9, @truncate(inst >> 12))));
                            const op: A64Op = if (size == 3)
                                (if (opc == 0b01) (if (is_pre) .ldr64_pre else .ldr64_post) else (if (is_pre) .str64_pre else .str64_post))
                            else
                                (if (opc == 0b01) (if (is_pre) .ldr32_pre else .ldr32_post) else (if (is_pre) .str32_pre else .str32_post));
                            return .{ .raw = inst, .op = @intFromEnum(op), .rd = rt, .rn = rn, .imm = @bitCast(imm9) };
                        }
                    } else if ((inst & 0x3f20_0c00) == 0x3820_0800) {
                        // Register offset [Xn, Xm, LSL #shift] (option == 0b011)
                        const option: u3 = @truncate(inst >> 13);
                        const size: u2 = @truncate(inst >> 30);
                        const opc: u2 = @truncate(inst >> 22);
                        if (option == 0b011 and (opc == 0b00 or opc == 0b01) and (size == 0 or size == 2 or size == 3)) {
                            const s_bit = ((inst >> 12) & 1) != 0;
                            const shift: u64 = if (s_bit) size else 0;
                            const rm: u8 = @truncate((inst >> 16) & 0x1f);
                            const rn: u8 = @truncate((inst >> 5) & 0x1f);
                            const rt: u8 = @truncate(inst & 0x1f);
                            const op: A64Op = switch (size) {
                                0 => if (opc == 0b01) .ldr8_reg_lsl else .str8_reg_lsl,
                                2 => if (opc == 0b01) .ldr32_reg_lsl else .str32_reg_lsl,
                                else => if (opc == 0b01) .ldr64_reg_lsl else .str64_reg_lsl,
                            };
                            return .{ .raw = inst, .op = @intFromEnum(op), .rd = rt, .rn = rn, .rm = rm, .imm = shift };
                        }
                    } else if ((inst & 0x3f00_0000) == 0x0800_0000) {
                        // Load/Store Exclusive & Load-Acquire/Store-Release
                        const size: u2 = @truncate(inst >> 30);
                        const o2 = ((inst >> 23) & 1) != 0;
                        const is_load = ((inst >> 22) & 1) != 0;
                        const o1 = ((inst >> 21) & 1) != 0;
                        const rs: u8 = @truncate((inst >> 16) & 0x1f);
                        const rn: u8 = @truncate((inst >> 5) & 0x1f);
                        const rt: u8 = @truncate(inst & 0x1f);
                        if (!o1) {
                            if (o2) {
                                // LDAR / STLR: map directly to unsigned-immediate LDR/STR with offset 0
                                const op: A64Op = if (is_load) switch (size) {
                                    0 => .ldr8_uimm,
                                    1 => .ldr16_uimm,
                                    2 => .ldr32_uimm,
                                    3 => .ldr64_uimm,
                                } else switch (size) {
                                    0 => .str8_uimm,
                                    1 => .str16_uimm,
                                    2 => .str32_uimm,
                                    3 => .str64_uimm,
                                };
                                return .{ .raw = inst, .op = @intFromEnum(op), .rd = rt, .rn = rn, .imm = 0 };
                            } else if (size == 2 or size == 3) {
                                const op: A64Op = if (size == 3)
                                    (if (is_load) .ldxr64 else .stxr64)
                                else
                                    (if (is_load) .ldxr32 else .stxr32);
                                return .{ .raw = inst, .op = @intFromEnum(op), .rd = rt, .rn = rn, .rm = rs };
                            }
                        }
                    } else if ((inst & 0x3e00_0000) == 0x2800_0000) {
                        // Integer STP / LDP (signed offset, post-index, pre-index)
                        const opc: u2 = @truncate(inst >> 30);
                        const mode: u2 = @truncate(inst >> 23);
                        const is_load = ((inst >> 22) & 1) != 0;
                        const imm7: i64 = @as(i7, @bitCast(@as(u7, @truncate(inst >> 15))));
                        const rt2: u8 = @truncate((inst >> 10) & 0x1f);
                        const rn: u8 = @truncate((inst >> 5) & 0x1f);
                        const rt: u8 = @truncate(inst & 0x1f);
                        const no_overlap = (rt != rn and rt2 != rn) and (!is_load or rt != rt2);
                        if (opc == 0b10 and no_overlap) {
                            const op: A64Op = switch (mode) {
                                0b01 => if (is_load) .ldp64_post else .stp64_post,
                                0b10 => if (is_load) .ldp64_off else .stp64_off,
                                0b11 => if (is_load) .ldp64_pre else .stp64_pre,
                                else => .load_store_other,
                            };
                            if (op != .load_store_other) {
                                return .{
                                    .raw = inst,
                                    .op = @intFromEnum(op),
                                    .rd = rt,
                                    .rn = rn,
                                    .rm = rt2,
                                    .imm = @bitCast(imm7 << 3),
                                };
                            }
                        } else if (opc == 0b00 and no_overlap) {
                            const op: A64Op = switch (mode) {
                                0b01 => if (is_load) .ldp32_post else .stp32_post,
                                0b10 => if (is_load) .ldp32_off else .stp32_off,
                                0b11 => if (is_load) .ldp32_pre else .stp32_pre,
                                else => .load_store_other,
                            };
                            if (op != .load_store_other) {
                                return .{
                                    .raw = inst,
                                    .op = @intFromEnum(op),
                                    .rd = rt,
                                    .rn = rn,
                                    .rm = rt2,
                                    .imm = @bitCast(imm7 << 2),
                                };
                            }
                        } else if (opc == 0b01 and is_load and no_overlap) {
                            const op: A64Op = switch (mode) {
                                0b01 => .ldpsw_post,
                                0b10 => .ldpsw_off,
                                0b11 => .ldpsw_pre,
                                else => .load_store_other,
                            };
                            if (op != .load_store_other) {
                                return .{
                                    .raw = inst,
                                    .op = @intFromEnum(op),
                                    .rd = rt,
                                    .rn = rn,
                                    .rm = rt2,
                                    .imm = @bitCast(imm7 << 2),
                                };
                            }
                        }
                    } else if ((inst & 0x3f00_0000) == 0x3d00_0000 or (inst & 0x3f20_0c00) == 0x3c00_0000) {
                        // Unsigned immediate or unscaled 9-bit signed immediate FP/SIMD LDR/STR (S/D/Q)
                        const size: u2 = @truncate(inst >> 30);
                        const opc: u2 = @truncate(inst >> 22);
                        const is_uimm = ((inst >> 24) & 1) != 0;
                        const rn: u8 = @truncate((inst >> 5) & 0x1f);
                        const rt: u8 = @truncate(inst & 0x1f);
                        const is_load = (opc & 1) != 0;
                        if ((opc & 2) == 0 and (size == 2 or size == 3)) {
                            const imm: u64 = if (is_uimm)
                                (@as(u64, (inst >> 10) & 0xfff) << size)
                            else
                                @bitCast(@as(i64, @as(i9, @bitCast(@as(u9, @truncate(inst >> 12))))));
                            const op: A64Op = if (size == 3)
                                (if (is_load) .ldr_fp64_uimm else .str_fp64_uimm)
                            else
                                (if (is_load) .ldr_fp32_uimm else .str_fp32_uimm);
                            return .{ .raw = inst, .op = @intFromEnum(op), .rd = rt, .rn = rn, .imm = imm };
                        } else if ((opc & 2) != 0 and size == 0) {
                            const imm: u64 = if (is_uimm)
                                (@as(u64, (inst >> 10) & 0xfff) << 4)
                            else
                                @bitCast(@as(i64, @as(i9, @bitCast(@as(u9, @truncate(inst >> 12))))));
                            const op: A64Op = if (is_load) .ldr_fp128_uimm else .str_fp128_uimm;
                            return .{ .raw = inst, .op = @intFromEnum(op), .rd = rt, .rn = rn, .imm = imm };
                        }
                    } else if ((inst & 0x3f20_0400) == 0x3c00_0400) {
                        // Pre-index or Post-index 9-bit signed immediate FP/SIMD LDR/STR (D/Q)
                        const size: u2 = @truncate(inst >> 30);
                        const opc: u2 = @truncate(inst >> 22);
                        const is_pre = ((inst >> 11) & 1) != 0;
                        const is_load = (opc & 1) != 0;
                        const rn: u8 = @truncate((inst >> 5) & 0x1f);
                        const rt: u8 = @truncate(inst & 0x1f);
                        const imm9: i64 = @as(i9, @bitCast(@as(u9, @truncate(inst >> 12))));
                        if ((opc & 2) == 0 and size == 3) {
                            const op: A64Op = if (is_load)
                                (if (is_pre) .ldr_fp64_pre else .ldr_fp64_post)
                            else
                                (if (is_pre) .str_fp64_pre else .str_fp64_post);
                            return .{ .raw = inst, .op = @intFromEnum(op), .rd = rt, .rn = rn, .imm = @bitCast(imm9) };
                        } else if ((opc & 2) != 0 and size == 0) {
                            const op: A64Op = if (is_load)
                                (if (is_pre) .ldr_fp128_pre else .ldr_fp128_post)
                            else
                                (if (is_pre) .str_fp128_pre else .str_fp128_post);
                            return .{ .raw = inst, .op = @intFromEnum(op), .rd = rt, .rn = rn, .imm = @bitCast(imm9) };
                        }
                    } else if ((inst & 0x3f20_0c00) == 0x3c20_0800) {
                        // Register offset FP/SIMD LDR/STR (D/Q) [Xn, Xm, LSL #shift] (option == 0b011)
                        const option: u3 = @truncate(inst >> 13);
                        const size: u2 = @truncate(inst >> 30);
                        const opc: u2 = @truncate(inst >> 22);
                        if (option == 0b011) {
                            const s_bit = ((inst >> 12) & 1) != 0;
                            const is_load = (opc & 1) != 0;
                            const rm: u8 = @truncate((inst >> 16) & 0x1f);
                            const rn: u8 = @truncate((inst >> 5) & 0x1f);
                            const rt: u8 = @truncate(inst & 0x1f);
                            if ((opc & 2) == 0 and size == 3) {
                                return .{
                                    .raw = inst,
                                    .op = @intFromEnum(if (is_load) A64Op.ldr_fp64_reg_lsl else A64Op.str_fp64_reg_lsl),
                                    .rd = rt,
                                    .rn = rn,
                                    .rm = rm,
                                    .imm = if (s_bit) 3 else 0,
                                };
                            } else if ((opc & 2) != 0 and size == 0) {
                                return .{
                                    .raw = inst,
                                    .op = @intFromEnum(if (is_load) A64Op.ldr_fp128_reg_lsl else A64Op.str_fp128_reg_lsl),
                                    .rd = rt,
                                    .rn = rn,
                                    .rm = rm,
                                    .imm = if (s_bit) 4 else 0,
                                };
                            }
                        }
                    } else if ((inst & 0x3e00_0000) == 0x2c00_0000) {
                        // FP/SIMD STP / LDP (D and Q pairs: signed offset, post-index, pre-index)
                        const opc: u2 = @truncate(inst >> 30);
                        const mode: u2 = @truncate(inst >> 23);
                        const is_load = ((inst >> 22) & 1) != 0;
                        const imm7: i64 = @as(i7, @bitCast(@as(u7, @truncate(inst >> 15))));
                        const rt2: u8 = @truncate((inst >> 10) & 0x1f);
                        const rn: u8 = @truncate((inst >> 5) & 0x1f);
                        const rt: u8 = @truncate(inst & 0x1f);
                        if (!is_load or rt != rt2) {
                            if (opc == 0b01) {
                                const op: A64Op = switch (mode) {
                                    0b01 => if (is_load) .ldp_fp64_post else .stp_fp64_post,
                                    0b10 => if (is_load) .ldp_fp64_off else .stp_fp64_off,
                                    0b11 => if (is_load) .ldp_fp64_pre else .stp_fp64_pre,
                                    else => .load_store_other,
                                };
                                if (op != .load_store_other) {
                                    return .{
                                        .raw = inst,
                                        .op = @intFromEnum(op),
                                        .rd = rt,
                                        .rn = rn,
                                        .rm = rt2,
                                        .imm = @bitCast(imm7 << 3),
                                    };
                                }
                            } else if (opc == 0b10) {
                                const op: A64Op = switch (mode) {
                                    0b01 => if (is_load) .ldp_fp128_post else .stp_fp128_post,
                                    0b10 => if (is_load) .ldp_fp128_off else .stp_fp128_off,
                                    0b11 => if (is_load) .ldp_fp128_pre else .stp_fp128_pre,
                                    else => .load_store_other,
                                };
                                if (op != .load_store_other) {
                                    return .{
                                        .raw = inst,
                                        .op = @intFromEnum(op),
                                        .rd = rt,
                                        .rn = rn,
                                        .rm = rt2,
                                        .imm = @bitCast(imm7 << 4),
                                    };
                                }
                            }
                        }
                    } else if ((inst & 0xbf20_0000) == 0x0c00_0000) {
                        // AdvSIMD LD1 / ST1 multiple structures (selem == 1, 1..4 contiguous D/Q registers)
                        const q = ((inst >> 30) & 1) != 0;
                        const is_post = ((inst >> 23) & 1) != 0;
                        const is_load = ((inst >> 22) & 1) != 0;
                        const rm: u8 = @truncate((inst >> 16) & 0x1f);
                        const opcode: u4 = @truncate(inst >> 12);
                        const rn: u8 = @truncate((inst >> 5) & 0x1f);
                        const rt: u8 = @truncate(inst & 0x1f);
                        if (is_post or rm == 0) {
                            const rpt: u8 = switch (opcode) {
                                0b0111 => 1,
                                0b1010 => 2,
                                0b0110 => 3,
                                0b0010 => 4,
                                else => 0,
                            };
                            if (rpt != 0) {
                                return .{
                                    .raw = inst,
                                    .op = @intFromEnum(if (is_load) A64Op.simd_ld1_mult else A64Op.simd_st1_mult),
                                    .rd = rt,
                                    .rn = rn,
                                    .rm = if (is_post) rm else 32,
                                    .imm = (@as(u64, rpt) << 1) | @intFromBool(q),
                                };
                            }
                        }
                    }
                    return .{ .raw = inst, .op = @intFromEnum(A64Op.load_store_other) };
                },
                0b1010, 0b1011 => {
                    if ((inst & 0x7c00_0000) == 0x1400_0000) {
                        const is_bl = (inst >> 31) != 0;
                        const imm26: i64 = @as(i26, @bitCast(@as(u26, @truncate(inst))));
                        return .{
                            .raw = inst,
                            .op = @intFromEnum(if (is_bl) A64Op.bl_imm else A64Op.b_imm),
                            .imm = @bitCast(imm26 << 2),
                        };
                    }
                    if ((inst & 0xff00_0010) == 0x5400_0000) {
                        const imm19: i64 = @as(i19, @bitCast(@as(u19, @truncate(inst >> 5))));
                        return .{
                            .raw = inst,
                            .op = @intFromEnum(A64Op.b_cond),
                            .rd = @truncate(inst & 0xf),
                            .imm = @bitCast(imm19 << 2),
                        };
                    }
                    if ((inst & 0x7e00_0000) == 0x3400_0000) {
                        const sf: u1 = @truncate(inst >> 31);
                        const is_nz = ((inst >> 24) & 1) != 0;
                        const imm19: i64 = @as(i19, @bitCast(@as(u19, @truncate(inst >> 5))));
                        const op: A64Op = if (sf == 1) (if (is_nz) .cbnz64 else .cbz64) else (if (is_nz) .cbnz32 else .cbz32);
                        return .{
                            .raw = inst,
                            .op = @intFromEnum(op),
                            .rd = @truncate(inst & 0x1f),
                            .imm = @bitCast(imm19 << 2),
                        };
                    }
                    if ((inst & 0x7e00_0000) == 0x3600_0000) {
                        const b5: u8 = @truncate((inst >> 31) << 5);
                        const b40: u8 = @truncate((inst >> 19) & 0x1f);
                        const is_nz = ((inst >> 24) & 1) != 0;
                        const imm14: i64 = @as(i14, @bitCast(@as(u14, @truncate(inst >> 5))));
                        return .{
                            .raw = inst,
                            .op = @intFromEnum(if (is_nz) A64Op.tbnz else A64Op.tbz),
                            .rd = @truncate(inst & 0x1f),
                            .rm = b5 | b40,
                            .imm = @bitCast(imm14 << 2),
                        };
                    }
                    if ((inst & 0xffff_fc1f) == 0xd65f_0000) {
                        return .{
                            .raw = inst,
                            .op = @intFromEnum(A64Op.ret),
                            .rn = @truncate((inst >> 5) & 0x1f),
                        };
                    }
                    if ((inst & 0xffff_fc1f) == 0xd61f_0000) {
                        return .{
                            .raw = inst,
                            .op = @intFromEnum(A64Op.br_reg),
                            .rn = @truncate((inst >> 5) & 0x1f),
                        };
                    }
                    if ((inst & 0xffff_fc1f) == 0xd63f_0000) {
                        return .{
                            .raw = inst,
                            .op = @intFromEnum(A64Op.blr_reg),
                            .rn = @truncate((inst >> 5) & 0x1f),
                        };
                    }
                    if ((inst & 0xffc0_0000) == 0xd500_0000) {
                        const l = ((inst >> 21) & 1) != 0;
                        const op0_sys: u2 = @truncate(inst >> 19);
                        const op1_sys: u3 = @truncate(inst >> 16);
                        const crn: u4 = @truncate(inst >> 12);
                        const crm: u4 = @truncate(inst >> 8);
                        const op2_sys: u3 = @truncate(inst >> 5);
                        const rt: u8 = @truncate(inst & 0x1f);
                        if (op0_sys == 0) {
                            if (crn == 2) {
                                const hint = (@as(u8, crm) << 3) | op2_sys;
                                if (hint == 0 or hint > 3) {
                                    return .{ .raw = inst, .op = @intFromEnum(A64Op.nop) };
                                } else if (hint == 1 or hint == 2) {
                                    return .{ .raw = inst, .op = @intFromEnum(A64Op.msr_safe), .rn = 1 };
                                }
                            } else if (crn == 3) {
                                if (op2_sys == 2) {
                                    return .{ .raw = inst, .op = @intFromEnum(A64Op.msr_safe), .rn = 0 }; // CLREX
                                } else if (op2_sys == 4 or op2_sys == 5) {
                                    return .{ .raw = inst, .op = @intFromEnum(A64Op.msr_safe), .rn = 2, .imm = op2_sys }; // DSB / DMB
                                } else if (op2_sys == 6) {
                                    return .{ .raw = inst, .op = @intFromEnum(A64Op.msr_safe), .rn = 11 }; // ISB
                                }
                            } else if (crn == 4 and op1_sys == 3) {
                                if (op2_sys == 6) {
                                    return .{ .raw = inst, .op = @intFromEnum(A64Op.msr_safe), .rn = 3, .imm = @as(u64, crm) << 6 }; // MSR DAIFSet
                                } else if (op2_sys == 7) {
                                    return .{ .raw = inst, .op = @intFromEnum(A64Op.msr_safe), .rn = 4, .imm = ~(@as(u64, crm) << 6) }; // MSR DAIFClr
                                }
                            }
                        } else if (op0_sys == 1) {
                            if (!l and op1_sys == 3 and crn == 7 and crm == 4 and op2_sys == 1) {
                                return .{ .raw = inst, .op = @intFromEnum(A64Op.dc_zva), .rd = rt };
                            }
                        } else if (l) {
                            const id = sysRegId(op0_sys, op1_sys, crn, crm, op2_sys);
                            if (id == sysRegId(3, 3, 13, 0, 2)) {
                                return .{ .raw = inst, .op = @intFromEnum(A64Op.mrs_tpidr_el0), .rd = rt };
                            }
                            return .{
                                .raw = inst,
                                .op = @intFromEnum(A64Op.mrs_sys),
                                .rd = rt,
                                .rn = (@as(u8, op0_sys) << 3) | op1_sys,
                                .rm = (@as(u8, crn) << 4) | crm,
                                .imm = op2_sys,
                            };
                        } else {
                            switch (sysRegId(op0_sys, op1_sys, crn, crm, op2_sys)) {
                                sysRegId(3, 3, 4, 2, 1) => return .{ .raw = inst, .op = @intFromEnum(A64Op.msr_safe), .rd = rt, .rn = 5 }, // DAIF
                                sysRegId(3, 3, 4, 2, 0) => return .{ .raw = inst, .op = @intFromEnum(A64Op.msr_safe), .rd = rt, .rn = 6 }, // NZCV
                                sysRegId(3, 3, 13, 0, 2) => return .{ .raw = inst, .op = @intFromEnum(A64Op.msr_safe), .rd = rt, .rn = 7 }, // TPIDR_EL0
                                sysRegId(3, 0, 13, 0, 4) => return .{ .raw = inst, .op = @intFromEnum(A64Op.msr_safe), .rd = rt, .rn = 8 }, // TPIDR_EL1
                                sysRegId(3, 0, 4, 1, 0) => return .{ .raw = inst, .op = @intFromEnum(A64Op.msr_safe), .rd = rt, .rn = 9 }, // SP_EL0
                                sysRegId(3, 3, 4, 4, 0) => return .{ .raw = inst, .op = @intFromEnum(A64Op.msr_safe), .rd = rt, .rn = 10, .imm = 0 }, // FPCR
                                sysRegId(3, 3, 4, 4, 1) => return .{ .raw = inst, .op = @intFromEnum(A64Op.msr_safe), .rd = rt, .rn = 10, .imm = 1 }, // FPSR
                                else => {},
                            }
                        }
                    }
                    return .{ .raw = inst, .op = @intFromEnum(A64Op.branch_sys_other) };
                },
                0b0111, 0b1111 => {
                    const rd: u8 = @truncate(inst & 0x1f);
                    const rn: u8 = @truncate((inst >> 5) & 0x1f);
                    const rm: u8 = @truncate((inst >> 16) & 0x1f);

                    // 1. Scalar FP Data Processing (`(inst & 0x5f20_0000) == 0x1e20_0000`)
                    if ((inst & 0x5f20_0000) == 0x1e20_0000) {
                        const sf = ((inst >> 31) & 1) != 0;
                        const ftype: u2 = @truncate(inst >> 22);
                        if (ftype == 0 or ftype == 1) {
                            const is_dbl = (ftype == 1);
                            if ((inst & 0x0000_fc00) == 0x0000_0000 and ((inst >> 21) & 1) == 1) {
                                const rmode: u2 = @truncate(inst >> 19);
                                const opcode: u3 = @truncate(inst >> 16);
                                if (opcode == 0b110 and rmode == 0b00) {
                                    return .{ .raw = inst, .op = @intFromEnum(if (sf) A64Op.fmov_x_d else A64Op.fmov_w_s), .rd = rd, .rn = rn };
                                } else if (opcode == 0b111 and rmode == 0b00) {
                                    return .{ .raw = inst, .op = @intFromEnum(if (sf) A64Op.fmov_d_x else A64Op.fmov_s_w), .rd = rd, .rn = rn };
                                } else if (opcode == 0b110 and rmode == 0b01 and sf) {
                                    return .{ .raw = inst, .op = @intFromEnum(A64Op.fmov_x_d_hi), .rd = rd, .rn = rn };
                                } else if (opcode == 0b111 and rmode == 0b01 and sf) {
                                    return .{ .raw = inst, .op = @intFromEnum(A64Op.fmov_d_hi_x), .rd = rd, .rn = rn };
                                } else if ((opcode == 0b010 or opcode == 0b011) and rmode == 0b00) {
                                    return .{
                                        .raw = inst,
                                        .op = @intFromEnum(A64Op.fcvt_int),
                                        .rd = rd,
                                        .rn = rn,
                                        .imm = (@as(u64, opcode) << 2) | (@as(u64, @intFromBool(sf)) << 1) | @intFromBool(is_dbl),
                                    };
                                } else if ((opcode == 0b000 or opcode == 0b001) and rmode == 0b11) {
                                    return .{
                                        .raw = inst,
                                        .op = @intFromEnum(A64Op.fcvt_int),
                                        .rd = rd,
                                        .rn = rn,
                                        .imm = (@as(u64, opcode) << 2) | (@as(u64, @intFromBool(sf)) << 1) | @intFromBool(is_dbl),
                                    };
                                }
                            } else if ((inst & 0xffa0_1fe0) == 0x1e20_1000) {
                                const imm8: u8 = @truncate(inst >> 13);
                                const val64: u64 = if (is_dbl) expandFpImm64(imm8) else expandFpImm32(imm8);
                                return .{ .raw = inst, .op = @intFromEnum(A64Op.simd_movi), .rd = rd, .rn = 0, .imm = val64 };
                            } else if ((inst & 0xffe0_0c00) == 0x1e20_0800 or (inst & 0xffe0_0c00) == 0x1e60_0800) {
                                const opc: u4 = @truncate(inst >> 12);
                                const fp2_op: ?A64Op = switch (opc) {
                                    0 => if (is_dbl) .fmul_f64 else .fmul_f32,
                                    1 => if (is_dbl) .fdiv_f64 else .fdiv_f32,
                                    2 => if (is_dbl) .fadd_f64 else .fadd_f32,
                                    3 => if (is_dbl) .fsub_f64 else .fsub_f32,
                                    else => null,
                                };
                                if (fp2_op) |fop| {
                                    return .{ .raw = inst, .op = @intFromEnum(fop), .rd = rd, .rn = rn, .rm = rm };
                                }
                                if (opc >= 4 and opc <= 8) {
                                    const sub_op: u64 = switch (opc) {
                                        4, 6 => 1, // FMAX / FMAXNM
                                        5, 7 => 2, // FMIN / FMINNM
                                        else => 3, // FNMUL
                                    };
                                    return .{ .raw = inst, .op = @intFromEnum(A64Op.fop_misc), .rd = rd, .rn = rn, .rm = rm, .imm = (sub_op << 1) | @intFromBool(is_dbl) };
                                }
                            } else if ((inst & 0xffa0_7c00) == 0x1e20_4000) {
                                const opc: u6 = @truncate(inst >> 15);
                                if (opc == 3) {
                                    return .{ .raw = inst, .op = @intFromEnum(A64Op.fop_misc), .rd = rd, .rn = rn, .imm = @intFromBool(is_dbl) };
                                }
                                const fp1_op: ?A64Op = switch (opc) {
                                    0 => if (is_dbl) .fmov_f64 else .fmov_f32,
                                    1 => if (is_dbl) .fabs_f64 else .fabs_f32,
                                    2 => if (is_dbl) .fneg_f64 else .fneg_f32,
                                    4 => if (is_dbl) .fcvt_s_d else null,
                                    5 => if (!is_dbl) .fcvt_d_s else null,
                                    else => null,
                                };
                                if (fp1_op) |fop| {
                                    return .{ .raw = inst, .op = @intFromEnum(fop), .rd = rd, .rn = rn };
                                }
                            } else if ((inst & 0xffa0_fc07) == 0x1e20_2000) {
                                const cmp_zero = ((inst >> 3) & 1) != 0;
                                const fcmp_op: A64Op = if (is_dbl)
                                    (if (cmp_zero) .fcmpz_f64 else .fcmp_f64)
                                else
                                    (if (cmp_zero) .fcmpz_f32 else .fcmp_f32);
                                return .{ .raw = inst, .op = @intFromEnum(fcmp_op), .rn = rn, .rm = rm };
                            } else if ((inst & 0xffa0_0c00) == 0x1e20_0c00) {
                                const cond: u64 = (inst >> 12) & 0xf;
                                return .{ .raw = inst, .op = @intFromEnum(A64Op.fop_misc), .rd = rd, .rn = rn, .rm = rm, .imm = (@as(u64, 4) << 1) | @as(u64, @intFromBool(is_dbl)) | (cond << 4) };
                            }
                        }
                    } else if ((inst & 0x5f00_0000) == 0x1f00_0000) {
                        // 1b. Scalar FP 3-source (`FMADD`, `FMSUB`)
                        const ftype: u2 = @truncate(inst >> 22);
                        const o1 = ((inst >> 21) & 1) != 0;
                        const o0 = ((inst >> 15) & 1) != 0;
                        const ra: u8 = @truncate((inst >> 10) & 0x1f);
                        if (!o1 and (ftype == 0 or ftype == 1)) {
                            const fop: A64Op = if (ftype == 1)
                                (if (o0) .fmsub_f64 else .fmadd_f64)
                            else
                                (if (o0) .fmsub_f32 else .fmadd_f32);
                            return .{ .raw = inst, .op = @intFromEnum(fop), .rd = rd, .rn = rn, .rm = rm, .imm = ra };
                        }
                    } else if ((inst & 0x9ff8_0400) == 0x0f00_0400) {
                        // 2. AdvSIMD modified immediate (`MOVI`, `MVNI`, `FMOV`)
                        const q = ((inst >> 30) & 1) != 0;
                        const op_b = ((inst >> 29) & 1) != 0;
                        const cmode: u4 = @truncate(inst >> 12);
                        const abc: u8 = @truncate((inst >> 16) & 7);
                        const defgh: u8 = @truncate((inst >> 5) & 0x1f);
                        const imm8: u8 = (abc << 5) | defgh;
                        if (!(cmode < 0b1100 and (cmode & 1) != 0)) {
                            var val64: u64 = 0;
                            if (cmode == 0b1111) {
                                if (!op_b) {
                                    const f32_bits: u64 = expandFpImm32(imm8);
                                    val64 = f32_bits | (f32_bits << 32);
                                } else {
                                    val64 = expandFpImm64(imm8);
                                }
                            } else if (cmode == 0b1110 and !op_b) {
                                val64 = @as(u64, imm8) * 0x0101_0101_0101_0101;
                            } else if (cmode == 0b1110 and op_b) {
                                var i: u6 = 0;
                                while (i < 8) : (i += 1) {
                                    if (((imm8 >> @intCast(i)) & 1) != 0) {
                                        val64 |= @as(u64, 0xff) << (i * 8);
                                    }
                                }
                            } else if (cmode < 0b1100) {
                                const is_16 = (cmode & 0b1000) != 0;
                                const sh: u5 = if (is_16) @as(u5, (cmode >> 1) & 1) * 8 else @as(u5, (cmode >> 1) & 3) * 8;
                                const elem: u64 = (@as(u64, imm8) << sh);
                                if (is_16) {
                                    const rep16: u64 = (elem & 0xffff) * 0x0001_0001_0001_0001;
                                    val64 = if (op_b) ~rep16 else rep16;
                                } else {
                                    const rep32: u64 = (elem & 0xffff_ffff) * 0x0000_0001_0000_0001;
                                    val64 = if (op_b) ~rep32 else rep32;
                                }
                            } else if ((cmode & 0b1110) == 0b1100) {
                                const sh: u5 = if ((cmode & 1) != 0) 16 else 8;
                                const elem32: u64 = ((@as(u64, imm8) << sh) | ((@as(u64, 1) << sh) - 1)) & 0xffff_ffff;
                                const rep32: u64 = elem32 | (elem32 << 32);
                                val64 = if (op_b) ~rep32 else rep32;
                            }
                            return .{
                                .raw = inst,
                                .op = @intFromEnum(A64Op.simd_movi),
                                .rd = rd,
                                .rn = @intFromBool(q),
                                .imm = val64,
                            };
                        }
                    } else if ((inst & 0x9fe0_0400) == 0x0e00_0400) {
                        // 3. AdvSIMD copy (`DUP`, `UMOV`)
                        const q = ((inst >> 30) & 1) != 0;
                        const op_b = ((inst >> 29) & 1) != 0;
                        const imm5: u5 = @truncate(inst >> 16);
                        const imm4: u4 = @truncate(inst >> 11);
                        if (!op_b and imm5 != 0) {
                            const tz = @ctz(@as(u6, imm5));
                            const esize_bytes: u8 = if (tz >= 4) 8 else (@as(u8, 1) << @intCast(tz));
                            const dst_idx: u8 = imm5 >> @intCast(tz + 1);
                            const shift_bits: u8 = dst_idx * (esize_bytes * 8);
                            if (imm4 == 0b0000) {
                                return .{
                                    .raw = inst,
                                    .op = @intFromEnum(A64Op.simd_dup_elem),
                                    .rd = rd,
                                    .rn = rn,
                                    .rm = shift_bits,
                                    .imm = (@as(u64, esize_bytes) << 1) | @intFromBool(q),
                                };
                            } else if (imm4 == 0b0001) {
                                return .{
                                    .raw = inst,
                                    .op = @intFromEnum(A64Op.simd_dup_gpr),
                                    .rd = rd,
                                    .rn = rn,
                                    .rm = esize_bytes,
                                    .imm = @intFromBool(q),
                                };
                            } else if (imm4 == 0b0111 and (esize_bytes == 4 or esize_bytes == 8)) {
                                return .{
                                    .raw = inst,
                                    .op = @intFromEnum(if (esize_bytes == 8) A64Op.simd_umov64 else A64Op.simd_umov32),
                                    .rd = rd,
                                    .rn = rn,
                                    .rm = shift_bits,
                                };
                            }
                        }
                    } else if ((inst & 0x9f20_0400) == 0x0e20_0400) {
                        // 4. AdvSIMD three same (`AND`, `BIC`, `ORR`/`MOV`, `ORN`, `EOR`, `BSL`, `ADD`, `SUB`, `CMEQ`, `CMTST`)
                        const q = ((inst >> 30) & 1) != 0;
                        const u = ((inst >> 29) & 1) != 0;
                        const size: u2 = @truncate(inst >> 22);
                        const opcode: u5 = @truncate(inst >> 11);
                        const q_imm: u64 = @intFromBool(q);
                        if (opcode == 0b00011) {
                            const log_op: ?A64Op = if (!u) switch (size) {
                                0 => .simd_and,
                                1 => .simd_bic,
                                2 => .simd_orr,
                                3 => .simd_orn,
                            } else switch (size) {
                                0 => .simd_eor,
                                1 => .simd_bsl,
                                else => null,
                            };
                            if (log_op) |lop| {
                                return .{ .raw = inst, .op = @intFromEnum(lop), .rd = rd, .rn = rn, .rm = rm, .imm = q_imm };
                            }
                        } else if (opcode == 0b10000) {
                            const add_op: A64Op = switch (size) {
                                0 => if (u) .simd_sub_8 else .simd_add_8,
                                1 => if (u) .simd_sub_16 else .simd_add_16,
                                2 => if (u) .simd_sub_32 else .simd_add_32,
                                3 => if (u) .simd_sub_64 else .simd_add_64,
                            };
                            return .{ .raw = inst, .op = @intFromEnum(add_op), .rd = rd, .rn = rn, .rm = rm, .imm = q_imm };
                        } else if (opcode == 0b10001 and size == 0) {
                            return .{
                                .raw = inst,
                                .op = @intFromEnum(if (u) A64Op.simd_cmeq_8 else A64Op.simd_cmtst_8),
                                .rd = rd,
                                .rn = rn,
                                .rm = rm,
                                .imm = q_imm,
                            };
                        } else if ((opcode == 0b10010 or (opcode == 0b10011 and !u)) and size < 3) {
                            const kind: u64 = if (opcode == 0b10011) 0 else if (!u) 1 else 2; // 0=MUL, 1=MLA, 2=MLS
                            return .{
                                .raw = inst,
                                .op = @intFromEnum(A64Op.simd_mul_mla),
                                .rd = rd,
                                .rn = rn,
                                .rm = rm,
                                .imm = (@as(u64, size) << 3) | (kind << 1) | q_imm,
                            };
                        }
                    } else if ((inst & 0x9f3e_0c00) == 0x0e20_0800) {
                        // 5. AdvSIMD two-register misc (`NOT`/`MVN`, `CMEQ v.16b, #0`, `XTN`, `SHLL`)
                        const q = ((inst >> 30) & 1) != 0;
                        const u = ((inst >> 29) & 1) != 0;
                        const size: u2 = @truncate(inst >> 22);
                        const opcode: u5 = @truncate(inst >> 12);
                        const q_imm: u64 = @intFromBool(q);
                        if (opcode == 0b00101 and u and size == 0) {
                            return .{ .raw = inst, .op = @intFromEnum(A64Op.simd_not), .rd = rd, .rn = rn, .imm = q_imm };
                        } else if (opcode == 0b01001 and !u and size == 0) {
                            return .{ .raw = inst, .op = @intFromEnum(A64Op.simd_cmeqz_8), .rd = rd, .rn = rn, .imm = q_imm };
                        } else if (opcode == 0b10010 and !u and size < 3) {
                            return .{ .raw = inst, .op = @intFromEnum(A64Op.simd_xtn_shrn), .rd = rd, .rn = rn, .rm = size, .imm = q_imm };
                        } else if (opcode == 0b10011 and u and size < 3) {
                            const src_bits: u8 = @as(u8, 8) << size;
                            return .{ .raw = inst, .op = @intFromEnum(A64Op.simd_shll), .rd = rd, .rn = rn, .rm = src_bits, .imm = (@as(u64, size) << 2) | 2 | q_imm };
                        }
                    } else if ((inst & 0xbf20_8400) == 0x2e00_0000) {
                        // 6. AdvSIMD EXT (`EXT Vd.<T>, Vn.<T>, Vm.<T>, #imm4`)
                        const q = ((inst >> 30) & 1) != 0;
                        const imm4: u8 = @truncate((inst >> 11) & 0xf);
                        if (q or imm4 < 8) {
                            return .{
                                .raw = inst,
                                .op = @intFromEnum(if (q) A64Op.simd_ext_q else A64Op.simd_ext_d),
                                .rd = rd,
                                .rn = rn,
                                .rm = rm,
                                .imm = @as(u64, imm4) * 8,
                            };
                        }
                    } else if ((inst & 0x9f80_0400) == 0x0f00_0400 and ((inst >> 19) & 0xf) != 0) {
                        // 7. AdvSIMD vector shift by immediate (`USHR`, `SHL`, `SHRN`/`RSHRN`, `SSHLL`/`USHLL`)
                        const q = ((inst >> 30) & 1) != 0;
                        const u = ((inst >> 29) & 1) != 0;
                        const immh: u4 = @truncate(inst >> 19);
                        const immb: u3 = @truncate(inst >> 16);
                        const immhb: u7 = (@as(u7, immh) << 3) | immb;
                        const opcode: u5 = @truncate(inst >> 11);
                        const esize: u7 = if ((immh & 8) != 0) 64 else if ((immh & 4) != 0) 32 else if ((immh & 2) != 0) 16 else 8;
                        if (opcode == 0b00000 and u) {
                            // USHR
                            const rshift: u7 = (esize * 2) - immhb;
                            const sh_u8: u8 = if (rshift >= esize) 0 else @intCast(rshift);
                            const elem_mask: u64 = if (rshift >= esize) 0 else ((@as(u64, 1) << @intCast(esize - rshift)) - 1);
                            const rep_mask64: u64 = switch (esize) {
                                8 => elem_mask * 0x0101_0101_0101_0101,
                                16 => elem_mask * 0x0001_0001_0001_0001,
                                32 => elem_mask * 0x0000_0001_0000_0001,
                                else => elem_mask,
                            };
                            return .{
                                .raw = inst,
                                .op = @intFromEnum(A64Op.simd_ushr),
                                .rd = rd,
                                .rn = rn,
                                .rm = (@as(u8, @intFromBool(q)) << 6) | sh_u8,
                                .imm = rep_mask64,
                            };
                        } else if (opcode == 0b01010 and !u) {
                            // SHL
                            const lshift: u6 = @intCast(immhb - esize);
                            const elem_mask: u64 = ((@as(u64, 1) << @intCast(esize - lshift)) - 1) << lshift;
                            const rep_mask64: u64 = switch (esize) {
                                8 => elem_mask * 0x0101_0101_0101_0101,
                                16 => elem_mask * 0x0001_0001_0001_0001,
                                32 => elem_mask * 0x0000_0001_0000_0001,
                                else => elem_mask,
                            };
                            return .{
                                .raw = inst,
                                .op = @intFromEnum(A64Op.simd_shl),
                                .rd = rd,
                                .rn = rn,
                                .rm = (@as(u8, @intFromBool(q)) << 6) | @as(u8, lshift),
                                .imm = rep_mask64,
                            };
                        } else if ((opcode == 0b10000 or opcode == 0b10001) and !u and esize < 64) {
                            // SHRN / SHRN2 / RSHRN / RSHRN2
                            const size_idx: u8 = if (esize == 8) 0 else if (esize == 16) 1 else 2;
                            const rshift: u6 = @intCast((esize * 2) - immhb);
                            const round: u64 = if ((opcode & 1) != 0 and rshift > 0) (@as(u64, 1) << (rshift - 1)) else 0;
                            return .{
                                .raw = inst,
                                .op = @intFromEnum(A64Op.simd_xtn_shrn),
                                .rd = rd,
                                .rn = rn,
                                .rm = size_idx | (@as(u8, rshift) << 2),
                                .imm = (round << 1) | @intFromBool(q),
                            };
                        } else if (opcode == 0b10100 and esize < 64) {
                            // SSHLL / USHLL
                            const size_idx: u64 = if (esize == 8) 0 else if (esize == 16) 1 else 2;
                            const lshift: u8 = @intCast(immhb - esize);
                            return .{
                                .raw = inst,
                                .op = @intFromEnum(A64Op.simd_shll),
                                .rd = rd,
                                .rn = rn,
                                .rm = lshift,
                                .imm = (size_idx << 2) | (@as(u64, @intFromBool(u)) << 1) | @intFromBool(q),
                            };
                        }
                    }
                    return .{ .raw = inst, .op = @intFromEnum(A64Op.fp_simd) };
                },
                else => return .{ .raw = inst, .op = @intFromEnum(A64Op.nop) },
            }
        }

        pub fn step64(cpu: *CpuType, bus: *Bus) void {
            _ = runSteps64(cpu, bus, 1);
        }

        pub fn runSteps64(cpu: *CpuType, bus: *Bus, max_steps: usize) usize {
            @setEvalBranchQuota(10000);
            _ = checkInterrupts64(cpu, bus);
            if (cpu.mmu.halted_wfi) return 0;

            cpu.yield_slice = false;
            cpu.last_dmb_pc = 0xffff_ffff;
            defer cpu.excl_valid = false;

            const limit = if (max_steps >= 4096) max_steps + 256 else max_steps;
            const SlotType = @TypeOf(cpu.icache[0]);
            var executed: usize = 0;
            var priv: u1 = @intFromBool(currentEl(cpu) != 0);
            var code_vbase: u64 = 0xffff_ffff_ffff_ffff;
            var code_pbase: u32 = 0;
            var code_page_idx: usize = 0;
            var code_page_ptr: [*]const u8 = bus.ram.ptr;
            var code_icache_ptr: [*]SlotType = cpu.icache[0..].ptr;
            var data_r_vbase: [2]u64 = @splat(0xffff_ffff_ffff_ffff);
            var data_w_vbase: [2]u64 = @splat(0xffff_ffff_ffff_ffff);
            var data_r_page_ptr: [2][*]const u8 = @splat(bus.ram.ptr);
            var data_w_page_ptr: [2][*]u8 = @splat(bus.ram.ptr);

            step_loop: while (true) {
                if (executed >= max_steps) {
                    if (executed >= limit or (cpu.pstate & PstateFlags.I) == 0) break;
                }
                if (atomic_ram.busParallel(bus)) {
                    // Apply TLB invalidations other cores broadcast while this slice runs
                    if (bus.smp.serviceTlb(cpu.mmu.core_id, &cpu.mmu)) {
                        code_vbase = 0xffff_ffff_ffff_ffff;
                        data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                        data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                    }
                }
                const batch_end = if (executed >= max_steps)
                    (executed + 1)
                else if (atomic_ram.busParallel(bus))
                    @min(max_steps, executed + 256)
                else
                    max_steps;

                while (executed < batch_end) {
                    const cur_pc = cpu.pc64;
                    if ((cur_pc & ~@as(u64, 0xfff)) != code_vbase) {
                        const islot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((cur_pc >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                        if ((cur_pc & ~@as(u64, 0xfff)) == islot.x_vbase) {
                            code_vbase = islot.x_vbase;
                            code_pbase = islot.pbase;
                            code_page_ptr = bus.ram.ptr + code_pbase;
                            code_page_idx = CpuType.icachePageIdx(code_pbase);
                            code_icache_ptr = cpu.prepareIcachePage(code_page_idx, code_pbase);
                            continue;
                        }
                        const fetched = fetchInst64(cpu, bus, cur_pc) catch {
                            const target_el: u2 = @max(currentEl(cpu), 1);
                            const esr = if (target_el >= 2) cpu.mmu.esr_el2 else cpu.mmu.esr_el1;
                            takeException64(cpu, target_el, 0x000, esr, cur_pc, cur_pc);
                            priv = 1;
                            code_vbase = 0xffff_ffff_ffff_ffff;
                            data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                            data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                            executed += 1;
                            continue;
                        };
                        const islot2 = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((cur_pc >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                        if ((cur_pc & ~@as(u64, 0xfff)) == islot2.x_vbase) {
                            code_vbase = islot2.x_vbase;
                            code_pbase = islot2.pbase;
                            code_page_ptr = bus.ram.ptr + code_pbase;
                            code_page_idx = CpuType.icachePageIdx(code_pbase);
                            code_icache_ptr = cpu.prepareIcachePage(code_page_idx, code_pbase);
                            continue;
                        }
                        const pword: usize = @truncate((cur_pc >> 2) & 0x3ff);
                        code_page_idx = CpuType.icachePageIdx(@truncate(cur_pc));
                        code_icache_ptr = cpu.prepareIcachePage(code_page_idx, 0xffff_fffe);
                        cpu.icache_page_tags[code_page_idx] = 0xffff_ffff;
                        _ = decodeAndFuseA64(cpu, SlotType, code_page_idx, code_icache_ptr, code_page_ptr, pword, fetched, false);
                    }

                    const page_word: usize = @truncate((cur_pc >> 2) & 0x3ff);
                    const d = code_icache_ptr[page_word];
                    if (d.raw == 0xffff_ffff) {
                        populateIcacheSlot64(cpu, SlotType, code_page_idx, code_icache_ptr, code_page_ptr, page_word);
                        continue;
                    }

                    const inst = d.raw;
                    cpu.pc64 = cur_pc +% 4;
                    executed += 1;

                const op: A64Op = @enumFromInt(d.op);
                switch (op) {
                    .adr => setX(cpu, @truncate(d.rd), cur_pc +% d.imm),
                    .adrp => setX(cpu, @truncate(d.rd), (cur_pc & ~@as(u64, 0xfff)) +% d.imm),
                    .adrp_add => {
                        if (executed < batch_end and (cur_pc & ~@as(u64, 0xfff)) == code_vbase) {
                            setX(cpu, @truncate(d.rd), (cur_pc & ~@as(u64, 0xfff)) +% d.imm);
                            cpu.pc64 = cur_pc +% 8;
                            executed += 1;
                        } else {
                            setX(cpu, @truncate(d.rd), (cur_pc & ~@as(u64, 0xfff)) +% (d.imm & ~@as(u64, 0xfff)));
                        }
                    },
                    .adrp_ldr64, .adrp_ldr32 => {
                        const base = (cur_pc & ~@as(u64, 0xfff)) +% (d.imm & ~@as(u64, 0xfff));
                        setX(cpu, @truncate(d.rn), base);
                        if (executed < batch_end and (cur_pc & ~@as(u64, 0xfff)) == code_vbase) {
                            cpu.pc64 = cur_pc +% 8;
                            executed += 1;
                            if (op == .adrp_ldr64) {
                                const addr = base +% ((d.imm & 0xfff) << 3);
                                if ((addr & ~@as(u64, 0xff8)) == data_r_vbase[0]) {
                                    setX(cpu, @truncate(d.rd), std.mem.readInt(u64, data_r_page_ptr[0][@as(usize, @truncate(addr & 0xff8))..][0..8], .little));
                                } else {
                                    const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                                    if ((addr & 0xfff) <= 0xff8 and (addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                        data_r_vbase[0] = dslot.r_vbase;
                                        data_r_page_ptr[0] = bus.ram.ptr + dslot.pbase;
                                        setX(cpu, @truncate(d.rd), std.mem.readInt(u64, data_r_page_ptr[0][@as(usize, @truncate(addr & 0xfff))..][0..8], .little));
                                    } else {
                                        const val = readData64(cpu, bus, addr) catch {
                                            handleAbort64(cpu, cur_pc +% 4);
                                            priv = 1;
                                            code_vbase = 0xffff_ffff_ffff_ffff;
                                            data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                            data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                            continue;
                                        };
                                        setX(cpu, @truncate(d.rd), val);
                                    }
                                }
                            } else {
                                const addr = base +% ((d.imm & 0xfff) << 2);
                                if ((addr & ~@as(u64, 0xffc)) == data_r_vbase[0]) {
                                    setW(cpu, @truncate(d.rd), std.mem.readInt(u32, data_r_page_ptr[0][@as(usize, @truncate(addr & 0xffc))..][0..4], .little));
                                } else {
                                    const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                                    if ((addr & 0xfff) <= 0xffc and (addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                        data_r_vbase[0] = dslot.r_vbase;
                                        data_r_page_ptr[0] = bus.ram.ptr + dslot.pbase;
                                        setW(cpu, @truncate(d.rd), std.mem.readInt(u32, data_r_page_ptr[0][@as(usize, @truncate(addr & 0xfff))..][0..4], .little));
                                    } else {
                                        const val = readData32(cpu, bus, addr) catch {
                                            handleAbort64(cpu, cur_pc +% 4);
                                            priv = 1;
                                            code_vbase = 0xffff_ffff_ffff_ffff;
                                            data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                            data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                            continue;
                                        };
                                        setW(cpu, @truncate(d.rd), val);
                                    }
                                }
                            }
                        }
                    },
                    .cmp_imm_bcond => {
                        const cmp_imm: u64 = @as(u32, @truncate(d.imm));
                        const sf: u1 = @truncate((d.rm >> 5) & 1);
                        const is_sub = (d.rm & 0x40) != 0;
                        const dst_rd: u5 = @truncate(d.rm & 0x1f);
                        addSub(cpu, sf, is_sub, true, dst_rd, getXOrSp(cpu, @truncate(d.rn)), cmp_imm, if (is_sub) 1 else 0, false);
                        if (executed < batch_end and (cur_pc & ~@as(u64, 0xfff)) == code_vbase) {
                            executed += 1;
                            if (evalCond(cpu.pstate, @truncate(d.rd))) {
                                const target_off: i64 = @as(i32, @bitCast(@as(u32, @truncate(d.imm >> 32))));
                                const target_pc = cur_pc +% @as(u64, @bitCast(target_off));
                                cpu.pc64 = target_pc;
                                noteBackwardBranch64(cpu, SlotType, code_vbase, code_page_idx, code_icache_ptr, code_page_ptr, cur_pc, target_pc, @intCast(page_word + 2));
                            } else {
                                cpu.pc64 = cur_pc +% 8;
                            }
                        }
                    },
                    .cmp_reg_bcond => {
                        const sf: u1 = @truncate(d.rd >> 4);
                        const dst_rd: u5 = @truncate(d.imm >> 32);
                        addSub(cpu, sf, true, true, dst_rd, getX(cpu, @truncate(d.rn)), getX(cpu, @truncate(d.rm)), 1, false);
                        if (executed < batch_end and (cur_pc & ~@as(u64, 0xfff)) == code_vbase) {
                            executed += 1;
                            if (evalCond(cpu.pstate, @truncate(d.rd))) {
                                const target_off: i64 = @as(i32, @bitCast(@as(u32, @truncate(d.imm))));
                                const target_pc = cur_pc +% @as(u64, @bitCast(target_off));
                                cpu.pc64 = target_pc;
                                noteBackwardBranch64(cpu, SlotType, code_vbase, code_page_idx, code_icache_ptr, code_page_ptr, cur_pc, target_pc, @intCast(page_word + 2));
                            } else {
                                cpu.pc64 = cur_pc +% 8;
                            }
                        }
                    },
                    .tst_imm_bcond => {
                        const mask: u64 = @as(u32, @truncate(d.imm));
                        const res = getX(cpu, @truncate(d.rn)) & mask;
                        const sign = if ((d.rd & 0x10) != 0) false else ((res >> 31) != 0);
                        setNzcv(cpu, sign, res == 0, false, false);
                        if (executed < batch_end and (cur_pc & ~@as(u64, 0xfff)) == code_vbase) {
                            executed += 1;
                            if (evalCond(cpu.pstate, @truncate(d.rd))) {
                                const target_off: i64 = @as(i32, @bitCast(@as(u32, @truncate(d.imm >> 32))));
                                const target_pc = cur_pc +% @as(u64, @bitCast(target_off));
                                cpu.pc64 = target_pc;
                                noteBackwardBranch64(cpu, SlotType, code_vbase, code_page_idx, code_icache_ptr, code_page_ptr, cur_pc, target_pc, @intCast(page_word + 2));
                            } else {
                                cpu.pc64 = cur_pc +% 8;
                            }
                        }
                    },
                    .tst_reg_bcond => {
                        const dst_rd: u5 = @truncate(d.imm >> 32);
                        if ((d.rd & 0x10) != 0) {
                            const res = getX(cpu, @truncate(d.rn)) & getX(cpu, @truncate(d.rm));
                            setNzcv(cpu, (res >> 63) != 0, res == 0, false, false);
                            setX(cpu, dst_rd, res);
                        } else {
                            const res = getW(cpu, @truncate(d.rn)) & getW(cpu, @truncate(d.rm));
                            setNzcv(cpu, (res >> 31) != 0, res == 0, false, false);
                            setW(cpu, dst_rd, res);
                        }
                        if (executed < batch_end and (cur_pc & ~@as(u64, 0xfff)) == code_vbase) {
                            executed += 1;
                            if (evalCond(cpu.pstate, @truncate(d.rd))) {
                                const target_off: i64 = @as(i32, @bitCast(@as(u32, @truncate(d.imm))));
                                const target_pc = cur_pc +% @as(u64, @bitCast(target_off));
                                cpu.pc64 = target_pc;
                                noteBackwardBranch64(cpu, SlotType, code_vbase, code_page_idx, code_icache_ptr, code_page_ptr, cur_pc, target_pc, @intCast(page_word + 2));
                            } else {
                                cpu.pc64 = cur_pc +% 8;
                            }
                        }
                    },
                    .ldr_cbz => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const addr = getXOrSp(cpu, rn) +% @as(u32, @truncate(d.imm));
                        var val: u64 = undefined;
                        if ((d.rm & 4) == 0) {
                            if ((addr & ~@as(u64, 0xff8)) == data_r_vbase[bank]) {
                                val = std.mem.readInt(u64, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xff8))..][0..8], .little);
                            } else {
                                const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                                if ((addr & 0xfff) <= 0xff8 and (addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                    data_r_vbase[bank] = dslot.r_vbase;
                                    data_r_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                    val = std.mem.readInt(u64, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..8], .little);
                                } else {
                                    val = readData64(cpu, bus, addr) catch {
                                        handleAbort64(cpu, cur_pc);
                                        priv = 1;
                                        code_vbase = 0xffff_ffff_ffff_ffff;
                                        data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        continue;
                                    };
                                }
                            }
                            setX(cpu, @truncate(d.rd), val);
                        } else {
                            var val32: u32 = undefined;
                            if ((addr & ~@as(u64, 0xffc)) == data_r_vbase[bank]) {
                                val32 = std.mem.readInt(u32, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xffc))..][0..4], .little);
                            } else {
                                const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                                if ((addr & 0xfff) <= 0xffc and (addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                    data_r_vbase[bank] = dslot.r_vbase;
                                    data_r_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                    val32 = std.mem.readInt(u32, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..4], .little);
                                } else {
                                    val32 = readData32(cpu, bus, addr) catch {
                                        handleAbort64(cpu, cur_pc);
                                        priv = 1;
                                        code_vbase = 0xffff_ffff_ffff_ffff;
                                        data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        continue;
                                    };
                                }
                            }
                            setW(cpu, @truncate(d.rd), val32);
                            val = val32;
                        }
                        if (executed < batch_end and (cur_pc & ~@as(u64, 0xfff)) == code_vbase) {
                            executed += 1;
                            const test_val: u64 = if ((d.rm & 2) != 0) @as(u32, @truncate(val)) else val;
                            const take = if ((d.rm & 1) != 0) (test_val != 0) else (test_val == 0);
                            if (take) {
                                const target_off: i64 = @as(i32, @bitCast(@as(u32, @truncate(d.imm >> 32))));
                                const target_pc = cur_pc +% @as(u64, @bitCast(target_off));
                                cpu.pc64 = target_pc;
                                noteBackwardBranch64(cpu, SlotType, code_vbase, code_page_idx, code_icache_ptr, code_page_ptr, cur_pc, target_pc, @intCast(page_word + 2));
                            } else {
                                cpu.pc64 = cur_pc +% 8;
                            }
                        }
                    },
                    .ldr64_pair_uimm => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const base = getXOrSp(cpu, rn);
                        const addr1 = base +% @as(u32, @truncate(d.imm));
                        const addr2 = base +% (d.imm >> 32);
                        if (executed < batch_end and (cur_pc & ~@as(u64, 0xfff)) == code_vbase and
                            (addr1 & ~@as(u64, 0xff8)) == data_r_vbase[bank] and
                            (addr2 & ~@as(u64, 0xff8)) == data_r_vbase[bank])
                        {
                            setX(cpu, @truncate(d.rd), std.mem.readInt(u64, data_r_page_ptr[bank][@as(usize, @truncate(addr1 & 0xff8))..][0..8], .little));
                            setX(cpu, @truncate(d.rm), std.mem.readInt(u64, data_r_page_ptr[bank][@as(usize, @truncate(addr2 & 0xff8))..][0..8], .little));
                            cpu.pc64 = cur_pc +% 8;
                            executed += 1;
                        } else {
                            if ((addr1 & ~@as(u64, 0xff8)) == data_r_vbase[bank]) {
                                setX(cpu, @truncate(d.rd), std.mem.readInt(u64, data_r_page_ptr[bank][@as(usize, @truncate(addr1 & 0xff8))..][0..8], .little));
                            } else {
                                const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr1 >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                                if ((addr1 & 0xfff) <= 0xff8 and (addr1 & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                    data_r_vbase[bank] = dslot.r_vbase;
                                    data_r_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                    setX(cpu, @truncate(d.rd), std.mem.readInt(u64, data_r_page_ptr[bank][@as(usize, @truncate(addr1 & 0xfff))..][0..8], .little));
                                } else {
                                    const val = readData64(cpu, bus, addr1) catch {
                                        handleAbort64(cpu, cur_pc);
                                        priv = 1;
                                        code_vbase = 0xffff_ffff_ffff_ffff;
                                        data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        continue;
                                    };
                                    setX(cpu, @truncate(d.rd), val);
                                }
                            }
                        }
                    },
                    .add_imm64 => setXOrSp(cpu, @truncate(d.rd), getXOrSp(cpu, @truncate(d.rn)) +% d.imm),
                    .sub_imm64 => setXOrSp(cpu, @truncate(d.rd), getXOrSp(cpu, @truncate(d.rn)) -% d.imm),
                    .adds_imm64 => addSub(cpu, 1, false, true, @truncate(d.rd), getXOrSp(cpu, @truncate(d.rn)), d.imm, 0, false),
                    .subs_imm64 => addSub(cpu, 1, true, true, @truncate(d.rd), getXOrSp(cpu, @truncate(d.rn)), d.imm, 1, false),
                    .add_imm32 => setWOrSp(cpu, @truncate(d.rd), @as(u32, @truncate(getXOrSp(cpu, @truncate(d.rn)))) +% @as(u32, @truncate(d.imm))),
                    .sub_imm32 => setWOrSp(cpu, @truncate(d.rd), @as(u32, @truncate(getXOrSp(cpu, @truncate(d.rn)))) -% @as(u32, @truncate(d.imm))),
                    .adds_imm32 => addSub(cpu, 0, false, true, @truncate(d.rd), getXOrSp(cpu, @truncate(d.rn)), d.imm, 0, false),
                    .subs_imm32 => addSub(cpu, 0, true, true, @truncate(d.rd), getXOrSp(cpu, @truncate(d.rn)), d.imm, 1, false),
                    .and_imm64 => setXOrSp(cpu, @truncate(d.rd), getX(cpu, @truncate(d.rn)) & d.imm),
                    .orr_imm64 => setXOrSp(cpu, @truncate(d.rd), getX(cpu, @truncate(d.rn)) | d.imm),
                    .eor_imm64 => setXOrSp(cpu, @truncate(d.rd), getX(cpu, @truncate(d.rn)) ^ d.imm),
                    .ands_imm64 => {
                        const res = getX(cpu, @truncate(d.rn)) & d.imm;
                        setNzcv(cpu, (res >> 63) != 0, res == 0, false, false);
                        setX(cpu, @truncate(d.rd), res);
                    },
                    .and_imm32 => setWOrSp(cpu, @truncate(d.rd), getW(cpu, @truncate(d.rn)) & @as(u32, @truncate(d.imm))),
                    .orr_imm32 => setWOrSp(cpu, @truncate(d.rd), getW(cpu, @truncate(d.rn)) | @as(u32, @truncate(d.imm))),
                    .eor_imm32 => setWOrSp(cpu, @truncate(d.rd), getW(cpu, @truncate(d.rn)) ^ @as(u32, @truncate(d.imm))),
                    .ands_imm32 => {
                        const res = getW(cpu, @truncate(d.rn)) & @as(u32, @truncate(d.imm));
                        setNzcv(cpu, (res >> 31) != 0, res == 0, false, false);
                        setW(cpu, @truncate(d.rd), res);
                    },
                    .mov_wide => setX(cpu, @truncate(d.rd), d.imm),
                    .movk64 => {
                        const rd: u5 = @truncate(d.rd);
                        const sh: u6 = @truncate(d.rm);
                        setX(cpu, rd, (getX(cpu, rd) & ~(@as(u64, 0xffff) << sh)) | d.imm);
                    },
                    .movk32 => {
                        const rd: u5 = @truncate(d.rd);
                        const sh: u6 = @truncate(d.rm);
                        setX(cpu, rd, ((getX(cpu, rd) & ~(@as(u64, 0xffff) << sh)) | d.imm) & 0xffff_ffff);
                    },
                    .ubfm_r => setX(cpu, @truncate(d.rd), (getX(cpu, @truncate(d.rn)) >> @intCast(d.rm)) & d.imm),
                    .ubfm_l => setX(cpu, @truncate(d.rd), (getX(cpu, @truncate(d.rn)) << @intCast(d.rm)) & d.imm),
                    .bfm_r => {
                        const rmask: u64 = if ((d.rm & 64) != 0) 0xffff_ffff_ffff_ffff else 0xffff_ffff;
                        const dst = getX(cpu, @truncate(d.rd)) & ~d.imm;
                        const ext = (getX(cpu, @truncate(d.rn)) >> @intCast(d.rm & 63)) & d.imm;
                        setX(cpu, @truncate(d.rd), (dst | ext) & rmask);
                    },
                    .bfm_l => {
                        const rmask: u64 = if ((d.rm & 64) != 0) 0xffff_ffff_ffff_ffff else 0xffff_ffff;
                        const dst = getX(cpu, @truncate(d.rd)) & ~d.imm;
                        const ins = (getX(cpu, @truncate(d.rn)) << @intCast(d.rm & 63)) & d.imm;
                        setX(cpu, @truncate(d.rd), (dst | ins) & rmask);
                    },
                    .sbfm64_r => {
                        const sval: i64 = @bitCast(getX(cpu, @truncate(d.rn)));
                        setX(cpu, @truncate(d.rd), @bitCast((sval << @as(u6, @truncate(d.rm))) >> @as(u6, @truncate(d.imm))));
                    },
                    .sbfm32_r => {
                        const sval: i32 = @bitCast(getW(cpu, @truncate(d.rn)));
                        setW(cpu, @truncate(d.rd), @bitCast((sval << @as(u5, @truncate(d.rm))) >> @as(u5, @truncate(d.imm))));
                    },
                    .extr64 => {
                        const a: u128 = getX(cpu, @truncate(d.rn));
                        const b: u128 = getX(cpu, @truncate(d.rm));
                        setX(cpu, @truncate(d.rd), @truncate(((a << 64) | b) >> @as(u6, @truncate(d.imm))));
                    },
                    .extr32 => {
                        const a: u64 = getW(cpu, @truncate(d.rn));
                        const b: u64 = getW(cpu, @truncate(d.rm));
                        setW(cpu, @truncate(d.rd), @truncate(((a << 32) | b) >> @as(u5, @truncate(d.imm))));
                    },
                    .orr_reg64 => setX(cpu, @truncate(d.rd), getX(cpu, @truncate(d.rn)) | getX(cpu, @truncate(d.rm))),
                    .orr_reg32 => setW(cpu, @truncate(d.rd), getW(cpu, @truncate(d.rn)) | getW(cpu, @truncate(d.rm))),
                    .orn_reg64 => setX(cpu, @truncate(d.rd), getX(cpu, @truncate(d.rn)) | ~getX(cpu, @truncate(d.rm))),
                    .orn_reg32 => setW(cpu, @truncate(d.rd), getW(cpu, @truncate(d.rn)) | ~getW(cpu, @truncate(d.rm))),
                    .add_reg64 => setX(cpu, @truncate(d.rd), getX(cpu, @truncate(d.rn)) +% getX(cpu, @truncate(d.rm))),
                    .add_reg32 => setW(cpu, @truncate(d.rd), getW(cpu, @truncate(d.rn)) +% getW(cpu, @truncate(d.rm))),
                    .adds_reg64 => addSub(cpu, 1, false, true, @truncate(d.rd), getX(cpu, @truncate(d.rn)), getX(cpu, @truncate(d.rm)), 0, false),
                    .adds_reg32 => addSub(cpu, 0, false, true, @truncate(d.rd), getX(cpu, @truncate(d.rn)), getX(cpu, @truncate(d.rm)), 0, false),
                    .sub_reg64 => setX(cpu, @truncate(d.rd), getX(cpu, @truncate(d.rn)) -% getX(cpu, @truncate(d.rm))),
                    .sub_reg32 => setW(cpu, @truncate(d.rd), getW(cpu, @truncate(d.rn)) -% getW(cpu, @truncate(d.rm))),
                    .subs_reg64 => addSub(cpu, 1, true, true, @truncate(d.rd), getX(cpu, @truncate(d.rn)), getX(cpu, @truncate(d.rm)), 1, false),
                    .subs_reg32 => addSub(cpu, 0, true, true, @truncate(d.rd), getX(cpu, @truncate(d.rn)), getX(cpu, @truncate(d.rm)), 1, false),
                    .and_reg64 => setX(cpu, @truncate(d.rd), getX(cpu, @truncate(d.rn)) & getX(cpu, @truncate(d.rm))),
                    .and_reg32 => setW(cpu, @truncate(d.rd), getW(cpu, @truncate(d.rn)) & getW(cpu, @truncate(d.rm))),
                    .bic_reg64 => setX(cpu, @truncate(d.rd), getX(cpu, @truncate(d.rn)) & ~getX(cpu, @truncate(d.rm))),
                    .bic_reg32 => setW(cpu, @truncate(d.rd), getW(cpu, @truncate(d.rn)) & ~getW(cpu, @truncate(d.rm))),
                    .eor_reg64 => setX(cpu, @truncate(d.rd), getX(cpu, @truncate(d.rn)) ^ getX(cpu, @truncate(d.rm))),
                    .eor_reg32 => setW(cpu, @truncate(d.rd), getW(cpu, @truncate(d.rn)) ^ getW(cpu, @truncate(d.rm))),
                    .ands_reg64 => {
                        const res = getX(cpu, @truncate(d.rn)) & getX(cpu, @truncate(d.rm));
                        setNzcv(cpu, (res >> 63) != 0, res == 0, false, false);
                        setX(cpu, @truncate(d.rd), res);
                    },
                    .ands_reg32 => {
                        const res = getW(cpu, @truncate(d.rn)) & getW(cpu, @truncate(d.rm));
                        setNzcv(cpu, (res >> 31) != 0, res == 0, false, false);
                        setW(cpu, @truncate(d.rd), res);
                    },
                    .add_lsl64 => setX(cpu, @truncate(d.rd), getX(cpu, @truncate(d.rn)) +% (getX(cpu, @truncate(d.rm)) << @as(u6, @truncate(d.imm)))),
                    .add_lsl32 => setW(cpu, @truncate(d.rd), getW(cpu, @truncate(d.rn)) +% (getW(cpu, @truncate(d.rm)) << @as(u5, @truncate(d.imm)))),
                    .sub_lsl64 => setX(cpu, @truncate(d.rd), getX(cpu, @truncate(d.rn)) -% (getX(cpu, @truncate(d.rm)) << @as(u6, @truncate(d.imm)))),
                    .sub_lsl32 => setW(cpu, @truncate(d.rd), getW(cpu, @truncate(d.rn)) -% (getW(cpu, @truncate(d.rm)) << @as(u5, @truncate(d.imm)))),
                    .orr_lsl64 => setX(cpu, @truncate(d.rd), getX(cpu, @truncate(d.rn)) | (getX(cpu, @truncate(d.rm)) << @as(u6, @truncate(d.imm)))),
                    .orr_lsr64 => setX(cpu, @truncate(d.rd), getX(cpu, @truncate(d.rn)) | (getX(cpu, @truncate(d.rm)) >> @as(u6, @truncate(d.imm)))),
                    .add_ext64 => setXOrSp(cpu, @truncate(d.rd), getXOrSp(cpu, @truncate(d.rn)) +% extendReg(getX(cpu, @truncate(d.rm)), @truncate(d.imm >> 3), @truncate(d.imm))),
                    .sub_ext64 => setXOrSp(cpu, @truncate(d.rd), getXOrSp(cpu, @truncate(d.rn)) -% extendReg(getX(cpu, @truncate(d.rm)), @truncate(d.imm >> 3), @truncate(d.imm))),
                    .add_sub_ext => {
                        const imm3: u3 = @truncate(d.imm);
                        const option: u3 = @truncate(d.imm >> 3);
                        const s = ((d.imm >> 6) & 1) != 0;
                        const op0 = ((d.imm >> 7) & 1) != 0;
                        const sf: u1 = @truncate(d.imm >> 8);
                        const a = getXOrSp(cpu, @truncate(d.rn));
                        const b = extendReg(getX(cpu, @truncate(d.rm)), option, imm3);
                        addSub(cpu, sf, op0, s, @truncate(d.rd), a, b, if (op0) 1 else 0, !s);
                    },
                    .dp_shift_reg => {
                        const imm6: u6 = @truncate(d.imm);
                        const shift_type: u2 = @truncate(d.imm >> 6);
                        const op2: u4 = @truncate(d.imm >> 8);
                        const s: u1 = @truncate(d.imm >> 12);
                        const op0: u1 = @truncate(d.imm >> 13);
                        const sf: u1 = @truncate(d.imm >> 14);
                        const a = getX(cpu, @truncate(d.rn));
                        var b = shiftReg(sf, getX(cpu, @truncate(d.rm)), shift_type, imm6);
                        if ((op2 & 0b1000) == 0) {
                            if ((op2 & 1) != 0) b = ~b;
                            const opc: u2 = (@as(u2, op0) << 1) | s;
                            var res: u64 = switch (opc) {
                                0b00 => a & b,
                                0b01 => a | b,
                                0b10 => a ^ b,
                                0b11 => a & b,
                            };
                            if (sf == 0) res &= 0xffff_ffff;
                            if (opc == 0b11) {
                                const sign_bit: u6 = if (sf == 1) 63 else 31;
                                setNzcv(cpu, ((res >> sign_bit) & 1) != 0, res == 0, false, false);
                            }
                            setX(cpu, @truncate(d.rd), res);
                        } else {
                            addSub(cpu, sf, op0 == 1, s == 1, @truncate(d.rd), a, b, if (op0 == 1) 1 else 0, false);
                        }
                    },
                    .lslv64 => setX(cpu, @truncate(d.rd), getX(cpu, @truncate(d.rn)) << @as(u6, @truncate(getX(cpu, @truncate(d.rm))))),
                    .lsrv64 => setX(cpu, @truncate(d.rd), getX(cpu, @truncate(d.rn)) >> @as(u6, @truncate(getX(cpu, @truncate(d.rm))))),
                    .asrv64 => setX(cpu, @truncate(d.rd), @bitCast(@as(i64, @bitCast(getX(cpu, @truncate(d.rn)))) >> @as(u6, @truncate(getX(cpu, @truncate(d.rm)))))),
                    .lslv32 => setW(cpu, @truncate(d.rd), getW(cpu, @truncate(d.rn)) << @as(u5, @truncate(getW(cpu, @truncate(d.rm))))),
                    .lsrv32 => setW(cpu, @truncate(d.rd), getW(cpu, @truncate(d.rn)) >> @as(u5, @truncate(getW(cpu, @truncate(d.rm))))),
                    .asrv32 => setW(cpu, @truncate(d.rd), @bitCast(@as(i32, @bitCast(getW(cpu, @truncate(d.rn)))) >> @as(u5, @truncate(getW(cpu, @truncate(d.rm)))))),
                    .udiv64 => {
                        const a = getX(cpu, @truncate(d.rn));
                        const b = getX(cpu, @truncate(d.rm));
                        setX(cpu, @truncate(d.rd), if (b == 0) 0 else a / b);
                    },
                    .sdiv64 => {
                        const a = getX(cpu, @truncate(d.rn));
                        const b = getX(cpu, @truncate(d.rm));
                        const res: u64 = if (b == 0) 0 else blk: {
                            const sa: i64 = @bitCast(a);
                            const sb: i64 = @bitCast(b);
                            if (sa == std.math.minInt(i64) and sb == -1) break :blk @bitCast(sa);
                            break :blk @bitCast(@divTrunc(sa, sb));
                        };
                        setX(cpu, @truncate(d.rd), res);
                    },
                    .udiv32 => {
                        const a = getW(cpu, @truncate(d.rn));
                        const b = getW(cpu, @truncate(d.rm));
                        setW(cpu, @truncate(d.rd), if (b == 0) 0 else a / b);
                    },
                    .sdiv32 => {
                        const a = getW(cpu, @truncate(d.rn));
                        const b = getW(cpu, @truncate(d.rm));
                        const res: u32 = if (b == 0) 0 else blk: {
                            const sa: i32 = @bitCast(a);
                            const sb: i32 = @bitCast(b);
                            if (sa == std.math.minInt(i32) and sb == -1) break :blk @bitCast(sa);
                            break :blk @bitCast(@divTrunc(sa, sb));
                        };
                        setW(cpu, @truncate(d.rd), res);
                    },
                    .clz64 => setX(cpu, @truncate(d.rd), @clz(getX(cpu, @truncate(d.rn)))),
                    .clz32 => setW(cpu, @truncate(d.rd), @clz(getW(cpu, @truncate(d.rn)))),
                    .rev64 => setX(cpu, @truncate(d.rd), @byteSwap(getX(cpu, @truncate(d.rn)))),
                    .rev32 => setW(cpu, @truncate(d.rd), @byteSwap(getW(cpu, @truncate(d.rn)))),
                    .csel => {
                        const cond: u4 = @truncate(d.imm);
                        const inv = ((d.imm >> 4) & 1) != 0;
                        const inc = ((d.imm >> 5) & 1) != 0;
                        const sf = ((d.imm >> 6) & 1) != 0;
                        var res: u64 = if (evalCond(cpu.pstate, cond))
                            getX(cpu, @truncate(d.rn))
                        else blk: {
                            var v = getX(cpu, @truncate(d.rm));
                            if (inv) v = ~v;
                            if (inc) v +%= 1;
                            break :blk v;
                        };
                        if (!sf) res &= 0xffff_ffff;
                        setX(cpu, @truncate(d.rd), res);
                    },
                    .adc_sbc => {
                        const c_in: u1 = if ((cpu.pstate & PstateFlags.C) != 0) 1 else 0;
                        addSub(cpu, @truncate(d.imm >> 2), ((d.imm >> 1) & 1) != 0, (d.imm & 1) != 0, @truncate(d.rd), getX(cpu, @truncate(d.rn)), getX(cpu, @truncate(d.rm)), c_in, false);
                    },
                    .ccmp => {
                        const cond: u4 = @truncate(d.imm);
                        const nzcv_imm: u32 = @as(u32, @truncate((d.imm >> 4) & 0xf)) << 28;
                        const is_imm = ((d.imm >> 8) & 1) != 0;
                        const is_sub = ((d.imm >> 9) & 1) != 0;
                        const sf: u1 = @truncate(d.imm >> 10);
                        if (evalCond(cpu.pstate, cond)) {
                            const b: u64 = if (is_imm) d.rm else getX(cpu, @truncate(d.rm));
                            addSub(cpu, sf, is_sub, true, 31, getX(cpu, @truncate(d.rn)), b, if (is_sub) 1 else 0, false);
                        } else {
                            cpu.pstate = (cpu.pstate & 0x0fff_ffff) | nzcv_imm;
                        }
                    },
                    .madd_msub => {
                        const ra: u5 = @truncate(d.imm);
                        const is_sub = ((d.imm >> 5) & 1) != 0;
                        const sf = ((d.imm >> 6) & 1) != 0;
                        const a = getX(cpu, @truncate(d.rn));
                        const b = getX(cpu, @truncate(d.rm));
                        const c = getX(cpu, ra);
                        const res = if (is_sub) (c -% (a *% b)) else (c +% (a *% b));
                        if (sf) setX(cpu, @truncate(d.rd), res) else setW(cpu, @truncate(d.rd), @truncate(res));
                    },
                    .maddl_mulh => {
                        const ra: u5 = @truncate(d.imm);
                        const o0 = ((d.imm >> 5) & 1) != 0;
                        const op31: u3 = @truncate(d.imm >> 6);
                        const rn: u5 = @truncate(d.rn);
                        const rm: u5 = @truncate(d.rm);
                        const rd: u5 = @truncate(d.rd);
                        switch (op31) {
                            0b001 => { // SMADDL / SMSUBL
                                const a: i64 = @as(i32, @bitCast(getW(cpu, rn)));
                                const b: i64 = @as(i32, @bitCast(getW(cpu, rm)));
                                const c: i64 = @bitCast(getX(cpu, ra));
                                const res: i64 = if (o0) (c -% (a * b)) else (c +% (a * b));
                                setX(cpu, rd, @bitCast(res));
                            },
                            0b010 => { // SMULH
                                const a: i128 = @as(i64, @bitCast(getX(cpu, rn)));
                                const b: i128 = @as(i64, @bitCast(getX(cpu, rm)));
                                setX(cpu, rd, @truncate(@as(u128, @bitCast(a * b)) >> 64));
                            },
                            0b101 => { // UMADDL / UMSUBL
                                const a: u64 = getW(cpu, rn);
                                const b: u64 = getW(cpu, rm);
                                const c: u64 = getX(cpu, ra);
                                const res: u64 = if (o0) (c -% (a * b)) else (c +% (a * b));
                                setX(cpu, rd, res);
                            },
                            else => { // UMULH
                                const a: u128 = getX(cpu, rn);
                                const b: u128 = getX(cpu, rm);
                                setX(cpu, rd, @truncate((a * b) >> 64));
                            },
                        }
                    },
                    .ldr64_uimm => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const addr = getXOrSp(cpu, rn) +% d.imm;
                        if ((addr & ~@as(u64, 0xff8)) == data_r_vbase[bank]) {
                            setX(cpu, @truncate(d.rd), std.mem.readInt(u64, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xff8))..][0..8], .little));
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xff8 and (addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                data_r_vbase[bank] = dslot.r_vbase;
                                data_r_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                setX(cpu, @truncate(d.rd), std.mem.readInt(u64, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..8], .little));
                            } else {
                                const val = readData64(cpu, bus, addr) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                setX(cpu, @truncate(d.rd), val);
                            }
                        }
                    },
                    .str64_uimm => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const addr = getXOrSp(cpu, rn) +% d.imm;
                        const val = getX(cpu, @truncate(d.rd));
                        if ((addr & ~@as(u64, 0xff8)) == data_w_vbase[bank]) {
                            std.mem.writeInt(u64, data_w_page_ptr[bank][@as(usize, @truncate(addr & 0xff8))..][0..8], val, .little);
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xff8 and (addr & ~@as(u64, 0xfff)) == dslot.w_vbase) {
                                data_w_vbase[bank] = dslot.w_vbase;
                                data_w_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                std.mem.writeInt(u64, data_w_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..8], val, .little);
                            } else {
                                writeData64(cpu, bus, addr, val) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                if ((addr & ~@as(u64, 0xfff)) != dslot.w_vbase) {
                                    if (checkInterrupts64(cpu, bus)) {
                                        priv = 1;
                                        code_vbase = 0xffff_ffff_ffff_ffff;
                                        data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        continue;
                                    }
                                }
                            }
                        }
                    },
                    .ldr32_uimm => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const addr = getXOrSp(cpu, rn) +% d.imm;
                        if ((addr & ~@as(u64, 0xffc)) == data_r_vbase[bank]) {
                            setW(cpu, @truncate(d.rd), std.mem.readInt(u32, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xffc))..][0..4], .little));
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xffc and (addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                data_r_vbase[bank] = dslot.r_vbase;
                                data_r_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                setW(cpu, @truncate(d.rd), std.mem.readInt(u32, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..4], .little));
                            } else {
                                const val = readData32(cpu, bus, addr) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                setW(cpu, @truncate(d.rd), val);
                            }
                        }
                    },
                    .str32_uimm => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const addr = getXOrSp(cpu, rn) +% d.imm;
                        const val = getW(cpu, @truncate(d.rd));
                        if ((addr & ~@as(u64, 0xffc)) == data_w_vbase[bank]) {
                            std.mem.writeInt(u32, data_w_page_ptr[bank][@as(usize, @truncate(addr & 0xffc))..][0..4], val, .little);
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xffc and (addr & ~@as(u64, 0xfff)) == dslot.w_vbase) {
                                data_w_vbase[bank] = dslot.w_vbase;
                                data_w_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                std.mem.writeInt(u32, data_w_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..4], val, .little);
                            } else {
                                writeData32(cpu, bus, addr, val) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                if ((addr & ~@as(u64, 0xfff)) != dslot.w_vbase) {
                                    if (checkInterrupts64(cpu, bus)) {
                                        priv = 1;
                                        code_vbase = 0xffff_ffff_ffff_ffff;
                                        data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        continue;
                                    }
                                }
                            }
                        }
                    },
                    .ldrsw_uimm => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const addr = getXOrSp(cpu, rn) +% d.imm;
                        const val32: u32 = if ((addr & ~@as(u64, 0xffc)) == data_r_vbase[bank])
                            std.mem.readInt(u32, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xffc))..][0..4], .little)
                        else blk: {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xffc and (addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                data_r_vbase[bank] = dslot.r_vbase;
                                data_r_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                break :blk std.mem.readInt(u32, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..4], .little);
                            }
                            break :blk readData32(cpu, bus, addr) catch {
                                handleAbort64(cpu, cur_pc);
                                priv = 1;
                                code_vbase = 0xffff_ffff_ffff_ffff;
                                data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                continue;
                            };
                        };
                        setX(cpu, @truncate(d.rd), @bitCast(@as(i64, @as(i32, @bitCast(val32)))));
                    },
                    .ldr16_uimm => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const addr = getXOrSp(cpu, rn) +% d.imm;
                        if ((addr & ~@as(u64, 0xffe)) == data_r_vbase[bank]) {
                            setW(cpu, @truncate(d.rd), std.mem.readInt(u16, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xffe))..][0..2], .little));
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xffe and (addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                data_r_vbase[bank] = dslot.r_vbase;
                                data_r_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                setW(cpu, @truncate(d.rd), std.mem.readInt(u16, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..2], .little));
                            } else {
                                const val = readData16(cpu, bus, addr) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                setW(cpu, @truncate(d.rd), val);
                            }
                        }
                    },
                    .str16_uimm => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const addr = getXOrSp(cpu, rn) +% d.imm;
                        const val: u16 = @truncate(getW(cpu, @truncate(d.rd)));
                        if ((addr & ~@as(u64, 0xffe)) == data_w_vbase[bank]) {
                            std.mem.writeInt(u16, data_w_page_ptr[bank][@as(usize, @truncate(addr & 0xffe))..][0..2], val, .little);
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xffe and (addr & ~@as(u64, 0xfff)) == dslot.w_vbase) {
                                data_w_vbase[bank] = dslot.w_vbase;
                                data_w_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                std.mem.writeInt(u16, data_w_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..2], val, .little);
                            } else {
                                writeData16(cpu, bus, addr, val) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                if ((addr & ~@as(u64, 0xfff)) != dslot.w_vbase) {
                                    if (checkInterrupts64(cpu, bus)) {
                                        priv = 1;
                                        code_vbase = 0xffff_ffff_ffff_ffff;
                                        data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        continue;
                                    }
                                }
                            }
                        }
                    },
                    .ldr8_uimm => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const addr = getXOrSp(cpu, rn) +% d.imm;
                        if ((addr & ~@as(u64, 0xfff)) == data_r_vbase[bank]) {
                            setW(cpu, @truncate(d.rd), data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))]);
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                data_r_vbase[bank] = dslot.r_vbase;
                                data_r_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                setW(cpu, @truncate(d.rd), data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))]);
                            } else {
                                const val = readData8(cpu, bus, addr) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                setW(cpu, @truncate(d.rd), val);
                            }
                        }
                    },
                    .str8_uimm => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const addr = getXOrSp(cpu, rn) +% d.imm;
                        const val: u8 = @truncate(getW(cpu, @truncate(d.rd)));
                        if ((addr & ~@as(u64, 0xfff)) == data_w_vbase[bank]) {
                            data_w_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))] = val;
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & ~@as(u64, 0xfff)) == dslot.w_vbase) {
                                data_w_vbase[bank] = dslot.w_vbase;
                                data_w_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                data_w_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))] = val;
                            } else {
                                writeData8(cpu, bus, addr, val) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                if ((addr & ~@as(u64, 0xfff)) != dslot.w_vbase) {
                                    if (checkInterrupts64(cpu, bus)) {
                                        priv = 1;
                                        code_vbase = 0xffff_ffff_ffff_ffff;
                                        data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        continue;
                                    }
                                }
                            }
                        }
                    },
                    .ldrsb64_uimm, .ldrsb32_uimm => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const addr = getXOrSp(cpu, rn) +% d.imm;
                        const val8: u8 = if ((addr & ~@as(u64, 0xfff)) == data_r_vbase[bank])
                            data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))]
                        else blk: {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                data_r_vbase[bank] = dslot.r_vbase;
                                data_r_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                break :blk data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))];
                            }
                            break :blk readData8(cpu, bus, addr) catch {
                                handleAbort64(cpu, cur_pc);
                                priv = 1;
                                code_vbase = 0xffff_ffff_ffff_ffff;
                                data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                continue;
                            };
                        };
                        const s8: i8 = @bitCast(val8);
                        if (op == .ldrsb64_uimm) {
                            setX(cpu, @truncate(d.rd), @bitCast(@as(i64, s8)));
                        } else {
                            setW(cpu, @truncate(d.rd), @bitCast(@as(i32, s8)));
                        }
                    },
                    .ldrsh64_uimm, .ldrsh32_uimm => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const addr = getXOrSp(cpu, rn) +% d.imm;
                        const val16: u16 = if ((addr & ~@as(u64, 0xffe)) == data_r_vbase[bank])
                            std.mem.readInt(u16, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xffe))..][0..2], .little)
                        else blk: {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xffe and (addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                data_r_vbase[bank] = dslot.r_vbase;
                                data_r_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                break :blk std.mem.readInt(u16, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..2], .little);
                            }
                            break :blk readData16(cpu, bus, addr) catch {
                                handleAbort64(cpu, cur_pc);
                                priv = 1;
                                code_vbase = 0xffff_ffff_ffff_ffff;
                                data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                continue;
                            };
                        };
                        const s16: i16 = @bitCast(val16);
                        if (op == .ldrsh64_uimm) {
                            setX(cpu, @truncate(d.rd), @bitCast(@as(i64, s16)));
                        } else {
                            setW(cpu, @truncate(d.rd), @bitCast(@as(i32, s16)));
                        }
                    },
                    .ldr_lit32, .ldrsw_lit, .ldr_fp32_lit => {
                        const addr = cur_pc +% d.imm;
                        const val32: u32 = if ((addr & ~@as(u64, 0xffc)) == code_vbase)
                            std.mem.readInt(u32, code_page_ptr[@as(usize, @truncate(addr & 0xffc))..][0..4], .little)
                        else if ((addr & ~@as(u64, 0xffc)) == data_r_vbase[0])
                            std.mem.readInt(u32, data_r_page_ptr[0][@as(usize, @truncate(addr & 0xffc))..][0..4], .little)
                        else blk: {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xffc and (addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                data_r_vbase[0] = dslot.r_vbase;
                                data_r_page_ptr[0] = bus.ram.ptr + dslot.pbase;
                                break :blk std.mem.readInt(u32, data_r_page_ptr[0][@as(usize, @truncate(addr & 0xfff))..][0..4], .little);
                            }
                            break :blk readData32(cpu, bus, addr) catch {
                                handleAbort64(cpu, cur_pc);
                                priv = 1;
                                code_vbase = 0xffff_ffff_ffff_ffff;
                                data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                continue;
                            };
                        };
                        if (op == .ldr_lit32) {
                            setW(cpu, @truncate(d.rd), val32);
                        } else if (op == .ldrsw_lit) {
                            setX(cpu, @truncate(d.rd), @bitCast(@as(i64, @as(i32, @bitCast(val32)))));
                        } else {
                            cpu.vfp.v[@as(u5, @truncate(d.rd))] = val32;
                        }
                    },
                    .ldr_lit64, .ldr_fp64_lit => {
                        const addr = cur_pc +% d.imm;
                        const val64: u64 = if ((addr & ~@as(u64, 0xff8)) == code_vbase)
                            std.mem.readInt(u64, code_page_ptr[@as(usize, @truncate(addr & 0xff8))..][0..8], .little)
                        else if ((addr & ~@as(u64, 0xff8)) == data_r_vbase[0])
                            std.mem.readInt(u64, data_r_page_ptr[0][@as(usize, @truncate(addr & 0xff8))..][0..8], .little)
                        else blk: {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xff8 and (addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                data_r_vbase[0] = dslot.r_vbase;
                                data_r_page_ptr[0] = bus.ram.ptr + dslot.pbase;
                                break :blk std.mem.readInt(u64, data_r_page_ptr[0][@as(usize, @truncate(addr & 0xfff))..][0..8], .little);
                            }
                            break :blk readData64(cpu, bus, addr) catch {
                                handleAbort64(cpu, cur_pc);
                                priv = 1;
                                code_vbase = 0xffff_ffff_ffff_ffff;
                                data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                continue;
                            };
                        };
                        if (op == .ldr_lit64) {
                            setX(cpu, @truncate(d.rd), val64);
                        } else {
                            cpu.vfp.v[@as(u5, @truncate(d.rd))] = val64;
                        }
                    },
                    .ldr_fp128_lit => {
                        const addr = cur_pc +% d.imm;
                        const val128: u128 = if ((addr & 0xfff) <= 0xff0 and (addr & ~@as(u64, 0xfff)) == code_vbase)
                            std.mem.readInt(u128, code_page_ptr[@as(usize, @truncate(addr & 0xfff))..][0..16], .little)
                        else if ((addr & 0xfff) <= 0xff0 and (addr & ~@as(u64, 0xfff)) == data_r_vbase[0])
                            std.mem.readInt(u128, data_r_page_ptr[0][@as(usize, @truncate(addr & 0xfff))..][0..16], .little)
                        else blk: {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xff0 and (addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                data_r_vbase[0] = dslot.r_vbase;
                                data_r_page_ptr[0] = bus.ram.ptr + dslot.pbase;
                                break :blk std.mem.readInt(u128, data_r_page_ptr[0][@as(usize, @truncate(addr & 0xfff))..][0..16], .little);
                            }
                            break :blk readData128(cpu, bus, addr) catch {
                                handleAbort64(cpu, cur_pc);
                                priv = 1;
                                code_vbase = 0xffff_ffff_ffff_ffff;
                                data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                continue;
                            };
                        };
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = val128;
                    },
                    .ldr64_pre, .ldr64_post => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const base = getXOrSp(cpu, rn);
                        const wb_addr = base +% d.imm;
                        const addr = if (op == .ldr64_post) base else wb_addr;
                        const val: u64 = if ((addr & ~@as(u64, 0xff8)) == data_r_vbase[bank])
                            std.mem.readInt(u64, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xff8))..][0..8], .little)
                        else blk: {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xff8 and (addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                data_r_vbase[bank] = dslot.r_vbase;
                                data_r_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                break :blk std.mem.readInt(u64, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..8], .little);
                            }
                            break :blk readData64(cpu, bus, addr) catch {
                                handleAbort64(cpu, cur_pc);
                                priv = 1;
                                code_vbase = 0xffff_ffff_ffff_ffff;
                                data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                continue;
                            };
                        };
                        setX(cpu, @truncate(d.rd), val);
                        setXOrSp(cpu, rn, wb_addr);
                    },
                    .str64_pre, .str64_post => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const base = getXOrSp(cpu, rn);
                        const wb_addr = base +% d.imm;
                        const addr = if (op == .str64_post) base else wb_addr;
                        const val = getX(cpu, @truncate(d.rd));
                        if ((addr & ~@as(u64, 0xff8)) == data_w_vbase[bank]) {
                            std.mem.writeInt(u64, data_w_page_ptr[bank][@as(usize, @truncate(addr & 0xff8))..][0..8], val, .little);
                            setXOrSp(cpu, rn, wb_addr);
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xff8 and (addr & ~@as(u64, 0xfff)) == dslot.w_vbase) {
                                data_w_vbase[bank] = dslot.w_vbase;
                                data_w_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                std.mem.writeInt(u64, data_w_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..8], val, .little);
                                setXOrSp(cpu, rn, wb_addr);
                            } else {
                                writeData64(cpu, bus, addr, val) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                setXOrSp(cpu, rn, wb_addr);
                                if ((addr & ~@as(u64, 0xfff)) != dslot.w_vbase) {
                                    if (checkInterrupts64(cpu, bus)) {
                                        priv = 1;
                                        code_vbase = 0xffff_ffff_ffff_ffff;
                                        data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        continue;
                                    }
                                }
                            }
                        }
                    },
                    .ldr32_pre, .ldr32_post => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const base = getXOrSp(cpu, rn);
                        const wb_addr = base +% d.imm;
                        const addr = if (op == .ldr32_post) base else wb_addr;
                        const val: u32 = if ((addr & ~@as(u64, 0xffc)) == data_r_vbase[bank])
                            std.mem.readInt(u32, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xffc))..][0..4], .little)
                        else blk: {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xffc and (addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                data_r_vbase[bank] = dslot.r_vbase;
                                data_r_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                break :blk std.mem.readInt(u32, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..4], .little);
                            }
                            break :blk readData32(cpu, bus, addr) catch {
                                handleAbort64(cpu, cur_pc);
                                priv = 1;
                                code_vbase = 0xffff_ffff_ffff_ffff;
                                data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                continue;
                            };
                        };
                        setW(cpu, @truncate(d.rd), val);
                        setXOrSp(cpu, rn, wb_addr);
                    },
                    .str32_pre, .str32_post => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const base = getXOrSp(cpu, rn);
                        const wb_addr = base +% d.imm;
                        const addr = if (op == .str32_post) base else wb_addr;
                        const val = getW(cpu, @truncate(d.rd));
                        if ((addr & ~@as(u64, 0xffc)) == data_w_vbase[bank]) {
                            std.mem.writeInt(u32, data_w_page_ptr[bank][@as(usize, @truncate(addr & 0xffc))..][0..4], val, .little);
                            setXOrSp(cpu, rn, wb_addr);
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xffc and (addr & ~@as(u64, 0xfff)) == dslot.w_vbase) {
                                data_w_vbase[bank] = dslot.w_vbase;
                                data_w_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                std.mem.writeInt(u32, data_w_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..4], val, .little);
                                setXOrSp(cpu, rn, wb_addr);
                            } else {
                                writeData32(cpu, bus, addr, val) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                setXOrSp(cpu, rn, wb_addr);
                                if ((addr & ~@as(u64, 0xfff)) != dslot.w_vbase) {
                                    if (checkInterrupts64(cpu, bus)) {
                                        priv = 1;
                                        code_vbase = 0xffff_ffff_ffff_ffff;
                                        data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        continue;
                                    }
                                }
                            }
                        }
                    },
                    .ldr64_reg_lsl => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const addr = getXOrSp(cpu, rn) +% (getX(cpu, @truncate(d.rm)) << @as(u3, @truncate(d.imm)));
                        if ((addr & ~@as(u64, 0xff8)) == data_r_vbase[bank]) {
                            setX(cpu, @truncate(d.rd), std.mem.readInt(u64, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xff8))..][0..8], .little));
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xff8 and (addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                data_r_vbase[bank] = dslot.r_vbase;
                                data_r_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                setX(cpu, @truncate(d.rd), std.mem.readInt(u64, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..8], .little));
                            } else {
                                const val = readData64(cpu, bus, addr) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                setX(cpu, @truncate(d.rd), val);
                            }
                        }
                    },
                    .str64_reg_lsl => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const addr = getXOrSp(cpu, rn) +% (getX(cpu, @truncate(d.rm)) << @as(u3, @truncate(d.imm)));
                        const val = getX(cpu, @truncate(d.rd));
                        if ((addr & ~@as(u64, 0xff8)) == data_w_vbase[bank]) {
                            std.mem.writeInt(u64, data_w_page_ptr[bank][@as(usize, @truncate(addr & 0xff8))..][0..8], val, .little);
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xff8 and (addr & ~@as(u64, 0xfff)) == dslot.w_vbase) {
                                data_w_vbase[bank] = dslot.w_vbase;
                                data_w_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                std.mem.writeInt(u64, data_w_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..8], val, .little);
                            } else {
                                writeData64(cpu, bus, addr, val) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                if ((addr & ~@as(u64, 0xfff)) != dslot.w_vbase) {
                                    if (checkInterrupts64(cpu, bus)) {
                                        priv = 1;
                                        code_vbase = 0xffff_ffff_ffff_ffff;
                                        data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        continue;
                                    }
                                }
                            }
                        }
                    },
                    .ldr32_reg_lsl => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const addr = getXOrSp(cpu, rn) +% (getX(cpu, @truncate(d.rm)) << @as(u3, @truncate(d.imm)));
                        if ((addr & ~@as(u64, 0xffc)) == data_r_vbase[bank]) {
                            setW(cpu, @truncate(d.rd), std.mem.readInt(u32, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xffc))..][0..4], .little));
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xffc and (addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                data_r_vbase[bank] = dslot.r_vbase;
                                data_r_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                setW(cpu, @truncate(d.rd), std.mem.readInt(u32, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..4], .little));
                            } else {
                                const val = readData32(cpu, bus, addr) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                setW(cpu, @truncate(d.rd), val);
                            }
                        }
                    },
                    .str32_reg_lsl => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const addr = getXOrSp(cpu, rn) +% (getX(cpu, @truncate(d.rm)) << @as(u3, @truncate(d.imm)));
                        const val = getW(cpu, @truncate(d.rd));
                        if ((addr & ~@as(u64, 0xffc)) == data_w_vbase[bank]) {
                            std.mem.writeInt(u32, data_w_page_ptr[bank][@as(usize, @truncate(addr & 0xffc))..][0..4], val, .little);
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xffc and (addr & ~@as(u64, 0xfff)) == dslot.w_vbase) {
                                data_w_vbase[bank] = dslot.w_vbase;
                                data_w_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                std.mem.writeInt(u32, data_w_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..4], val, .little);
                            } else {
                                writeData32(cpu, bus, addr, val) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                if ((addr & ~@as(u64, 0xfff)) != dslot.w_vbase) {
                                    if (checkInterrupts64(cpu, bus)) {
                                        priv = 1;
                                        code_vbase = 0xffff_ffff_ffff_ffff;
                                        data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        continue;
                                    }
                                }
                            }
                        }
                    },
                    .ldr8_reg_lsl => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const addr = getXOrSp(cpu, rn) +% getX(cpu, @truncate(d.rm));
                        if ((addr & ~@as(u64, 0xfff)) == data_r_vbase[bank]) {
                            setW(cpu, @truncate(d.rd), data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))]);
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                data_r_vbase[bank] = dslot.r_vbase;
                                data_r_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                setW(cpu, @truncate(d.rd), data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))]);
                            } else {
                                const val = readData8(cpu, bus, addr) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                setW(cpu, @truncate(d.rd), val);
                            }
                        }
                    },
                    .str8_reg_lsl => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const addr = getXOrSp(cpu, rn) +% getX(cpu, @truncate(d.rm));
                        const val: u8 = @truncate(getW(cpu, @truncate(d.rd)));
                        if ((addr & ~@as(u64, 0xfff)) == data_w_vbase[bank]) {
                            data_w_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))] = val;
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & ~@as(u64, 0xfff)) == dslot.w_vbase) {
                                data_w_vbase[bank] = dslot.w_vbase;
                                data_w_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                data_w_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))] = val;
                            } else {
                                writeData8(cpu, bus, addr, val) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                if ((addr & ~@as(u64, 0xfff)) != dslot.w_vbase) {
                                    if (checkInterrupts64(cpu, bus)) {
                                        priv = 1;
                                        code_vbase = 0xffff_ffff_ffff_ffff;
                                        data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        continue;
                                    }
                                }
                            }
                        }
                    },
                    .ldxr64 => {
                        const addr = getXOrSp(cpu, @truncate(d.rn));
                        const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                        if ((addr & 0xfff) <= 0xff8 and (addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                            const paddr = dslot.pbase | @as(u32, @truncate(addr & 0xfff));
                            const loaded = std.mem.readInt(u64, bus.ram[paddr..][0..8], .little);
                            cpu.excl_valid = true;
                            cpu.excl_paddr = paddr & ~@as(u32, 7);
                            cpu.excl_val = loaded;
                            setX(cpu, @truncate(d.rd), loaded);
                        } else {
                            executeLoadStoreExcl(cpu, bus, inst) catch {
                                handleAbort64(cpu, cur_pc);
                                priv = 1;
                                code_vbase = 0xffff_ffff_ffff_ffff;
                                data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                continue;
                            };
                        }
                    },
                    .stxr64 => {
                        const addr = getXOrSp(cpu, @truncate(d.rn));
                        const val = getX(cpu, @truncate(d.rd));
                        const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                        if ((addr & 0xfff) <= 0xff8 and (addr & ~@as(u64, 0xfff)) == dslot.w_vbase) {
                            const paddr = dslot.pbase | @as(u32, @truncate(addr & 0xfff));
                            if (cpu.excl_valid and (paddr & ~@as(u32, 7)) == cpu.excl_paddr) {
                                const stored = atomic_ram.compareAndSwap(u64, bus.ram, paddr, cpu.excl_val, val);
                                cpu.excl_valid = false;
                                setW(cpu, @truncate(d.rm), if (stored) 0 else 1);
                            } else {
                                cpu.excl_valid = false;
                                setW(cpu, @truncate(d.rm), 1);
                            }
                        } else {
                            executeLoadStoreExcl(cpu, bus, inst) catch {
                                handleAbort64(cpu, cur_pc);
                                priv = 1;
                                code_vbase = 0xffff_ffff_ffff_ffff;
                                data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                continue;
                            };
                        }
                    },
                    .ldxr32 => {
                        const addr = getXOrSp(cpu, @truncate(d.rn));
                        const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                        if ((addr & 0xfff) <= 0xffc and (addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                            const paddr = dslot.pbase | @as(u32, @truncate(addr & 0xfff));
                            const loaded = std.mem.readInt(u32, bus.ram[paddr..][0..4], .little);
                            cpu.excl_valid = true;
                            cpu.excl_paddr = paddr & ~@as(u32, 7);
                            cpu.excl_val = loaded;
                            setW(cpu, @truncate(d.rd), loaded);
                        } else {
                            executeLoadStoreExcl(cpu, bus, inst) catch {
                                handleAbort64(cpu, cur_pc);
                                priv = 1;
                                code_vbase = 0xffff_ffff_ffff_ffff;
                                data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                continue;
                            };
                        }
                    },
                    .stxr32 => {
                        const addr = getXOrSp(cpu, @truncate(d.rn));
                        const val = getW(cpu, @truncate(d.rd));
                        const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                        if ((addr & 0xfff) <= 0xffc and (addr & ~@as(u64, 0xfff)) == dslot.w_vbase) {
                            const paddr = dslot.pbase | @as(u32, @truncate(addr & 0xfff));
                            if (cpu.excl_valid and (paddr & ~@as(u32, 7)) == cpu.excl_paddr) {
                                const stored = atomic_ram.compareAndSwap(u32, bus.ram, paddr, @truncate(cpu.excl_val), val);
                                cpu.excl_valid = false;
                                setW(cpu, @truncate(d.rm), if (stored) 0 else 1);
                            } else {
                                cpu.excl_valid = false;
                                setW(cpu, @truncate(d.rm), 1);
                            }
                        } else {
                            executeLoadStoreExcl(cpu, bus, inst) catch {
                                handleAbort64(cpu, cur_pc);
                                priv = 1;
                                code_vbase = 0xffff_ffff_ffff_ffff;
                                data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                continue;
                            };
                        }
                    },
                    .ldp64_off, .ldp64_pre, .ldp64_post => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const base = getXOrSp(cpu, rn);
                        const wb_addr = base +% d.imm;
                        const addr = if (op == .ldp64_post) base else wb_addr;
                        if ((addr & 0xfff) <= 0xff0 and (addr & ~@as(u64, 0xfff)) == data_r_vbase[bank]) {
                            const off: usize = @truncate(addr & 0xfff);
                            const v1 = std.mem.readInt(u64, data_r_page_ptr[bank][off..][0..8], .little);
                            const v2 = std.mem.readInt(u64, data_r_page_ptr[bank][off + 8 ..][0..8], .little);
                            setX(cpu, @truncate(d.rd), v1);
                            setX(cpu, @truncate(d.rm), v2);
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xff0 and (addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                data_r_vbase[bank] = dslot.r_vbase;
                                data_r_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                const off: usize = @truncate(addr & 0xfff);
                                const v1 = std.mem.readInt(u64, data_r_page_ptr[bank][off..][0..8], .little);
                                const v2 = std.mem.readInt(u64, data_r_page_ptr[bank][off + 8 ..][0..8], .little);
                                setX(cpu, @truncate(d.rd), v1);
                                setX(cpu, @truncate(d.rm), v2);
                            } else {
                                const pair = readData128(cpu, bus, addr) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                setX(cpu, @truncate(d.rd), @truncate(pair));
                                setX(cpu, @truncate(d.rm), @truncate(pair >> 64));
                            }
                        }
                        if (op != .ldp64_off) setXOrSp(cpu, rn, wb_addr);
                    },
                    .stp64_off, .stp64_pre, .stp64_post => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const base = getXOrSp(cpu, rn);
                        const wb_addr = base +% d.imm;
                        const addr = if (op == .stp64_post) base else wb_addr;
                        const v1 = getX(cpu, @truncate(d.rd));
                        const v2 = getX(cpu, @truncate(d.rm));
                        if ((addr & 0xfff) <= 0xff0 and (addr & ~@as(u64, 0xfff)) == data_w_vbase[bank]) {
                            const off: usize = @truncate(addr & 0xfff);
                            std.mem.writeInt(u64, data_w_page_ptr[bank][off..][0..8], v1, .little);
                            std.mem.writeInt(u64, data_w_page_ptr[bank][off + 8 ..][0..8], v2, .little);
                            if (op != .stp64_off) setXOrSp(cpu, rn, wb_addr);
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xff0 and (addr & ~@as(u64, 0xfff)) == dslot.w_vbase) {
                                data_w_vbase[bank] = dslot.w_vbase;
                                data_w_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                const off: usize = @truncate(addr & 0xfff);
                                std.mem.writeInt(u64, data_w_page_ptr[bank][off..][0..8], v1, .little);
                                std.mem.writeInt(u64, data_w_page_ptr[bank][off + 8 ..][0..8], v2, .little);
                                if (op != .stp64_off) setXOrSp(cpu, rn, wb_addr);
                            } else {
                                writeData128(cpu, bus, addr, @as(u128, v1) | (@as(u128, v2) << 64)) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                if (op != .stp64_off) setXOrSp(cpu, rn, wb_addr);
                                if ((addr & ~@as(u64, 0xfff)) != dslot.w_vbase) {
                                    if (checkInterrupts64(cpu, bus)) {
                                        priv = 1;
                                        code_vbase = 0xffff_ffff_ffff_ffff;
                                        data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        continue;
                                    }
                                }
                            }
                        }
                        if ((d.rn & 0x80) != 0 and executed < batch_end and (cur_pc & ~@as(u64, 0xfff)) == code_vbase) {
                            cpu.x[29] = wb_addr;
                            cpu.pc64 = cur_pc +% 8;
                            executed += 1;
                        }
                    },
                    .ldp32_off, .ldp32_pre, .ldp32_post => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const base = getXOrSp(cpu, rn);
                        const wb_addr = base +% d.imm;
                        const addr = if (op == .ldp32_post) base else wb_addr;
                        if ((addr & 0xfff) <= 0xff8 and (addr & ~@as(u64, 0xfff)) == data_r_vbase[bank]) {
                            const off: usize = @truncate(addr & 0xfff);
                            const v1 = std.mem.readInt(u32, data_r_page_ptr[bank][off..][0..4], .little);
                            const v2 = std.mem.readInt(u32, data_r_page_ptr[bank][off + 4 ..][0..4], .little);
                            setW(cpu, @truncate(d.rd), v1);
                            setW(cpu, @truncate(d.rm), v2);
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xff8 and (addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                data_r_vbase[bank] = dslot.r_vbase;
                                data_r_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                const off: usize = @truncate(addr & 0xfff);
                                const v1 = std.mem.readInt(u32, data_r_page_ptr[bank][off..][0..4], .little);
                                const v2 = std.mem.readInt(u32, data_r_page_ptr[bank][off + 4 ..][0..4], .little);
                                setW(cpu, @truncate(d.rd), v1);
                                setW(cpu, @truncate(d.rm), v2);
                            } else {
                                const v1 = readData32(cpu, bus, addr) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                const v2 = readData32(cpu, bus, addr +% 4) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                setW(cpu, @truncate(d.rd), v1);
                                setW(cpu, @truncate(d.rm), v2);
                            }
                        }
                        if (op != .ldp32_off) setXOrSp(cpu, rn, wb_addr);
                    },
                    .stp32_off, .stp32_pre, .stp32_post => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const base = getXOrSp(cpu, rn);
                        const wb_addr = base +% d.imm;
                        const addr = if (op == .stp32_post) base else wb_addr;
                        const v1 = getW(cpu, @truncate(d.rd));
                        const v2 = getW(cpu, @truncate(d.rm));
                        if ((addr & 0xfff) <= 0xff8 and (addr & ~@as(u64, 0xfff)) == data_w_vbase[bank]) {
                            const off: usize = @truncate(addr & 0xfff);
                            std.mem.writeInt(u32, data_w_page_ptr[bank][off..][0..4], v1, .little);
                            std.mem.writeInt(u32, data_w_page_ptr[bank][off + 4 ..][0..4], v2, .little);
                            if (op != .stp32_off) setXOrSp(cpu, rn, wb_addr);
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xff8 and (addr & ~@as(u64, 0xfff)) == dslot.w_vbase) {
                                data_w_vbase[bank] = dslot.w_vbase;
                                data_w_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                const off: usize = @truncate(addr & 0xfff);
                                std.mem.writeInt(u32, data_w_page_ptr[bank][off..][0..4], v1, .little);
                                std.mem.writeInt(u32, data_w_page_ptr[bank][off + 4 ..][0..4], v2, .little);
                                if (op != .stp32_off) setXOrSp(cpu, rn, wb_addr);
                            } else {
                                writeData32(cpu, bus, addr, v1) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                writeData32(cpu, bus, addr +% 4, v2) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                if (op != .stp32_off) setXOrSp(cpu, rn, wb_addr);
                                if ((addr & ~@as(u64, 0xfff)) != dslot.w_vbase) {
                                    if (checkInterrupts64(cpu, bus)) {
                                        priv = 1;
                                        code_vbase = 0xffff_ffff_ffff_ffff;
                                        data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        continue;
                                    }
                                }
                            }
                        }
                    },
                    .ldpsw_off, .ldpsw_pre, .ldpsw_post => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const base = getXOrSp(cpu, rn);
                        const wb_addr = base +% d.imm;
                        const addr = if (op == .ldpsw_post) base else wb_addr;
                        if ((addr & 0xfff) <= 0xff8 and (addr & ~@as(u64, 0xfff)) == data_r_vbase[bank]) {
                            const off: usize = @truncate(addr & 0xfff);
                            const v1: u64 = @bitCast(@as(i64, std.mem.readInt(i32, data_r_page_ptr[bank][off..][0..4], .little)));
                            const v2: u64 = @bitCast(@as(i64, std.mem.readInt(i32, data_r_page_ptr[bank][off + 4 ..][0..4], .little)));
                            setX(cpu, @truncate(d.rd), v1);
                            setX(cpu, @truncate(d.rm), v2);
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xff8 and (addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                data_r_vbase[bank] = dslot.r_vbase;
                                data_r_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                const off: usize = @truncate(addr & 0xfff);
                                const v1: u64 = @bitCast(@as(i64, std.mem.readInt(i32, data_r_page_ptr[bank][off..][0..4], .little)));
                                const v2: u64 = @bitCast(@as(i64, std.mem.readInt(i32, data_r_page_ptr[bank][off + 4 ..][0..4], .little)));
                                setX(cpu, @truncate(d.rd), v1);
                                setX(cpu, @truncate(d.rm), v2);
                            } else {
                                const pair = readData64(cpu, bus, addr) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                const v1: u64 = @bitCast(@as(i64, @as(i32, @bitCast(@as(u32, @truncate(pair))))));
                                const v2: u64 = @bitCast(@as(i64, @as(i32, @bitCast(@as(u32, @truncate(pair >> 32))))));
                                setX(cpu, @truncate(d.rd), v1);
                                setX(cpu, @truncate(d.rm), v2);
                            }
                        }
                        if (op != .ldpsw_off) setXOrSp(cpu, rn, wb_addr);
                    },
                    .ldr_fp32_uimm => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const addr = getXOrSp(cpu, rn) +% d.imm;
                        if ((addr & ~@as(u64, 0xffc)) == data_r_vbase[bank]) {
                            cpu.vfp.v[@as(u5, @truncate(d.rd))] = std.mem.readInt(u32, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xffc))..][0..4], .little);
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xffc and (addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                data_r_vbase[bank] = dslot.r_vbase;
                                data_r_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                cpu.vfp.v[@as(u5, @truncate(d.rd))] = std.mem.readInt(u32, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..4], .little);
                            } else {
                                const val = readData32(cpu, bus, addr) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                cpu.vfp.v[@as(u5, @truncate(d.rd))] = val;
                            }
                        }
                    },
                    .str_fp32_uimm => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const addr = getXOrSp(cpu, rn) +% d.imm;
                        const val: u32 = @truncate(cpu.vfp.v[@as(u5, @truncate(d.rd))]);
                        if ((addr & ~@as(u64, 0xffc)) == data_w_vbase[bank]) {
                            std.mem.writeInt(u32, data_w_page_ptr[bank][@as(usize, @truncate(addr & 0xffc))..][0..4], val, .little);
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xffc and (addr & ~@as(u64, 0xfff)) == dslot.w_vbase) {
                                data_w_vbase[bank] = dslot.w_vbase;
                                data_w_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                std.mem.writeInt(u32, data_w_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..4], val, .little);
                            } else {
                                writeData32(cpu, bus, addr, val) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                if ((addr & ~@as(u64, 0xfff)) != dslot.w_vbase) {
                                    if (checkInterrupts64(cpu, bus)) {
                                        priv = 1;
                                        code_vbase = 0xffff_ffff_ffff_ffff;
                                        data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        continue;
                                    }
                                }
                            }
                        }
                    },
                    .ldr_fp64_uimm => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const addr = getXOrSp(cpu, rn) +% d.imm;
                        if ((addr & ~@as(u64, 0xff8)) == data_r_vbase[bank]) {
                            cpu.vfp.v[@as(u5, @truncate(d.rd))] = std.mem.readInt(u64, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xff8))..][0..8], .little);
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xff8 and (addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                data_r_vbase[bank] = dslot.r_vbase;
                                data_r_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                cpu.vfp.v[@as(u5, @truncate(d.rd))] = std.mem.readInt(u64, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..8], .little);
                            } else {
                                const val = readData64(cpu, bus, addr) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                cpu.vfp.v[@as(u5, @truncate(d.rd))] = val;
                            }
                        }
                    },
                    .str_fp64_uimm => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const addr = getXOrSp(cpu, rn) +% d.imm;
                        const val: u64 = @truncate(cpu.vfp.v[@as(u5, @truncate(d.rd))]);
                        if ((addr & ~@as(u64, 0xff8)) == data_w_vbase[bank]) {
                            std.mem.writeInt(u64, data_w_page_ptr[bank][@as(usize, @truncate(addr & 0xff8))..][0..8], val, .little);
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xff8 and (addr & ~@as(u64, 0xfff)) == dslot.w_vbase) {
                                data_w_vbase[bank] = dslot.w_vbase;
                                data_w_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                std.mem.writeInt(u64, data_w_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..8], val, .little);
                            } else {
                                writeData64(cpu, bus, addr, val) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                if ((addr & ~@as(u64, 0xfff)) != dslot.w_vbase) {
                                    if (checkInterrupts64(cpu, bus)) {
                                        priv = 1;
                                        code_vbase = 0xffff_ffff_ffff_ffff;
                                        data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        continue;
                                    }
                                }
                            }
                        }
                    },
                    .ldr_fp128_uimm => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const addr = getXOrSp(cpu, rn) +% d.imm;
                        if ((addr & 0xfff) <= 0xff0 and (addr & ~@as(u64, 0xfff)) == data_r_vbase[bank]) {
                            cpu.vfp.v[@as(u5, @truncate(d.rd))] = std.mem.readInt(u128, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..16], .little);
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xff0 and (addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                data_r_vbase[bank] = dslot.r_vbase;
                                data_r_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                cpu.vfp.v[@as(u5, @truncate(d.rd))] = std.mem.readInt(u128, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..16], .little);
                            } else {
                                cpu.vfp.v[@as(u5, @truncate(d.rd))] = readData128(cpu, bus, addr) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                            }
                        }
                    },
                    .str_fp128_uimm => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const addr = getXOrSp(cpu, rn) +% d.imm;
                        const val = cpu.vfp.v[@as(u5, @truncate(d.rd))];
                        if ((addr & 0xfff) <= 0xff0 and (addr & ~@as(u64, 0xfff)) == data_w_vbase[bank]) {
                            std.mem.writeInt(u128, data_w_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..16], val, .little);
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xff0 and (addr & ~@as(u64, 0xfff)) == dslot.w_vbase) {
                                data_w_vbase[bank] = dslot.w_vbase;
                                data_w_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                std.mem.writeInt(u128, data_w_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..16], val, .little);
                            } else {
                                writeData128(cpu, bus, addr, val) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                if ((addr & ~@as(u64, 0xfff)) != dslot.w_vbase) {
                                    if (checkInterrupts64(cpu, bus)) {
                                        priv = 1;
                                        code_vbase = 0xffff_ffff_ffff_ffff;
                                        data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        continue;
                                    }
                                }
                            }
                        }
                    },
                    .ldr_fp64_reg_lsl => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const addr = getXOrSp(cpu, rn) +% (getX(cpu, @truncate(d.rm)) << @intCast(d.imm));
                        if ((addr & ~@as(u64, 0xff8)) == data_r_vbase[bank]) {
                            cpu.vfp.v[@as(u5, @truncate(d.rd))] = std.mem.readInt(u64, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xff8))..][0..8], .little);
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xff8 and (addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                data_r_vbase[bank] = dslot.r_vbase;
                                data_r_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                cpu.vfp.v[@as(u5, @truncate(d.rd))] = std.mem.readInt(u64, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..8], .little);
                            } else {
                                cpu.vfp.v[@as(u5, @truncate(d.rd))] = readData64(cpu, bus, addr) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                            }
                        }
                    },
                    .str_fp64_reg_lsl => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const addr = getXOrSp(cpu, rn) +% (getX(cpu, @truncate(d.rm)) << @intCast(d.imm));
                        const val: u64 = @truncate(cpu.vfp.v[@as(u5, @truncate(d.rd))]);
                        if ((addr & ~@as(u64, 0xff8)) == data_w_vbase[bank]) {
                            std.mem.writeInt(u64, data_w_page_ptr[bank][@as(usize, @truncate(addr & 0xff8))..][0..8], val, .little);
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xff8 and (addr & ~@as(u64, 0xfff)) == dslot.w_vbase) {
                                data_w_vbase[bank] = dslot.w_vbase;
                                data_w_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                std.mem.writeInt(u64, data_w_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..8], val, .little);
                            } else {
                                writeData64(cpu, bus, addr, val) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                if ((addr & ~@as(u64, 0xfff)) != dslot.w_vbase) {
                                    if (checkInterrupts64(cpu, bus)) {
                                        priv = 1;
                                        code_vbase = 0xffff_ffff_ffff_ffff;
                                        data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        continue;
                                    }
                                }
                            }
                        }
                    },
                    .ldr_fp128_reg_lsl => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const addr = getXOrSp(cpu, rn) +% (getX(cpu, @truncate(d.rm)) << @intCast(d.imm));
                        if ((addr & 0xfff) <= 0xff0 and (addr & ~@as(u64, 0xfff)) == data_r_vbase[bank]) {
                            cpu.vfp.v[@as(u5, @truncate(d.rd))] = std.mem.readInt(u128, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..16], .little);
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xff0 and (addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                data_r_vbase[bank] = dslot.r_vbase;
                                data_r_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                cpu.vfp.v[@as(u5, @truncate(d.rd))] = std.mem.readInt(u128, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..16], .little);
                            } else {
                                cpu.vfp.v[@as(u5, @truncate(d.rd))] = readData128(cpu, bus, addr) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                            }
                        }
                    },
                    .str_fp128_reg_lsl => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const addr = getXOrSp(cpu, rn) +% (getX(cpu, @truncate(d.rm)) << @intCast(d.imm));
                        const val = cpu.vfp.v[@as(u5, @truncate(d.rd))];
                        if ((addr & 0xfff) <= 0xff0 and (addr & ~@as(u64, 0xfff)) == data_w_vbase[bank]) {
                            std.mem.writeInt(u128, data_w_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..16], val, .little);
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xff0 and (addr & ~@as(u64, 0xfff)) == dslot.w_vbase) {
                                data_w_vbase[bank] = dslot.w_vbase;
                                data_w_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                std.mem.writeInt(u128, data_w_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..16], val, .little);
                            } else {
                                writeData128(cpu, bus, addr, val) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                if ((addr & ~@as(u64, 0xfff)) != dslot.w_vbase) {
                                    if (checkInterrupts64(cpu, bus)) {
                                        priv = 1;
                                        code_vbase = 0xffff_ffff_ffff_ffff;
                                        data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        continue;
                                    }
                                }
                            }
                        }
                    },
                    .ldr_fp64_pre, .ldr_fp64_post => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const base = getXOrSp(cpu, rn);
                        const wb_addr = base +% d.imm;
                        const addr = if (op == .ldr_fp64_post) base else wb_addr;
                        const val: u64 = if ((addr & ~@as(u64, 0xff8)) == data_r_vbase[bank])
                            std.mem.readInt(u64, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xff8))..][0..8], .little)
                        else blk: {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xff8 and (addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                data_r_vbase[bank] = dslot.r_vbase;
                                data_r_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                break :blk std.mem.readInt(u64, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..8], .little);
                            }
                            break :blk readData64(cpu, bus, addr) catch {
                                handleAbort64(cpu, cur_pc);
                                priv = 1;
                                code_vbase = 0xffff_ffff_ffff_ffff;
                                data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                continue;
                            };
                        };
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = val;
                        setXOrSp(cpu, rn, wb_addr);
                    },
                    .str_fp64_pre, .str_fp64_post => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const base = getXOrSp(cpu, rn);
                        const wb_addr = base +% d.imm;
                        const addr = if (op == .str_fp64_post) base else wb_addr;
                        const val: u64 = @truncate(cpu.vfp.v[@as(u5, @truncate(d.rd))]);
                        if ((addr & ~@as(u64, 0xff8)) == data_w_vbase[bank]) {
                            std.mem.writeInt(u64, data_w_page_ptr[bank][@as(usize, @truncate(addr & 0xff8))..][0..8], val, .little);
                            setXOrSp(cpu, rn, wb_addr);
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xff8 and (addr & ~@as(u64, 0xfff)) == dslot.w_vbase) {
                                data_w_vbase[bank] = dslot.w_vbase;
                                data_w_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                std.mem.writeInt(u64, data_w_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..8], val, .little);
                                setXOrSp(cpu, rn, wb_addr);
                            } else {
                                writeData64(cpu, bus, addr, val) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                setXOrSp(cpu, rn, wb_addr);
                                if ((addr & ~@as(u64, 0xfff)) != dslot.w_vbase) {
                                    if (checkInterrupts64(cpu, bus)) {
                                        priv = 1;
                                        code_vbase = 0xffff_ffff_ffff_ffff;
                                        data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        continue;
                                    }
                                }
                            }
                        }
                    },
                    .ldr_fp128_pre, .ldr_fp128_post => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const base = getXOrSp(cpu, rn);
                        const wb_addr = base +% d.imm;
                        const addr = if (op == .ldr_fp128_post) base else wb_addr;
                        if ((addr & 0xfff) <= 0xff0 and (addr & ~@as(u64, 0xfff)) == data_r_vbase[bank]) {
                            cpu.vfp.v[@as(u5, @truncate(d.rd))] = std.mem.readInt(u128, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..16], .little);
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xff0 and (addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                data_r_vbase[bank] = dslot.r_vbase;
                                data_r_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                cpu.vfp.v[@as(u5, @truncate(d.rd))] = std.mem.readInt(u128, data_r_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..16], .little);
                            } else {
                                cpu.vfp.v[@as(u5, @truncate(d.rd))] = readData128(cpu, bus, addr) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                            }
                        }
                        setXOrSp(cpu, rn, wb_addr);
                    },
                    .str_fp128_pre, .str_fp128_post => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const base = getXOrSp(cpu, rn);
                        const wb_addr = base +% d.imm;
                        const addr = if (op == .str_fp128_post) base else wb_addr;
                        const val = cpu.vfp.v[@as(u5, @truncate(d.rd))];
                        if ((addr & 0xfff) <= 0xff0 and (addr & ~@as(u64, 0xfff)) == data_w_vbase[bank]) {
                            std.mem.writeInt(u128, data_w_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..16], val, .little);
                            setXOrSp(cpu, rn, wb_addr);
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xff0 and (addr & ~@as(u64, 0xfff)) == dslot.w_vbase) {
                                data_w_vbase[bank] = dslot.w_vbase;
                                data_w_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                std.mem.writeInt(u128, data_w_page_ptr[bank][@as(usize, @truncate(addr & 0xfff))..][0..16], val, .little);
                                setXOrSp(cpu, rn, wb_addr);
                            } else {
                                writeData128(cpu, bus, addr, val) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                setXOrSp(cpu, rn, wb_addr);
                                if ((addr & ~@as(u64, 0xfff)) != dslot.w_vbase) {
                                    if (checkInterrupts64(cpu, bus)) {
                                        priv = 1;
                                        code_vbase = 0xffff_ffff_ffff_ffff;
                                        data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        continue;
                                    }
                                }
                            }
                        }
                    },
                    .ldp_fp64_off, .ldp_fp64_pre, .ldp_fp64_post => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const base = getXOrSp(cpu, rn);
                        const wb_addr = base +% d.imm;
                        const addr = if (op == .ldp_fp64_post) base else wb_addr;
                        if ((addr & 0xfff) <= 0xff0 and (addr & ~@as(u64, 0xfff)) == data_r_vbase[bank]) {
                            const off: usize = @truncate(addr & 0xfff);
                            const v1 = std.mem.readInt(u64, data_r_page_ptr[bank][off..][0..8], .little);
                            const v2 = std.mem.readInt(u64, data_r_page_ptr[bank][off + 8 ..][0..8], .little);
                            cpu.vfp.v[@as(u5, @truncate(d.rd))] = v1;
                            cpu.vfp.v[@as(u5, @truncate(d.rm))] = v2;
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xff0 and (addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                data_r_vbase[bank] = dslot.r_vbase;
                                data_r_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                const off: usize = @truncate(addr & 0xfff);
                                const v1 = std.mem.readInt(u64, data_r_page_ptr[bank][off..][0..8], .little);
                                const v2 = std.mem.readInt(u64, data_r_page_ptr[bank][off + 8 ..][0..8], .little);
                                cpu.vfp.v[@as(u5, @truncate(d.rd))] = v1;
                                cpu.vfp.v[@as(u5, @truncate(d.rm))] = v2;
                            } else {
                                const pair = readData128(cpu, bus, addr) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                cpu.vfp.v[@as(u5, @truncate(d.rd))] = @as(u64, @truncate(pair));
                                cpu.vfp.v[@as(u5, @truncate(d.rm))] = @as(u64, @truncate(pair >> 64));
                            }
                        }
                        if (op != .ldp_fp64_off) setXOrSp(cpu, rn, wb_addr);
                    },
                    .stp_fp64_off, .stp_fp64_pre, .stp_fp64_post => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const base = getXOrSp(cpu, rn);
                        const wb_addr = base +% d.imm;
                        const addr = if (op == .stp_fp64_post) base else wb_addr;
                        const v1: u64 = @truncate(cpu.vfp.v[@as(u5, @truncate(d.rd))]);
                        const v2: u64 = @truncate(cpu.vfp.v[@as(u5, @truncate(d.rm))]);
                        if ((addr & 0xfff) <= 0xff0 and (addr & ~@as(u64, 0xfff)) == data_w_vbase[bank]) {
                            const off: usize = @truncate(addr & 0xfff);
                            std.mem.writeInt(u64, data_w_page_ptr[bank][off..][0..8], v1, .little);
                            std.mem.writeInt(u64, data_w_page_ptr[bank][off + 8 ..][0..8], v2, .little);
                            if (op != .stp_fp64_off) setXOrSp(cpu, rn, wb_addr);
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xff0 and (addr & ~@as(u64, 0xfff)) == dslot.w_vbase) {
                                data_w_vbase[bank] = dslot.w_vbase;
                                data_w_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                const off: usize = @truncate(addr & 0xfff);
                                std.mem.writeInt(u64, data_w_page_ptr[bank][off..][0..8], v1, .little);
                                std.mem.writeInt(u64, data_w_page_ptr[bank][off + 8 ..][0..8], v2, .little);
                                if (op != .stp_fp64_off) setXOrSp(cpu, rn, wb_addr);
                            } else {
                                writeData128(cpu, bus, addr, @as(u128, v1) | (@as(u128, v2) << 64)) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                if (op != .stp_fp64_off) setXOrSp(cpu, rn, wb_addr);
                                if ((addr & ~@as(u64, 0xfff)) != dslot.w_vbase) {
                                    if (checkInterrupts64(cpu, bus)) {
                                        priv = 1;
                                        code_vbase = 0xffff_ffff_ffff_ffff;
                                        data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        continue;
                                    }
                                }
                            }
                        }
                    },
                    .ldp_fp128_off, .ldp_fp128_pre, .ldp_fp128_post => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const base = getXOrSp(cpu, rn);
                        const wb_addr = base +% d.imm;
                        const addr = if (op == .ldp_fp128_post) base else wb_addr;
                        if ((addr & 0xfff) <= 0xfe0 and (addr & ~@as(u64, 0xfff)) == data_r_vbase[bank]) {
                            const off: usize = @truncate(addr & 0xfff);
                            const v1 = std.mem.readInt(u128, data_r_page_ptr[bank][off..][0..16], .little);
                            const v2 = std.mem.readInt(u128, data_r_page_ptr[bank][off + 16 ..][0..16], .little);
                            cpu.vfp.v[@as(u5, @truncate(d.rd))] = v1;
                            cpu.vfp.v[@as(u5, @truncate(d.rm))] = v2;
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xfe0 and (addr & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                data_r_vbase[bank] = dslot.r_vbase;
                                data_r_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                const off: usize = @truncate(addr & 0xfff);
                                const v1 = std.mem.readInt(u128, data_r_page_ptr[bank][off..][0..16], .little);
                                const v2 = std.mem.readInt(u128, data_r_page_ptr[bank][off + 16 ..][0..16], .little);
                                cpu.vfp.v[@as(u5, @truncate(d.rd))] = v1;
                                cpu.vfp.v[@as(u5, @truncate(d.rm))] = v2;
                            } else {
                                const v1 = readData128(cpu, bus, addr) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                const v2 = readData128(cpu, bus, addr +% 16) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                cpu.vfp.v[@as(u5, @truncate(d.rd))] = v1;
                                cpu.vfp.v[@as(u5, @truncate(d.rm))] = v2;
                            }
                        }
                        if (op != .ldp_fp128_off) setXOrSp(cpu, rn, wb_addr);
                    },
                    .stp_fp128_off, .stp_fp128_pre, .stp_fp128_post => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const base = getXOrSp(cpu, rn);
                        const wb_addr = base +% d.imm;
                        const addr = if (op == .stp_fp128_post) base else wb_addr;
                        const v1 = cpu.vfp.v[@as(u5, @truncate(d.rd))];
                        const v2 = cpu.vfp.v[@as(u5, @truncate(d.rm))];
                        if ((addr & 0xfff) <= 0xfe0 and (addr & ~@as(u64, 0xfff)) == data_w_vbase[bank]) {
                            const off: usize = @truncate(addr & 0xfff);
                            std.mem.writeInt(u128, data_w_page_ptr[bank][off..][0..16], v1, .little);
                            std.mem.writeInt(u128, data_w_page_ptr[bank][off + 16 ..][0..16], v2, .little);
                            if (op != .stp_fp128_off) setXOrSp(cpu, rn, wb_addr);
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((addr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((addr & 0xfff) <= 0xfe0 and (addr & ~@as(u64, 0xfff)) == dslot.w_vbase) {
                                data_w_vbase[bank] = dslot.w_vbase;
                                data_w_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                const off: usize = @truncate(addr & 0xfff);
                                std.mem.writeInt(u128, data_w_page_ptr[bank][off..][0..16], v1, .little);
                                std.mem.writeInt(u128, data_w_page_ptr[bank][off + 16 ..][0..16], v2, .little);
                                if (op != .stp_fp128_off) setXOrSp(cpu, rn, wb_addr);
                            } else {
                                writeData128(cpu, bus, addr, v1) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                writeData128(cpu, bus, addr +% 16, v2) catch {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                };
                                if (op != .stp_fp128_off) setXOrSp(cpu, rn, wb_addr);
                                if ((addr & ~@as(u64, 0xfff)) != dslot.w_vbase) {
                                    if (checkInterrupts64(cpu, bus)) {
                                        priv = 1;
                                        code_vbase = 0xffff_ffff_ffff_ffff;
                                        data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        continue;
                                    }
                                }
                            }
                        }
                    },
                    .simd_ld1_mult => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const base = getXOrSp(cpu, rn);
                        const q = (d.imm & 1) != 0;
                        const rpt: u5 = @truncate(d.imm >> 1);
                        const bytes_per_reg: u64 = if (q) 16 else 8;
                        const total_bytes: u64 = @as(u64, rpt) * bytes_per_reg;
                        const rt: u5 = @truncate(d.rd);
                        if ((base & 0xfff) + total_bytes <= 0x1000 and (base & ~@as(u64, 0xfff)) == data_r_vbase[bank]) {
                            var off: usize = @truncate(base & 0xfff);
                            var r_idx: u5 = 0;
                            while (r_idx < rpt) : (r_idx += 1) {
                                cpu.vfp.v[rt +% r_idx] = if (q)
                                    std.mem.readInt(u128, data_r_page_ptr[bank][off..][0..16], .little)
                                else
                                    std.mem.readInt(u64, data_r_page_ptr[bank][off..][0..8], .little);
                                off += @intCast(bytes_per_reg);
                            }
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((base >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((base & 0xfff) + total_bytes <= 0x1000 and (base & ~@as(u64, 0xfff)) == dslot.r_vbase) {
                                data_r_vbase[bank] = dslot.r_vbase;
                                data_r_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                var off: usize = @truncate(base & 0xfff);
                                var r_idx: u5 = 0;
                                while (r_idx < rpt) : (r_idx += 1) {
                                    cpu.vfp.v[rt +% r_idx] = if (q)
                                        std.mem.readInt(u128, data_r_page_ptr[bank][off..][0..16], .little)
                                    else
                                        std.mem.readInt(u64, data_r_page_ptr[bank][off..][0..8], .little);
                                    off += @intCast(bytes_per_reg);
                                }
                            } else {
                                var addr = base;
                                var aborted = false;
                                var r_idx: u5 = 0;
                                while (r_idx < rpt) : (r_idx += 1) {
                                    if (q) {
                                        cpu.vfp.v[rt +% r_idx] = readData128(cpu, bus, addr) catch {
                                            aborted = true;
                                            break;
                                        };
                                    } else {
                                        cpu.vfp.v[rt +% r_idx] = readData64(cpu, bus, addr) catch {
                                            aborted = true;
                                            break;
                                        };
                                    }
                                    addr +%= bytes_per_reg;
                                }
                                if (aborted) {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                }
                            }
                        }
                        if (d.rm < 32) {
                            const inc: u64 = if (d.rm == 31) total_bytes else getX(cpu, @truncate(d.rm));
                            setXOrSp(cpu, rn, base +% inc);
                        }
                    },
                    .simd_st1_mult => {
                        const rn: u5 = @truncate(d.rn);
                        const bank: usize = @intFromBool(rn >= 29);
                        const base = getXOrSp(cpu, rn);
                        const q = (d.imm & 1) != 0;
                        const rpt: u5 = @truncate(d.imm >> 1);
                        const bytes_per_reg: u64 = if (q) 16 else 8;
                        const total_bytes: u64 = @as(u64, rpt) * bytes_per_reg;
                        const rt: u5 = @truncate(d.rd);
                        if ((base & 0xfff) + total_bytes <= 0x1000 and (base & ~@as(u64, 0xfff)) == data_w_vbase[bank]) {
                            var off: usize = @truncate(base & 0xfff);
                            var r_idx: u5 = 0;
                            while (r_idx < rpt) : (r_idx += 1) {
                                if (q) {
                                    std.mem.writeInt(u128, data_w_page_ptr[bank][off..][0..16], cpu.vfp.v[rt +% r_idx], .little);
                                } else {
                                    std.mem.writeInt(u64, data_w_page_ptr[bank][off..][0..8], @truncate(cpu.vfp.v[rt +% r_idx]), .little);
                                }
                                off += @intCast(bytes_per_reg);
                            }
                            if (d.rm < 32) {
                                const inc: u64 = if (d.rm == 31) total_bytes else getX(cpu, @truncate(d.rm));
                                setXOrSp(cpu, rn, base +% inc);
                            }
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((base >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if ((base & 0xfff) + total_bytes <= 0x1000 and (base & ~@as(u64, 0xfff)) == dslot.w_vbase) {
                                data_w_vbase[bank] = dslot.w_vbase;
                                data_w_page_ptr[bank] = bus.ram.ptr + dslot.pbase;
                                var off: usize = @truncate(base & 0xfff);
                                var r_idx: u5 = 0;
                                while (r_idx < rpt) : (r_idx += 1) {
                                    if (q) {
                                        std.mem.writeInt(u128, data_w_page_ptr[bank][off..][0..16], cpu.vfp.v[rt +% r_idx], .little);
                                    } else {
                                        std.mem.writeInt(u64, data_w_page_ptr[bank][off..][0..8], @truncate(cpu.vfp.v[rt +% r_idx]), .little);
                                    }
                                    off += @intCast(bytes_per_reg);
                                }
                                if (d.rm < 32) {
                                    const inc: u64 = if (d.rm == 31) total_bytes else getX(cpu, @truncate(d.rm));
                                    setXOrSp(cpu, rn, base +% inc);
                                }
                            } else {
                                var addr = base;
                                var aborted = false;
                                var r_idx: u5 = 0;
                                while (r_idx < rpt) : (r_idx += 1) {
                                    if (q) {
                                        writeData128(cpu, bus, addr, cpu.vfp.v[rt +% r_idx]) catch {
                                            aborted = true;
                                            break;
                                        };
                                    } else {
                                        writeData64(cpu, bus, addr, @truncate(cpu.vfp.v[rt +% r_idx])) catch {
                                            aborted = true;
                                            break;
                                        };
                                    }
                                    addr +%= bytes_per_reg;
                                }
                                if (aborted) {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                }
                                if (d.rm < 32) {
                                    const inc: u64 = if (d.rm == 31) total_bytes else getX(cpu, @truncate(d.rm));
                                    setXOrSp(cpu, rn, base +% inc);
                                }
                                if ((base & ~@as(u64, 0xfff)) != dslot.w_vbase) {
                                    if (checkInterrupts64(cpu, bus)) {
                                        priv = 1;
                                        code_vbase = 0xffff_ffff_ffff_ffff;
                                        data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                        continue;
                                    }
                                }
                            }
                        }
                    },
                    .b_imm => {
                        const target_pc = cur_pc +% d.imm;
                        cpu.pc64 = target_pc;
                        noteBackwardBranch64(cpu, SlotType, code_vbase, code_page_idx, code_icache_ptr, code_page_ptr, cur_pc, target_pc, @intCast(page_word + 1));
                    },
                    .bl_imm => {
                        cpu.x[30] = cur_pc +% 4;
                        cpu.pc64 = cur_pc +% d.imm;
                    },
                    .b_cond => {
                        if (evalCond(cpu.pstate, @truncate(d.rd))) {
                            const target_pc = cur_pc +% d.imm;
                            cpu.pc64 = target_pc;
                            noteBackwardBranch64(cpu, SlotType, code_vbase, code_page_idx, code_icache_ptr, code_page_ptr, cur_pc, target_pc, @intCast(page_word + 1));
                        }
                    },
                    .cbz64 => {
                        if (getX(cpu, @truncate(d.rd)) == 0) {
                            const target_pc = cur_pc +% d.imm;
                            cpu.pc64 = target_pc;
                            noteBackwardBranch64(cpu, SlotType, code_vbase, code_page_idx, code_icache_ptr, code_page_ptr, cur_pc, target_pc, @intCast(page_word + 1));
                        }
                    },
                    .cbnz64 => {
                        if (getX(cpu, @truncate(d.rd)) != 0) {
                            const target_pc = cur_pc +% d.imm;
                            cpu.pc64 = target_pc;
                            noteBackwardBranch64(cpu, SlotType, code_vbase, code_page_idx, code_icache_ptr, code_page_ptr, cur_pc, target_pc, @intCast(page_word + 1));
                        }
                    },
                    .cbz32 => {
                        if (getW(cpu, @truncate(d.rd)) == 0) {
                            const target_pc = cur_pc +% d.imm;
                            cpu.pc64 = target_pc;
                            noteBackwardBranch64(cpu, SlotType, code_vbase, code_page_idx, code_icache_ptr, code_page_ptr, cur_pc, target_pc, @intCast(page_word + 1));
                        }
                    },
                    .cbnz32 => {
                        if (getW(cpu, @truncate(d.rd)) != 0) {
                            const target_pc = cur_pc +% d.imm;
                            cpu.pc64 = target_pc;
                            noteBackwardBranch64(cpu, SlotType, code_vbase, code_page_idx, code_icache_ptr, code_page_ptr, cur_pc, target_pc, @intCast(page_word + 1));
                        }
                    },
                    .tbz => {
                        if (((getX(cpu, @truncate(d.rd)) >> @intCast(d.rm)) & 1) == 0) {
                            const target_pc = cur_pc +% d.imm;
                            cpu.pc64 = target_pc;
                            noteBackwardBranch64(cpu, SlotType, code_vbase, code_page_idx, code_icache_ptr, code_page_ptr, cur_pc, target_pc, @intCast(page_word + 1));
                        }
                    },
                    .tbnz => {
                        if (((getX(cpu, @truncate(d.rd)) >> @intCast(d.rm)) & 1) != 0) {
                            const target_pc = cur_pc +% d.imm;
                            cpu.pc64 = target_pc;
                            noteBackwardBranch64(cpu, SlotType, code_vbase, code_page_idx, code_icache_ptr, code_page_ptr, cur_pc, target_pc, @intCast(page_word + 1));
                        }
                    },
                    .br_reg => cpu.pc64 = getX(cpu, @truncate(d.rn)),
                    .blr_reg => {
                        const target = getX(cpu, @truncate(d.rn));
                        cpu.x[30] = cur_pc +% 4;
                        cpu.pc64 = target;
                    },
                    .ret => cpu.pc64 = getX(cpu, @truncate(d.rn)),
                    .dp_imm_other => executeDpImm(cpu, inst, cur_pc),
                    .dp_reg_other => executeDpReg(cpu, inst),
                    .load_store_other => {
                        executeLoadStore(cpu, bus, inst, cur_pc) catch {
                            handleAbort64(cpu, cur_pc);
                            priv = 1;
                            code_vbase = 0xffff_ffff_ffff_ffff;
                            data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                            data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                            continue;
                        };
                        if (checkInterrupts64(cpu, bus)) {
                            priv = 1;
                            code_vbase = 0xffff_ffff_ffff_ffff;
                            data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                            data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                            continue;
                        }
                    },
                    .mrs_tpidr_el0 => setX(cpu, @truncate(d.rd), cpu.mmu.tpidr_el0),
                    .mrs_sys => {
                        setX(
                            cpu,
                            @truncate(d.rd),
                            readSysReg(cpu, @truncate(d.rn >> 3), @truncate(d.rn), @truncate(d.rm >> 4), @truncate(d.rm), @truncate(d.imm)),
                        );
                        if (cpu.yield_slice) break :step_loop;
                    },
                    .msr_safe => {
                        switch (d.rn) {
                            0 => cpu.excl_valid = false,
                            1 => {
                                cpu.yield_slice = true;
                                break :step_loop;
                            },
                            2 => {
                                if (atomic_ram.busParallel(bus)) {
                                    atomic_ram.fence(&cpu.fence_word);
                                    if (d.imm == 4) bus.smp.broadcastTlb(cpu.mmu.core_id, &cpu.mmu);
                                }
                                const pc32: u32 = @truncate(cur_pc);
                                if ((cpu.last_dmb_pc ^ pc32) < 256) {
                                    cpu.yield_slice = true;
                                    cpu.last_dmb_pc = pc32;
                                    break :step_loop;
                                }
                                cpu.last_dmb_pc = pc32;
                            },
                            3 => cpu.pstate |= @truncate(d.imm),
                            4 => {
                                cpu.pstate &= @truncate(d.imm);
                                if (checkInterrupts64(cpu, bus)) {
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                }
                            },
                            5 => {
                                cpu.pstate = (cpu.pstate & ~@as(u32, 0x3c0)) | (@as(u32, @truncate(getX(cpu, @truncate(d.rd)))) & 0x3c0);
                                if (checkInterrupts64(cpu, bus)) {
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                }
                            },
                            6 => cpu.pstate = (cpu.pstate & 0x0fff_ffff) | (@as(u32, @truncate(getX(cpu, @truncate(d.rd)))) & 0xf000_0000),
                            7 => cpu.mmu.tpidr_el0 = getX(cpu, @truncate(d.rd)),
                            8 => cpu.mmu.tpidr_el1 = getX(cpu, @truncate(d.rd)),
                            9 => cpu.sp_el[0] = getX(cpu, @truncate(d.rd)),
                            11 => {
                                cpu.invalidateIcache();
                                code_vbase = 0xffff_ffff_ffff_ffff;
                            },
                            else => {
                                if (d.imm == 0) cpu.vfp.fpcr64 = getX(cpu, @truncate(d.rd)) else cpu.vfp.fpsr64 = getX(cpu, @truncate(d.rd));
                            },
                        }
                    },
                    .dc_zva => {
                        const base_va = getX(cpu, @truncate(d.rd)) & ~@as(u64, 63);
                        const vbase = base_va & ~@as(u64, 0xfff);
                        if (vbase == data_w_vbase[0]) {
                            @memset(data_w_page_ptr[0][@as(usize, @truncate(base_va & 0xfff))..][0..64], 0);
                        } else {
                            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((base_va >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                            if (vbase == dslot.w_vbase) {
                                data_w_vbase[0] = dslot.w_vbase;
                                data_w_page_ptr[0] = bus.ram.ptr + dslot.pbase;
                                @memset(data_w_page_ptr[0][@as(usize, @truncate(base_va & 0xfff))..][0..64], 0);
                            } else {
                                var aborted = false;
                                var off: u64 = 0;
                                while (off < 64) : (off += 8) {
                                    writeData64(cpu, bus, base_va +% off, 0) catch {
                                        aborted = true;
                                        break;
                                    };
                                }
                                if (aborted) {
                                    handleAbort64(cpu, cur_pc);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff_ffff_ffff;
                                    data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                    continue;
                                }
                                if (vbase == dslot.w_vbase) {
                                    data_w_vbase[0] = dslot.w_vbase;
                                    data_w_page_ptr[0] = bus.ram.ptr + dslot.pbase;
                                }
                            }
                        }
                    },
                    .branch_sys_other => {
                        executeBranchSys(cpu, bus, inst, cur_pc) catch {
                            handleAbort64(cpu, cur_pc);
                            priv = 1;
                            code_vbase = 0xffff_ffff_ffff_ffff;
                            data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                            data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                            continue;
                        };
                        if (checkInterrupts64(cpu, bus)) {
                            priv = 1;
                            code_vbase = 0xffff_ffff_ffff_ffff;
                            data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                            data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                            continue;
                        }
                        priv = @intFromBool(currentEl(cpu) != 0);
                        code_vbase = 0xffff_ffff_ffff_ffff;
                        data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                        data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                        if (cpu.mmu.halted_wfi or cpu.yield_slice or !cpu.is_aarch64) break :step_loop;
                    },
                    .fmov_d_x => cpu.vfp.v[@as(u5, @truncate(d.rd))] = getX(cpu, @truncate(d.rn)),
                    .fmov_x_d => setX(cpu, @truncate(d.rd), @truncate(cpu.vfp.v[@as(u5, @truncate(d.rn))])),
                    .fmov_s_w => cpu.vfp.v[@as(u5, @truncate(d.rd))] = getW(cpu, @truncate(d.rn)),
                    .fmov_w_s => setW(cpu, @truncate(d.rd), @truncate(cpu.vfp.v[@as(u5, @truncate(d.rn))])),
                    .fmov_d_hi_x => {
                        const rd_idx: u5 = @truncate(d.rd);
                        cpu.vfp.v[rd_idx] = (cpu.vfp.v[rd_idx] & 0xffff_ffff_ffff_ffff) | (@as(u128, getX(cpu, @truncate(d.rn))) << 64);
                    },
                    .fmov_x_d_hi => setX(cpu, @truncate(d.rd), @truncate(cpu.vfp.v[@as(u5, @truncate(d.rn))] >> 64)),
                    .fmov_f64 => cpu.vfp.v[@as(u5, @truncate(d.rd))] = @as(u64, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rn))])),
                    .fmov_f32 => cpu.vfp.v[@as(u5, @truncate(d.rd))] = @as(u32, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rn))])),
                    .fabs_f64 => cpu.vfp.v[@as(u5, @truncate(d.rd))] = @as(u64, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rn))])) & 0x7fff_ffff_ffff_ffff,
                    .fneg_f64 => cpu.vfp.v[@as(u5, @truncate(d.rd))] = @as(u64, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rn))])) ^ 0x8000_0000_0000_0000,
                    .fabs_f32 => cpu.vfp.v[@as(u5, @truncate(d.rd))] = @as(u32, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rn))])) & 0x7fff_ffff,
                    .fneg_f32 => cpu.vfp.v[@as(u5, @truncate(d.rd))] = @as(u32, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rn))])) ^ 0x8000_0000,
                    .fcvt_s_d => {
                        const a: f64 = @bitCast(@as(u64, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rn))])));
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = @as(u32, @bitCast(@as(f32, @floatCast(a))));
                    },
                    .fcvt_d_s => {
                        const a: f32 = @bitCast(@as(u32, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rn))])));
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = @as(u64, @bitCast(@as(f64, a)));
                    },
                    .fadd_f64 => {
                        const a: f64 = @bitCast(@as(u64, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rn))])));
                        const b: f64 = @bitCast(@as(u64, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rm))])));
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = @as(u64, @bitCast(a + b));
                    },
                    .fsub_f64 => {
                        const a: f64 = @bitCast(@as(u64, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rn))])));
                        const b: f64 = @bitCast(@as(u64, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rm))])));
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = @as(u64, @bitCast(a - b));
                    },
                    .fmul_f64 => {
                        const a: f64 = @bitCast(@as(u64, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rn))])));
                        const b: f64 = @bitCast(@as(u64, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rm))])));
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = @as(u64, @bitCast(a * b));
                    },
                    .fdiv_f64 => {
                        const a: f64 = @bitCast(@as(u64, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rn))])));
                        const b: f64 = @bitCast(@as(u64, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rm))])));
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = @as(u64, @bitCast(a / b));
                    },
                    .fadd_f32 => {
                        const a: f32 = @bitCast(@as(u32, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rn))])));
                        const b: f32 = @bitCast(@as(u32, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rm))])));
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = @as(u32, @bitCast(a + b));
                    },
                    .fsub_f32 => {
                        const a: f32 = @bitCast(@as(u32, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rn))])));
                        const b: f32 = @bitCast(@as(u32, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rm))])));
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = @as(u32, @bitCast(a - b));
                    },
                    .fmul_f32 => {
                        const a: f32 = @bitCast(@as(u32, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rn))])));
                        const b: f32 = @bitCast(@as(u32, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rm))])));
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = @as(u32, @bitCast(a * b));
                    },
                    .fdiv_f32 => {
                        const a: f32 = @bitCast(@as(u32, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rn))])));
                        const b: f32 = @bitCast(@as(u32, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rm))])));
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = @as(u32, @bitCast(a / b));
                    },
                    .fmadd_f64 => {
                        const n: f64 = @bitCast(@as(u64, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rn))])));
                        const m: f64 = @bitCast(@as(u64, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rm))])));
                        const a: f64 = @bitCast(@as(u64, @truncate(cpu.vfp.v[@as(u5, @truncate(d.imm))])));
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = @as(u64, @bitCast(a + (n * m)));
                    },
                    .fmsub_f64 => {
                        const n: f64 = @bitCast(@as(u64, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rn))])));
                        const m: f64 = @bitCast(@as(u64, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rm))])));
                        const a: f64 = @bitCast(@as(u64, @truncate(cpu.vfp.v[@as(u5, @truncate(d.imm))])));
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = @as(u64, @bitCast(a - (n * m)));
                    },
                    .fmadd_f32 => {
                        const n: f32 = @bitCast(@as(u32, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rn))])));
                        const m: f32 = @bitCast(@as(u32, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rm))])));
                        const a: f32 = @bitCast(@as(u32, @truncate(cpu.vfp.v[@as(u5, @truncate(d.imm))])));
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = @as(u32, @bitCast(a + (n * m)));
                    },
                    .fmsub_f32 => {
                        const n: f32 = @bitCast(@as(u32, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rn))])));
                        const m: f32 = @bitCast(@as(u32, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rm))])));
                        const a: f32 = @bitCast(@as(u32, @truncate(cpu.vfp.v[@as(u5, @truncate(d.imm))])));
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = @as(u32, @bitCast(a - (n * m)));
                    },
                    .fcmp_f64, .fcmpz_f64 => {
                        const a: f64 = @bitCast(@as(u64, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rn))])));
                        const b: f64 = if (op == .fcmpz_f64) 0.0 else @bitCast(@as(u64, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rm))])));
                        if (std.math.isNan(a) or std.math.isNan(b)) {
                            setNzcv(cpu, false, false, true, true);
                        } else if (a == b) {
                            setNzcv(cpu, false, true, true, false);
                        } else if (a < b) {
                            setNzcv(cpu, true, false, false, false);
                        } else {
                            setNzcv(cpu, false, false, true, false);
                        }
                    },
                    .fcmp_f32, .fcmpz_f32 => {
                        const a: f32 = @bitCast(@as(u32, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rn))])));
                        const b: f32 = if (op == .fcmpz_f32) 0.0 else @bitCast(@as(u32, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rm))])));
                        if (std.math.isNan(a) or std.math.isNan(b)) {
                            setNzcv(cpu, false, false, true, true);
                        } else if (a == b) {
                            setNzcv(cpu, false, true, true, false);
                        } else if (a < b) {
                            setNzcv(cpu, true, false, false, false);
                        } else {
                            setNzcv(cpu, false, false, true, false);
                        }
                    },
                    .simd_movi => cpu.vfp.v[@as(u5, @truncate(d.rd))] = if (d.rn != 0) (@as(u128, d.imm) | (@as(u128, d.imm) << 64)) else d.imm,
                    .simd_and => {
                        const mask: u128 = if (d.imm != 0) ~@as(u128, 0) else 0xffff_ffff_ffff_ffff;
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = (cpu.vfp.v[@as(u5, @truncate(d.rn))] & cpu.vfp.v[@as(u5, @truncate(d.rm))]) & mask;
                    },
                    .simd_bic => {
                        const mask: u128 = if (d.imm != 0) ~@as(u128, 0) else 0xffff_ffff_ffff_ffff;
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = (cpu.vfp.v[@as(u5, @truncate(d.rn))] & ~cpu.vfp.v[@as(u5, @truncate(d.rm))]) & mask;
                    },
                    .simd_orr => {
                        const mask: u128 = if (d.imm != 0) ~@as(u128, 0) else 0xffff_ffff_ffff_ffff;
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = (cpu.vfp.v[@as(u5, @truncate(d.rn))] | cpu.vfp.v[@as(u5, @truncate(d.rm))]) & mask;
                    },
                    .simd_orn => {
                        const mask: u128 = if (d.imm != 0) ~@as(u128, 0) else 0xffff_ffff_ffff_ffff;
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = (cpu.vfp.v[@as(u5, @truncate(d.rn))] | ~cpu.vfp.v[@as(u5, @truncate(d.rm))]) & mask;
                    },
                    .simd_eor => {
                        const mask: u128 = if (d.imm != 0) ~@as(u128, 0) else 0xffff_ffff_ffff_ffff;
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = (cpu.vfp.v[@as(u5, @truncate(d.rn))] ^ cpu.vfp.v[@as(u5, @truncate(d.rm))]) & mask;
                    },
                    .simd_bsl => {
                        const mask: u128 = if (d.imm != 0) ~@as(u128, 0) else 0xffff_ffff_ffff_ffff;
                        const rd_idx: u5 = @truncate(d.rd);
                        const vd = cpu.vfp.v[rd_idx];
                        const va = cpu.vfp.v[@as(u5, @truncate(d.rn))];
                        const vb = cpu.vfp.v[@as(u5, @truncate(d.rm))];
                        cpu.vfp.v[rd_idx] = ((va & vd) | (vb & ~vd)) & mask;
                    },
                    .simd_not => {
                        const mask: u128 = if (d.imm != 0) ~@as(u128, 0) else 0xffff_ffff_ffff_ffff;
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = (~cpu.vfp.v[@as(u5, @truncate(d.rn))]) & mask;
                    },
                    .simd_dup_gpr => {
                        const gval = getX(cpu, @truncate(d.rn));
                        const rep64: u64 = switch (d.rm) {
                            1 => (@as(u64, @as(u8, @truncate(gval))) * 0x0101_0101_0101_0101),
                            2 => (@as(u64, @as(u16, @truncate(gval))) * 0x0001_0001_0001_0001),
                            4 => (@as(u64, @as(u32, @truncate(gval))) * 0x0000_0001_0000_0001),
                            else => gval,
                        };
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = if (d.imm != 0) (@as(u128, rep64) | (@as(u128, rep64) << 64)) else @as(u128, rep64);
                    },
                    .simd_dup_elem => {
                        const elem: u64 = @truncate(cpu.vfp.v[@as(u5, @truncate(d.rn))] >> @as(u7, @truncate(d.rm)));
                        const esize_bytes: u8 = @truncate(d.imm >> 1);
                        const rep64: u64 = switch (esize_bytes) {
                            1 => (@as(u64, @as(u8, @truncate(elem))) * 0x0101_0101_0101_0101),
                            2 => (@as(u64, @as(u16, @truncate(elem))) * 0x0001_0001_0001_0001),
                            4 => (@as(u64, @as(u32, @truncate(elem))) * 0x0000_0001_0000_0001),
                            else => elem,
                        };
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = if ((d.imm & 1) != 0) (@as(u128, rep64) | (@as(u128, rep64) << 64)) else @as(u128, rep64);
                    },
                    .simd_umov32 => {
                        const elem: u32 = @truncate(cpu.vfp.v[@as(u5, @truncate(d.rn))] >> @as(u7, @truncate(d.rm)));
                        setW(cpu, @truncate(d.rd), elem);
                    },
                    .simd_umov64 => {
                        const elem: u64 = @truncate(cpu.vfp.v[@as(u5, @truncate(d.rn))] >> @as(u7, @truncate(d.rm)));
                        setX(cpu, @truncate(d.rd), elem);
                    },
                    .simd_add_8 => {
                        const mask: u128 = if (d.imm != 0) ~@as(u128, 0) else 0xffff_ffff_ffff_ffff;
                        const va: @Vector(16, u8) = @bitCast(cpu.vfp.v[@as(u5, @truncate(d.rn))]);
                        const vb: @Vector(16, u8) = @bitCast(cpu.vfp.v[@as(u5, @truncate(d.rm))]);
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = @as(u128, @bitCast(va +% vb)) & mask;
                    },
                    .simd_sub_8 => {
                        const mask: u128 = if (d.imm != 0) ~@as(u128, 0) else 0xffff_ffff_ffff_ffff;
                        const va: @Vector(16, u8) = @bitCast(cpu.vfp.v[@as(u5, @truncate(d.rn))]);
                        const vb: @Vector(16, u8) = @bitCast(cpu.vfp.v[@as(u5, @truncate(d.rm))]);
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = @as(u128, @bitCast(va -% vb)) & mask;
                    },
                    .simd_add_16 => {
                        const mask: u128 = if (d.imm != 0) ~@as(u128, 0) else 0xffff_ffff_ffff_ffff;
                        const va: @Vector(8, u16) = @bitCast(cpu.vfp.v[@as(u5, @truncate(d.rn))]);
                        const vb: @Vector(8, u16) = @bitCast(cpu.vfp.v[@as(u5, @truncate(d.rm))]);
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = @as(u128, @bitCast(va +% vb)) & mask;
                    },
                    .simd_sub_16 => {
                        const mask: u128 = if (d.imm != 0) ~@as(u128, 0) else 0xffff_ffff_ffff_ffff;
                        const va: @Vector(8, u16) = @bitCast(cpu.vfp.v[@as(u5, @truncate(d.rn))]);
                        const vb: @Vector(8, u16) = @bitCast(cpu.vfp.v[@as(u5, @truncate(d.rm))]);
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = @as(u128, @bitCast(va -% vb)) & mask;
                    },
                    .simd_add_32 => {
                        const mask: u128 = if (d.imm != 0) ~@as(u128, 0) else 0xffff_ffff_ffff_ffff;
                        const va: @Vector(4, u32) = @bitCast(cpu.vfp.v[@as(u5, @truncate(d.rn))]);
                        const vb: @Vector(4, u32) = @bitCast(cpu.vfp.v[@as(u5, @truncate(d.rm))]);
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = @as(u128, @bitCast(va +% vb)) & mask;
                    },
                    .simd_sub_32 => {
                        const mask: u128 = if (d.imm != 0) ~@as(u128, 0) else 0xffff_ffff_ffff_ffff;
                        const va: @Vector(4, u32) = @bitCast(cpu.vfp.v[@as(u5, @truncate(d.rn))]);
                        const vb: @Vector(4, u32) = @bitCast(cpu.vfp.v[@as(u5, @truncate(d.rm))]);
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = @as(u128, @bitCast(va -% vb)) & mask;
                    },
                    .simd_add_64 => {
                        const mask: u128 = if (d.imm != 0) ~@as(u128, 0) else 0xffff_ffff_ffff_ffff;
                        const va: @Vector(2, u64) = @bitCast(cpu.vfp.v[@as(u5, @truncate(d.rn))]);
                        const vb: @Vector(2, u64) = @bitCast(cpu.vfp.v[@as(u5, @truncate(d.rm))]);
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = @as(u128, @bitCast(va +% vb)) & mask;
                    },
                    .simd_sub_64 => {
                        const mask: u128 = if (d.imm != 0) ~@as(u128, 0) else 0xffff_ffff_ffff_ffff;
                        const va: @Vector(2, u64) = @bitCast(cpu.vfp.v[@as(u5, @truncate(d.rn))]);
                        const vb: @Vector(2, u64) = @bitCast(cpu.vfp.v[@as(u5, @truncate(d.rm))]);
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = @as(u128, @bitCast(va -% vb)) & mask;
                    },
                    .simd_cmeq_8 => {
                        const mask: u128 = if (d.imm != 0) ~@as(u128, 0) else 0xffff_ffff_ffff_ffff;
                        const va: @Vector(16, u8) = @bitCast(cpu.vfp.v[@as(u5, @truncate(d.rn))]);
                        const vb: @Vector(16, u8) = @bitCast(cpu.vfp.v[@as(u5, @truncate(d.rm))]);
                        const zero: @Vector(16, u8) = @splat(0);
                        const ones: @Vector(16, u8) = @splat(0xff);
                        const res: @Vector(16, u8) = @select(u8, va == vb, ones, zero);
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = @as(u128, @bitCast(res)) & mask;
                    },
                    .simd_cmeqz_8 => {
                        const mask: u128 = if (d.imm != 0) ~@as(u128, 0) else 0xffff_ffff_ffff_ffff;
                        const va: @Vector(16, u8) = @bitCast(cpu.vfp.v[@as(u5, @truncate(d.rn))]);
                        const zero: @Vector(16, u8) = @splat(0);
                        const ones: @Vector(16, u8) = @splat(0xff);
                        const res: @Vector(16, u8) = @select(u8, va == zero, ones, zero);
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = @as(u128, @bitCast(res)) & mask;
                    },
                    .simd_cmtst_8 => {
                        const mask: u128 = if (d.imm != 0) ~@as(u128, 0) else 0xffff_ffff_ffff_ffff;
                        const va: @Vector(16, u8) = @bitCast(cpu.vfp.v[@as(u5, @truncate(d.rn))]);
                        const vb: @Vector(16, u8) = @bitCast(cpu.vfp.v[@as(u5, @truncate(d.rm))]);
                        const zero: @Vector(16, u8) = @splat(0);
                        const ones: @Vector(16, u8) = @splat(0xff);
                        const res: @Vector(16, u8) = @select(u8, (va & vb) != zero, ones, zero);
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = @as(u128, @bitCast(res)) & mask;
                    },
                    .simd_ext_q => {
                        const va = cpu.vfp.v[@as(u5, @truncate(d.rn))];
                        const vb = cpu.vfp.v[@as(u5, @truncate(d.rm))];
                        const sh: u7 = @truncate(d.imm);
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = if (sh == 0) va else ((va >> sh) | (vb << @intCast(@as(u8, 128) - sh)));
                    },
                    .simd_ext_d => {
                        const va: u128 = @as(u64, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rn))]));
                        const vb: u128 = @as(u64, @truncate(cpu.vfp.v[@as(u5, @truncate(d.rm))]));
                        const sh: u7 = @truncate(d.imm);
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = ((va | (vb << 64)) >> sh) & 0xffff_ffff_ffff_ffff;
                    },
                    .simd_ushr => {
                        const va = cpu.vfp.v[@as(u5, @truncate(d.rn))];
                        const sh: u7 = @truncate(d.rm & 0x3f);
                        const mask128: u128 = if ((d.rm & 0x40) != 0) (@as(u128, d.imm) | (@as(u128, d.imm) << 64)) else d.imm;
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = (va >> sh) & mask128;
                    },
                    .simd_shl => {
                        const va = cpu.vfp.v[@as(u5, @truncate(d.rn))];
                        const sh: u7 = @truncate(d.rm & 0x3f);
                        const mask128: u128 = if ((d.rm & 0x40) != 0) (@as(u128, d.imm) | (@as(u128, d.imm) << 64)) else d.imm;
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = (va << sh) & mask128;
                    },
                    .fcvt_int => {
                        const is_dbl = (d.imm & 1) != 0;
                        const sf = ((d.imm >> 1) & 1) != 0;
                        const opcode: u3 = @truncate(d.imm >> 2);
                        const rd_idx: u5 = @truncate(d.rd);
                        const rn_idx: u5 = @truncate(d.rn);
                        if (opcode == 0b010) { // SCVTF
                            const iv: f64 = if (sf) @floatFromInt(@as(i64, @bitCast(getX(cpu, rn_idx)))) else @floatFromInt(@as(i32, @bitCast(getW(cpu, rn_idx))));
                            cpu.vfp.v[rd_idx] = if (is_dbl) @as(u64, @bitCast(iv)) else @as(u32, @bitCast(@as(f32, @floatCast(iv))));
                        } else if (opcode == 0b011) { // UCVTF
                            const uv: f64 = if (sf) @floatFromInt(getX(cpu, rn_idx)) else @floatFromInt(getW(cpu, rn_idx));
                            cpu.vfp.v[rd_idx] = if (is_dbl) @as(u64, @bitCast(uv)) else @as(u32, @bitCast(@as(f32, @floatCast(uv))));
                        } else { // FCVTZS (0b000) / FCVTZU (0b001)
                            const raw_fv: f64 = if (is_dbl) @bitCast(@as(u64, @truncate(cpu.vfp.v[rn_idx]))) else @as(f64, @as(f32, @bitCast(@as(u32, @truncate(cpu.vfp.v[rn_idx])))));
                            const fv = @trunc(raw_fv);
                            if (std.math.isNan(fv)) {
                                if (sf) setX(cpu, rd_idx, 0) else setW(cpu, rd_idx, 0);
                            } else if (opcode == 0b000) {
                                if (sf) {
                                    const clamped = std.math.clamp(fv, -9223372036854775808.0, 9223372036854774784.0);
                                    setX(cpu, rd_idx, @bitCast(@as(i64, @intFromFloat(clamped))));
                                } else {
                                    const clamped = std.math.clamp(fv, -2147483648.0, 2147483647.0);
                                    setW(cpu, rd_idx, @bitCast(@as(i32, @intFromFloat(clamped))));
                                }
                            } else {
                                if (sf) {
                                    const clamped = std.math.clamp(fv, 0.0, 18446744073709549568.0);
                                    setX(cpu, rd_idx, @intFromFloat(clamped));
                                } else {
                                    const clamped = std.math.clamp(fv, 0.0, 4294967295.0);
                                    setW(cpu, rd_idx, @intFromFloat(clamped));
                                }
                            }
                        }
                    },
                    .fop_misc => {
                        const is_dbl = (d.imm & 1) != 0;
                        const sub_op: u3 = @truncate((d.imm >> 1) & 7);
                        const rd_idx: u5 = @truncate(d.rd);
                        const rn_idx: u5 = @truncate(d.rn);
                        const rm_idx: u5 = @truncate(d.rm);
                        if (sub_op == 4) { // FCSEL
                            const cond: u4 = @truncate(d.imm >> 4);
                            const sel = if (evalCond(cpu.pstate, cond)) cpu.vfp.v[rn_idx] else cpu.vfp.v[rm_idx];
                            cpu.vfp.v[rd_idx] = if (is_dbl) @as(u64, @truncate(sel)) else @as(u32, @truncate(sel));
                        } else if (is_dbl) {
                            const a: f64 = @bitCast(@as(u64, @truncate(cpu.vfp.v[rn_idx])));
                            if (sub_op == 0) {
                                cpu.vfp.v[rd_idx] = @as(u64, @bitCast(@sqrt(a)));
                            } else {
                                const b: f64 = @bitCast(@as(u64, @truncate(cpu.vfp.v[rm_idx])));
                                const res: f64 = switch (sub_op) {
                                    1 => @max(a, b),
                                    2 => @min(a, b),
                                    else => -(a * b),
                                };
                                cpu.vfp.v[rd_idx] = @as(u64, @bitCast(res));
                            }
                        } else {
                            const a: f32 = @bitCast(@as(u32, @truncate(cpu.vfp.v[rn_idx])));
                            if (sub_op == 0) {
                                cpu.vfp.v[rd_idx] = @as(u32, @bitCast(@sqrt(a)));
                            } else {
                                const b: f32 = @bitCast(@as(u32, @truncate(cpu.vfp.v[rm_idx])));
                                const res: f32 = switch (sub_op) {
                                    1 => @max(a, b),
                                    2 => @min(a, b),
                                    else => -(a * b),
                                };
                                cpu.vfp.v[rd_idx] = @as(u32, @bitCast(res));
                            }
                        }
                    },
                    .simd_mul_mla => {
                        const mask: u128 = if ((d.imm & 1) != 0) ~@as(u128, 0) else 0xffff_ffff_ffff_ffff;
                        const kind: u2 = @truncate((d.imm >> 1) & 3);
                        const size: u2 = @truncate(d.imm >> 3);
                        const rd_idx: u5 = @truncate(d.rd);
                        const raw_a = cpu.vfp.v[@as(u5, @truncate(d.rn))];
                        const raw_b = cpu.vfp.v[@as(u5, @truncate(d.rm))];
                        const raw_d = cpu.vfp.v[rd_idx];
                        const res128: u128 = switch (size) {
                            0 => blk: {
                                const va: @Vector(16, u8) = @bitCast(raw_a);
                                const vb: @Vector(16, u8) = @bitCast(raw_b);
                                const prod = va *% vb;
                                if (kind == 0) break :blk @bitCast(prod);
                                const vd: @Vector(16, u8) = @bitCast(raw_d);
                                break :blk @bitCast(if (kind == 1) (vd +% prod) else (vd -% prod));
                            },
                            1 => blk: {
                                const va: @Vector(8, u16) = @bitCast(raw_a);
                                const vb: @Vector(8, u16) = @bitCast(raw_b);
                                const prod = va *% vb;
                                if (kind == 0) break :blk @bitCast(prod);
                                const vd: @Vector(8, u16) = @bitCast(raw_d);
                                break :blk @bitCast(if (kind == 1) (vd +% prod) else (vd -% prod));
                            },
                            else => blk: {
                                const va: @Vector(4, u32) = @bitCast(raw_a);
                                const vb: @Vector(4, u32) = @bitCast(raw_b);
                                const prod = va *% vb;
                                if (kind == 0) break :blk @bitCast(prod);
                                const vd: @Vector(4, u32) = @bitCast(raw_d);
                                break :blk @bitCast(if (kind == 1) (vd +% prod) else (vd -% prod));
                            },
                        };
                        cpu.vfp.v[rd_idx] = res128 & mask;
                    },
                    .simd_xtn_shrn => {
                        const q = (d.imm & 1) != 0;
                        const round: u64 = d.imm >> 1;
                        const size: u2 = @truncate(d.rm & 3);
                        const rshift: u6 = @truncate(d.rm >> 2);
                        const va = cpu.vfp.v[@as(u5, @truncate(d.rn))];
                        const rd_idx: u5 = @truncate(d.rd);
                        const narrow64: u64 = switch (size) {
                            0 => blk: {
                                const v16: @Vector(8, u16) = @bitCast(va);
                                const rvec: @Vector(8, u16) = @splat(@truncate(round));
                                const shvec: @Vector(8, u4) = @splat(@truncate(rshift));
                                const narrow: @Vector(8, u8) = @truncate((v16 +% rvec) >> shvec);
                                break :blk @bitCast(narrow);
                            },
                            1 => blk: {
                                const v32: @Vector(4, u32) = @bitCast(va);
                                const rvec: @Vector(4, u32) = @splat(@truncate(round));
                                const shvec: @Vector(4, u5) = @splat(@truncate(rshift));
                                const narrow: @Vector(4, u16) = @truncate((v32 +% rvec) >> shvec);
                                break :blk @bitCast(narrow);
                            },
                            else => blk: {
                                const v64: @Vector(2, u64) = @bitCast(va);
                                const rvec: @Vector(2, u64) = @splat(round);
                                const shvec: @Vector(2, u6) = @splat(rshift);
                                const narrow: @Vector(2, u32) = @truncate((v64 +% rvec) >> shvec);
                                break :blk @bitCast(narrow);
                            },
                        };
                        if (q) {
                            cpu.vfp.v[rd_idx] = (cpu.vfp.v[rd_idx] & 0xffff_ffff_ffff_ffff) | (@as(u128, narrow64) << 64);
                        } else {
                            cpu.vfp.v[rd_idx] = narrow64;
                        }
                    },
                    .simd_shll => {
                        const q = (d.imm & 1) != 0;
                        const is_unsigned = ((d.imm >> 1) & 1) != 0;
                        const size: u2 = @truncate(d.imm >> 2);
                        const lshift: u6 = @truncate(d.rm);
                        const va = cpu.vfp.v[@as(u5, @truncate(d.rn))];
                        const src64: u64 = if (q) @truncate(va >> 64) else @truncate(va);
                        const out128: u128 = switch (size) {
                            0 => if (is_unsigned) blk: {
                                const v8: @Vector(8, u8) = @bitCast(src64);
                                const wide: @Vector(8, u16) = v8;
                                const sh: @Vector(8, u4) = @splat(@truncate(lshift));
                                break :blk @bitCast(wide << sh);
                            } else blk: {
                                const v8: @Vector(8, i8) = @bitCast(src64);
                                const wide: @Vector(8, u16) = @bitCast(@as(@Vector(8, i16), v8));
                                const sh: @Vector(8, u4) = @splat(@truncate(lshift));
                                break :blk @bitCast(wide << sh);
                            },
                            1 => if (is_unsigned) blk: {
                                const v16: @Vector(4, u16) = @bitCast(src64);
                                const wide: @Vector(4, u32) = v16;
                                const sh: @Vector(4, u5) = @splat(@truncate(lshift));
                                break :blk @bitCast(wide << sh);
                            } else blk: {
                                const v16: @Vector(4, i16) = @bitCast(src64);
                                const wide: @Vector(4, u32) = @bitCast(@as(@Vector(4, i32), v16));
                                const sh: @Vector(4, u5) = @splat(@truncate(lshift));
                                break :blk @bitCast(wide << sh);
                            },
                            else => if (is_unsigned) blk: {
                                const v32: @Vector(2, u32) = @bitCast(src64);
                                const wide: @Vector(2, u64) = v32;
                                const sh: @Vector(2, u6) = @splat(lshift);
                                break :blk @bitCast(wide << sh);
                            } else blk: {
                                const v32: @Vector(2, i32) = @bitCast(src64);
                                const wide: @Vector(2, u64) = @bitCast(@as(@Vector(2, i64), v32));
                                const sh: @Vector(2, u6) = @splat(lshift);
                                break :blk @bitCast(wide << sh);
                            },
                        };
                        cpu.vfp.v[@as(u5, @truncate(d.rd))] = out128;
                    },
                    .fp_simd => executeFpSimd(cpu, inst),
                    .nop => {},
                    .jit_trace => {
                        const max_jit: usize = (batch_end - executed) + 1;
                        if (max_jit >= d.rd) {
                            cpu.pc64 = code_vbase;
                            const fn_ptr: jit_mod.JitFn = @ptrFromInt(@as(usize, @truncate(d.imm)));
                            const sp_ptr = &cpu.sp_el[spIndex(cpu)];
                            const tlb_ptr = &cpu.mmu.soft_tlb64[priv][0];
                            const ran = fn_ptr(cpu, bus, bus.ram.ptr, tlb_ptr, max_jit, sp_ptr);
                            executed += ran - 1;
                            const new_priv: u1 = @intFromBool(currentEl(cpu) != 0);
                            if (new_priv != priv or (cpu.pc64 & ~@as(u64, 0xfff)) != code_vbase) {
                                priv = new_priv;
                                code_vbase = 0xffff_ffff_ffff_ffff;
                                data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                            }
                        } else if (batch_end < max_steps and (max_steps - executed) + 1 >= d.rd) {
                            cpu.pc64 = cur_pc;
                            executed -= 1;
                            if (checkInterrupts64(cpu, bus)) {
                                priv = 1;
                                code_vbase = 0xffff_ffff_ffff_ffff;
                                data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                            }
                            break;
                        } else {
                            executeSingleA64(cpu, bus, cur_pc, inst) catch {
                                handleAbort64(cpu, cur_pc);
                                priv = 1;
                                code_vbase = 0xffff_ffff_ffff_ffff;
                                data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                continue;
                            };
                            if (checkInterrupts64(cpu, bus)) {
                                priv = 1;
                                code_vbase = 0xffff_ffff_ffff_ffff;
                                data_r_vbase = @splat(0xffff_ffff_ffff_ffff);
                                data_w_vbase = @splat(0xffff_ffff_ffff_ffff);
                                continue;
                            }
                        }
                    },
                }
                }
            }

            cpu.cycles +%= executed;
            cpu.mmu.pmccntr +%= @truncate(executed);
            cpu.r[15] = @truncate(cpu.pc64);
            cpu.cpsr = cpu.pstate;
            return executed;
        }

        noinline fn executeSingleA64(cpu: *CpuType, bus: *Bus, cur_pc: u64, inst: u32) error{Abort}!void {
            const top4: u4 = @truncate(inst >> 25);
            switch (top4) {
                0b1000, 0b1001 => executeDpImm(cpu, inst, cur_pc),
                0b1010, 0b1011 => try executeBranchSys(cpu, bus, inst, cur_pc),
                0b0100, 0b0110, 0b1100, 0b1110 => try executeLoadStore(cpu, bus, inst, cur_pc),
                0b0101, 0b1101 => executeDpReg(cpu, inst),
                0b0111, 0b1111 => executeFpSimd(cpu, inst),
                else => {},
            }
        }

        pub noinline fn handleAbort64(cpu: *CpuType, cur_pc: u64) void {
            const target_el: u2 = @max(currentEl(cpu), 1);
            const esr = if (target_el >= 2) cpu.mmu.esr_el2 else cpu.mmu.esr_el1;
            const far = if (target_el >= 2) cpu.mmu.far_el2 else cpu.mmu.far_el1;
            takeException64(cpu, target_el, 0x000, esr, far, cur_pc);
        }

        noinline fn executeDpImm(cpu: *CpuType, inst: u32, cur_pc: u64) void {
            const op0: u3 = @truncate(inst >> 23);
            const rd: u5 = @truncate(inst);
            const sf: u1 = @truncate(inst >> 31);

            switch (op0) {
                0b000, 0b001 => {
                    // ADR / ADRP
                    const immlo: u64 = (inst >> 29) & 3;
                    const immhi: i64 = @as(i19, @bitCast(@as(u19, @truncate(inst >> 5))));
                    const raw_imm: u64 = (@as(u64, @bitCast(immhi)) << 2) | immlo;
                    if (sf == 0) {
                        setX(cpu, rd, cur_pc +% raw_imm);
                    } else {
                        setX(cpu, rd, (cur_pc & ~@as(u64, 0xfff)) +% (raw_imm << 12));
                    }
                },
                0b010, 0b011 => {
                    // Add/subtract (immediate)
                    const op_sub = ((inst >> 30) & 1) != 0;
                    const set_flags = ((inst >> 29) & 1) != 0;
                    const sh = ((inst >> 22) & 1) != 0;
                    const imm12: u64 = (inst >> 10) & 0xfff;
                    const imm: u64 = if (sh) (imm12 << 12) else imm12;
                    const rn: u5 = @truncate(inst >> 5);
                    const a: u64 = getXOrSp(cpu, rn);
                    addSub(cpu, sf, op_sub, set_flags, rd, a, imm, if (op_sub) 1 else 0, !set_flags);
                },
                0b100 => {
                    // Logical (immediate)
                    const opc: u2 = @truncate(inst >> 29);
                    const n: u1 = @truncate(inst >> 22);
                    const immr: u6 = @truncate(inst >> 16);
                    const imms: u6 = @truncate(inst >> 10);
                    const rn: u5 = @truncate(inst >> 5);
                    const imm = decodeLogicalImm(sf, n, imms, immr) orelse 0;
                    const a = getX(cpu, rn);
                    const res_raw: u64 = switch (opc) {
                        0b00 => a & imm, // AND
                        0b01 => a | imm, // ORR
                        0b10 => a ^ imm, // EOR
                        0b11 => a & imm, // ANDS
                    };
                    const res = if (sf == 0) (res_raw & 0xffff_ffff) else res_raw;
                    if (opc == 0b11) {
                        const sign_bit: u6 = if (sf == 1) 63 else 31;
                        setNzcv(cpu, ((res >> sign_bit) & 1) != 0, res == 0, false, false);
                        setX(cpu, rd, res);
                    } else {
                        setXOrSp(cpu, rd, res);
                    }
                },
                0b101 => {
                    // Move wide (immediate): MOVN (0), MOVZ (2), MOVK (3)
                    const opc: u2 = @truncate(inst >> 29);
                    const hw: u2 = @truncate(inst >> 21);
                    const imm16: u64 = (inst >> 5) & 0xffff;
                    const shift: u6 = @as(u6, hw) * 16;
                    var res: u64 = switch (opc) {
                        0b00 => ~(imm16 << shift), // MOVN
                        0b10 => imm16 << shift, // MOVZ
                        0b11 => (getX(cpu, rd) & ~(@as(u64, 0xffff) << shift)) | (imm16 << shift), // MOVK
                        else => 0,
                    };
                    if (sf == 0) res &= 0xffff_ffff;
                    setX(cpu, rd, res);
                },
                0b110 => {
                    // Bitfield: SBFM (0), BFM (1), UBFM (2)
                    const opc: u2 = @truncate(inst >> 29);
                    const immr: u6 = @truncate(inst >> 16);
                    const imms: u6 = @truncate(inst >> 10);
                    const rn: u5 = @truncate(inst >> 5);
                    const reg_bits: u7 = if (sf == 1) 64 else 32;
                    const reg_mask: u64 = if (sf == 1) 0xffff_ffff_ffff_ffff else 0xffff_ffff;
                    const src = getX(cpu, rn) & reg_mask;
                    const dst = getX(cpu, rd) & reg_mask;

                    var res: u64 = 0;
                    if (imms >= immr) {
                        const width: u7 = @as(u7, imms - immr) + 1;
                        const wmask: u64 = if (width >= 64) 0xffff_ffff_ffff_ffff else ((@as(u64, 1) << @intCast(width)) - 1);
                        const extracted = (src >> immr) & wmask;
                        res = switch (opc) {
                            0b00 => blk: { // SBFM
                                const sign = (src >> imms) & 1;
                                break :blk if (sign != 0) (extracted | ~wmask) else extracted;
                            },
                            0b01 => (dst & ~wmask) | extracted, // BFM
                            else => extracted, // UBFM
                        };
                    } else {
                        const width: u7 = @as(u7, imms) + 1;
                        const lshift: u6 = @intCast(reg_bits - @as(u7, immr));
                        const wmask: u64 = if (width >= 64) 0xffff_ffff_ffff_ffff else ((@as(u64, 1) << @intCast(width)) - 1);
                        const dmask: u64 = wmask << lshift;
                        const inserted = (src & wmask) << lshift;
                        res = switch (opc) {
                            0b00 => blk: { // SBFM
                                const sign = (src >> imms) & 1;
                                const top_mask: u64 = if (@as(u7, lshift) + width >= 64) 0 else (~@as(u64, 0) << @intCast(@as(u7, lshift) + width));
                                break :blk if (sign != 0) (inserted | top_mask) else inserted;
                            },
                            0b01 => (dst & ~dmask) | inserted, // BFM
                            else => inserted, // UBFM
                        };
                    }
                    setX(cpu, rd, res & reg_mask);
                },
                0b111 => {
                    // Extract (EXTR / ROR)
                    const rm: u5 = @truncate(inst >> 16);
                    const imms: u6 = @truncate(inst >> 10);
                    const rn: u5 = @truncate(inst >> 5);
                    if (sf == 1) {
                        const a: u128 = getX(cpu, rn);
                        const b: u128 = getX(cpu, rm);
                        const pair: u128 = (a << 64) | b;
                        setX(cpu, rd, @truncate(pair >> imms));
                    } else {
                        const a: u64 = getW(cpu, rn);
                        const b: u64 = getW(cpu, rm);
                        const pair: u64 = (a << 32) | b;
                        setW(cpu, rd, @truncate(pair >> @as(u5, @truncate(imms))));
                    }
                },
            }
        }

        inline fn addSub(
            cpu: *CpuType,
            sf: u1,
            is_sub: bool,
            set_flags: bool,
            rd: u5,
            a_raw: u64,
            b_raw: u64,
            carry_in: u1,
            rd_can_be_sp: bool,
        ) void {
            if (sf == 1) {
                const a = a_raw;
                const b = if (is_sub) ~b_raw else b_raw;
                const sum1 = @addWithOverflow(a, b);
                const sum2 = @addWithOverflow(sum1[0], @as(u64, carry_in));
                const res = sum2[0];
                if (set_flags) {
                    const cout = (sum1[1] | sum2[1]) != 0;
                    const v = (((a ^ ~b) & (a ^ res)) >> 63) != 0;
                    setNzcv(cpu, (res >> 63) != 0, res == 0, cout, v);
                }
                if (rd_can_be_sp) setXOrSp(cpu, rd, res) else setX(cpu, rd, res);
            } else {
                const a: u32 = @truncate(a_raw);
                const b: u32 = if (is_sub) ~@as(u32, @truncate(b_raw)) else @truncate(b_raw);
                const sum1 = @addWithOverflow(a, b);
                const sum2 = @addWithOverflow(sum1[0], @as(u32, carry_in));
                const res = sum2[0];
                if (set_flags) {
                    const cout = (sum1[1] | sum2[1]) != 0;
                    const v = (((a ^ ~b) & (a ^ res)) >> 31) != 0;
                    setNzcv(cpu, (res >> 31) != 0, res == 0, cout, v);
                }
                if (rd_can_be_sp) setWOrSp(cpu, rd, res) else setW(cpu, rd, res);
            }
        }

        noinline fn executeBranchSys(cpu: *CpuType, bus: *Bus, inst: u32, cur_pc: u64) error{Abort}!void {
            const op0: u3 = @truncate(inst >> 29);
            const op1: u4 = @truncate(inst >> 22);

            // 1. Unconditional branch (immediate): B (op0=0b000), BL (op0=0b100)
            if ((inst & 0x7c00_0000) == 0x1400_0000) {
                const is_bl = (inst >> 31) != 0;
                const imm26: i64 = @as(i26, @bitCast(@as(u26, @truncate(inst))));
                const offset: u64 = @bitCast(imm26 << 2);
                if (is_bl) cpu.x[30] = cur_pc +% 4;
                cpu.pc64 = cur_pc +% offset;
                return;
            }

            // 2. Compare and branch (immediate): CBZ / CBNZ (`0x3400_0000`)
            if ((inst & 0x7e00_0000) == 0x3400_0000) {
                const sf: u1 = @truncate(inst >> 31);
                const is_nz = ((inst >> 24) & 1) != 0;
                const imm19: i64 = @as(i19, @bitCast(@as(u19, @truncate(inst >> 5))));
                const rt: u5 = @truncate(inst);
                const val = if (sf == 1) getX(cpu, rt) else @as(u64, getW(cpu, rt));
                if ((val != 0) == is_nz) {
                    cpu.pc64 = cur_pc +% @as(u64, @bitCast(imm19 << 2));
                }
                return;
            }

            // 3. Test bit and branch (immediate): TBZ / TBNZ (`0x3600_0000`)
            if ((inst & 0x7e00_0000) == 0x3600_0000) {
                const b5: u6 = @truncate((inst >> 31) << 5);
                const b40: u6 = @truncate((inst >> 19) & 0x1f);
                const bit_pos: u6 = b5 | b40;
                const is_nz = ((inst >> 24) & 1) != 0;
                const imm14: i64 = @as(i14, @bitCast(@as(u14, @truncate(inst >> 5))));
                const rt: u5 = @truncate(inst);
                const bit = ((getX(cpu, rt) >> bit_pos) & 1) != 0;
                if (bit == is_nz) {
                    cpu.pc64 = cur_pc +% @as(u64, @bitCast(imm14 << 2));
                }
                return;
            }

            // 4. Conditional branch (immediate): B.cond (`0x5400_0000`)
            if ((inst & 0xff00_0010) == 0x5400_0000) {
                const cond: u4 = @truncate(inst);
                if (evalCond(cpu.pstate, cond)) {
                    const imm19: i64 = @as(i19, @bitCast(@as(u19, @truncate(inst >> 5))));
                    cpu.pc64 = cur_pc +% @as(u64, @bitCast(imm19 << 2));
                }
                return;
            }

            // 5. Exception generation: SVC / HVC / SMC / BRK / HLT (`0xd400_0000`)
            if ((inst & 0xff00_0000) == 0xd400_0000) {
                const opc: u3 = @truncate(inst >> 21);
                const ll: u2 = @truncate(inst);
                const imm16: u32 = (inst >> 5) & 0xffff;
                switch (opc) {
                    0b000 => {
                        if (ll == 0b01) { // SVC
                            const esr: u32 = (0b010101 << 26) | (1 << 25) | imm16;
                            takeException64(cpu, @max(currentEl(cpu), 1), 0x000, esr, null, cur_pc +% 4);
                        } else if (ll == 0b10) { // HVC
                            const esr: u32 = (0b010110 << 26) | (1 << 25) | imm16;
                            takeException64(cpu, @max(currentEl(cpu), 2), 0x000, esr, null, cur_pc +% 4);
                        } else if (ll == 0b11) { // SMC
                            const esr: u32 = (0b010111 << 26) | (1 << 25) | imm16;
                            takeException64(cpu, 3, 0x000, esr, null, cur_pc +% 4);
                        }
                    },
                    0b001 => { // BRK
                        const esr: u32 = (0b111100 << 26) | (1 << 25) | imm16;
                        takeException64(cpu, @max(currentEl(cpu), 1), 0x000, esr, null, cur_pc);
                    },
                    else => {},
                }
                return;
            }

            // 6. System instructions, hints, barriers, MSR/MRS (`0xd500_0000`)
            if ((inst & 0xffc0_0000) == 0xd500_0000) {
                try executeSystem(cpu, bus, inst, cur_pc);
                return;
            }

            // 7. Unconditional branch (register): BR, BLR, RET, ERET (`0xd600_0000`)
            if ((inst & 0xfe00_0000) == 0xd600_0000) {
                const opc: u4 = @truncate(inst >> 21);
                const rn: u5 = @truncate(inst >> 5);
                switch (opc) {
                    0b0000 => cpu.pc64 = getX(cpu, rn), // BR
                    0b0001 => { // BLR
                        const target = getX(cpu, rn);
                        cpu.x[30] = cur_pc +% 4;
                        cpu.pc64 = target;
                    },
                    0b0010 => cpu.pc64 = getX(cpu, rn), // RET
                    0b0100 => { // ERET
                        const el = currentEl(cpu);
                        const target_pc = cpu.elr_el[el];
                        const spsr = cpu.spsr_el[el];
                        cpu.pstate = spsr;
                        cpu.pc64 = target_pc;
                        cpu.excl_valid = false;
                        if ((currentEl(cpu) >= 2) != (el >= 2)) cpu.mmu.flushTlb();
                    },
                    else => {},
                }
                return;
            }
            _ = op0;
            _ = op1;
        }

        fn executeSystem(cpu: *CpuType, bus: *Bus, inst: u32, cur_pc: u64) error{Abort}!void {
            const l = ((inst >> 21) & 1) != 0;
            const op0: u2 = @truncate(inst >> 19);
            const op1: u3 = @truncate(inst >> 16);
            const crn: u4 = @truncate(inst >> 12);
            const crm: u4 = @truncate(inst >> 8);
            const op2: u3 = @truncate(inst >> 5);
            const rt: u5 = @truncate(inst);

            if (op0 == 0) {
                // Hints, barriers, CLREX, MSR (immediate)
                if (crn == 2) {
                    // Hints: NOP (0), YIELD (1), WFE (2), WFI (3), SEV (4), SEVL (5)
                    const hint = (@as(u8, crm) << 3) | op2;
                    if (hint == 1 or hint == 2) {
                        cpu.yield_slice = true;
                    } else if (hint == 3) {
                        cpu.mmu.halted_wfi = true;
                    }
                } else if (crn == 3) {
                    if (op2 == 2) {
                        cpu.excl_valid = false; // CLREX
                    } else if (op2 == 4 or op2 == 5) {
                        if (atomic_ram.busParallel(bus)) {
                            atomic_ram.fence(&cpu.fence_word);
                            // DSB completes this core's TLBI ...IS on every other core
                            if (op2 == 4) bus.smp.broadcastTlb(cpu.mmu.core_id, &cpu.mmu);
                        }
                        const pc32: u32 = @truncate(cur_pc);
                        if ((cpu.last_dmb_pc ^ pc32) < 256) {
                            cpu.yield_slice = true;
                        }
                        cpu.last_dmb_pc = pc32;
                    }
                } else if (crn == 4) {
                    // MSR (immediate): SPSel (op1=0, op2=5), DAIFSet (op1=3, op2=6), DAIFClr (op1=3, op2=7)
                    if (op1 == 0 and op2 == 5) {
                        cpu.pstate = (cpu.pstate & ~@as(u32, 1)) | (crm & 1);
                    } else if (op1 == 3 and op2 == 6) {
                        cpu.pstate |= (@as(u32, crm) << 6);
                    } else if (op1 == 3 and op2 == 7) {
                        cpu.pstate &= ~(@as(u32, crm) << 6);
                    }
                }
                return;
            }

            if (op0 == 1) {
                // SYS / SYSL: DC ZVA, TLBI, AT, IC, DC
                if (!l) {
                    if (op1 == 3 and crn == 7 and crm == 4 and op2 == 1) {
                        // DC ZVA: Zero 64-byte cache line at virtual address X[rt]
                        const base_va = getX(cpu, rt) & ~@as(u64, 63);
                        const vbase = base_va & ~@as(u64, 0xfff);
                        const priv: u1 = @intFromBool(currentEl(cpu) != 0);
                        const slot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((base_va >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                        if (vbase == slot.w_vbase) {
                            const paddr = slot.pbase | @as(u32, @truncate(base_va & 0xfff));
                            @memset(bus.ram[paddr..][0..64], 0);
                        } else {
                            var off: u64 = 0;
                            while (off < 64) : (off += 8) {
                                try writeData64(cpu, bus, base_va +% off, 0);
                            }
                        }
                    } else if (crn == 7 and (crm == 1 or crm == 5)) {
                        // IC IALLUIS / IC IALLU / IC IVAU
                        cpu.invalidateIcache();
                    } else if (crn == 8) {
                        // TLBI maintenance
                        cpu.invalidateIcache();
                        if (op1 == 0 and (crm == 3 or crm == 7) and (op2 == 1 or op2 == 3 or op2 == 5 or op2 == 7)) {
                            const va_arg = getX(cpu, rt);
                            cpu.mmu.flushTlbVa64(va_arg);
                            if (crm == 3 and !cpu.mmu.tlb_broadcast_full) {
                                if (cpu.mmu.tlb_broadcast_va_count < cpu.mmu.tlb_broadcast_vas.len) {
                                    cpu.mmu.tlb_broadcast_vas[cpu.mmu.tlb_broadcast_va_count] = va_arg;
                                    cpu.mmu.tlb_broadcast_va_count += 1;
                                } else {
                                    cpu.mmu.tlb_broadcast_full = true;
                                }
                            }
                        } else {
                            cpu.mmu.flushTlb();
                            if (crm == 3) {
                                cpu.mmu.tlb_broadcast_full = true;
                            }
                        }
                    } else if (crn == 7 and crm == 8) {
                        // AT S1E1R / S1E1W / S1E0R / S1E0W -> update PAR_EL1
                        const va = getX(cpu, rt);
                        const is_write = (op2 & 1) != 0;
                        const is_el0 = (crm == 8 and (op2 == 2 or op2 == 3));
                        if (cpu.mmu.translate64(bus.ram, va, if (is_write) .write else .read, !is_el0)) |pa| {
                            cpu.mmu.par_64 = @as(u64, pa & 0xffff_f000);
                        } else |_| {
                            cpu.mmu.par_64 = 1 | ((@as(u64, cpu.mmu.esr_el1 & 0x3f)) << 1);
                        }
                    }
                }
                return;
            }

            // op0 == 2 or 3: MRS (l == true) / MSR (l == false)
            if (l) {
                setX(cpu, rt, readSysReg(cpu, op0, op1, crn, crm, op2));
            } else {
                writeSysReg(cpu, op0, op1, crn, crm, op2, getX(cpu, rt));
                if (crn == 14) {
                    if (@hasDecl(Bus, "setCoreTimerLines")) {
                        bus.setCoreTimerLines(cpu.mmu.core_id, cpu.mmu.timer_irq_lines);
                    } else if (@hasField(Bus, "local_intc")) {
                        bus.local_intc.core_timer_lines[cpu.mmu.core_id] = cpu.mmu.timer_irq_lines;
                    }
                }
            }
        }

        fn sysRegId(op0: u2, op1: u3, crn: u4, crm: u4, op2: u3) u16 {
            return (@as(u16, op0) << 14) | (@as(u16, op1) << 11) | (@as(u16, crn) << 7) | (@as(u16, crm) << 3) | @as(u16, op2);
        }

        pub noinline fn readSysReg(cpu: *CpuType, op0: u2, op1: u3, crn: u4, crm: u4, op2: u3) u64 {
            return switch (sysRegId(op0, op1, crn, crm, op2)) {
                // Special Purpose Registers (op0=3)
                sysRegId(3, 0, 4, 2, 2) => @as(u64, currentEl(cpu)) << 2, // CurrentEL
                sysRegId(3, 0, 4, 2, 0) => cpu.pstate & 1, // SPSel
                sysRegId(3, 3, 4, 2, 0) => cpu.pstate & 0xf000_0000, // NZCV
                sysRegId(3, 3, 4, 2, 1) => cpu.pstate & 0x3c0, // DAIF
                sysRegId(3, 3, 4, 4, 0) => cpu.vfp.fpcr64, // FPCR
                sysRegId(3, 3, 4, 4, 1) => cpu.vfp.fpsr64, // FPSR
                sysRegId(3, 0, 4, 1, 0) => cpu.sp_el[0], // SP_EL0
                sysRegId(3, 4, 4, 1, 0) => cpu.sp_el[1], // SP_EL1
                sysRegId(3, 6, 4, 1, 0) => cpu.sp_el[2], // SP_EL2
                sysRegId(3, 0, 4, 0, 1) => cpu.elr_el[1], // ELR_EL1
                sysRegId(3, 4, 4, 0, 1) => cpu.elr_el[2], // ELR_EL2
                sysRegId(3, 6, 4, 0, 1) => cpu.elr_el[3], // ELR_EL3
                sysRegId(3, 0, 4, 0, 0) => cpu.spsr_el[1], // SPSR_EL1
                sysRegId(3, 4, 4, 0, 0) => cpu.spsr_el[2], // SPSR_EL2
                sysRegId(3, 6, 4, 0, 0) => cpu.spsr_el[3], // SPSR_EL3

                // Identification Registers
                sysRegId(3, 0, 0, 0, 0) => 0x410fd034, // MIDR_EL1 (Cortex-A53 r0p4)
                sysRegId(3, 0, 0, 0, 5) => 0x8000_0000 | @as(u64, cpu.mmu.core_id), // MPIDR_EL1
                sysRegId(3, 0, 0, 0, 6) => 0, // REVIDR_EL1
                sysRegId(3, 0, 0, 4, 0) => 0x0000_0000_0000_2222, // ID_AA64PFR0_EL1 (EL0..EL3 AArch64+AArch32, FP+AdvSIMD)
                sysRegId(3, 0, 0, 4, 1) => 0, // ID_AA64PFR1_EL1
                sysRegId(3, 0, 0, 5, 0) => 0x0000_0000_1030_5106, // ID_AA64DFR0_EL1
                sysRegId(3, 0, 0, 6, 0) => 0x0000_0000_0001_0000, // ID_AA64ISAR0_EL1 (CRC32 supported; BCM2837 Cortex-A53 has no Crypto)
                sysRegId(3, 0, 0, 6, 1) => 0, // ID_AA64ISAR1_EL1
                sysRegId(3, 0, 0, 7, 0) => 0x0000_0000_0010_1122, // ID_AA64MMFR0_EL1 (40-bit PA, 4KB granule supported)
                sysRegId(3, 0, 0, 7, 1) => 0, // ID_AA64MMFR1_EL1
                sysRegId(3, 0, 0, 7, 2) => 0, // ID_AA64MMFR2_EL1
                sysRegId(3, 3, 0, 0, 1) => 0x8444_8004, // CTR_EL0 (64-byte I/D cache lines)
                sysRegId(3, 3, 0, 0, 7) => 4, // DCZID_EL0 (BS=4 -> 64-byte DC ZVA block, DZP=0)
                sysRegId(3, 1, 0, 0, 0) => 0x700f_e01a, // CCSIDR_EL1
                sysRegId(3, 1, 0, 0, 1) => 0x0a20_0023, // CLIDR_EL1
                sysRegId(3, 2, 0, 0, 0) => cpu.mmu.csselr, // CSSELR_EL1

                // Control & MMU Registers
                sysRegId(3, 0, 1, 0, 0) => cpu.mmu.sctlr_el1, // SCTLR_EL1
                sysRegId(3, 4, 1, 0, 0) => cpu.mmu.sctlr_el2, // SCTLR_EL2
                sysRegId(3, 6, 1, 0, 0) => cpu.mmu.sctlr_el3, // SCTLR_EL3
                sysRegId(3, 0, 1, 0, 1) => cpu.mmu.actlr, // ACTLR_EL1
                sysRegId(3, 0, 1, 0, 2) => cpu.mmu.cpacr_el1, // CPACR_EL1
                sysRegId(3, 4, 1, 1, 0) => cpu.mmu.hcr_el2, // HCR_EL2
                sysRegId(3, 6, 1, 1, 0) => cpu.mmu.scr_el3, // SCR_EL3
                sysRegId(3, 4, 1, 1, 2) => cpu.mmu.cptr_el2, // CPTR_EL2
                sysRegId(3, 6, 1, 1, 2) => cpu.mmu.cptr_el3, // CPTR_EL3
                sysRegId(3, 4, 1, 1, 1) => cpu.mmu.mdcr_el2, // MDCR_EL2
                sysRegId(3, 0, 2, 0, 0) => cpu.mmu.ttbr0_64, // TTBR0_EL1
                sysRegId(3, 0, 2, 0, 1) => cpu.mmu.ttbr1_64, // TTBR1_EL1
                sysRegId(3, 4, 2, 0, 0) => cpu.mmu.ttbr0_el2, // TTBR0_EL2
                sysRegId(3, 0, 2, 0, 2) => cpu.mmu.tcr_el1, // TCR_EL1
                sysRegId(3, 4, 2, 0, 2) => cpu.mmu.tcr_el2, // TCR_EL2
                sysRegId(3, 0, 5, 2, 0) => cpu.mmu.esr_el1, // ESR_EL1
                sysRegId(3, 4, 5, 2, 0) => cpu.mmu.esr_el2, // ESR_EL2
                sysRegId(3, 0, 6, 0, 0) => cpu.mmu.far_el1, // FAR_EL1
                sysRegId(3, 4, 6, 0, 0) => cpu.mmu.far_el2, // FAR_EL2
                sysRegId(3, 0, 7, 4, 0) => cpu.mmu.par_64, // PAR_EL1
                sysRegId(3, 0, 10, 2, 0) => cpu.mmu.mair_el1, // MAIR_EL1
                sysRegId(3, 4, 10, 2, 0) => cpu.mmu.mair_el2, // MAIR_EL2
                sysRegId(3, 0, 10, 3, 0) => cpu.mmu.amair_el1, // AMAIR_EL1
                sysRegId(3, 0, 12, 0, 0) => cpu.mmu.vbar_el1, // VBAR_EL1
                sysRegId(3, 4, 12, 0, 0) => cpu.mmu.vbar_el2, // VBAR_EL2
                sysRegId(3, 6, 12, 0, 0) => cpu.mmu.vbar_el3, // VBAR_EL3
                sysRegId(3, 0, 13, 0, 1) => cpu.mmu.contextidr, // CONTEXTIDR_EL1
                sysRegId(3, 3, 13, 0, 2) => cpu.mmu.tpidr_el0, // TPIDR_EL0
                sysRegId(3, 3, 13, 0, 3) => cpu.mmu.tpidrro_el0, // TPIDRRO_EL0
                sysRegId(3, 0, 13, 0, 4) => cpu.mmu.tpidr_el1, // TPIDR_EL1
                sysRegId(3, 4, 13, 0, 2) => cpu.mmu.tpidr_el2, // TPIDR_EL2
                sysRegId(3, 4, 0, 0, 0) => cpu.mmu.vpidr_el2, // VPIDR_EL2
                sysRegId(3, 4, 0, 0, 5) => cpu.mmu.vmpidr_el2, // VMPIDR_EL2
                sysRegId(3, 1, 15, 2, 1) => cpu.mmu.cpuectlr_64, // CPUECTLR_EL1
                sysRegId(3, 1, 15, 3, 0) => 0x4000_0000, // CBAR_EL1

                // Generic Timer Registers
                sysRegId(3, 3, 14, 0, 0) => cpu.mmu.cntfrq, // CNTFRQ_EL0
                sysRegId(3, 3, 14, 0, 1) => blk: { // CNTPCT_EL0
                    if (cpu.mmu.noteTimerCounterRead()) cpu.yield_slice = true;
                    break :blk cpu.mmu.cntpct;
                },
                sysRegId(3, 3, 14, 0, 2) => blk: { // CNTVCT_EL0
                    if (cpu.mmu.noteTimerCounterRead()) cpu.yield_slice = true;
                    break :blk cpu.mmu.cntpct -% cpu.mmu.cntvoff;
                },
                sysRegId(3, 0, 14, 1, 0) => cpu.mmu.cntkctl, // CNTKCTL_EL1
                sysRegId(3, 4, 14, 1, 0) => cpu.mmu.cnthctl_el2, // CNTHCTL_EL2
                sysRegId(3, 4, 14, 0, 3) => cpu.mmu.cntvoff, // CNTVOFF_EL2
                sysRegId(3, 3, 14, 2, 0) => @bitCast(@as(i64, @as(i32, @truncate(@as(i64, @bitCast(cpu.mmu.cntp_cval -% cpu.mmu.cntpct)))))), // CNTP_TVAL_EL0
                sysRegId(3, 3, 14, 2, 1) => blk: {
                    _ = cpu.mmu.timerIrqLines();
                    break :blk cpu.mmu.cntp_ctl;
                }, // CNTP_CTL_EL0
                sysRegId(3, 3, 14, 2, 2) => cpu.mmu.cntp_cval, // CNTP_CVAL_EL0
                sysRegId(3, 3, 14, 3, 0) => @bitCast(@as(i64, @as(i32, @truncate(@as(i64, @bitCast(cpu.mmu.cntv_cval -% (cpu.mmu.cntpct -% cpu.mmu.cntvoff))))))), // CNTV_TVAL_EL0
                sysRegId(3, 3, 14, 3, 1) => blk: {
                    _ = cpu.mmu.timerIrqLines();
                    break :blk cpu.mmu.cntv_ctl;
                }, // CNTV_CTL_EL0
                sysRegId(3, 3, 14, 3, 2) => cpu.mmu.cntv_cval, // CNTV_CVAL_EL0
                sysRegId(3, 4, 14, 2, 0) => @bitCast(@as(i64, @as(i32, @truncate(@as(i64, @bitCast(cpu.mmu.cnthp_cval -% cpu.mmu.cntpct)))))), // CNTHP_TVAL_EL2
                sysRegId(3, 4, 14, 2, 1) => blk: {
                    _ = cpu.mmu.timerIrqLines();
                    break :blk cpu.mmu.cnthp_ctl;
                }, // CNTHP_CTL_EL2
                sysRegId(3, 4, 14, 2, 2) => cpu.mmu.cnthp_cval, // CNTHP_CVAL_EL2
                sysRegId(3, 7, 14, 2, 0) => @bitCast(@as(i64, @as(i32, @truncate(@as(i64, @bitCast(cpu.mmu.cntps_cval -% cpu.mmu.cntpct)))))), // CNTPS_TVAL_EL1
                sysRegId(3, 7, 14, 2, 1) => blk: {
                    _ = cpu.mmu.timerIrqLines();
                    break :blk cpu.mmu.cntps_ctl;
                }, // CNTPS_CTL_EL1
                sysRegId(3, 7, 14, 2, 2) => cpu.mmu.cntps_cval, // CNTPS_CVAL_EL1
                else => 0,
            };
        }

        pub noinline fn writeSysReg(cpu: *CpuType, op0: u2, op1: u3, crn: u4, crm: u4, op2: u3, val: u64) void {
            switch (sysRegId(op0, op1, crn, crm, op2)) {
                sysRegId(3, 0, 4, 2, 0) => cpu.pstate = (cpu.pstate & ~@as(u32, 1)) | @as(u32, @truncate(val & 1)), // SPSel
                sysRegId(3, 3, 4, 2, 0) => cpu.pstate = (cpu.pstate & 0x0fff_ffff) | (@as(u32, @truncate(val)) & 0xf000_0000), // NZCV
                sysRegId(3, 3, 4, 2, 1) => cpu.pstate = (cpu.pstate & ~@as(u32, 0x3c0)) | (@as(u32, @truncate(val)) & 0x3c0), // DAIF
                sysRegId(3, 3, 4, 4, 0) => cpu.vfp.fpcr64 = val, // FPCR
                sysRegId(3, 3, 4, 4, 1) => cpu.vfp.fpsr64 = val, // FPSR
                sysRegId(3, 0, 4, 1, 0) => cpu.sp_el[0] = val, // SP_EL0
                sysRegId(3, 4, 4, 1, 0) => cpu.sp_el[1] = val, // SP_EL1
                sysRegId(3, 6, 4, 1, 0) => cpu.sp_el[2] = val, // SP_EL2
                sysRegId(3, 0, 4, 0, 1) => cpu.elr_el[1] = val, // ELR_EL1
                sysRegId(3, 4, 4, 0, 1) => cpu.elr_el[2] = val, // ELR_EL2
                sysRegId(3, 6, 4, 0, 1) => cpu.elr_el[3] = val, // ELR_EL3
                sysRegId(3, 0, 4, 0, 0) => cpu.spsr_el[1] = @truncate(val), // SPSR_EL1
                sysRegId(3, 4, 4, 0, 0) => cpu.spsr_el[2] = @truncate(val), // SPSR_EL2
                sysRegId(3, 6, 4, 0, 0) => cpu.spsr_el[3] = @truncate(val), // SPSR_EL3

                sysRegId(3, 2, 0, 0, 0) => cpu.mmu.csselr = @truncate(val), // CSSELR_EL1
                sysRegId(3, 0, 1, 0, 0) => { // SCTLR_EL1
                    cpu.mmu.sctlr_el1 = val;
                    cpu.mmu.sctlr = @truncate(val);
                    cpu.mmu.flushTlb();
                    cpu.invalidateInlineTlb();
                },
                sysRegId(3, 4, 1, 0, 0) => { // SCTLR_EL2
                    cpu.mmu.sctlr_el2 = val;
                    cpu.mmu.flushTlb();
                    cpu.invalidateInlineTlb();
                },
                sysRegId(3, 6, 1, 0, 0) => cpu.mmu.sctlr_el3 = val, // SCTLR_EL3
                sysRegId(3, 0, 1, 0, 1) => cpu.mmu.actlr = @truncate(val), // ACTLR_EL1
                sysRegId(3, 0, 1, 0, 2) => cpu.mmu.cpacr_el1 = val, // CPACR_EL1
                sysRegId(3, 4, 1, 1, 0) => cpu.mmu.hcr_el2 = val, // HCR_EL2
                sysRegId(3, 6, 1, 1, 0) => cpu.mmu.scr_el3 = val, // SCR_EL3
                sysRegId(3, 4, 1, 1, 2) => cpu.mmu.cptr_el2 = val, // CPTR_EL2
                sysRegId(3, 6, 1, 1, 2) => cpu.mmu.cptr_el3 = val, // CPTR_EL3
                sysRegId(3, 4, 1, 1, 1) => cpu.mmu.mdcr_el2 = @truncate(val), // MDCR_EL2
                sysRegId(3, 0, 2, 0, 0) => { // TTBR0_EL1
                    cpu.mmu.ttbr0_64 = val;
                    cpu.mmu.ttbr0 = @truncate(val);
                    cpu.mmu.flushTlb();
                    cpu.invalidateInlineTlb();
                },
                sysRegId(3, 0, 2, 0, 1) => { // TTBR1_EL1
                    cpu.mmu.ttbr1_64 = val;
                    cpu.mmu.ttbr1 = @truncate(val);
                    cpu.mmu.flushTlb();
                    cpu.invalidateInlineTlb();
                },
                sysRegId(3, 4, 2, 0, 0) => cpu.mmu.ttbr0_el2 = val,
                sysRegId(3, 0, 2, 0, 2) => { // TCR_EL1
                    cpu.mmu.tcr_el1 = val;
                    cpu.mmu.flushTlb();
                    cpu.invalidateInlineTlb();
                },
                sysRegId(3, 4, 2, 0, 2) => cpu.mmu.tcr_el2 = val,
                sysRegId(3, 0, 5, 2, 0) => cpu.mmu.esr_el1 = @truncate(val),
                sysRegId(3, 4, 5, 2, 0) => cpu.mmu.esr_el2 = @truncate(val),
                sysRegId(3, 0, 6, 0, 0) => cpu.mmu.far_el1 = val,
                sysRegId(3, 4, 6, 0, 0) => cpu.mmu.far_el2 = val,
                sysRegId(3, 0, 7, 4, 0) => cpu.mmu.par_64 = val,
                sysRegId(3, 0, 10, 2, 0) => cpu.mmu.mair_el1 = val,
                sysRegId(3, 4, 10, 2, 0) => cpu.mmu.mair_el2 = val,
                sysRegId(3, 0, 10, 3, 0) => cpu.mmu.amair_el1 = val,
                sysRegId(3, 0, 12, 0, 0) => cpu.mmu.vbar_el1 = val & ~@as(u64, 0x7ff),
                sysRegId(3, 4, 12, 0, 0) => cpu.mmu.vbar_el2 = val & ~@as(u64, 0x7ff),
                sysRegId(3, 6, 12, 0, 0) => cpu.mmu.vbar_el3 = val & ~@as(u64, 0x7ff),
                sysRegId(3, 0, 13, 0, 1) => {
                    cpu.mmu.contextidr = @truncate(val);
                    cpu.mmu.flushTlb();
                    cpu.invalidateInlineTlb();
                },
                sysRegId(3, 3, 13, 0, 2) => cpu.mmu.tpidr_el0 = val,
                sysRegId(3, 3, 13, 0, 3) => cpu.mmu.tpidrro_el0 = val,
                sysRegId(3, 0, 13, 0, 4) => cpu.mmu.tpidr_el1 = val,
                sysRegId(3, 4, 13, 0, 2) => cpu.mmu.tpidr_el2 = val,
                sysRegId(3, 4, 0, 0, 0) => cpu.mmu.vpidr_el2 = @truncate(val),
                sysRegId(3, 4, 0, 0, 5) => cpu.mmu.vmpidr_el2 = val,
                sysRegId(3, 1, 15, 2, 1) => cpu.mmu.cpuectlr_64 = val,

                // Generic Timer Registers
                sysRegId(3, 3, 14, 0, 0) => cpu.mmu.cntfrq = @truncate(val),
                sysRegId(3, 0, 14, 1, 0) => cpu.mmu.cntkctl = @truncate(val),
                sysRegId(3, 4, 14, 1, 0) => cpu.mmu.cnthctl_el2 = @truncate(val),
                sysRegId(3, 4, 14, 0, 3) => {
                    cpu.mmu.cntvoff = val;
                    _ = cpu.mmu.timerIrqLines();
                },
                sysRegId(3, 3, 14, 2, 0) => {
                    const signed_tval: i64 = @as(i32, @bitCast(@as(u32, @truncate(val))));
                    cpu.mmu.cntp_cval = cpu.mmu.cntpct +% @as(u64, @bitCast(signed_tval));
                    _ = cpu.mmu.timerIrqLines();
                },
                sysRegId(3, 3, 14, 2, 1) => {
                    cpu.mmu.cntp_ctl = (cpu.mmu.cntp_ctl & 4) | (@as(u32, @truncate(val)) & 3);
                    _ = cpu.mmu.timerIrqLines();
                },
                sysRegId(3, 3, 14, 2, 2) => {
                    cpu.mmu.cntp_cval = val;
                    _ = cpu.mmu.timerIrqLines();
                },
                sysRegId(3, 3, 14, 3, 0) => {
                    const signed_tval: i64 = @as(i32, @bitCast(@as(u32, @truncate(val))));
                    const cntvct = cpu.mmu.cntpct -% cpu.mmu.cntvoff;
                    cpu.mmu.cntv_cval = cntvct +% @as(u64, @bitCast(signed_tval));
                    _ = cpu.mmu.timerIrqLines();
                },
                sysRegId(3, 3, 14, 3, 1) => {
                    cpu.mmu.cntv_ctl = (cpu.mmu.cntv_ctl & 4) | (@as(u32, @truncate(val)) & 3);
                    _ = cpu.mmu.timerIrqLines();
                },
                sysRegId(3, 3, 14, 3, 2) => {
                    cpu.mmu.cntv_cval = val;
                    _ = cpu.mmu.timerIrqLines();
                },
                sysRegId(3, 4, 14, 2, 0) => {
                    const signed_tval: i64 = @as(i32, @bitCast(@as(u32, @truncate(val))));
                    cpu.mmu.cnthp_cval = cpu.mmu.cntpct +% @as(u64, @bitCast(signed_tval));
                    _ = cpu.mmu.timerIrqLines();
                },
                sysRegId(3, 4, 14, 2, 1) => {
                    cpu.mmu.cnthp_ctl = (cpu.mmu.cnthp_ctl & 4) | (@as(u32, @truncate(val)) & 3);
                    _ = cpu.mmu.timerIrqLines();
                },
                sysRegId(3, 4, 14, 2, 2) => {
                    cpu.mmu.cnthp_cval = val;
                    _ = cpu.mmu.timerIrqLines();
                },
                sysRegId(3, 7, 14, 2, 0) => {
                    const signed_tval: i64 = @as(i32, @bitCast(@as(u32, @truncate(val))));
                    cpu.mmu.cntps_cval = cpu.mmu.cntpct +% @as(u64, @bitCast(signed_tval));
                    _ = cpu.mmu.timerIrqLines();
                },
                sysRegId(3, 7, 14, 2, 1) => {
                    cpu.mmu.cntps_ctl = (cpu.mmu.cntps_ctl & 4) | (@as(u32, @truncate(val)) & 3);
                    _ = cpu.mmu.timerIrqLines();
                },
                sysRegId(3, 7, 14, 2, 2) => {
                    cpu.mmu.cntps_cval = val;
                    _ = cpu.mmu.timerIrqLines();
                },
                else => {},
            }
        }

        noinline fn executeLoadStore(cpu: *CpuType, bus: *Bus, inst: u32, cur_pc: u64) error{Abort}!void {
            // 1. Load/Store Exclusive & Load-Acquire/Store-Release (`0x0800_0000`)
            if ((inst & 0x3f00_0000) == 0x0800_0000) {
                try executeLoadStoreExcl(cpu, bus, inst);
                return;
            }

            // 2. Load register (literal) (`0x1800_0000`)
            if ((inst & 0x3b00_0000) == 0x1800_0000) {
                const opc: u2 = @truncate(inst >> 30);
                const is_fp = ((inst >> 26) & 1) != 0;
                const imm19: i64 = @as(i19, @bitCast(@as(u19, @truncate(inst >> 5))));
                const addr: u64 = cur_pc +% @as(u64, @bitCast(imm19 << 2));
                const rt: u5 = @truncate(inst);
                if (!is_fp) {
                    switch (opc) {
                        0b00 => setW(cpu, rt, try readData32(cpu, bus, addr)),
                        0b01 => setX(cpu, rt, try readData64(cpu, bus, addr)),
                        0b10 => setX(cpu, rt, @bitCast(@as(i64, @as(i32, @bitCast(try readData32(cpu, bus, addr)))))),
                        0b11 => {}, // PRFM
                    }
                } else {
                    switch (opc) {
                        0b00 => cpu.vfp.v[rt] = @as(u128, try readData32(cpu, bus, addr)),
                        0b01 => cpu.vfp.v[rt] = @as(u128, try readData64(cpu, bus, addr)),
                        0b10 => {
                            const lo: u128 = try readData64(cpu, bus, addr);
                            const hi: u128 = try readData64(cpu, bus, addr +% 8);
                            cpu.vfp.v[rt] = lo | (hi << 64);
                        },
                        0b11 => {},
                    }
                }
                return;
            }

            // 3. Load/Store Pair (`0x2800_0000`)
            if ((inst & 0x3a00_0000) == 0x2800_0000) {
                const opc: u2 = @truncate(inst >> 30);
                const is_fp = ((inst >> 26) & 1) != 0;
                const mode: u2 = @truncate(inst >> 23);
                const is_load = ((inst >> 22) & 1) != 0;
                const imm7: i64 = @as(i7, @bitCast(@as(u7, @truncate(inst >> 15))));
                const rt2: u5 = @truncate(inst >> 10);
                const rn: u5 = @truncate(inst >> 5);
                const rt: u5 = @truncate(inst);

                const scale: u3 = if (is_fp) (@as(u3, 2) + opc) else (if (opc == 2) 3 else 2);
                const step_bytes: u64 = @as(u64, 1) << scale;
                const offset: u64 = @bitCast(imm7 << scale);
                const base = getXOrSp(cpu, rn);
                const addr: u64 = if (mode == 0b01) base else (base +% offset);

                if (!is_fp) {
                    if (is_load) {
                        if (opc == 0b00) {
                            const v1 = try readData32(cpu, bus, addr);
                            const v2 = try readData32(cpu, bus, addr +% 4);
                            setW(cpu, rt, v1);
                            setW(cpu, rt2, v2);
                        } else if (opc == 0b01) { // LDPSW
                            const v1: u64 = @bitCast(@as(i64, @as(i32, @bitCast(try readData32(cpu, bus, addr)))));
                            const v2: u64 = @bitCast(@as(i64, @as(i32, @bitCast(try readData32(cpu, bus, addr +% 4)))));
                            setX(cpu, rt, v1);
                            setX(cpu, rt2, v2);
                        } else {
                            const v1 = try readData64(cpu, bus, addr);
                            const v2 = try readData64(cpu, bus, addr +% 8);
                            setX(cpu, rt, v1);
                            setX(cpu, rt2, v2);
                        }
                    } else {
                        if (opc == 0b00) {
                            try writeData32(cpu, bus, addr, getW(cpu, rt));
                            try writeData32(cpu, bus, addr +% 4, getW(cpu, rt2));
                        } else {
                            try writeData64(cpu, bus, addr, getX(cpu, rt));
                            try writeData64(cpu, bus, addr +% 8, getX(cpu, rt2));
                        }
                    }
                } else {
                    if (is_load) {
                        switch (opc) {
                            0b00 => {
                                const v1 = try readData32(cpu, bus, addr);
                                const v2 = try readData32(cpu, bus, addr +% 4);
                                cpu.vfp.v[rt] = v1;
                                cpu.vfp.v[rt2] = v2;
                            },
                            0b01 => {
                                const v1 = try readData64(cpu, bus, addr);
                                const v2 = try readData64(cpu, bus, addr +% 8);
                                cpu.vfp.v[rt] = v1;
                                cpu.vfp.v[rt2] = v2;
                            },
                            else => {
                                cpu.vfp.v[rt] = try readData128(cpu, bus, addr);
                                cpu.vfp.v[rt2] = try readData128(cpu, bus, addr +% 16);
                            },
                        }
                    } else {
                        switch (opc) {
                            0b00 => {
                                try writeData32(cpu, bus, addr, @truncate(cpu.vfp.v[rt]));
                                try writeData32(cpu, bus, addr +% 4, @truncate(cpu.vfp.v[rt2]));
                            },
                            0b01 => {
                                try writeData64(cpu, bus, addr, @truncate(cpu.vfp.v[rt]));
                                try writeData64(cpu, bus, addr +% 8, @truncate(cpu.vfp.v[rt2]));
                            },
                            else => {
                                try writeData128(cpu, bus, addr, cpu.vfp.v[rt]);
                                try writeData128(cpu, bus, addr +% 16, cpu.vfp.v[rt2]);
                            },
                        }
                    }
                }
                _ = step_bytes;
                if (mode == 0b01 or mode == 0b11) {
                    setXOrSp(cpu, rn, base +% offset);
                }
                return;
            }

            // 4. Load/Store Register (Unsigned immediate `0x3900_0000`, Unscaled/Indexed/Register/Atomic `0x3800_0000`)
            if ((inst & 0x3a00_0000) == 0x3800_0000) {
                const size: u2 = @truncate(inst >> 30);
                const is_fp = ((inst >> 26) & 1) != 0;
                const is_uimm = ((inst >> 24) & 1) != 0;
                const opc: u2 = @truncate(inst >> 22);
                const rn: u5 = @truncate(inst >> 5);
                const rt: u5 = @truncate(inst);

                const scale: u3 = if (is_fp and (opc & 2) != 0 and size == 0) 4 else size;
                const base = getXOrSp(cpu, rn);

                var addr: u64 = base;
                var writeback_addr: ?u64 = null;

                if (is_uimm) {
                    const imm12: u64 = (inst >> 10) & 0xfff;
                    addr = base +% (imm12 << scale);
                } else if (((inst >> 21) & 1) == 0) {
                    // Unscaled / Post-index / Unprivileged / Pre-index 9-bit signed immediate
                    const imm9: i64 = @as(i9, @bitCast(@as(u9, @truncate(inst >> 12))));
                    const offset: u64 = @bitCast(imm9);
                    const mode2: u2 = @truncate(inst >> 10);
                    switch (mode2) {
                        0b00, 0b10 => addr = base +% offset, // LDUR/STUR, LDTR/STTR
                        0b01 => { // Post-index
                            addr = base;
                            writeback_addr = base +% offset;
                        },
                        0b11 => { // Pre-index
                            addr = base +% offset;
                            writeback_addr = addr;
                        },
                    }
                } else {
                    const mode2: u2 = @truncate(inst >> 10);
                    if (mode2 == 0b10) {
                        // Register offset: [Xn, Rm, option #shift]
                        const rm: u5 = @truncate(inst >> 16);
                        const option: u3 = @truncate(inst >> 13);
                        const s_bit = ((inst >> 12) & 1) != 0;
                        const shift: u3 = if (s_bit) scale else 0;
                        const extended = extendReg(getX(cpu, rm), option, shift);
                        addr = base +% extended;
                    } else if (mode2 == 0b00 and !is_fp) {
                        // LSE Atomic memory operations (LDADD, LDCLR, LDEOR, LDSET, SWP)
                        try executeAtomic(cpu, bus, inst, base);
                        return;
                    }
                }

                if (!is_fp) {
                    switch (opc) {
                        0b00 => { // Store
                            switch (size) {
                                0 => try writeData8(cpu, bus, addr, @truncate(getW(cpu, rt))),
                                1 => try writeData16(cpu, bus, addr, @truncate(getW(cpu, rt))),
                                2 => try writeData32(cpu, bus, addr, getW(cpu, rt)),
                                3 => try writeData64(cpu, bus, addr, getX(cpu, rt)),
                            }
                        },
                        0b01 => { // Unsigned Load
                            switch (size) {
                                0 => setW(cpu, rt, try readData8(cpu, bus, addr)),
                                1 => setW(cpu, rt, try readData16(cpu, bus, addr)),
                                2 => setW(cpu, rt, try readData32(cpu, bus, addr)),
                                3 => setX(cpu, rt, try readData64(cpu, bus, addr)),
                            }
                        },
                        0b10 => { // Signed Load to 64-bit Xt (or PRFM when size==3)
                            switch (size) {
                                0 => setX(cpu, rt, @bitCast(@as(i64, @as(i8, @bitCast(try readData8(cpu, bus, addr)))))),
                                1 => setX(cpu, rt, @bitCast(@as(i64, @as(i16, @bitCast(try readData16(cpu, bus, addr)))))),
                                2 => setX(cpu, rt, @bitCast(@as(i64, @as(i32, @bitCast(try readData32(cpu, bus, addr)))))),
                                3 => {}, // PRFM
                            }
                        },
                        0b11 => { // Signed Load to 32-bit Wt
                            switch (size) {
                                0 => setW(cpu, rt, @bitCast(@as(i32, @as(i8, @bitCast(try readData8(cpu, bus, addr)))))),
                                1 => setW(cpu, rt, @bitCast(@as(i32, @as(i16, @bitCast(try readData16(cpu, bus, addr)))))),
                                else => {},
                            }
                        },
                    }
                } else {
                    const is_load = (opc & 1) != 0;
                    if (is_load) {
                        switch (scale) {
                            0 => cpu.vfp.v[rt] = try readData8(cpu, bus, addr),
                            1 => cpu.vfp.v[rt] = try readData16(cpu, bus, addr),
                            2 => cpu.vfp.v[rt] = try readData32(cpu, bus, addr),
                            3 => cpu.vfp.v[rt] = try readData64(cpu, bus, addr),
                            else => cpu.vfp.v[rt] = try readData128(cpu, bus, addr),
                        }
                    } else {
                        switch (scale) {
                            0 => try writeData8(cpu, bus, addr, @truncate(cpu.vfp.v[rt])),
                            1 => try writeData16(cpu, bus, addr, @truncate(cpu.vfp.v[rt])),
                            2 => try writeData32(cpu, bus, addr, @truncate(cpu.vfp.v[rt])),
                            3 => try writeData64(cpu, bus, addr, @truncate(cpu.vfp.v[rt])),
                            else => try writeData128(cpu, bus, addr, cpu.vfp.v[rt]),
                        }
                    }
                }

                if (writeback_addr) |wb| {
                    setXOrSp(cpu, rn, wb);
                }
                return;
            }

            // 5. AdvSIMD Load/Store multiple/single structures (`0x0c00_0000` / `0x0d00_0000` / `0x4c00_0000` / `0x4d00_0000`)
            if ((inst & 0xbe00_0000) == 0x0c00_0000) {
                try executeSimdStructLoadStore(cpu, bus, inst);
            }
        }

        fn executeLoadStoreExcl(cpu: *CpuType, bus: *Bus, inst: u32) error{Abort}!void {
            const size: u2 = @truncate(inst >> 30);
            const o2 = ((inst >> 23) & 1) != 0;
            const is_load = ((inst >> 22) & 1) != 0;
            const o1 = ((inst >> 21) & 1) != 0;
            const rs: u5 = @truncate(inst >> 16);
            const rt2: u5 = @truncate(inst >> 10);
            const rn: u5 = @truncate(inst >> 5);
            const rt: u5 = @truncate(inst);
            const addr = getXOrSp(cpu, rn);

            // CAS / CASP (`o2=1, o1=1`)
            if (o2 and o1) {
                if (size == 2) {
                    const cur = try readData32(cpu, bus, addr);
                    if (cur == getW(cpu, rs)) {
                        try writeData32(cpu, bus, addr, getW(cpu, rt));
                    }
                    setW(cpu, rs, cur);
                } else if (size == 3) {
                    const cur = try readData64(cpu, bus, addr);
                    if (cur == getX(cpu, rs)) {
                        try writeData64(cpu, bus, addr, getX(cpu, rt));
                    }
                    setX(cpu, rs, cur);
                }
                return;
            }

            if (!o2) {
                // Exclusive Load/Store (single `o1=0` or pair `o1=1`)
                if (is_load) {
                    const paddr = try cpu.mmu.translate64AtEl(bus.ram, addr, .read, currentEl(cpu));
                    if (!o1) {
                        const loaded: u64 = switch (size) {
                            0 => try readData8(cpu, bus, addr),
                            1 => try readData16(cpu, bus, addr),
                            2 => try readData32(cpu, bus, addr),
                            3 => try readData64(cpu, bus, addr),
                        };
                        if (size == 3) setX(cpu, rt, loaded) else setW(cpu, rt, @truncate(loaded));
                        cpu.excl_val = loaded;
                    } else {
                        if (size == 2) {
                            const v1 = try readData32(cpu, bus, addr);
                            const v2 = try readData32(cpu, bus, addr +% 4);
                            setW(cpu, rt, v1);
                            setW(cpu, rt2, v2);
                            cpu.excl_val = @as(u64, v1) | (@as(u64, v2) << 32);
                        } else {
                            const v1 = try readData64(cpu, bus, addr);
                            const v2 = try readData64(cpu, bus, addr +% 8);
                            setX(cpu, rt, v1);
                            setX(cpu, rt2, v2);
                            cpu.excl_val = v1;
                            cpu.excl_val_hi = v2;
                        }
                    }
                    cpu.excl_valid = true;
                    cpu.excl_paddr = paddr & ~@as(u32, 7);
                } else {
                    const paddr = try cpu.mmu.translate64AtEl(bus.ram, addr, .write, currentEl(cpu));
                    if (!cpu.excl_valid or (paddr & ~@as(u32, 7)) != cpu.excl_paddr) {
                        cpu.excl_valid = false;
                        setW(cpu, rs, 1);
                        return;
                    }
                    cpu.excl_valid = false;
                    if (paddr < bus.ram.len) {
                        const stored = if (!o1) switch (size) {
                            0 => atomic_ram.compareAndSwap(u8, bus.ram, paddr, @truncate(cpu.excl_val), @truncate(getW(cpu, rt))),
                            1 => atomic_ram.compareAndSwap(u16, bus.ram, paddr, @truncate(cpu.excl_val), @truncate(getW(cpu, rt))),
                            2 => atomic_ram.compareAndSwap(u32, bus.ram, paddr, @truncate(cpu.excl_val), getW(cpu, rt)),
                            3 => atomic_ram.compareAndSwap(u64, bus.ram, paddr, cpu.excl_val, getX(cpu, rt)),
                        } else if (size == 2)
                            atomic_ram.compareAndSwap(u64, bus.ram, paddr, cpu.excl_val, @as(u64, getW(cpu, rt)) | (@as(u64, getW(cpu, rt2)) << 32))
                        else
                            atomic_ram.compareAndSwap(u128, bus.ram, paddr, @as(u128, cpu.excl_val) | (@as(u128, cpu.excl_val_hi) << 64), @as(u128, getX(cpu, rt)) | (@as(u128, getX(cpu, rt2)) << 64));
                        setW(cpu, rs, if (stored) 0 else 1);
                        return;
                    }
                    if (!o1) {
                        switch (size) {
                            0 => try writeData8(cpu, bus, addr, @truncate(getW(cpu, rt))),
                            1 => try writeData16(cpu, bus, addr, @truncate(getW(cpu, rt))),
                            2 => try writeData32(cpu, bus, addr, getW(cpu, rt)),
                            3 => try writeData64(cpu, bus, addr, getX(cpu, rt)),
                        }
                    } else {
                        if (size == 2) {
                            try writeData32(cpu, bus, addr, getW(cpu, rt));
                            try writeData32(cpu, bus, addr +% 4, getW(cpu, rt2));
                        } else {
                            try writeData64(cpu, bus, addr, getX(cpu, rt));
                            try writeData64(cpu, bus, addr +% 8, getX(cpu, rt2));
                        }
                    }
                    setW(cpu, rs, 0);
                }
            } else {
                // Load-Acquire / Store-Release (`LDAR` / `STLR`)
                const parallel = atomic_ram.busParallel(bus);
                if (parallel) atomic_ram.fence(&cpu.fence_word);
                defer if (parallel) atomic_ram.fence(&cpu.fence_word);
                if (is_load) {
                    switch (size) {
                        0 => setW(cpu, rt, try readData8(cpu, bus, addr)),
                        1 => setW(cpu, rt, try readData16(cpu, bus, addr)),
                        2 => setW(cpu, rt, try readData32(cpu, bus, addr)),
                        3 => setX(cpu, rt, try readData64(cpu, bus, addr)),
                    }
                } else {
                    switch (size) {
                        0 => try writeData8(cpu, bus, addr, @truncate(getW(cpu, rt))),
                        1 => try writeData16(cpu, bus, addr, @truncate(getW(cpu, rt))),
                        2 => try writeData32(cpu, bus, addr, getW(cpu, rt)),
                        3 => try writeData64(cpu, bus, addr, getX(cpu, rt)),
                    }
                }
            }
        }

        fn executeAtomic(cpu: *CpuType, bus: *Bus, inst: u32, addr: u64) error{Abort}!void {
            const size: u2 = @truncate(inst >> 30);
            const rs: u5 = @truncate(inst >> 16);
            const opc: u3 = @truncate(inst >> 12);
            const rt: u5 = @truncate(inst);
            const old_val: u64 = switch (size) {
                0 => try readData8(cpu, bus, addr),
                1 => try readData16(cpu, bus, addr),
                2 => try readData32(cpu, bus, addr),
                3 => try readData64(cpu, bus, addr),
            };
            const operand = getX(cpu, rs);
            const new_val: u64 = switch (opc) {
                0b000 => old_val +% operand, // LDADD
                0b001 => old_val & ~operand, // LDCLR
                0b010 => old_val ^ operand, // LDEOR
                0b011 => old_val | operand, // LDSET
                else => operand, // SWP (0b1000)
            };
            switch (size) {
                0 => try writeData8(cpu, bus, addr, @truncate(new_val)),
                1 => try writeData16(cpu, bus, addr, @truncate(new_val)),
                2 => try writeData32(cpu, bus, addr, @truncate(new_val)),
                3 => try writeData64(cpu, bus, addr, new_val),
            }
            if (size == 3) setX(cpu, rt, old_val) else setW(cpu, rt, @truncate(old_val));
        }

        fn getSimdLaneU(vec: u128, esize: u3, index: usize) u64 {
            const width_bits: u7 = @as(u7, 1) << esize;
            const sh: u7 = @intCast(index * @as(usize, width_bits));
            const elem: u64 = @truncate(vec >> sh);
            const mask: u64 = if (width_bits >= 64) 0xffff_ffff_ffff_ffff else ((@as(u64, 1) << @intCast(width_bits)) - 1);
            return elem & mask;
        }

        fn setSimdLaneU(vec: u128, esize: u3, index: usize, val: u64) u128 {
            const width_bits: u7 = @as(u7, 1) << esize;
            const sh: u7 = @intCast(index * @as(usize, width_bits));
            const mask64: u64 = if (width_bits >= 64) 0xffff_ffff_ffff_ffff else ((@as(u64, 1) << @intCast(width_bits)) - 1);
            const mask128: u128 = @as(u128, mask64) << sh;
            return (vec & ~mask128) | (@as(u128, val & mask64) << sh);
        }

        fn executeSimdStructLoadStore(cpu: *CpuType, bus: *Bus, inst: u32) error{Abort}!void {
            const q = ((inst >> 30) & 1) != 0;
            const is_single = ((inst >> 24) & 1) != 0;
            const is_post = ((inst >> 23) & 1) != 0;
            const is_load = ((inst >> 22) & 1) != 0;
            const rm: u5 = @truncate(inst >> 16);
            const size: u2 = @truncate(inst >> 10);
            const rn: u5 = @truncate(inst >> 5);
            const rt: u5 = @truncate(inst);
            var addr = getXOrSp(cpu, rn);

            if (is_single) {
                // AdvSIMD load/store single structure (lane-indexed or LD1R..LD4R replicate)
                const r_bit: u3 = @truncate((inst >> 21) & 1);
                const opcode3: u3 = @truncate(inst >> 13);
                const s_bit: u4 = @truncate((inst >> 12) & 1);
                const selem: u5 = @intCast((((opcode3 & 1) << 1) | r_bit) + 1);
                const scale: u2 = @truncate(opcode3 >> 1);
                if (scale == 0b11) {
                    // LD1R / LD2R / LD3R / LD4R (replicate across all lanes)
                    const ebytes: u64 = @as(u64, 1) << size;
                    const esize: u3 = @as(u3, size) + 3;
                    const lanes: usize = if (q) (@as(usize, 16) >> size) else (@as(usize, 8) >> size);
                    var s: u5 = 0;
                    while (s < selem) : (s += 1) {
                        const vreg: u5 = rt +% s;
                        const val: u64 = switch (size) {
                            0 => try readData8(cpu, bus, addr),
                            1 => try readData16(cpu, bus, addr),
                            2 => try readData32(cpu, bus, addr),
                            3 => try readData64(cpu, bus, addr),
                        };
                        var rep: u128 = 0;
                        var l: usize = 0;
                        while (l < lanes) : (l += 1) {
                            rep = setSimdLaneU(rep, esize, l, val);
                        }
                        cpu.vfp.v[vreg] = rep;
                        addr +%= ebytes;
                    }
                } else {
                    const q_u4: u4 = if (q) 1 else 0;
                    const size_u4: u4 = size;
                    const esize: u3 = switch (scale) {
                        0b00 => 3, // 8-bit
                        0b01 => 4, // 16-bit
                        0b10 => if ((size & 1) == 0) @as(u3, 5) else @as(u3, 6), // 32-bit or 64-bit
                        0b11 => unreachable,
                    };
                    const index: usize = switch (esize) {
                        3 => (q_u4 << 3) | (s_bit << 2) | size_u4,
                        4 => (q_u4 << 2) | (s_bit << 1) | (size_u4 >> 1),
                        5 => (q_u4 << 1) | s_bit,
                        6 => q_u4,
                        else => 0,
                    };
                    const ebytes: u64 = @as(u64, 1) << (esize - 3);
                    var s: u5 = 0;
                    while (s < selem) : (s += 1) {
                        const vreg: u5 = rt +% s;
                        if (is_load) {
                            const val: u64 = switch (esize) {
                                3 => try readData8(cpu, bus, addr),
                                4 => try readData16(cpu, bus, addr),
                                5 => try readData32(cpu, bus, addr),
                                6 => try readData64(cpu, bus, addr),
                                else => 0,
                            };
                            cpu.vfp.v[vreg] = setSimdLaneU(cpu.vfp.v[vreg], esize, index, val);
                        } else {
                            const val = getSimdLaneU(cpu.vfp.v[vreg], esize, index);
                            switch (esize) {
                                3 => try writeData8(cpu, bus, addr, @truncate(val)),
                                4 => try writeData16(cpu, bus, addr, @truncate(val)),
                                5 => try writeData32(cpu, bus, addr, @truncate(val)),
                                6 => try writeData64(cpu, bus, addr, val),
                                else => {},
                            }
                        }
                        addr +%= ebytes;
                    }
                }
            } else {
                // AdvSIMD load/store multiple structures
                const opcode: u4 = @truncate(inst >> 12);
                const rpt: u5 = switch (opcode) {
                    0b0111 => 1, // LD1/ST1 (1 reg)
                    0b1010 => 2, // LD1/ST1 (2 regs)
                    0b0110 => 3, // LD1/ST1 (3 regs)
                    0b0010 => 4, // LD1/ST1 (4 regs)
                    else => 1,
                };
                const selem: u5 = switch (opcode) {
                    0b0000 => 4, // LD4/ST4
                    0b0100 => 3, // LD3/ST3
                    0b1000 => 2, // LD2/ST2
                    else => 1, // LD1/ST1
                };
                const bytes_per_reg: u64 = if (q) 16 else 8;
                if (selem == 1) {
                    var r_idx: u5 = 0;
                    while (r_idx < rpt) : (r_idx += 1) {
                        const vreg: u5 = rt +% r_idx;
                        if (is_load) {
                            const lo: u128 = try readData64(cpu, bus, addr);
                            const hi: u128 = if (q) try readData64(cpu, bus, addr +% 8) else 0;
                            cpu.vfp.v[vreg] = lo | (hi << 64);
                        } else {
                            try writeData64(cpu, bus, addr, @truncate(cpu.vfp.v[vreg]));
                            if (q) try writeData64(cpu, bus, addr +% 8, @truncate(cpu.vfp.v[vreg] >> 64));
                        }
                        addr +%= bytes_per_reg;
                    }
                } else {
                    const esize: u3 = @as(u3, size) + 3;
                    const ebytes: u64 = @as(u64, 1) << size;
                    const elements: usize = @intCast(bytes_per_reg >> size);
                    if (is_load) {
                        var s: u5 = 0;
                        while (s < selem) : (s += 1) {
                            cpu.vfp.v[rt +% s] = 0;
                        }
                    }
                    var e: usize = 0;
                    while (e < elements) : (e += 1) {
                        var s: u5 = 0;
                        while (s < selem) : (s += 1) {
                            const vreg: u5 = rt +% s;
                            if (is_load) {
                                const val: u64 = switch (size) {
                                    0 => try readData8(cpu, bus, addr),
                                    1 => try readData16(cpu, bus, addr),
                                    2 => try readData32(cpu, bus, addr),
                                    3 => try readData64(cpu, bus, addr),
                                };
                                cpu.vfp.v[vreg] = setSimdLaneU(cpu.vfp.v[vreg], esize, e, val);
                            } else {
                                const val = getSimdLaneU(cpu.vfp.v[vreg], esize, e);
                                switch (size) {
                                    0 => try writeData8(cpu, bus, addr, @truncate(val)),
                                    1 => try writeData16(cpu, bus, addr, @truncate(val)),
                                    2 => try writeData32(cpu, bus, addr, @truncate(val)),
                                    3 => try writeData64(cpu, bus, addr, val),
                                }
                            }
                            addr +%= ebytes;
                        }
                    }
                }
            }
            if (is_post) {
                if (rm == 31) {
                    setXOrSp(cpu, rn, addr);
                } else {
                    setXOrSp(cpu, rn, getXOrSp(cpu, rn) +% getX(cpu, rm));
                }
            }
        }

        fn extendReg(val: u64, option: u3, shift: u3) u64 {
            const extended: u64 = switch (option) {
                0b000 => @as(u8, @truncate(val)), // UXTB
                0b001 => @as(u16, @truncate(val)), // UXTH
                0b010 => @as(u32, @truncate(val)), // UXTW
                0b011 => val, // UXTX / LSL
                0b100 => @bitCast(@as(i64, @as(i8, @bitCast(@as(u8, @truncate(val)))))), // SXTB
                0b101 => @bitCast(@as(i64, @as(i16, @bitCast(@as(u16, @truncate(val)))))), // SXTH
                0b110 => @bitCast(@as(i64, @as(i32, @bitCast(@as(u32, @truncate(val)))))), // SXTW
                0b111 => val, // SXTX
            };
            return extended << shift;
        }

        fn shiftReg(sf: u1, val_raw: u64, shift_type: u2, amount: u6) u64 {
            if (sf == 1) {
                return switch (shift_type) {
                    0b00 => val_raw << amount,
                    0b01 => val_raw >> amount,
                    0b10 => @bitCast(@as(i64, @bitCast(val_raw)) >> amount),
                    0b11 => if (amount == 0) val_raw else ((val_raw >> amount) | (val_raw << @intCast(@as(u7, 64) - amount))),
                };
            } else {
                const v: u32 = @truncate(val_raw);
                const sh: u5 = @truncate(amount);
                return switch (shift_type) {
                    0b00 => v << sh,
                    0b01 => v >> sh,
                    0b10 => @as(u32, @bitCast(@as(i32, @bitCast(v)) >> sh)),
                    0b11 => if (sh == 0) v else ((v >> sh) | (v << @intCast(@as(u6, 32) - sh))),
                };
            }
        }

        noinline fn executeDpReg(cpu: *CpuType, inst: u32) void {
            const sf: u1 = @truncate(inst >> 31);
            const op0: u1 = @truncate(inst >> 30);
            const s: u1 = @truncate(inst >> 29);
            const op1: u1 = @truncate(inst >> 28);
            const op2: u4 = @truncate(inst >> 21);
            const rm: u5 = @truncate(inst >> 16);
            const rn: u5 = @truncate(inst >> 5);
            const rd: u5 = @truncate(inst);

            if (op1 == 0) {
                if ((op2 & 0b1000) == 0) {
                    // Logical (shifted register)
                    const shift_type: u2 = @truncate(inst >> 22);
                    const invert = (op2 & 1) != 0;
                    const imm6: u6 = @truncate(inst >> 10);
                    const a = getX(cpu, rn);
                    var b = shiftReg(sf, getX(cpu, rm), shift_type, imm6);
                    if (invert) b = ~b;
                    const opc: u2 = (@as(u2, op0) << 1) | s;
                    var res: u64 = switch (opc) {
                        0b00 => a & b, // AND / BIC
                        0b01 => a | b, // ORR / ORN
                        0b10 => a ^ b, // EOR / EON
                        0b11 => a & b, // ANDS / BICS
                    };
                    if (sf == 0) res &= 0xffff_ffff;
                    if (opc == 0b11) {
                        const sign_bit: u6 = if (sf == 1) 63 else 31;
                        setNzcv(cpu, ((res >> sign_bit) & 1) != 0, res == 0, false, false);
                    }
                    setX(cpu, rd, res);
                } else {
                    // Add/subtract (shifted register or extended register)
                    const is_ext = (op2 & 1) != 0;
                    if (!is_ext) {
                        const shift_type: u2 = @truncate(inst >> 22);
                        const imm6: u6 = @truncate(inst >> 10);
                        const a = getX(cpu, rn);
                        const b = shiftReg(sf, getX(cpu, rm), shift_type, imm6);
                        addSub(cpu, sf, op0 == 1, s == 1, rd, a, b, if (op0 == 1) 1 else 0, false);
                    } else {
                        const option: u3 = @truncate(inst >> 13);
                        const imm3: u3 = @truncate(inst >> 10);
                        const a = getXOrSp(cpu, rn);
                        const b = extendReg(getX(cpu, rm), option, imm3);
                        addSub(cpu, sf, op0 == 1, s == 1, rd, a, b, if (op0 == 1) 1 else 0, s == 0);
                    }
                }
                return;
            }

            // op1 == 1
            if (op2 == 0b0000) {
                // Add/subtract (with carry): ADC, ADCS, SBC, SBCS
                const c_in: u1 = if ((cpu.pstate & PstateFlags.C) != 0) 1 else 0;
                addSub(cpu, sf, op0 == 1, s == 1, rd, getX(cpu, rn), getX(cpu, rm), c_in, false);
            } else if (op2 == 0b0010) {
                // Conditional compare (register / immediate): CCMP, CCMN
                const cond: u4 = @truncate(inst >> 12);
                const nzcv_imm: u32 = (inst & 0xf) << 28;
                const is_imm = ((inst >> 11) & 1) != 0;
                if (evalCond(cpu.pstate, cond)) {
                    const b: u64 = if (is_imm) rm else getX(cpu, rm);
                    addSub(cpu, sf, op0 == 1, true, 31, getX(cpu, rn), b, if (op0 == 1) 1 else 0, false);
                } else {
                    cpu.pstate = (cpu.pstate & 0x0fff_ffff) | nzcv_imm;
                }
            } else if (op2 == 0b0100) {
                // Conditional select: CSEL, CSINC, CSINV, CSNEG
                const cond: u4 = @truncate(inst >> 12);
                const o2 = ((inst >> 10) & 1) != 0;
                var res: u64 = if (evalCond(cpu.pstate, cond))
                    getX(cpu, rn)
                else blk: {
                    var v = getX(cpu, rm);
                    if (op0 == 1) v = ~v;
                    if (o2) v +%= 1;
                    break :blk v;
                };
                if (sf == 0) res &= 0xffff_ffff;
                setX(cpu, rd, res);
            } else if ((op2 & 0b1000) != 0) {
                // Data-processing (3-source): MADD, MSUB, SMADDL, SMSUBL, SMULH, UMADDL, UMSUBL, UMULH
                const op31: u3 = @truncate(inst >> 21);
                const o0 = ((inst >> 15) & 1) != 0;
                const ra: u5 = @truncate(inst >> 10);
                if (op31 == 0b000) {
                    const a = getX(cpu, rn);
                    const b = getX(cpu, rm);
                    const c = getX(cpu, ra);
                    const res = if (o0) (c -% (a *% b)) else (c +% (a *% b));
                    if (sf == 1) setX(cpu, rd, res) else setW(cpu, rd, @truncate(res));
                } else if (op31 == 0b001) { // SMADDL / SMSUBL
                    const a: i64 = @as(i32, @bitCast(getW(cpu, rn)));
                    const b: i64 = @as(i32, @bitCast(getW(cpu, rm)));
                    const c: i64 = @bitCast(getX(cpu, ra));
                    const res: i64 = if (o0) (c -% (a * b)) else (c +% (a * b));
                    setX(cpu, rd, @bitCast(res));
                } else if (op31 == 0b010) { // SMULH
                    const a: i128 = @as(i64, @bitCast(getX(cpu, rn)));
                    const b: i128 = @as(i64, @bitCast(getX(cpu, rm)));
                    setX(cpu, rd, @truncate(@as(u128, @bitCast(a * b)) >> 64));
                } else if (op31 == 0b101) { // UMADDL / UMSUBL
                    const a: u64 = getW(cpu, rn);
                    const b: u64 = getW(cpu, rm);
                    const c: u64 = getX(cpu, ra);
                    const res: u64 = if (o0) (c -% (a * b)) else (c +% (a * b));
                    setX(cpu, rd, res);
                } else if (op31 == 0b110) { // UMULH
                    const a: u128 = getX(cpu, rn);
                    const b: u128 = getX(cpu, rm);
                    setX(cpu, rd, @truncate((a * b) >> 64));
                }
            } else if (op2 == 0b0110) {
                const opcode: u6 = @truncate(inst >> 10);
                if (op0 == 0) {
                    // Data-processing (2-source): UDIV (2), SDIV (3), LSLV (8), LSRV (9), ASRV (10), RORV (11), CRC32* (16..23)
                    if ((opcode & 0b111000) == 0b010000) {
                        const poly: u32 = if ((opcode & 0b000100) != 0) 0x82f6_3b78 else 0xedb8_8320;
                        const sz: u2 = @truncate(opcode);
                        const nbytes: usize = @as(usize, 1) << sz;
                        var crc: u32 = getW(cpu, rn);
                        var v: u64 = getX(cpu, rm);
                        for (0..nbytes) |_| {
                            crc ^= @as(u8, @truncate(v));
                            for (0..8) |_| {
                                crc = (crc >> 1) ^ (if ((crc & 1) != 0) poly else 0);
                            }
                            v >>= 8;
                        }
                        setW(cpu, rd, crc);
                        return;
                    }
                    if (sf == 1) {
                        const a = getX(cpu, rn);
                        const b = getX(cpu, rm);
                        const sh: u6 = @truncate(b);
                        const res: u64 = switch (opcode) {
                            0b000010 => if (b == 0) 0 else a / b,
                            0b000011 => blk: {
                                if (b == 0) break :blk 0;
                                const sa: i64 = @bitCast(a);
                                const sb: i64 = @bitCast(b);
                                if (sa == std.math.minInt(i64) and sb == -1) break :blk @bitCast(sa);
                                break :blk @bitCast(@divTrunc(sa, sb));
                            },
                            0b001000 => a << sh,
                            0b001001 => a >> sh,
                            0b001010 => @bitCast(@as(i64, @bitCast(a)) >> sh),
                            0b001011 => if (sh == 0) a else ((a >> sh) | (a << @intCast(@as(u7, 64) - sh))),
                            else => 0,
                        };
                        setX(cpu, rd, res);
                    } else {
                        const a = getW(cpu, rn);
                        const b = getW(cpu, rm);
                        const sh: u5 = @truncate(b);
                        const res: u32 = switch (opcode) {
                            0b000010 => if (b == 0) 0 else a / b,
                            0b000011 => blk: {
                                if (b == 0) break :blk 0;
                                const sa: i32 = @bitCast(a);
                                const sb: i32 = @bitCast(b);
                                if (sa == std.math.minInt(i32) and sb == -1) break :blk @bitCast(sa);
                                break :blk @bitCast(@divTrunc(sa, sb));
                            },
                            0b001000 => a << sh,
                            0b001001 => a >> sh,
                            0b001010 => @bitCast(@as(i32, @bitCast(a)) >> sh),
                            0b001011 => if (sh == 0) a else ((a >> sh) | (a << @intCast(@as(u6, 32) - sh))),
                            else => 0,
                        };
                        setW(cpu, rd, res);
                    }
                } else {
                    // Data-processing (1-source): RBIT (0), REV16 (1), REV32 (2), REV64 (3), CLZ (4), CLS (5)
                    if (sf == 1) {
                        const a = getX(cpu, rn);
                        const res: u64 = switch (opcode) {
                            0 => (@as(u64, reverseBits32(@as(u32, @truncate(a)))) << 32) |
                                @as(u64, reverseBits32(@as(u32, @truncate(a >> 32)))),
                            1 => (@as(u64, @byteSwap(@as(u16, @truncate(a)))) |
                                (@as(u64, @byteSwap(@as(u16, @truncate(a >> 16)))) << 16) |
                                (@as(u64, @byteSwap(@as(u16, @truncate(a >> 32)))) << 32) |
                                (@as(u64, @byteSwap(@as(u16, @truncate(a >> 48)))) << 48)),
                            2 => (@as(u64, @byteSwap(@as(u32, @truncate(a)))) |
                                (@as(u64, @byteSwap(@as(u32, @truncate(a >> 32)))) << 32)),
                            3 => @byteSwap(a),
                            4 => @clz(a),
                            5 => @clz(if ((a >> 63) != 0) ~a else a) -| 1,
                            else => 0,
                        };
                        setX(cpu, rd, res);
                    } else {
                        const a = getW(cpu, rn);
                        const res: u32 = switch (opcode) {
                            0 => reverseBits32(a),
                            1 => (@as(u32, @byteSwap(@as(u16, @truncate(a)))) |
                                (@as(u32, @byteSwap(@as(u16, @truncate(a >> 16)))) << 16)),
                            2 => @byteSwap(a),
                            4 => @clz(a),
                            5 => @clz(if ((a >> 31) != 0) ~a else a) -| 1,
                            else => 0,
                        };
                        setW(cpu, rd, res);
                    }
                }
            }
        }

        fn reverseBits32(x0: u32) u32 {
            var x = x0;
            x = ((x >> 1) & 0x5555_5555) | ((x & 0x5555_5555) << 1);
            x = ((x >> 2) & 0x3333_3333) | ((x & 0x3333_3333) << 2);
            x = ((x >> 4) & 0x0f0f_0f0f) | ((x & 0x0f0f_0f0f) << 4);
            return @byteSwap(x);
        }

        fn expandFpImm32(imm8: u8) u32 {
            const sign: u32 = @as(u32, imm8 >> 7) << 31;
            const exp_hi: u32 = if ((imm8 & 0x40) == 0) 0b100000 else 0b011111;
            const exp: u32 = (exp_hi << 2) | @as(u32, (imm8 >> 4) & 3);
            const frac: u32 = @as(u32, imm8 & 0xf) << 19;
            return sign | (exp << 23) | frac;
        }

        fn expandFpImm64(imm8: u8) u64 {
            const sign: u64 = @as(u64, imm8 >> 7) << 63;
            const exp_hi: u64 = if ((imm8 & 0x40) == 0) 0b100000000 else 0b011111111;
            const exp: u64 = (exp_hi << 2) | @as(u64, (imm8 >> 4) & 3);
            const frac: u64 = @as(u64, imm8 & 0xf) << 48;
            return sign | (exp << 52) | frac;
        }

        noinline fn executeFpSimd(cpu: *CpuType, inst: u32) void {
            const rd: u5 = @truncate(inst);
            const rn: u5 = @truncate(inst >> 5);
            const rm: u5 = @truncate(inst >> 16);

            // 1. Scalar FP <-> GPR conversions & FMOV (`(inst & 0x5f20_0000) == 0x1e20_0000`)
            // 0. Scalar FP <-> Fixed-point conversions (`SCVTF`, `UCVTF`, `FCVTZS`, `FCVTZU`: `(inst & 0x5f20_0000) == 0x1e00_0000`)
            if ((inst & 0x5f20_0000) == 0x1e00_0000) {
                const sf = ((inst >> 31) & 1) != 0;
                const ftype: u2 = @truncate(inst >> 22);
                const is_dbl = (ftype == 1);
                const opcode: u3 = @truncate(inst >> 16);
                const scale: u6 = @truncate(inst >> 10);
                const fbits: u6 = @intCast(@as(u7, 64) - scale);
                const factor: f64 = @floatFromInt(@as(u64, 1) << fbits);
                switch (opcode) {
                    0b010 => { // SCVTF (fixed-point)
                        const iv: f64 = if (sf) @floatFromInt(@as(i64, @bitCast(getX(cpu, rn)))) else @floatFromInt(@as(i32, @bitCast(getW(cpu, rn))));
                        const fv = iv / factor;
                        cpu.vfp.v[rd] = if (is_dbl) @as(u64, @bitCast(fv)) else @as(u32, @bitCast(@as(f32, @floatCast(fv))));
                    },
                    0b011 => { // UCVTF (fixed-point)
                        const uv: f64 = if (sf) @floatFromInt(getX(cpu, rn)) else @floatFromInt(getW(cpu, rn));
                        const fv = uv / factor;
                        cpu.vfp.v[rd] = if (is_dbl) @as(u64, @bitCast(fv)) else @as(u32, @bitCast(@as(f32, @floatCast(fv))));
                    },
                    0b000, 0b001 => { // FCVTZS (000) / FCVTZU (001) (fixed-point)
                        const raw_fv: f64 = if (is_dbl) @bitCast(@as(u64, @truncate(cpu.vfp.v[rn]))) else @as(f64, @as(f32, @bitCast(@as(u32, @truncate(cpu.vfp.v[rn])))));
                        const fv = @trunc(raw_fv * factor);
                        if (std.math.isNan(fv)) {
                            if (sf) setX(cpu, rd, 0) else setW(cpu, rd, 0);
                        } else if (opcode == 0b000) {
                            if (sf) {
                                const c = std.math.clamp(fv, -9223372036854775808.0, 9223372036854774784.0);
                                setX(cpu, rd, @bitCast(@as(i64, @intFromFloat(c))));
                            } else {
                                const c = std.math.clamp(fv, -2147483648.0, 2147483647.0);
                                setW(cpu, rd, @bitCast(@as(i32, @intFromFloat(c))));
                            }
                        } else {
                            if (sf) {
                                const c = std.math.clamp(fv, 0.0, 18446744073709549568.0);
                                setX(cpu, rd, @intFromFloat(c));
                            } else {
                                const c = std.math.clamp(fv, 0.0, 4294967295.0);
                                setW(cpu, rd, @intFromFloat(c));
                            }
                        }
                    },
                    else => {},
                }
                return;
            }

            if ((inst & 0x5f20_0000) == 0x1e20_0000) {
                const sf = ((inst >> 31) & 1) != 0;
                const ftype: u2 = @truncate(inst >> 22);
                const is_dbl = (ftype == 1);

                if ((inst & 0x0000_fc00) == 0x0000_0000 and ((inst >> 21) & 1) == 1) {
                    // Conversion between FP and Int (`SCVTF`, `UCVTF`, `FCVT*S`, `FCVT*U`, `FMOV` GPR<->FP)
                    const rmode: u2 = @truncate(inst >> 19);
                    const opcode: u3 = @truncate(inst >> 16);
                    if (opcode == 0b110 and rmode == 0b00) { // FMOV Wt/Xt, Sn/Dn
                        if (sf) setX(cpu, rd, @truncate(cpu.vfp.v[rn])) else setW(cpu, rd, @truncate(cpu.vfp.v[rn]));
                        return;
                    }
                    if (opcode == 0b111 and rmode == 0b00) { // FMOV Sd/Dd, Wn/Xn
                        cpu.vfp.v[rd] = if (sf) getX(cpu, rn) else getW(cpu, rn);
                        return;
                    }
                    if (opcode == 0b110 and rmode == 0b01) { // FMOV Xt, Vn.D[1]
                        setX(cpu, rd, @truncate(cpu.vfp.v[rn] >> 64));
                        return;
                    }
                    if (opcode == 0b111 and rmode == 0b01) { // FMOV Vd.D[1], Xn
                        cpu.vfp.v[rd] = (cpu.vfp.v[rd] & 0xffff_ffff_ffff_ffff) | (@as(u128, getX(cpu, rn)) << 64);
                        return;
                    }
                    if (opcode == 0b010) { // SCVTF
                        const iv: f64 = if (sf) @floatFromInt(@as(i64, @bitCast(getX(cpu, rn)))) else @floatFromInt(@as(i32, @bitCast(getW(cpu, rn))));
                        cpu.vfp.v[rd] = if (is_dbl) @as(u64, @bitCast(iv)) else @as(u32, @bitCast(@as(f32, @floatCast(iv))));
                        return;
                    }
                    if (opcode == 0b011) { // UCVTF
                        const uv: f64 = if (sf) @floatFromInt(getX(cpu, rn)) else @floatFromInt(getW(cpu, rn));
                        cpu.vfp.v[rd] = if (is_dbl) @as(u64, @bitCast(uv)) else @as(u32, @bitCast(@as(f32, @floatCast(uv))));
                        return;
                    }
                    if (opcode == 0b000 or opcode == 0b001 or opcode == 0b100 or opcode == 0b101) {
                        // FCVTNS/NU (rmode=00), FCVTPS/PU (rmode=01), FCVTMS/MU (rmode=10), FCVTZS/ZU (rmode=11), FCVTAS/AU (opcode=100/101)
                        const raw_fv: f64 = if (is_dbl) @bitCast(@as(u64, @truncate(cpu.vfp.v[rn]))) else @as(f64, @as(f32, @bitCast(@as(u32, @truncate(cpu.vfp.v[rn])))));
                        const fv: f64 = if (opcode >= 0b100) @round(raw_fv) else switch (rmode) {
                            0b00 => @round(raw_fv),
                            0b01 => @ceil(raw_fv),
                            0b10 => @floor(raw_fv),
                            0b11 => @trunc(raw_fv),
                        };
                        const is_unsigned = (opcode & 1) != 0;
                        if (std.math.isNan(fv)) {
                            if (sf) setX(cpu, rd, 0) else setW(cpu, rd, 0);
                        } else if (!is_unsigned) {
                            if (sf) {
                                const clamped = std.math.clamp(fv, -9223372036854775808.0, 9223372036854774784.0);
                                setX(cpu, rd, @bitCast(@as(i64, @intFromFloat(clamped))));
                            } else {
                                const clamped = std.math.clamp(fv, -2147483648.0, 2147483647.0);
                                setW(cpu, rd, @bitCast(@as(i32, @intFromFloat(clamped))));
                            }
                        } else {
                            if (sf) {
                                const clamped = std.math.clamp(fv, 0.0, 18446744073709549568.0);
                                setX(cpu, rd, @intFromFloat(clamped));
                            } else {
                                const clamped = std.math.clamp(fv, 0.0, 4294967295.0);
                                setW(cpu, rd, @intFromFloat(clamped));
                            }
                        }
                        return;
                    }
                }

                // Scalar FP immediate (`FMOV Sd/Dd, #imm8`: `(inst & 0xffa0_1fe0) == 0x1e20_1000`)
                if ((inst & 0xffa0_1fe0) == 0x1e20_1000) {
                    const imm8: u8 = @truncate(inst >> 13);
                    cpu.vfp.v[rd] = if (is_dbl) expandFpImm64(imm8) else expandFpImm32(imm8);
                    return;
                }

                // Scalar FP 2-source (`FMUL`, `FDIV`, `FADD`, `FSUB`, `FMAX`, `FMIN`, `FMAXNM`, `FMINNM`, `FNMUL`)
                if ((inst & 0xffe0_0c00) == 0x1e20_0800 or (inst & 0xffe0_0c00) == 0x1e60_0800) {
                    const opc: u4 = @truncate(inst >> 12);
                    if (is_dbl) {
                        const a: f64 = @bitCast(@as(u64, @truncate(cpu.vfp.v[rn])));
                        const b: f64 = @bitCast(@as(u64, @truncate(cpu.vfp.v[rm])));
                        const res: f64 = switch (opc) {
                            0 => a * b,
                            1 => a / b,
                            2 => a + b,
                            3 => a - b,
                            4, 6 => @max(a, b),
                            5, 7 => @min(a, b),
                            8 => -(a * b),
                            else => a,
                        };
                        cpu.vfp.v[rd] = @as(u64, @bitCast(res));
                    } else {
                        const a: f32 = @bitCast(@as(u32, @truncate(cpu.vfp.v[rn])));
                        const b: f32 = @bitCast(@as(u32, @truncate(cpu.vfp.v[rm])));
                        const res: f32 = switch (opc) {
                            0 => a * b,
                            1 => a / b,
                            2 => a + b,
                            3 => a - b,
                            4, 6 => @max(a, b),
                            5, 7 => @min(a, b),
                            8 => -(a * b),
                            else => a,
                        };
                        cpu.vfp.v[rd] = @as(u32, @bitCast(res));
                    }
                    return;
                }

                // Scalar FP 1-source (`FMOV`, `FABS`, `FNEG`, `FSQRT`, `FCVT`, `FRINT*`)
                if ((inst & 0xffa0_7c00) == 0x1e20_4000) {
                    const opc: u6 = @truncate(inst >> 15);
                    if (is_dbl) {
                        const a: f64 = @bitCast(@as(u64, @truncate(cpu.vfp.v[rn])));
                        switch (opc) {
                            0 => cpu.vfp.v[rd] = @as(u64, @bitCast(a)), // FMOV
                            1 => cpu.vfp.v[rd] = @as(u64, @bitCast(@abs(a))), // FABS
                            2 => cpu.vfp.v[rd] = @as(u64, @bitCast(-a)), // FNEG
                            3 => cpu.vfp.v[rd] = @as(u64, @bitCast(@sqrt(a))), // FSQRT
                            4 => cpu.vfp.v[rd] = @as(u32, @bitCast(@as(f32, @floatCast(a)))), // FCVT Sd, Dn
                            8, 12, 14, 15 => cpu.vfp.v[rd] = @as(u64, @bitCast(@round(a))), // FRINTN/A/X/I
                            9 => cpu.vfp.v[rd] = @as(u64, @bitCast(@ceil(a))), // FRINTP
                            10 => cpu.vfp.v[rd] = @as(u64, @bitCast(@floor(a))), // FRINTM
                            11 => cpu.vfp.v[rd] = @as(u64, @bitCast(@trunc(a))), // FRINTZ
                            else => {},
                        }
                    } else {
                        const a: f32 = @bitCast(@as(u32, @truncate(cpu.vfp.v[rn])));
                        switch (opc) {
                            0 => cpu.vfp.v[rd] = @as(u32, @bitCast(a)),
                            1 => cpu.vfp.v[rd] = @as(u32, @bitCast(@abs(a))),
                            2 => cpu.vfp.v[rd] = @as(u32, @bitCast(-a)),
                            3 => cpu.vfp.v[rd] = @as(u32, @bitCast(@sqrt(a))),
                            5 => cpu.vfp.v[rd] = @as(u64, @bitCast(@as(f64, a))), // FCVT Dd, Sn
                            8, 12, 14, 15 => cpu.vfp.v[rd] = @as(u32, @bitCast(@round(a))),
                            9 => cpu.vfp.v[rd] = @as(u32, @bitCast(@ceil(a))),
                            10 => cpu.vfp.v[rd] = @as(u32, @bitCast(@floor(a))),
                            11 => cpu.vfp.v[rd] = @as(u32, @bitCast(@trunc(a))),
                            else => {},
                        }
                    }
                    return;
                }

                // Scalar FP compare (`FCMP`, `FCMPE`: `(inst & 0xffa0_fc07) == 0x1e20_2000`)
                if ((inst & 0xffa0_fc07) == 0x1e20_2000) {
                    const cmp_zero = ((inst >> 3) & 1) != 0;
                    const a: f64 = if (is_dbl) @bitCast(@as(u64, @truncate(cpu.vfp.v[rn]))) else @as(f64, @as(f32, @bitCast(@as(u32, @truncate(cpu.vfp.v[rn])))));
                    const b: f64 = if (cmp_zero) 0.0 else if (is_dbl) @bitCast(@as(u64, @truncate(cpu.vfp.v[rm]))) else @as(f64, @as(f32, @bitCast(@as(u32, @truncate(cpu.vfp.v[rm])))));
                    if (std.math.isNan(a) or std.math.isNan(b)) {
                        setNzcv(cpu, false, false, true, true);
                    } else if (a == b) {
                        setNzcv(cpu, false, true, true, false);
                    } else if (a < b) {
                        setNzcv(cpu, true, false, false, false);
                    } else {
                        setNzcv(cpu, false, false, true, false);
                    }
                    return;
                }

                // Scalar FP conditional compare (`FCCMP`, `FCCMPE`: `(inst & 0xffa0_0c00) == 0x1e20_0400`)
                if ((inst & 0xffa0_0c00) == 0x1e20_0400) {
                    const cond: u4 = @truncate(inst >> 12);
                    const nzcv_imm: u32 = (inst & 0xf) << 28;
                    if (evalCond(cpu.pstate, cond)) {
                        const a: f64 = if (is_dbl) @bitCast(@as(u64, @truncate(cpu.vfp.v[rn]))) else @as(f64, @as(f32, @bitCast(@as(u32, @truncate(cpu.vfp.v[rn])))));
                        const b: f64 = if (is_dbl) @bitCast(@as(u64, @truncate(cpu.vfp.v[rm]))) else @as(f64, @as(f32, @bitCast(@as(u32, @truncate(cpu.vfp.v[rm])))));
                        if (std.math.isNan(a) or std.math.isNan(b)) {
                            setNzcv(cpu, false, false, true, true);
                        } else if (a == b) {
                            setNzcv(cpu, false, true, true, false);
                        } else if (a < b) {
                            setNzcv(cpu, true, false, false, false);
                        } else {
                            setNzcv(cpu, false, false, true, false);
                        }
                    } else {
                        cpu.pstate = (cpu.pstate & 0x0fff_ffff) | nzcv_imm;
                    }
                    return;
                }

                // Scalar FP conditional select (`FCSEL`: `(inst & 0xffa0_0c00) == 0x1e20_0c00`)
                if ((inst & 0xffa0_0c00) == 0x1e20_0c00) {
                    const cond: u4 = @truncate(inst >> 12);
                    const sel = if (evalCond(cpu.pstate, cond)) cpu.vfp.v[rn] else cpu.vfp.v[rm];
                    cpu.vfp.v[rd] = if (is_dbl) @as(u64, @truncate(sel)) else @as(u32, @truncate(sel));
                    return;
                }
            }

            // 1b. Scalar FP 3-source (`FMADD`, `FMSUB`, `FNMADD`, `FNMSUB`: `(inst & 0x5f00_0000) == 0x1f00_0000`)
            if ((inst & 0x5f00_0000) == 0x1f00_0000) {
                const ftype: u2 = @truncate(inst >> 22);
                const is_dbl = (ftype == 1);
                const o1 = ((inst >> 21) & 1) != 0;
                const o0 = ((inst >> 15) & 1) != 0;
                const ra: u5 = @truncate(inst >> 10);
                if (is_dbl) {
                    const n: f64 = @bitCast(@as(u64, @truncate(cpu.vfp.v[rn])));
                    const m: f64 = @bitCast(@as(u64, @truncate(cpu.vfp.v[rm])));
                    const a: f64 = @bitCast(@as(u64, @truncate(cpu.vfp.v[ra])));
                    const prod: f64 = if (o0) -(n * m) else (n * m);
                    const res: f64 = (if (o1) -a else a) + prod;
                    cpu.vfp.v[rd] = @as(u64, @bitCast(res));
                } else {
                    const n: f32 = @bitCast(@as(u32, @truncate(cpu.vfp.v[rn])));
                    const m: f32 = @bitCast(@as(u32, @truncate(cpu.vfp.v[rm])));
                    const a: f32 = @bitCast(@as(u32, @truncate(cpu.vfp.v[ra])));
                    const prod: f32 = if (o0) -(n * m) else (n * m);
                    const res: f32 = (if (o1) -a else a) + prod;
                    cpu.vfp.v[rd] = @as(u32, @bitCast(res));
                }
                return;
            }

            // 2. AdvSIMD modified immediate (`MOVI`, `MVNI`, `ORR`, `BIC`, `FMOV`) (`immh == 0`: `(inst & 0x9ff8_0400) == 0x0f00_0400`)
            if ((inst & 0x9ff8_0400) == 0x0f00_0400) {
                const q = ((inst >> 30) & 1) != 0;
                const op = ((inst >> 29) & 1) != 0;
                const cmode: u4 = @truncate(inst >> 12);
                const abc: u8 = @truncate((inst >> 16) & 7);
                const defgh: u8 = @truncate((inst >> 5) & 0x1f);
                const imm8: u8 = (abc << 5) | defgh;
                const mask: u128 = if (q) ~@as(u128, 0) else 0xffff_ffff_ffff_ffff;

                var val64: u64 = 0;
                if (cmode == 0b1111) {
                    if (!op) {
                        const f32_bits: u64 = expandFpImm32(imm8);
                        val64 = f32_bits | (f32_bits << 32);
                    } else {
                        val64 = expandFpImm64(imm8);
                    }
                } else if (cmode == 0b1110 and !op) {
                    val64 = @as(u64, imm8) * 0x0101_0101_0101_0101;
                } else if (cmode == 0b1110 and op) {
                    var i: u6 = 0;
                    while (i < 8) : (i += 1) {
                        if (((imm8 >> @intCast(i)) & 1) != 0) {
                            val64 |= @as(u64, 0xff) << (i * 8);
                        }
                    }
                } else if (cmode < 0b1100) {
                    // 32-bit (0000..0111) or 16-bit (1000..1011) immediate:
                    // MOVI (cmode[0]=0, op=0), MVNI (cmode[0]=0, op=1), ORR (cmode[0]=1, op=0), BIC (cmode[0]=1, op=1)
                    const is_16 = (cmode & 0b1000) != 0;
                    const sh: u5 = if (is_16) @as(u5, (cmode >> 1) & 1) * 8 else @as(u5, (cmode >> 1) & 3) * 8;
                    const elem: u64 = (@as(u64, imm8) << sh);
                    if (is_16) {
                        const rep16: u64 = (elem & 0xffff) * 0x0001_0001_0001_0001;
                        val64 = if (op) ~rep16 else rep16;
                    } else {
                        const rep32: u64 = (elem & 0xffff_ffff) * 0x0000_0001_0000_0001;
                        val64 = if (op) ~rep32 else rep32;
                    }
                    if ((cmode & 1) != 0) {
                        const imm128 = @as(u128, val64) | (@as(u128, val64) << 64);
                        const cur = cpu.vfp.v[rd];
                        cpu.vfp.v[rd] = (if (op) (cur & imm128) else (cur | imm128)) & mask;
                        return;
                    }
                } else if ((cmode & 0b1110) == 0b1100) {
                    // Shifting ones (MSL)
                    const sh: u5 = if ((cmode & 1) != 0) 16 else 8;
                    const elem32: u64 = ((@as(u64, imm8) << sh) | ((@as(u64, 1) << sh) - 1)) & 0xffff_ffff;
                    const rep32: u64 = elem32 | (elem32 << 32);
                    val64 = if (op) ~rep32 else rep32;
                } else {
                    const byte_val: u64 = if (op) ~@as(u64, imm8) & 0xff else imm8;
                    const sh: u5 = @as(u5, (cmode >> 1) & 3) * 8;
                    const elem32: u64 = (byte_val << sh) & 0xffff_ffff;
                    val64 = elem32 | (elem32 << 32);
                }
                cpu.vfp.v[rd] = if (q) (@as(u128, val64) | (@as(u128, val64) << 64)) else @as(u128, val64);
                return;
            }

            // 2b. AdvSIMD shift by immediate (vector & scalar) (`immh != 0`: `(inst & 0x9f80_0400) == 0x0f00_0400` or `(inst & 0xdf80_0400) == 0x5f00_0400`)
            if (((inst & 0x9f80_0400) == 0x0f00_0400 or (inst & 0xdf80_0400) == 0x5f00_0400) and ((inst >> 19) & 0xf) != 0) {
                const is_scalar = ((inst >> 28) & 1) != 0;
                const q = ((inst >> 30) & 1) != 0;
                const u = ((inst >> 29) & 1) != 0;
                const immh: u4 = @truncate(inst >> 19);
                const immb: u3 = @truncate(inst >> 16);
                const immhb: u7 = (@as(u7, immh) << 3) | immb;
                const opcode: u5 = @truncate(inst >> 11);
                const esize: u7 = if ((immh & 8) != 0) 64 else if ((immh & 4) != 0) 32 else if ((immh & 2) != 0) 16 else 8;
                const rshift: u6 = @intCast((esize * 2) - immhb);
                const lshift: u6 = @intCast(immhb - esize);
                const va = cpu.vfp.v[rn];

                if (opcode == 0b10000 or opcode == 0b10001) {
                    // SHRN / SHRN2 / RSHRN / RSHRN2 (narrow from 2*esize in 128-bit Vn to esize in 64-bit half of Vd)
                    const src_bits: u8 = @as(u8, esize) * 2;
                    const lanes: usize = @intCast(64 / esize);
                    const round: u64 = if ((opcode & 1) != 0 and rshift > 0) (@as(u64, 1) << (rshift - 1)) else 0;
                    const emask: u64 = (@as(u64, 1) << @intCast(esize)) - 1;
                    var narrow64: u64 = 0;
                    for (0..lanes) |i| {
                        const src_sh: u7 = @intCast(i * src_bits);
                        const raw_elem: u64 = @truncate(va >> src_sh);
                        const shifted: u64 = ((raw_elem +% round) >> rshift) & emask;
                        narrow64 |= shifted << @intCast(i * esize);
                    }
                    if (q) {
                        cpu.vfp.v[rd] = (cpu.vfp.v[rd] & 0xffff_ffff_ffff_ffff) | (@as(u128, narrow64) << 64);
                    } else {
                        cpu.vfp.v[rd] = narrow64;
                    }
                    return;
                }

                if (opcode == 0b10100) {
                    // SSHLL / USHLL (widen from esize in low/high 64-bit half of Vn to 2*esize in 128-bit Vd)
                    const dst_bits: u8 = @as(u8, esize) * 2;
                    const lanes: usize = @intCast(64 / esize);
                    const src64: u64 = if (q) @truncate(va >> 64) else @truncate(va);
                    const src_mask: u64 = (@as(u64, 1) << @intCast(esize)) - 1;
                    const dst_mask: u128 = if (dst_bits >= 64) 0xffff_ffff_ffff_ffff else ((@as(u128, 1) << @intCast(dst_bits)) - 1);
                    var out128: u128 = 0;
                    for (0..lanes) |i| {
                        const raw: u64 = (src64 >> @intCast(i * esize)) & src_mask;
                        const ext: u64 = if (u) raw else switch (esize) {
                            8 => @bitCast(@as(i64, @as(i8, @bitCast(@as(u8, @truncate(raw)))))),
                            16 => @bitCast(@as(i64, @as(i16, @bitCast(@as(u16, @truncate(raw)))))),
                            else => @bitCast(@as(i64, @as(i32, @bitCast(@as(u32, @truncate(raw)))))),
                        };
                        const shifted: u128 = (@as(u128, ext) << lshift) & dst_mask;
                        out128 |= shifted << @intCast(i * dst_bits);
                    }
                    cpu.vfp.v[rd] = out128;
                    return;
                }

                const total_bits: usize = if (is_scalar) esize else if (q) 128 else 64;
                const lanes: usize = total_bits / esize;
                const emask: u64 = if (esize >= 64) 0xffff_ffff_ffff_ffff else ((@as(u64, 1) << @intCast(esize)) - 1);
                const vd_cur = cpu.vfp.v[rd];
                var out: u128 = 0;

                for (0..lanes) |i| {
                    const sh: u7 = @intCast(i * esize);
                    const raw: u64 = @as(u64, @truncate(va >> sh)) & emask;
                    const d_raw: u64 = @as(u64, @truncate(vd_cur >> sh)) & emask;
                    const s_ext: i64 = switch (esize) {
                        8 => @as(i8, @bitCast(@as(u8, @truncate(raw)))),
                        16 => @as(i16, @bitCast(@as(u16, @truncate(raw)))),
                        32 => @as(i32, @bitCast(@as(u32, @truncate(raw)))),
                        else => @bitCast(raw),
                    };
                    const res_elem: u64 = switch (opcode) {
                        0b00000 => if (u) (if (rshift >= 64) 0 else (raw >> rshift)) else @as(u64, @bitCast(if (rshift >= 64) (s_ext >> 63) else (s_ext >> rshift))), // SSHR / USHR
                        0b00010 => d_raw +% (if (u) (if (rshift >= 64) 0 else (raw >> rshift)) else @as(u64, @bitCast(if (rshift >= 64) (s_ext >> 63) else (s_ext >> rshift)))), // SSRA / USRA
                        0b00100 => blk: { // SRSHR / URSHR
                            const rbit: u64 = if (rshift > 0 and rshift <= 64) ((raw >> @intCast(rshift - 1)) & 1) else 0;
                            const base_s: u64 = if (u) (if (rshift >= 64) 0 else (raw >> rshift)) else @as(u64, @bitCast(if (rshift >= 64) (s_ext >> 63) else (s_ext >> rshift)));
                            break :blk base_s +% rbit;
                        },
                        0b01000 => blk: { // SRI
                            const ins_mask: u64 = if (rshift >= esize) 0 else (emask >> rshift);
                            const shifted: u64 = if (rshift >= 64) 0 else (raw >> rshift);
                            break :blk (d_raw & ~ins_mask) | (shifted & ins_mask);
                        },
                        0b01010 => if (!u) (raw << lshift) else blk: { // SHL (u=0) / SLI (u=1)
                            const keep_mask: u64 = (@as(u64, 1) << lshift) - 1;
                            break :blk (d_raw & keep_mask) | (raw << lshift);
                        },
                        0b11100 => blk: { // SCVTF / UCVTF (fixed-point vector/scalar)
                            const factor: f64 = if (rshift >= 64) (@as(f64, @floatFromInt(@as(u64, 1) << 63)) * 2.0) else @floatFromInt(@as(u64, 1) << rshift);
                            const fv: f64 = (if (u) @as(f64, @floatFromInt(raw)) else @as(f64, @floatFromInt(s_ext))) / factor;
                            break :blk if (esize == 64) @as(u64, @bitCast(fv)) else @as(u32, @bitCast(@as(f32, @floatCast(fv))));
                        },
                        0b11111 => blk: { // FCVTZS / FCVTZU (fixed-point vector/scalar)
                            const factor: f64 = if (rshift >= 64) (@as(f64, @floatFromInt(@as(u64, 1) << 63)) * 2.0) else @floatFromInt(@as(u64, 1) << rshift);
                            const raw_fv: f64 = if (esize == 64) @bitCast(raw) else @as(f64, @as(f32, @bitCast(@as(u32, @truncate(raw)))));
                            const fv = @trunc(raw_fv * factor);
                            if (std.math.isNan(fv)) break :blk 0;
                            if (!u) {
                                if (esize == 64) {
                                    const c = std.math.clamp(fv, -9223372036854775808.0, 9223372036854774784.0);
                                    break :blk @bitCast(@as(i64, @intFromFloat(c)));
                                } else {
                                    const c = std.math.clamp(fv, -2147483648.0, 2147483647.0);
                                    break :blk @as(u32, @bitCast(@as(i32, @intFromFloat(c))));
                                }
                            } else {
                                if (esize == 64) {
                                    const c = std.math.clamp(fv, 0.0, 18446744073709549568.0);
                                    break :blk @intFromFloat(c);
                                } else {
                                    const c = std.math.clamp(fv, 0.0, 4294967295.0);
                                    break :blk @as(u32, @intFromFloat(c));
                                }
                            }
                        },
                        else => raw,
                    };
                    out |= (@as(u128, res_elem & emask) << sh);
                }
                cpu.vfp.v[rd] = out;
                return;
            }

            // 3. AdvSIMD copy (`DUP`, `INS`, `UMOV`, `SMOV`) (`(inst & 0x9fe0_0400) == 0x0e00_0400`)
            if ((inst & 0x9fe0_0400) == 0x0e00_0400) {
                const q = ((inst >> 30) & 1) != 0;
                const op = ((inst >> 29) & 1) != 0;
                const imm5: u5 = @truncate(inst >> 16);
                const imm4: u4 = @truncate(inst >> 11);
                const tz = @ctz(@as(u6, imm5));
                const esize_bytes: u5 = if (tz >= 4) 8 else (@as(u5, 1) << @intCast(tz));
                const dst_idx: u5 = imm5 >> @intCast(tz + 1);

                if (op) {
                    // INS (element): Vd.<Ts>[dst_idx] = Vn.<Ts>[src_idx]
                    const src_idx: u5 = @truncate(@as(u5, imm4) >> @intCast(tz));
                    const width_bits: u7 = @as(u7, esize_bytes) * 8;
                    const src_sh: u7 = @as(u7, src_idx) * width_bits;
                    const dst_sh: u7 = @as(u7, dst_idx) * width_bits;
                    const elem: u128 = cpu.vfp.v[rn] >> src_sh;
                    const mask128: u128 = if (width_bits >= 64) (@as(u128, 0xffff_ffff_ffff_ffff) << dst_sh) else (((@as(u128, 1) << width_bits) - 1) << dst_sh);
                    cpu.vfp.v[rd] = (cpu.vfp.v[rd] & ~mask128) | ((elem << dst_sh) & mask128);
                    return;
                }

                if (imm4 == 0b0000) {
                    // DUP (element): replicate Vn.<Ts>[dst_idx] across vector
                    const shift_bits: u7 = @as(u7, dst_idx) * (@as(u7, esize_bytes) * 8);
                    const elem: u64 = @truncate(cpu.vfp.v[rn] >> shift_bits);
                    const rep64: u64 = switch (esize_bytes) {
                        1 => (@as(u64, @as(u8, @truncate(elem))) * 0x0101_0101_0101_0101),
                        2 => (@as(u64, @as(u16, @truncate(elem))) * 0x0001_0001_0001_0001),
                        4 => (@as(u64, @as(u32, @truncate(elem))) * 0x0000_0001_0000_0001),
                        else => elem,
                    };
                    cpu.vfp.v[rd] = if (q) (@as(u128, rep64) | (@as(u128, rep64) << 64)) else @as(u128, rep64);
                } else if (imm4 == 0b0001) {
                    // DUP (general): replicate GPR X[rn] across vector
                    const gval = getX(cpu, rn);
                    const rep64: u64 = switch (esize_bytes) {
                        1 => (@as(u64, @as(u8, @truncate(gval))) * 0x0101_0101_0101_0101),
                        2 => (@as(u64, @as(u16, @truncate(gval))) * 0x0001_0001_0001_0001),
                        4 => (@as(u64, @as(u32, @truncate(gval))) * 0x0000_0001_0000_0001),
                        else => gval,
                    };
                    cpu.vfp.v[rd] = if (q) (@as(u128, rep64) | (@as(u128, rep64) << 64)) else @as(u128, rep64);
                } else if (imm4 == 0b0101) {
                    // SMOV (signed vector element -> GPR)
                    const shift_bits: u7 = @as(u7, dst_idx) * (@as(u7, esize_bytes) * 8);
                    const elem: u64 = @truncate(cpu.vfp.v[rn] >> shift_bits);
                    const sext: i64 = switch (esize_bytes) {
                        1 => @as(i8, @bitCast(@as(u8, @truncate(elem)))),
                        2 => @as(i16, @bitCast(@as(u16, @truncate(elem)))),
                        else => @as(i32, @bitCast(@as(u32, @truncate(elem)))),
                    };
                    if (q) setX(cpu, rd, @bitCast(sext)) else setW(cpu, rd, @truncate(@as(u64, @bitCast(sext))));
                } else if (imm4 == 0b0111) {
                    // UMOV (vector element -> GPR)
                    const shift_bits: u7 = @as(u7, dst_idx) * (@as(u7, esize_bytes) * 8);
                    const elem: u64 = @truncate(cpu.vfp.v[rn] >> shift_bits);
                    switch (esize_bytes) {
                        1 => setW(cpu, rd, @as(u8, @truncate(elem))),
                        2 => setW(cpu, rd, @as(u16, @truncate(elem))),
                        4 => setW(cpu, rd, @as(u32, @truncate(elem))),
                        else => setX(cpu, rd, elem),
                    }
                } else if (imm4 == 0b0011) {
                    // INS (general -> vector element)
                    const shift_bits: u7 = @as(u7, dst_idx) * (@as(u7, esize_bytes) * 8);
                    const width_bits: u7 = @as(u7, esize_bytes) * 8;
                    const mask128: u128 = if (width_bits >= 64) (@as(u128, 0xffff_ffff_ffff_ffff) << shift_bits) else (((@as(u128, 1) << width_bits) - 1) << shift_bits);
                    const gval: u128 = getX(cpu, rn);
                    cpu.vfp.v[rd] = (cpu.vfp.v[rd] & ~mask128) | ((gval << shift_bits) & mask128);
                }
                return;
            }

            // 3b. AdvSIMD scalar copy (`DUP Sd/Dd, Vn.<Ts>[idx]`): `(inst & 0xdfe0_fc00) == 0x5e00_0400`
            if ((inst & 0xdfe0_fc00) == 0x5e00_0400) {
                const imm5: u5 = @truncate(inst >> 16);
                const tz = @ctz(@as(u6, imm5));
                const esize_bytes: u5 = if (tz >= 4) 8 else (@as(u5, 1) << @intCast(tz));
                const src_idx: u5 = imm5 >> @intCast(tz + 1);
                const shift_bits: u7 = @as(u7, src_idx) * (@as(u7, esize_bytes) * 8);
                const width_bits: u7 = @as(u7, esize_bytes) * 8;
                const emask: u128 = if (width_bits >= 64) 0xffff_ffff_ffff_ffff else ((@as(u128, 1) << width_bits) - 1);
                cpu.vfp.v[rd] = (cpu.vfp.v[rn] >> shift_bits) & emask;
                return;
            }

            // 4. AdvSIMD two-register miscellaneous (vector & scalar: `REV64`, `REV32`, `REV16`, `CNT`, `NOT`, `RBIT`, `CLZ`, `CLS`, `SADDLP`, `UADDLP`, `CMEQ #0`, `CMGT #0`, `CMGE #0`, `CMLE #0`, `CMLT #0`, `ABS`, `NEG`, `XTN`, `SHLL`, `SCVTF`, `UCVTF`, `FCVT*S`, `FCVT*U`, `FABS`, `FNEG`, `FSQRT`)
            if ((inst & 0x9f3e_0c00) == 0x0e20_0800 or (inst & 0xdf3e_0c00) == 0x5e20_0800) {
                const is_scalar = ((inst >> 28) & 1) != 0;
                const q = ((inst >> 30) & 1) != 0;
                const u = ((inst >> 29) & 1) != 0;
                const size: u2 = @truncate(inst >> 22);
                const opcode: u5 = @truncate(inst >> 12);
                const mask: u128 = if (q and !is_scalar) ~@as(u128, 0) else 0xffff_ffff_ffff_ffff;
                const va = cpu.vfp.v[rn];

                if (opcode == 0b00101 and u) {
                    if (size == 0) {
                        // NOT / MVN
                        cpu.vfp.v[rd] = (~va) & mask;
                    } else if (size == 1) {
                        // RBIT (byte-wise bit reverse)
                        var out: u128 = 0;
                        const count: usize = if (q) 16 else 8;
                        for (0..count) |i| {
                            const sh: u7 = @intCast(i * 8);
                            const b: u8 = @truncate(va >> sh);
                            out |= (@as(u128, @bitReverse(b)) << sh);
                        }
                        cpu.vfp.v[rd] = out & mask;
                    }
                    return;
                }
                if (opcode == 0b00101 and !u) {
                    // CNT (byte-wise population count)
                    var out: u128 = 0;
                    const count: usize = if (q) 16 else 8;
                    for (0..count) |i| {
                        const sh: u7 = @intCast(i * 8);
                        const b: u8 = @truncate(va >> sh);
                        out |= (@as(u128, @popCount(b)) << sh);
                    }
                    cpu.vfp.v[rd] = out & mask;
                    return;
                }
                if (opcode == 0b00100) {
                    // CLS (u=0) / CLZ (u=1)
                    const ebits: u7 = @as(u7, 8) << size;
                    const total_bits: usize = if (q) 128 else 64;
                    const lanes: usize = total_bits / ebits;
                    const emask: u64 = (@as(u64, 1) << @intCast(ebits)) - 1;
                    var out: u128 = 0;
                    for (0..lanes) |i| {
                        const sh: u7 = @intCast(i * ebits);
                        const raw: u64 = @as(u64, @truncate(va >> sh)) & emask;
                        const cnt: u64 = if (u) switch (size) {
                            0 => @clz(@as(u8, @truncate(raw))),
                            1 => @clz(@as(u16, @truncate(raw))),
                            else => @clz(@as(u32, @truncate(raw))),
                        } else switch (size) {
                            0 => blk: {
                                const v: u8 = @truncate(raw);
                                break :blk @clz(if ((v & 0x80) != 0) ~v else v) -| 1;
                            },
                            1 => blk: {
                                const v: u16 = @truncate(raw);
                                break :blk @clz(if ((v & 0x8000) != 0) ~v else v) -| 1;
                            },
                            else => blk: {
                                const v: u32 = @truncate(raw);
                                break :blk @clz(if ((v & 0x8000_0000) != 0) ~v else v) -| 1;
                            },
                        };
                        out |= (@as(u128, cnt & emask) << sh);
                    }
                    cpu.vfp.v[rd] = out & mask;
                    return;
                }
                if (opcode == 0b00010 or opcode == 0b00110) {
                    // SADDLP / UADDLP (00010) and SADALP / UADALP (00110)
                    const src_bits: u7 = @as(u7, 8) << size;
                    const dst_bits: u7 = src_bits * 2;
                    const total_bits: usize = if (q) 128 else 64;
                    const dst_lanes: usize = total_bits / dst_bits;
                    const smask: u64 = (@as(u64, 1) << @intCast(src_bits)) - 1;
                    const dmask: u64 = if (dst_bits >= 64) 0xffff_ffff_ffff_ffff else ((@as(u64, 1) << @intCast(dst_bits)) - 1);
                    const vd_cur = cpu.vfp.v[rd];
                    var out: u128 = 0;
                    for (0..dst_lanes) |i| {
                        const sh0: u7 = @intCast((i * 2) * src_bits);
                        const sh1: u7 = @intCast((i * 2 + 1) * src_bits);
                        const val_a: u64 = @as(u64, @truncate(va >> sh0)) & smask;
                        const val_b: u64 = @as(u64, @truncate(va >> sh1)) & smask;
                        const sval_a: i64 = switch (size) {
                            0 => @as(i8, @bitCast(@as(u8, @truncate(val_a)))),
                            1 => @as(i16, @bitCast(@as(u16, @truncate(val_a)))),
                            else => @as(i32, @bitCast(@as(u32, @truncate(val_a)))),
                        };
                        const sval_b: i64 = switch (size) {
                            0 => @as(i8, @bitCast(@as(u8, @truncate(val_b)))),
                            1 => @as(i16, @bitCast(@as(u16, @truncate(val_b)))),
                            else => @as(i32, @bitCast(@as(u32, @truncate(val_b)))),
                        };
                        var pair_sum: u64 = if (u) (val_a +% val_b) else @bitCast(sval_a + sval_b);
                        const dsh: u7 = @intCast(i * dst_bits);
                        if (opcode == 0b00110) {
                            const cur_d: u64 = @as(u64, @truncate(vd_cur >> dsh)) & dmask;
                            pair_sum +%= cur_d;
                        }
                        out |= (@as(u128, pair_sum & dmask) << dsh);
                    }
                    cpu.vfp.v[rd] = out & mask;
                    return;
                }
                if (opcode == 0b10011 and u) {
                    // SHLL / SHLL2
                    const src_bits: u7 = @as(u7, 8) << size;
                    const dst_bits: u7 = src_bits * 2;
                    const lanes: usize = @intCast(64 / src_bits);
                    const src64: u64 = if (q) @truncate(va >> 64) else @truncate(va);
                    const smask: u64 = (@as(u64, 1) << @intCast(src_bits)) - 1;
                    var out128: u128 = 0;
                    for (0..lanes) |i| {
                        const raw: u128 = (src64 >> @intCast(i * src_bits)) & smask;
                        out128 |= (raw << @intCast(src_bits)) << @intCast(i * dst_bits);
                    }
                    cpu.vfp.v[rd] = out128;
                    return;
                }
                if (opcode == 0b00000 or opcode == 0b00001) {
                    // REV64 (opcode=0, u=0), REV32 (opcode=0, u=1), REV16 (opcode=1, u=0)
                    const container_bytes: usize = if (opcode == 1) 2 else if (u) 4 else 8;
                    const elem_bytes: usize = @as(usize, 1) << size;
                    const total_bytes: usize = if (q) 16 else 8;
                    const elems_per_c = container_bytes / elem_bytes;
                    var out: u128 = 0;
                    var c_off: usize = 0;
                    while (c_off < total_bytes) : (c_off += container_bytes) {
                        for (0..elems_per_c) |e| {
                            const src_sh: u7 = @intCast((c_off + e * elem_bytes) * 8);
                            const dst_sh: u7 = @intCast((c_off + (elems_per_c - 1 - e) * elem_bytes) * 8);
                            const emask: u128 = (@as(u128, 1) << @intCast(elem_bytes * 8)) - 1;
                            out |= ((va >> src_sh) & emask) << dst_sh;
                        }
                    }
                    cpu.vfp.v[rd] = out & mask;
                    return;
                }
                if (opcode == 0b10010 and !u) {
                    // XTN / XTN2
                    const dst_bits: u7 = @as(u7, 8) << size;
                    const src_bits: u7 = dst_bits * 2;
                    const lanes: usize = @intCast(64 / dst_bits);
                    const emask: u64 = (@as(u64, 1) << @intCast(dst_bits)) - 1;
                    var narrow64: u64 = 0;
                    for (0..lanes) |i| {
                        const elem: u64 = @as(u64, @truncate(va >> @intCast(i * src_bits))) & emask;
                        narrow64 |= elem << @intCast(i * dst_bits);
                    }
                    if (q) {
                        cpu.vfp.v[rd] = (cpu.vfp.v[rd] & 0xffff_ffff_ffff_ffff) | (@as(u128, narrow64) << 64);
                    } else {
                        cpu.vfp.v[rd] = narrow64;
                    }
                    return;
                }
                if (opcode >= 0b01000 and opcode <= 0b01011) {
                    // Compare with #0 (CMGT=01000/0, CMGE=01000/1, CMEQ=01001/0, CMLE=01001/1, CMLT=01010/0) or ABS (01011/0) / NEG (01011/1)
                    const ebits: u7 = @as(u7, 8) << size;
                    const total_bits: usize = if (is_scalar) ebits else if (q) 128 else 64;
                    const lanes: usize = total_bits / ebits;
                    const emask: u64 = if (ebits >= 64) 0xffff_ffff_ffff_ffff else ((@as(u64, 1) << @intCast(ebits)) - 1);
                    var out: u128 = 0;
                    for (0..lanes) |i| {
                        const sh: u7 = @intCast(i * ebits);
                        const raw: u64 = @as(u64, @truncate(va >> sh)) & emask;
                        const sval: i64 = switch (size) {
                            0 => @as(i8, @bitCast(@as(u8, @truncate(raw)))),
                            1 => @as(i16, @bitCast(@as(u16, @truncate(raw)))),
                            2 => @as(i32, @bitCast(@as(u32, @truncate(raw)))),
                            3 => @bitCast(raw),
                        };
                        const res_elem: u64 = switch (opcode) {
                            0b01000 => if (if (u) (sval >= 0) else (sval > 0)) emask else 0,
                            0b01001 => if (if (u) (sval <= 0) else (raw == 0)) emask else 0,
                            0b01010 => if (sval < 0) emask else 0,
                            0b01011 => if (u) (0 -% raw) else @as(u64, @bitCast(if (sval < 0) -%sval else sval)),
                            else => 0,
                        };
                        out |= (@as(u128, res_elem & emask) << sh);
                    }
                    cpu.vfp.v[rd] = out & mask;
                    return;
                }
                if (opcode >= 0b11000 or (opcode == 0b01111 and (size & 2) != 0)) {
                    // FP two-reg misc: SCVTF/UCVTF (11101, s2=0), FCVT*S/U (11010..11100), FRINT* (11000..11001), FABS/FNEG (01111, s2=1), FSQRT (11111, s2=1, u=1)
                    const is_f64 = (size & 1) != 0;
                    const s2 = (size & 2) != 0;
                    const fp_bits: u7 = if (is_f64) 64 else 32;
                    const total_bits: usize = if (is_scalar) fp_bits else if (q) 128 else 64;
                    const lanes: usize = total_bits / fp_bits;
                    const emask: u64 = if (is_f64) 0xffff_ffff_ffff_ffff else 0xffff_ffff;
                    var out: u128 = 0;
                    for (0..lanes) |i| {
                        const sh: u7 = @intCast(i * fp_bits);
                        const raw: u64 = @as(u64, @truncate(va >> sh)) & emask;
                        const fv: f64 = if (is_f64) @bitCast(raw) else @as(f64, @as(f32, @bitCast(@as(u32, @truncate(raw)))));
                        const res_elem: u64 = switch (opcode) {
                            0b11101 => blk: { // SCVTF / UCVTF
                                if (is_f64) {
                                    const cv: f64 = if (u) @floatFromInt(raw) else @floatFromInt(@as(i64, @bitCast(raw)));
                                    break :blk @as(u64, @bitCast(cv));
                                } else {
                                    const cv: f32 = if (u) @floatFromInt(@as(u32, @truncate(raw))) else @floatFromInt(@as(i32, @bitCast(@as(u32, @truncate(raw)))));
                                    break :blk @as(u32, @bitCast(cv));
                                }
                            },
                            0b11010, 0b11011, 0b11100 => blk: { // FCVTNS/NU, FCVTMS/MU, FCVTPS/PU, FCVTZS/ZU, FCVTAS/AU
                                if (std.math.isNan(fv)) break :blk 0;
                                const rounded: f64 = if (opcode == 0b11010)
                                    (if (s2) @floor(fv) else @round(fv))
                                else if (opcode == 0b11011)
                                    (if (s2) @trunc(fv) else @ceil(fv))
                                else
                                    @round(fv);
                                if (!u) {
                                    if (is_f64) {
                                        const c = std.math.clamp(rounded, -9223372036854775808.0, 9223372036854774784.0);
                                        break :blk @bitCast(@as(i64, @intFromFloat(c)));
                                    } else {
                                        const c = std.math.clamp(rounded, -2147483648.0, 2147483647.0);
                                        break :blk @as(u32, @bitCast(@as(i32, @intFromFloat(c))));
                                    }
                                } else {
                                    if (is_f64) {
                                        const c = std.math.clamp(rounded, 0.0, 18446744073709549568.0);
                                        break :blk @intFromFloat(c);
                                    } else {
                                        const c = std.math.clamp(rounded, 0.0, 4294967295.0);
                                        break :blk @as(u32, @intFromFloat(c));
                                    }
                                }
                            },
                            0b01111 => blk: { // FABS (u=0) / FNEG (u=1)
                                const r = if (u) -fv else @abs(fv);
                                break :blk if (is_f64) @as(u64, @bitCast(r)) else @as(u32, @bitCast(@as(f32, @floatCast(r))));
                            },
                            0b11111 => blk: { // FSQRT
                                const r = @sqrt(fv);
                                break :blk if (is_f64) @as(u64, @bitCast(r)) else @as(u32, @bitCast(@as(f32, @floatCast(r))));
                            },
                            0b11000, 0b11001 => blk: { // FRINT*
                                const r = if (opcode == 0b11000 and s2)
                                    (if (u) @trunc(fv) else @floor(fv))
                                else if (opcode == 0b11001 and !s2 and !u)
                                    @ceil(fv)
                                else
                                    @round(fv);
                                break :blk if (is_f64) @as(u64, @bitCast(r)) else @as(u32, @bitCast(@as(f32, @floatCast(r))));
                            },
                            else => raw,
                        };
                        out |= (@as(u128, res_elem & emask) << sh);
                    }
                    cpu.vfp.v[rd] = out & mask;
                    return;
                }
                return;
            }

            // 4b. AdvSIMD across lanes (`ADDV`, `SMAXV`, `UMAXV`, `SMINV`, `UMINV`) (`(inst & 0x9f3e_0c00) == 0x0e30_0800`)
            if ((inst & 0x9f3e_0c00) == 0x0e30_0800) {
                const q = ((inst >> 30) & 1) != 0;
                const u = ((inst >> 29) & 1) != 0;
                const size: u2 = @truncate(inst >> 22);
                const opcode: u5 = @truncate(inst >> 12);
                const ebits: u7 = @as(u7, 8) << size;
                const total_bits: usize = if (q) 128 else 64;
                const lanes: usize = total_bits / ebits;
                const emask: u64 = (@as(u64, 1) << @intCast(ebits)) - 1;
                const va = cpu.vfp.v[rn];

                if (opcode == 0b11011 and !u) {
                    // ADDV
                    var sum: u64 = 0;
                    for (0..lanes) |i| {
                        sum +%= @as(u64, @truncate(va >> @intCast(i * ebits))) & emask;
                    }
                    cpu.vfp.v[rd] = sum & emask;
                } else if (opcode == 0b01010 or opcode == 0b11010) {
                    // SMAXV / UMAXV (01010) or SMINV / UMINV (11010)
                    const is_min = (opcode == 0b11010);
                    var best_u: u64 = @as(u64, @truncate(va)) & emask;
                    var best_s: i64 = switch (size) {
                        0 => @as(i8, @bitCast(@as(u8, @truncate(best_u)))),
                        1 => @as(i16, @bitCast(@as(u16, @truncate(best_u)))),
                        else => @as(i32, @bitCast(@as(u32, @truncate(best_u)))),
                    };
                    for (1..lanes) |i| {
                        const cur_u: u64 = @as(u64, @truncate(va >> @intCast(i * ebits))) & emask;
                        const cur_s: i64 = switch (size) {
                            0 => @as(i8, @bitCast(@as(u8, @truncate(cur_u)))),
                            1 => @as(i16, @bitCast(@as(u16, @truncate(cur_u)))),
                            else => @as(i32, @bitCast(@as(u32, @truncate(cur_u)))),
                        };
                        if (u) {
                            best_u = if (is_min) @min(best_u, cur_u) else @max(best_u, cur_u);
                        } else {
                            best_s = if (is_min) @min(best_s, cur_s) else @max(best_s, cur_s);
                        }
                    }
                    cpu.vfp.v[rd] = (if (u) best_u else @as(u64, @bitCast(best_s))) & emask;
                } else if (opcode == 0b00011) {
                    // SADDLV / UADDLV
                    var sum_u: u64 = 0;
                    var sum_s: i64 = 0;
                    for (0..lanes) |i| {
                        const cur_u: u64 = @as(u64, @truncate(va >> @intCast(i * ebits))) & emask;
                        const cur_s: i64 = switch (size) {
                            0 => @as(i8, @bitCast(@as(u8, @truncate(cur_u)))),
                            1 => @as(i16, @bitCast(@as(u16, @truncate(cur_u)))),
                            else => @as(i32, @bitCast(@as(u32, @truncate(cur_u)))),
                        };
                        sum_u +%= cur_u;
                        sum_s +%= cur_s;
                    }
                    const wide_mask: u64 = if (ebits * 2 >= 64) 0xffff_ffff_ffff_ffff else ((@as(u64, 1) << @intCast(ebits * 2)) - 1);
                    cpu.vfp.v[rd] = (if (u) sum_u else @as(u64, @bitCast(sum_s))) & wide_mask;
                }
                return;
            }

            // 4c. AdvSIMD scalar pairwise (`ADDP Dd, Vn.2D`): `(inst & 0xff3e_0c00) == 0x5e30_0800`
            if ((inst & 0xff3e_0c00) == 0x5e30_0800) {
                const va = cpu.vfp.v[rn];
                const lo: u64 = @truncate(va);
                const hi: u64 = @truncate(va >> 64);
                cpu.vfp.v[rd] = lo +% hi;
                return;
            }

            // 5. AdvSIMD EXT (`(inst & 0xbf20_8400) == 0x2e00_0000`)
            if ((inst & 0xbf20_8400) == 0x2e00_0000) {
                const q = ((inst >> 30) & 1) != 0;
                const imm4: u7 = @truncate((inst >> 11) & 0xf);
                const va = cpu.vfp.v[rn];
                const vb = cpu.vfp.v[rm];
                if (q) {
                    const sh: u7 = imm4 * 8;
                    const res: u128 = if (sh == 0) va else ((va >> sh) | (vb << @intCast(128 - @as(u8, sh))));
                    cpu.vfp.v[rd] = res;
                } else {
                    const sh: u6 = @intCast((imm4 & 7) * 8);
                    const a64: u64 = @truncate(va);
                    const b64: u64 = @truncate(vb);
                    const res64: u64 = if (sh == 0) a64 else ((a64 >> sh) | (b64 << @intCast(64 - @as(u7, sh))));
                    cpu.vfp.v[rd] = res64;
                }
                return;
            }

            // 5b. AdvSIMD TBL / TBX (`(inst & 0xbf20_8c00) == 0x0e00_0000`)
            if ((inst & 0xbf20_8c00) == 0x0e00_0000) {
                const q = ((inst >> 30) & 1) != 0;
                const len: u5 = @truncate(((inst >> 13) & 3) + 1);
                const is_tbx = ((inst >> 12) & 1) != 0;
                const count: usize = if (q) 16 else 8;
                const mask: u128 = if (q) ~@as(u128, 0) else 0xffff_ffff_ffff_ffff;
                const vidx = cpu.vfp.v[rm];
                const vd_cur = cpu.vfp.v[rd];
                var out: u128 = 0;
                for (0..count) |i| {
                    const sh: u7 = @intCast(i * 8);
                    const idx_byte: u8 = @truncate(vidx >> sh);
                    const r_off: u8 = idx_byte >> 4;
                    if (r_off < len) {
                        const tbl_reg: u5 = rn +% @as(u5, @truncate(r_off));
                        const b_sh: u7 = @intCast((idx_byte & 0xf) * 8);
                        const val_byte: u8 = @truncate(cpu.vfp.v[tbl_reg] >> b_sh);
                        out |= (@as(u128, val_byte) << sh);
                    } else if (is_tbx) {
                        const old_byte: u8 = @truncate(vd_cur >> sh);
                        out |= (@as(u128, old_byte) << sh);
                    }
                }
                cpu.vfp.v[rd] = out & mask;
                return;
            }

            // 5c. AdvSIMD ZIP1 / ZIP2 / UZP1 / UZP2 / TRN1 / TRN2 (`(inst & 0x9f20_8c00) == 0x0e00_0800`)
            if ((inst & 0x9f20_8c00) == 0x0e00_0800) {
                const q = ((inst >> 30) & 1) != 0;
                const size: u2 = @truncate(inst >> 22);
                const op: u3 = @truncate(inst >> 12);
                const ebits: u7 = @as(u7, 8) << size;
                const total_bits: usize = if (q) 128 else 64;
                const lanes: usize = total_bits / ebits;
                const half_lanes = lanes / 2;
                const emask: u128 = if (ebits >= 64) 0xffff_ffff_ffff_ffff else ((@as(u128, 1) << ebits) - 1);
                const va = cpu.vfp.v[rn];
                const vb = cpu.vfp.v[rm];
                var out: u128 = 0;

                switch (op) {
                    0b001, 0b101 => { // UZP1 (001) / UZP2 (101)
                        const part: usize = if (op == 0b101) 1 else 0;
                        for (0..lanes) |i| {
                            const pair_idx = i * 2 + part;
                            const src_vec = if (pair_idx < lanes) va else vb;
                            const src_lane = if (pair_idx < lanes) pair_idx else (pair_idx - lanes);
                            const elem = (src_vec >> @intCast(src_lane * ebits)) & emask;
                            out |= elem << @intCast(i * ebits);
                        }
                    },
                    0b010, 0b110 => { // TRN1 (010) / TRN2 (110)
                        const part: usize = if (op == 0b110) 1 else 0;
                        for (0..half_lanes) |p| {
                            const src_lane = p * 2 + part;
                            const ea = (va >> @intCast(src_lane * ebits)) & emask;
                            const eb = (vb >> @intCast(src_lane * ebits)) & emask;
                            out |= ea << @intCast((p * 2) * ebits);
                            out |= eb << @intCast((p * 2 + 1) * ebits);
                        }
                    },
                    0b011, 0b111 => { // ZIP1 (011) / ZIP2 (111)
                        const base_lane: usize = if (op == 0b111) half_lanes else 0;
                        for (0..half_lanes) |p| {
                            const ea = (va >> @intCast((base_lane + p) * ebits)) & emask;
                            const eb = (vb >> @intCast((base_lane + p) * ebits)) & emask;
                            out |= ea << @intCast((p * 2) * ebits);
                            out |= eb << @intCast((p * 2 + 1) * ebits);
                        }
                    },
                    else => {},
                }
                cpu.vfp.v[rd] = out;
                return;
            }

            // 5d. AdvSIMD three different (`PMULL`, `UMULL`, `SMULL`, `UADDL`, `USUBL`, `UABDL`) (`(inst & 0x9f20_0c00) == 0x0e20_0000`)
            if ((inst & 0x9f20_0c00) == 0x0e20_0000) {
                const q = ((inst >> 30) & 1) != 0;
                const u = ((inst >> 29) & 1) != 0;
                const size: u2 = @truncate(inst >> 22);
                const opcode: u4 = @truncate(inst >> 12);
                const va64: u64 = if (q) @truncate(cpu.vfp.v[rn] >> 64) else @truncate(cpu.vfp.v[rn]);
                const vb64: u64 = if (q) @truncate(cpu.vfp.v[rm] >> 64) else @truncate(cpu.vfp.v[rm]);

                if (opcode == 0b1110 and !u) {
                    // PMULL / PMULL2 (8x8->16 when size==0, 64x64->128 when size==3)
                    if (size == 3) {
                        var prod: u128 = 0;
                        var bit: u7 = 0;
                        while (bit < 64) : (bit += 1) {
                            if (((va64 >> @intCast(bit)) & 1) != 0) {
                                prod ^= (@as(u128, vb64) << bit);
                            }
                        }
                        cpu.vfp.v[rd] = prod;
                    } else if (size == 0) {
                        var out: u128 = 0;
                        for (0..8) |i| {
                            const ba: u16 = @as(u8, @truncate(va64 >> @intCast(i * 8)));
                            const bb: u16 = @as(u8, @truncate(vb64 >> @intCast(i * 8)));
                            var p: u16 = 0;
                            var b: u4 = 0;
                            while (b < 8) : (b += 1) {
                                if (((ba >> b) & 1) != 0) p ^= (bb << b);
                            }
                            out |= (@as(u128, p) << @intCast(i * 16));
                        }
                        cpu.vfp.v[rd] = out;
                    }
                    return;
                }

                const src_bits: u7 = @as(u7, 8) << size;
                const dst_bits: u7 = src_bits * 2;
                const lanes: usize = @intCast(64 / src_bits);
                const smask: u64 = (@as(u64, 1) << @intCast(src_bits)) - 1;
                const dmask: u128 = if (dst_bits >= 64) 0xffff_ffff_ffff_ffff else ((@as(u128, 1) << dst_bits) - 1);

                if (opcode == 0b0100 or opcode == 0b0110) {
                    // ADDHN / ADDHN2 / RADDHN / RADDHN2 (0100) and SUBHN / SUBHN2 / RSUBHN / RSUBHN2 (0110)
                    const va128 = cpu.vfp.v[rn];
                    const vb128 = cpu.vfp.v[rm];
                    const round_const: u128 = if (u) (@as(u128, 1) << @intCast(src_bits - 1)) else 0;
                    var narrow: u64 = 0;
                    for (0..lanes) |i| {
                        const dsh: u7 = @intCast(i * dst_bits);
                        const wa: u128 = (va128 >> dsh) & dmask;
                        const wb: u128 = (vb128 >> dsh) & dmask;
                        const res_wide: u128 = if (opcode == 0b0100)
                            (wa +% wb +% round_const)
                        else
                            (wa -% wb +% round_const);
                        const res_nar: u64 = @as(u64, @truncate(res_wide >> @intCast(src_bits))) & smask;
                        narrow |= (res_nar << @intCast(i * src_bits));
                    }
                    if (q) {
                        cpu.vfp.v[rd] = (cpu.vfp.v[rd] & 0xffff_ffff_ffff_ffff) | (@as(u128, narrow) << 64);
                    } else {
                        cpu.vfp.v[rd] = narrow;
                    }
                    return;
                }

                var out: u128 = if (opcode == 0b1000 or opcode == 0b1010 or opcode == 0b0101) cpu.vfp.v[rd] else 0;
                const va128 = cpu.vfp.v[rn];

                for (0..lanes) |i| {
                    const ua: u64 = (va64 >> @intCast(i * src_bits)) & smask;
                    const ub: u64 = (vb64 >> @intCast(i * src_bits)) & smask;
                    const sa: i64 = switch (size) {
                        0 => @as(i8, @bitCast(@as(u8, @truncate(ua)))),
                        1 => @as(i16, @bitCast(@as(u16, @truncate(ua)))),
                        else => @as(i32, @bitCast(@as(u32, @truncate(ua)))),
                    };
                    const sb: i64 = switch (size) {
                        0 => @as(i8, @bitCast(@as(u8, @truncate(ub)))),
                        1 => @as(i16, @bitCast(@as(u16, @truncate(ub)))),
                        else => @as(i32, @bitCast(@as(u32, @truncate(ub)))),
                    };
                    const dsh: u7 = @intCast(i * dst_bits);
                    const cur_d: u64 = @truncate((out >> dsh) & dmask);
                    const wide_a_u: u64 = @truncate((va128 >> dsh) & dmask);
                    const wide_a_s: i64 = switch (size) {
                        0 => @as(i16, @bitCast(@as(u16, @truncate(wide_a_u)))),
                        1 => @as(i32, @bitCast(@as(u32, @truncate(wide_a_u)))),
                        else => @bitCast(wide_a_u),
                    };
                    const val: u64 = switch (opcode) {
                        0b0000 => if (u) (ua +% ub) else @bitCast(sa + sb), // SADDL / UADDL
                        0b0001 => if (u) (wide_a_u +% ub) else @bitCast(wide_a_s +% sb), // SADDW / UADDW
                        0b0010 => if (u) (ua -% ub) else @bitCast(sa - sb), // SSUBL / USUBL
                        0b0011 => if (u) (wide_a_u -% ub) else @bitCast(wide_a_s -% sb), // SSUBW / USUBW
                        0b0101 => cur_d +% (if (u) (if (ua > ub) ua - ub else ub - ua) else @as(u64, @intCast(@abs(sa - sb)))), // SABAL / UABAL
                        0b0111 => if (u) (if (ua > ub) ua - ub else ub - ua) else @as(u64, @intCast(@abs(sa - sb))), // SABDL / UABDL
                        0b1000 => cur_d +% (if (u) (ua * ub) else @as(u64, @bitCast(sa * sb))), // SMLAL / UMLAL
                        0b1010 => cur_d -% (if (u) (ua * ub) else @as(u64, @bitCast(sa * sb))), // SMLSL / UMLSL
                        0b1100 => if (u) (ua * ub) else @bitCast(sa * sb), // SMULL / UMULL
                        else => 0,
                    };
                    out = (out & ~(dmask << dsh)) | ((@as(u128, val) & dmask) << dsh);
                }
                cpu.vfp.v[rd] = out;
                return;
            }

            // 6. AdvSIMD three same (`AND`, `BIC`, `ORR`, `ORN`, `EOR`, `BSL`, `BIT`, `BIF`, `ADD`, `SUB`, `CMEQ`, `CMTST`, `CMGT`, `CMHI`, `CMGE`, `CMHS`, `UMIN`, `UMAX`, `UMINP`, `UMAXP`, `ADDP`, `USHL`, `SSHL`, `MUL`) (`(inst & 0x9f20_0400) == 0x0e20_0400`)
            if ((inst & 0x9f20_0400) == 0x0e20_0400) {
                const q = ((inst >> 30) & 1) != 0;
                const u = ((inst >> 29) & 1) != 0;
                const size: u2 = @truncate(inst >> 22);
                const opcode: u5 = @truncate(inst >> 11);
                const mask: u128 = if (q) ~@as(u128, 0) else 0xffff_ffff_ffff_ffff;
                const va = cpu.vfp.v[rn];
                const vb = cpu.vfp.v[rm];

                if (opcode == 0b00011) {
                    // Bitwise logical: AND (u=0, s=0), BIC (u=0, s=1), ORR/MOV (u=0, s=2), ORN (u=0, s=3), EOR (u=1, s=0), BSL (u=1, s=1), BIT (u=1, s=2), BIF (u=1, s=3)
                    const vd = cpu.vfp.v[rd];
                    const res: u128 = if (!u) switch (size) {
                        0 => va & vb,
                        1 => va & ~vb,
                        2 => va | vb,
                        3 => va | ~vb,
                    } else switch (size) {
                        0 => va ^ vb,
                        1 => (va & vd) | (vb & ~vd), // BSL
                        2 => (va & vb) | (vd & ~vb), // BIT
                        3 => (va & ~vb) | (vd & vb), // BIF
                    };
                    cpu.vfp.v[rd] = res & mask;
                    return;
                }

                const ebits: u7 = @as(u7, 8) << size;
                const total_bits: usize = if (q) 128 else 64;
                const lanes: usize = total_bits / ebits;
                const emask: u64 = if (ebits >= 64) 0xffff_ffff_ffff_ffff else ((@as(u64, 1) << @intCast(ebits)) - 1);

                if (opcode == 0b10100 or opcode == 0b10101 or opcode == 0b10111) {
                    // Pairwise operations: SMAXP/UMAXP (10100), SMINP/UMINP (10101), ADDP (10111)
                    const half_lanes = lanes / 2;
                    var out: u128 = 0;
                    for (0..lanes) |i| {
                        const src_vec = if (i < half_lanes) va else vb;
                        const pair_idx = if (i < half_lanes) (i * 2) else ((i - half_lanes) * 2);
                        const sh0: u7 = @intCast(pair_idx * ebits);
                        const sh1: u7 = @intCast((pair_idx + 1) * ebits);
                        const val_u0: u64 = @as(u64, @truncate(src_vec >> sh0)) & emask;
                        const val_u1: u64 = @as(u64, @truncate(src_vec >> sh1)) & emask;
                        const s0: i64 = switch (size) {
                            0 => @as(i8, @bitCast(@as(u8, @truncate(val_u0)))),
                            1 => @as(i16, @bitCast(@as(u16, @truncate(val_u0)))),
                            2 => @as(i32, @bitCast(@as(u32, @truncate(val_u0)))),
                            3 => @bitCast(val_u0),
                        };
                        const s1: i64 = switch (size) {
                            0 => @as(i8, @bitCast(@as(u8, @truncate(val_u1)))),
                            1 => @as(i16, @bitCast(@as(u16, @truncate(val_u1)))),
                            2 => @as(i32, @bitCast(@as(u32, @truncate(val_u1)))),
                            3 => @bitCast(val_u1),
                        };
                        const res_elem: u64 = if (opcode == 0b10111)
                            (val_u0 +% val_u1)
                        else if (opcode == 0b10100)
                            (if (u) @max(val_u0, val_u1) else @as(u64, @bitCast(@max(s0, s1))))
                        else
                            (if (u) @min(val_u0, val_u1) else @as(u64, @bitCast(@min(s0, s1))));
                        out |= (@as(u128, res_elem & emask) << @intCast(i * ebits));
                    }
                    cpu.vfp.v[rd] = out & mask;
                    return;
                }

                var out: u128 = 0;
                const vd_cur = cpu.vfp.v[rd];
                for (0..lanes) |i| {
                    const sh: u7 = @intCast(i * ebits);
                    const ua: u64 = @as(u64, @truncate(va >> sh)) & emask;
                    const ub: u64 = @as(u64, @truncate(vb >> sh)) & emask;
                    const ud: u64 = @as(u64, @truncate(vd_cur >> sh)) & emask;
                    const sa: i64 = switch (size) {
                        0 => @as(i8, @bitCast(@as(u8, @truncate(ua)))),
                        1 => @as(i16, @bitCast(@as(u16, @truncate(ua)))),
                        2 => @as(i32, @bitCast(@as(u32, @truncate(ua)))),
                        3 => @bitCast(ua),
                    };
                    const sb: i64 = switch (size) {
                        0 => @as(i8, @bitCast(@as(u8, @truncate(ub)))),
                        1 => @as(i16, @bitCast(@as(u16, @truncate(ub)))),
                        2 => @as(i32, @bitCast(@as(u32, @truncate(ub)))),
                        3 => @bitCast(ub),
                    };
                    const res_elem: u64 = switch (opcode) {
                        0b00000 => if (u) (ua +| ub) else @bitCast(switch (size) { // SHADD / UHADD
                            0 => (sa + sb) >> 1,
                            1 => (sa + sb) >> 1,
                            2 => (sa + sb) >> 1,
                            3 => (sa + sb) >> 1,
                        }),
                        0b00100 => if (u) (ua -| ub) else @bitCast((sa - sb) >> 1), // SHSUB / UHSUB
                        0b00110 => if (if (u) (ua > ub) else (sa > sb)) emask else 0, // CMGT / CMHI
                        0b00111 => if (if (u) (ua >= ub) else (sa >= sb)) emask else 0, // CMGE / CMHS
                        0b01000 => blk: { // SSHL / USHL (signed shift count in low byte of ub!)
                            const sh_amt: i8 = @bitCast(@as(u8, @truncate(ub)));
                            if (sh_amt >= 0) {
                                const lsh: u7 = @intCast(sh_amt);
                                break :blk if (lsh >= ebits) 0 else (ua << @intCast(lsh));
                            } else {
                                const rsh: u7 = @intCast(-@as(i16, sh_amt));
                                if (u) {
                                    break :blk if (rsh >= ebits) 0 else (ua >> @intCast(rsh));
                                } else {
                                    break :blk @bitCast(if (rsh >= 64) (sa >> 63) else (sa >> @intCast(rsh)));
                                }
                            }
                        },
                        0b01100 => if (u) @max(ua, ub) else @bitCast(@max(sa, sb)), // SMAX / UMAX
                        0b01101 => if (u) @min(ua, ub) else @bitCast(@min(sa, sb)), // SMIN / UMIN
                        0b01110 => if (u) (if (ua > ub) ua - ub else ub - ua) else @intCast(@abs(sa - sb)), // SABD / UABD
                        0b01111 => ud +% (if (u) (if (ua > ub) ua - ub else ub - ua) else @as(u64, @intCast(@abs(sa - sb)))), // SABA / UABA
                        0b10000 => if (u) (ua -% ub) else (ua +% ub), // ADD / SUB
                        0b10001 => if (if (u) (ua == ub) else ((ua & ub) != 0)) emask else 0, // CMTST / CMEQ
                        0b10010 => if (u) (ud -% (ua *% ub)) else (ud +% (ua *% ub)), // MLA / MLS
                        0b10011 => if (!u) (ua *% ub) else blk: { // MUL / PMUL
                            var p: u16 = 0;
                            var b_i: u4 = 0;
                            while (b_i < 8) : (b_i += 1) {
                                if (((ua >> b_i) & 1) != 0) p ^= (@as(u16, @as(u8, @truncate(ub))) << b_i);
                            }
                            break :blk p;
                        },
                        else => ua,
                    };
                    out |= (@as(u128, res_elem & emask) << sh);
                }
                cpu.vfp.v[rd] = out & mask;
                return;
            }

            // 6b. AdvSIMD scalar three same (`ADD Dd, Dn, Dm`, `SUB Dd, Dn, Dm`, `CMTST`, `CMEQ`, `CMGT`, `CMHI`, `CMGE`, `CMHS`, `USHL`, `SSHL`) (`(inst & 0xdf20_0400) == 0x5e20_0400`)
            if ((inst & 0xdf20_0400) == 0x5e20_0400) {
                const u = ((inst >> 29) & 1) != 0;
                const size: u2 = @truncate(inst >> 22);
                const opcode: u5 = @truncate(inst >> 11);
                const ebits: u7 = @as(u7, 8) << size;
                const emask: u64 = if (ebits >= 64) 0xffff_ffff_ffff_ffff else ((@as(u64, 1) << @intCast(ebits)) - 1);
                const ua: u64 = @as(u64, @truncate(cpu.vfp.v[rn])) & emask;
                const ub: u64 = @as(u64, @truncate(cpu.vfp.v[rm])) & emask;
                const sa: i64 = @bitCast(ua);
                const sb: i64 = @bitCast(ub);
                const res: u64 = switch (opcode) {
                    0b10000 => if (u) (ua -% ub) else (ua +% ub),
                    0b10001 => if (if (u) (ua == ub) else ((ua & ub) != 0)) emask else 0,
                    0b00110 => if (if (u) (ua > ub) else (sa > sb)) emask else 0,
                    0b00111 => if (if (u) (ua >= ub) else (sa >= sb)) emask else 0,
                    else => ua,
                };
                cpu.vfp.v[rd] = res & emask;
                return;
            }
        }
    };
}

test "AArch64 A64 instruction execution, EL2->EL1 ERET transition, SVC exception, and SIMD" {
    const arm1176 = @import("arm1176.zig");
    const TestBus = struct {
        ram: []u8,
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

    // Verify decodeLogicalImm
    try std.testing.expectEqual(@as(?u64, 0x0000_0000_ffff_ffff), decodeLogicalImm(1, 1, 31, 0));
    try std.testing.expectEqual(@as(?u64, 0x0000_0001_0000_0001), decodeLogicalImm(1, 0, 0, 0));
    try std.testing.expectEqual(@as(?u64, 0x5555_5555_5555_5555), decodeLogicalImm(1, 0, 0b111100, 0));

    const allocator = std.testing.allocator;
    const ram = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(ram);
    @memset(ram, 0);

    var bus: TestBus = .{ .ram = ram };
    const Cpu = arm1176.Arm1176(TestBus);
    var cpu: Cpu = .{};
    cpu.initReset64(0x1000, 0x03f0_0000);

    // Verify initial EL2h state
    try std.testing.expect(cpu.is_aarch64);
    try std.testing.expectEqual(@as(u64, 0x03f0_0000), cpu.x[0]);
    try std.testing.expectEqual(@as(u2, 2), @as(u2, @truncate((cpu.pstate >> 2) & 3)));

    // Program at 0x1000 (EL2 -> EL1 drop via ERET, then arithmetic, STP/LDP, SVC to EL1 vector at 0x20000):
    // 0x1000: movz x1, #0x2000            (0xd2840001)
    // 0x1004: msr elr_el2, x1             (0xd51c4021)
    // 0x1008: movz x2, #0x3c5             (0xd28078a2) -> EL1h with DAIF masked
    // 0x100c: msr spsr_el2, x2            (0xd51c4002)
    // 0x1010: eret                        (0xd69f03e0)
    const el2_prog = [_]u32{
        0xd2840001,
        0xd51c4021,
        0xd28078a2,
        0xd51c4002,
        0xd69f03e0,
    };
    for (el2_prog, 0..) |inst, i| {
        std.mem.writeInt(u32, ram[0x1000 + i * 4 ..][0..4], inst, .little);
    }

    // Program at 0x2000 (EL1h):
    // 0x2000: movz x3, #0x10000, lsl #0   (0xd2a00023 -> 0x10000)
    // 0x2004: add sp, x3, #0              (0x9100007f -> SP_EL1 = 0x10000)
    // 0x2008: movz x4, #0x1234            (0xd2824684)
    // 0x200c: movk x4, #0x5678, lsl #16   (0xf2aacf04 -> x4 = 0x56781234)
    // 0x2010: movz x5, #42                (0xd2800545)
    // 0x2014: stp x4, x5, [sp, #-16]!     (0xa9bf17e4)
    // 0x2018: ldp x6, x7, [sp], #16       (0xa8c11fe6)
    // 0x201c: movz x8, #0x2, lsl #16      (0xd2a00048 -> 0x20000)
    // 0x2020: msr vbar_el1, x8            (0xd518c008)
    // 0x2024: svc #0x77                   (0xd4000ee1)
    const el1_prog = [_]u32{
        0xd2a00023,
        0x9100007f,
        0xd2824684,
        0xf2aacf04,
        0xd2800545,
        0xa9bf17e4,
        0xa8c11fe6,
        0xd2a00048,
        0xd518c008,
        0xd4000ee1,
    };
    for (el1_prog, 0..) |inst, i| {
        std.mem.writeInt(u32, ram[0x2000 + i * 4 ..][0..4], inst, .little);
    }

    // EL1 Synchronous Exception Vector (Current EL with SP_ELx = VBAR_EL1 + 0x200 = 0x20200):
    // 0x20200: mrs x9, esr_el1            (0xd5385209)
    // 0x20204: wfi                        (0xd503207f)
    std.mem.writeInt(u32, ram[0x20200..][0..4], 0xd5385209, .little);
    std.mem.writeInt(u32, ram[0x20204..][0..4], 0xd503207f, .little);

    _ = cpu.runSteps(&bus, 32);

    // Check EL1 transition and register results
    try std.testing.expectEqual(@as(u2, 1), @as(u2, @truncate((cpu.pstate >> 2) & 3)));
    try std.testing.expectEqual(@as(u64, 0x10000), cpu.sp_el[1]);
    try std.testing.expectEqual(@as(u64, 0x56781234), cpu.x[6]);
    try std.testing.expectEqual(@as(u64, 42), cpu.x[7]);
    // Check SVC ESR_EL1 (EC = 0b010101, IL = 1, ISS = 0x77)
    try std.testing.expectEqual(@as(u64, (0b010101 << 26) | (1 << 25) | 0x77), cpu.x[9]);
    try std.testing.expect(cpu.mmu.halted_wfi);

    // Verify BIC, ORN, EON, and shifted ORR/EOR in decodeA64:
    // 0x3000: orn x10, x4, x5             (0xaa25008a)
    // 0x3004: eon x11, x4, x5             (0xca25008b)
    // 0x3008: eor x12, x4, x5, lsl #4     (0xca05108c)
    // 0x300c: orr x13, x4, x5, lsl #4     (0xaa05108d)
    // 0x3010: wfi                         (0xd503207f)
    const logic_prog = [_]u32{
        0xaa25008a,
        0xca25008b,
        0xca05108c,
        0xaa05108d,
        0xd503207f,
    };
    for (logic_prog, 0..) |inst, i| {
        std.mem.writeInt(u32, ram[0x3000 + i * 4 ..][0..4], inst, .little);
    }
    cpu.mmu.halted_wfi = false;
    cpu.pc64 = 0x3000;
    _ = cpu.runSteps(&bus, 16);
    try std.testing.expectEqual(@as(u64, 0x56781234) | ~@as(u64, 42), cpu.x[10]);
    try std.testing.expectEqual(@as(u64, 0x56781234) ^ ~@as(u64, 42), cpu.x[11]);
    try std.testing.expectEqual(@as(u64, 0x56781234) ^ (@as(u64, 42) << 4), cpu.x[12]);
    try std.testing.expectEqual(@as(u64, 0x56781234) | (@as(u64, 42) << 4), cpu.x[13]);
}

test "AArch64 pre-decoded atomics, SBFM/SXTW, variable shifts, extended add, indexed/reg loads, and BLR" {
    const arm1176 = @import("arm1176.zig");
    const TestBus = struct {
        ram: []u8,
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

    const allocator = std.testing.allocator;
    const ram = try allocator.alloc(u8, 128 * 1024);
    defer allocator.free(ram);
    @memset(ram, 0);

    var bus: TestBus = .{ .ram = ram };
    const Cpu = arm1176.Arm1176(TestBus);
    const Exec = Aarch64Exec(Cpu, TestBus);
    var cpu: Cpu = .{};
    cpu.initReset64(0x1000, 0x3000);
    std.mem.writeInt(u64, ram[0x3000..][0..8], 100, .little);
    std.mem.writeInt(i32, ram[0x3010..][0..4], -7, .little);

    // 0x1000: ldxr x1, [x0]                 (0xc85f7c01) -> x1 = 100, excl_valid = true
    // 0x1004: add x2, x1, #23               (0x91005c22) -> x2 = 123
    // 0x1008: stxr w3, x2, [x0]             (0xc8037c02) -> [0x3000] = 123, w3 = 0
    // 0x100c: stxr w4, x1, [x0]             (0xc8047c01) -> fails, w4 = 1
    // 0x1010: ldrsw x5, [x0, #16]           (0xb9801005) -> x5 = -7 (0xffff_ffff_ffff_fff9)
    // 0x1014: sxtw x6, w5                   (0x93407ca6) -> sbfm64_r: x6 = -7
    // 0x1018: movz x7, #3                   (0xd2800067) -> x7 = 3
    // 0x101c: lslv x8, x2, x7               (0x9ac72048) -> x8 = 123 << 3 = 984
    // 0x1020: str x8, [x0, x7, lsl #3]      (0xf8277808) -> [0x3018] = 984
    // 0x1024: ldr x9, [x0, x7, lsl #3]      (0xf8677809) -> x9 = 984
    // 0x1028: wfi                           (0xd503207f)
    const prog = [_]u32{
        0xc85f7c01,
        0x91005c22,
        0xc8037c02,
        0xc8047c01,
        0xb9801005,
        0x93407ca6,
        0xd2800067,
        0x9ac72048,
        0xf8277808,
        0xf8677809,
        0xd503207f,
    };
    for (prog, 0..) |inst, i| {
        std.mem.writeInt(u32, ram[0x1000 + i * 4 ..][0..4], inst, .little);
    }

    const SlotType = @TypeOf(cpu.icache[0]);
    try std.testing.expectEqual(Exec.A64Op.ldxr64, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[0]).op)));
    try std.testing.expectEqual(Exec.A64Op.stxr64, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[2]).op)));
    try std.testing.expectEqual(Exec.A64Op.ldrsw_uimm, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[4]).op)));
    try std.testing.expectEqual(Exec.A64Op.sbfm64_r, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[5]).op)));
    try std.testing.expectEqual(Exec.A64Op.lslv64, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[7]).op)));
    try std.testing.expectEqual(Exec.A64Op.str64_reg_lsl, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[8]).op)));
    try std.testing.expectEqual(Exec.A64Op.ldr64_reg_lsl, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[9]).op)));

    _ = cpu.runSteps(&bus, 16);
    try std.testing.expectEqual(@as(u64, 100), cpu.x[1]);
    try std.testing.expectEqual(@as(u64, 123), cpu.x[2]);
    try std.testing.expectEqual(@as(u64, 0), cpu.x[3]);
    try std.testing.expectEqual(@as(u64, 1), cpu.x[4]);
    try std.testing.expectEqual(@as(u64, 123), std.mem.readInt(u64, ram[0x3000..][0..8], .little));
    try std.testing.expectEqual(@as(u64, @bitCast(@as(i64, -7))), cpu.x[5]);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(i64, -7))), cpu.x[6]);
    try std.testing.expectEqual(@as(u64, 984), cpu.x[8]);
    try std.testing.expectEqual(@as(u64, 984), cpu.x[9]);
}

test "AArch64 pre-decoded NEON/FP load-store (LDR/STR/LDP/STP Q/D)" {
    const TestBus = struct {
        ram: []u8,
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

    const allocator = std.testing.allocator;
    const ram = try allocator.alloc(u8, 128 * 1024);
    defer allocator.free(ram);
    @memset(ram, 0);

    const arm1176 = @import("arm1176.zig");
    var bus: TestBus = .{ .ram = ram };
    const Cpu = arm1176.Arm1176(TestBus);
    const Exec = Aarch64Exec(Cpu, TestBus);
    var cpu: Cpu = .{};
    cpu.initReset64(0x1000, 0x3000);
    cpu.x[1] = 0x3100;

    const q0_val: u128 = 0x01234567_89abcdef_fedcba98_76543210;
    const q1_val: u128 = 0xdeadbeef_cafebabe_11223344_55667788;
    std.mem.writeInt(u128, ram[0x3000..][0..16], q0_val, .little);
    std.mem.writeInt(u128, ram[0x3010..][0..16], q1_val, .little);

    // 0x1000: ldp q0, q1, [x0], #32         (0xacc10400) -> q0, q1 loaded, x0 = 0x3020
    // 0x1004: stp q0, q1, [x1], #32         (0xac810420) -> stored to [0x3100..0x3120], x1 = 0x3120
    // 0x1008: ldr q2, [x1, #-16]            (0x3cdf0022) -> unscaled ldur q2, [x1, #-16] = q1_val
    // 0x100c: str q2, [x1, #16]             (0x3d800422) -> scaled str q2, [x1, #16] -> [0x3130] = q1_val
    // 0x1010: ldr d3, [x1, #-32]            (0xf85e0023 -> wait: FP LDUR D3 is 0xfc5e0023)
    // 0x1014: str d3, [x1, #32]             (0xfd001023) -> scaled str d3, [x1, #32] -> [0x3140] = low64(q0_val)
    // 0x1018: wfi                           (0xd503207f)
    const prog = [_]u32{
        0xacc10400,
        0xac810420,
        0x3cdf0022,
        0x3d800422,
        0xfc5e0023,
        0xfd001023,
        0xd503207f,
    };
    for (prog, 0..) |inst, i| {
        std.mem.writeInt(u32, ram[0x1000 + i * 4 ..][0..4], inst, .little);
    }

    const SlotType = @TypeOf(cpu.icache[0]);
    try std.testing.expectEqual(Exec.A64Op.ldp_fp128_post, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[0]).op)));
    try std.testing.expectEqual(Exec.A64Op.stp_fp128_post, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[1]).op)));
    try std.testing.expectEqual(Exec.A64Op.ldr_fp128_uimm, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[2]).op)));
    try std.testing.expectEqual(Exec.A64Op.str_fp128_uimm, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[3]).op)));
    try std.testing.expectEqual(Exec.A64Op.ldr_fp64_uimm, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[4]).op)));
    try std.testing.expectEqual(Exec.A64Op.str_fp64_uimm, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[5]).op)));

    _ = cpu.runSteps(&bus, 16);
    try std.testing.expectEqual(q0_val, cpu.vfp.v[0]);
    try std.testing.expectEqual(q1_val, cpu.vfp.v[1]);
    try std.testing.expectEqual(q1_val, cpu.vfp.v[2]);
    try std.testing.expectEqual(@as(u64, 0x3020), cpu.x[0]);
    try std.testing.expectEqual(@as(u64, 0x3120), cpu.x[1]);
    try std.testing.expectEqual(q0_val, std.mem.readInt(u128, ram[0x3100..][0..16], .little));
    try std.testing.expectEqual(q1_val, std.mem.readInt(u128, ram[0x3110..][0..16], .little));
    try std.testing.expectEqual(q1_val, std.mem.readInt(u128, ram[0x3130..][0..16], .little));
    try std.testing.expectEqual(@as(u64, @truncate(q0_val)), std.mem.readInt(u64, ram[0x3140..][0..8], .little));
}

test "AArch64 pre-decoded scalar FP and NEON vector fast-paths" {
    const TestBus = struct {
        ram: []u8,
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

    const allocator = std.testing.allocator;
    const ram = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(ram);
    @memset(ram, 0);

    const arm1176 = @import("arm1176.zig");
    var bus: TestBus = .{ .ram = ram };
    const Cpu = arm1176.Arm1176(TestBus);
    const Exec = Aarch64Exec(Cpu, TestBus);
    var cpu: Cpu = .{};
    cpu.initReset64(0x1000, 0x3000);
    cpu.x[0] = @bitCast(@as(f64, 2.5));
    cpu.x[1] = @bitCast(@as(f64, 1.5));
    cpu.x[3] = 0x05;

    const prog = [_]u32{
        0x9e670000, // fmov d0, x0
        0x9e670021, // fmov d1, x1
        0x1e612802, // fadd d2, d0, d1        (d2 = 4.0)
        0x1e600843, // fmul d3, d2, d0        (d3 = 10.0)
        0x1e622060, // fcmp d3, d2            (10.0 > 4.0 -> N=0, Z=0, C=1, V=0)
        0x9e660062, // fmov x2, d3            (x2 = bits(10.0))
        0x4f00e604, // movi v4.16b, #0x10
        0x4e010c65, // dup v5.16b, w3         (0x05)
        0x4e258486, // add v6.16b, v4.16b, v5.16b (0x15 in all 16 bytes)
        0x6e248cc7, // cmeq v7.16b, v6.16b, v4.16b (0x00 in all 16 bytes)
        0x4e2098e8, // cmeq v8.16b, v7.16b, #0     (0xff in all 16 bytes)
        0x4e083cc4, // umov x4, v6.d[0]       (0x1515151515151515)
        0xd503207f, // wfi
    };
    for (prog, 0..) |inst, i| {
        std.mem.writeInt(u32, ram[0x1000 + i * 4 ..][0..4], inst, .little);
    }

    const SlotType = @TypeOf(cpu.icache[0]);
    try std.testing.expectEqual(Exec.A64Op.fmov_d_x, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[0]).op)));
    try std.testing.expectEqual(Exec.A64Op.fadd_f64, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[2]).op)));
    try std.testing.expectEqual(Exec.A64Op.fmul_f64, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[3]).op)));
    try std.testing.expectEqual(Exec.A64Op.fcmp_f64, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[4]).op)));
    try std.testing.expectEqual(Exec.A64Op.fmov_x_d, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[5]).op)));
    try std.testing.expectEqual(Exec.A64Op.simd_movi, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[6]).op)));
    try std.testing.expectEqual(Exec.A64Op.simd_dup_gpr, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[7]).op)));
    try std.testing.expectEqual(Exec.A64Op.simd_add_8, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[8]).op)));
    try std.testing.expectEqual(Exec.A64Op.simd_cmeq_8, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[9]).op)));
    try std.testing.expectEqual(Exec.A64Op.simd_cmeqz_8, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[10]).op)));
    try std.testing.expectEqual(Exec.A64Op.simd_umov64, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[11]).op)));

    _ = cpu.runSteps(&bus, 32);
    try std.testing.expectEqual(@as(f64, 10.0), @as(f64, @bitCast(cpu.x[2])));
    try std.testing.expectEqual(@as(u4, 0b0010), @as(u4, @truncate(cpu.cpsr >> 28)));
    try std.testing.expectEqual(@as(u128, 0x15151515_15151515_15151515_15151515), cpu.vfp.v[6]);
    try std.testing.expectEqual(@as(u128, 0), cpu.vfp.v[7]);
    try std.testing.expectEqual(~@as(u128, 0), cpu.vfp.v[8]);
    try std.testing.expectEqual(@as(u64, 0x15151515_15151515), cpu.x[4]);
}

test "AArch64 TLBI VAE1IS masks 16-bit ASID and queues broadcast VA while BTI c does not yield slice" {
    const TestBus = struct {
        ram: []u8,
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

    const allocator = std.testing.allocator;
    const ram = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(ram);
    @memset(ram, 0);

    const arm1176 = @import("arm1176.zig");
    var bus: TestBus = .{ .ram = ram };
    const Cpu = arm1176.Arm1176(TestBus);
    var cpu: Cpu = .{};
    cpu.initReset64(0x1000, 0);

    const vaddr: u64 = 0xffff_ffc0_8207_2000;
    const vpn: u52 = @truncate((vaddr & 0x00ff_ffff_ffff_ffff) >> 12);
    const idx: usize = @as(usize, @truncate(vpn)) & mmu_mod.Mmu.tlb_mask;
    cpu.mmu.tlb[idx] = .{
        .vpn = vpn,
        .ppn_base = 0x4000,
        .gen = cpu.mmu.tlb_gen,
        .perms = 0xff,
    };

    // Pass non-zero ASID (including low 4 bits 0xf) in bits [63:48] of TLBI operand
    const tlbi_arg: u64 = (0x123f << 48) | ((vaddr >> 12) & 0x0000_0fff_ffff_ffff);
    cpu.x[0] = tlbi_arg;

    // 0x1000: bti c          (0xd503245f) -> must NOT yield slice
    // 0x1004: tlbi vae1is,x0 (0xd5088320) -> invalidates vpn and queues broadcast VA
    // 0x1008: add x1, x1, #1 (0x91000421) -> executes within the same slice
    // 0x100c: wfi            (0xd503207f)
    const prog = [_]u32{
        0xd503245f,
        0xd5088320,
        0x91000421,
        0xd503207f,
    };
    for (prog, 0..) |inst, i| {
        std.mem.writeInt(u32, ram[0x1000 + i * 4 ..][0..4], inst, .little);
    }

    const ran = cpu.runSteps(&bus, 16);
    try std.testing.expectEqual(@as(usize, 4), ran);
    try std.testing.expectEqual(@as(u64, 1), cpu.x[1]);
    try std.testing.expectEqual(@as(u32, 0), cpu.mmu.tlb[idx].gen);
    try std.testing.expectEqual(@as(u16, 1), cpu.mmu.tlb_broadcast_va_count);
    try std.testing.expectEqual(tlbi_arg, cpu.mmu.tlb_broadcast_vas[0]);
}

test "AArch64 pre-decoded LDPSW, FP64/128 reg-offset, and NEON LD1/ST1/EXT/USHR/SHL" {
    const TestBus = struct {
        ram: []u8,
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

    const allocator = std.testing.allocator;
    const ram = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(ram);
    @memset(ram, 0);

    const arm1176 = @import("arm1176.zig");
    var bus: TestBus = .{ .ram = ram };
    const Cpu = arm1176.Arm1176(TestBus);
    const Exec = Aarch64Exec(Cpu, TestBus);
    var cpu: Cpu = .{};
    cpu.initReset64(0x1000, 0x3000);
    cpu.x[1] = 0x3100;
    cpu.x[2] = 1;

    std.mem.writeInt(i32, ram[0x3000..][0..4], -10, .little);
    std.mem.writeInt(i32, ram[0x3004..][0..4], 42, .little);
    const v0_init: u128 = 0x08070605_04030201_10203040_50607080;
    const v1_init: u128 = 0xfefdfcfb_faf9f8f7_f6f5f4f3_f2f1f0ef;
    std.mem.writeInt(u128, ram[0x3010..][0..16], v0_init, .little);
    std.mem.writeInt(u128, ram[0x3020..][0..16], v1_init, .little);

    // 0x1000: ldpsw x3, x4, [x0], #16              (0x68c21003) -> x3 = -10, x4 = 42, x0 = 0x3010
    // 0x1004: ld1 {v0.16b, v1.16b}, [x0], #32      (0x4cdfa400) -> v0=v0_init, v1=v1_init, x0 = 0x3030
    // 0x1008: ext v2.16b, v0.16b, v1.16b, #8       (0x6e014002) -> low64=high64(v0), high64=low64(v1)
    // 0x100c: ushr v3.16b, v0.16b, #4              (0x6f0c0403) -> each byte of v0 >> 4
    // 0x1010: shl v4.16b, v0.16b, #4               (0x4f0c5404) -> each byte of v0 << 4
    // 0x1014: st1 {v3.16b, v4.16b}, [x1], #32      (0x4c9fa423) -> stored to [0x3100..0x3120], x1 = 0x3120
    // 0x1018: str q2, [x1, x2, lsl #4]             (0x3ca27822) -> stored to [0x3130]
    // 0x101c: ldr q5, [x1, x2, lsl #4]             (0x3ce27825) -> loaded from [0x3130] into v5
    // 0x1020: wfi                                  (0xd503207f)
    const prog = [_]u32{
        0x68c21003,
        0x4cdfa400,
        0x6e014002,
        0x6f0c0403,
        0x4f0c5404,
        0x4c9fa423,
        0x3ca27822,
        0x3ce27825,
        0xd503207f,
    };
    for (prog, 0..) |inst, i| {
        std.mem.writeInt(u32, ram[0x1000 + i * 4 ..][0..4], inst, .little);
    }

    const SlotType = @TypeOf(cpu.icache[0]);
    try std.testing.expectEqual(Exec.A64Op.ldpsw_post, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[0]).op)));
    try std.testing.expectEqual(Exec.A64Op.simd_ld1_mult, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[1]).op)));
    try std.testing.expectEqual(Exec.A64Op.simd_ext_q, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[2]).op)));
    try std.testing.expectEqual(Exec.A64Op.simd_ushr, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[3]).op)));
    try std.testing.expectEqual(Exec.A64Op.simd_shl, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[4]).op)));
    try std.testing.expectEqual(Exec.A64Op.simd_st1_mult, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[5]).op)));
    try std.testing.expectEqual(Exec.A64Op.str_fp128_reg_lsl, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[6]).op)));
    try std.testing.expectEqual(Exec.A64Op.ldr_fp128_reg_lsl, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[7]).op)));

    _ = cpu.runSteps(&bus, 16);
    try std.testing.expectEqual(@as(i64, -10), @as(i64, @bitCast(cpu.x[3])));
    try std.testing.expectEqual(@as(i64, 42), @as(i64, @bitCast(cpu.x[4])));
    try std.testing.expectEqual(@as(u64, 0x3030), cpu.x[0]);
    try std.testing.expectEqual(@as(u64, 0x3120), cpu.x[1]);
    try std.testing.expectEqual(@as(u128, 0xf6f5f4f3_f2f1f0ef_08070605_04030201), cpu.vfp.v[2]);
    try std.testing.expectEqual(cpu.vfp.v[2], cpu.vfp.v[5]);
    try std.testing.expectEqual(@as(u128, 0x00000000_00000000_01020304_05060708), cpu.vfp.v[3]);
    try std.testing.expectEqual(@as(u128, 0x80706050_40302010_00000000_00000000), cpu.vfp.v[4]);
    try std.testing.expectEqual(cpu.vfp.v[3], std.mem.readInt(u128, ram[0x3100..][0..16], .little));
    try std.testing.expectEqual(cpu.vfp.v[4], std.mem.readInt(u128, ram[0x3110..][0..16], .little));
}

test "AArch64 AdvSIMD modified immediate shifts (MOVI/MVNI/ORR/BIC LSL #8/#16/#24)" {
    const arm1176 = @import("arm1176.zig");
    const TestBus = struct {
        ram: []u8,
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

    const allocator = std.testing.allocator;
    const ram = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(ram);
    @memset(ram, 0);

    var bus: TestBus = .{ .ram = ram };
    const Cpu = arm1176.Arm1176(TestBus);
    var cpu: Cpu = .{};
    cpu.initReset64(0x1000, 0);
    cpu.x[1] = 0x3000;
    cpu.vfp.v[3] = 0x0000_0011_0000_0011;
    cpu.vfp.v[4] = ~@as(u128, 0);

    // mke2fs builds the JBD2 superblock's big-endian s_first / s_sequence (htonl(1)) this way.
    // 0x1000: movi v0.2s, #0x1, lsl #24   (0x0f006420)
    // 0x1004: movi v1.4s, #0xab, lsl #16  (0x4f054561)
    // 0x1008: mvni v2.2s, #0x1, lsl #24   (0x2f006422)
    // 0x100c: orr v3.2s, #0x1, lsl #24    (0x0f007423)
    // 0x1010: bic v4.4s, #0xff, lsl #16   (0x6f0757e4)
    // 0x1014: movi v5.4h, #0x12, lsl #8   (0x0f00a645)
    // 0x1018: stur d0, [x1, #20]          (0xfc014020)
    // 0x101c: wfi                         (0xd503207f)
    const prog = [_]u32{ 0x0f006420, 0x4f054561, 0x2f006422, 0x0f007423, 0x6f0757e4, 0x0f00a645, 0xfc014020, 0xd503207f };
    for (prog, 0..) |inst, i| {
        std.mem.writeInt(u32, ram[0x1000 + i * 4 ..][0..4], inst, .little);
    }

    _ = cpu.runSteps(&bus, 16);
    try std.testing.expectEqual(@as(u128, 0x0100_0000_0100_0000), cpu.vfp.v[0]);
    try std.testing.expectEqual(@as(u128, 0x00ab_0000_00ab_0000_00ab_0000_00ab_0000), cpu.vfp.v[1]);
    try std.testing.expectEqual(@as(u128, 0xfeff_ffff_feff_ffff), cpu.vfp.v[2]);
    try std.testing.expectEqual(@as(u128, 0x0100_0011_0100_0011), cpu.vfp.v[3]);
    try std.testing.expectEqual(@as(u128, 0xff00_ffff_ff00_ffff_ff00_ffff_ff00_ffff), cpu.vfp.v[4]);
    try std.testing.expectEqual(@as(u128, 0x1200_1200_1200_1200), cpu.vfp.v[5]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0, 0, 0, 1 }, ram[0x3014..0x301c]);
}

test "AArch64 pre-decoded signed loads, literal loads, shifted/ext ALU, CCMP, UDIV/SDIV, and MADDL/MULH" {
    const arm1176 = @import("arm1176.zig");
    const TestBus = struct {
        ram: []u8,
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

    const allocator = std.testing.allocator;
    const ram = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(ram);
    @memset(ram, 0);

    var bus: TestBus = .{ .ram = ram };
    const Cpu = arm1176.Arm1176(TestBus);
    const Exec = Aarch64Exec(Cpu, TestBus);
    var cpu: Cpu = .{};
    cpu.initReset64(0x1000, 0x3000);

    // Populate data at 0x3000 (signed byte -5, signed halfword -300)
    ram[0x3000] = @bitCast(@as(i8, -5));
    std.mem.writeInt(i16, ram[0x3002..][0..2], -300, .little);

    // Populate PC-relative literal pool on the same code page at 0x1100
    std.mem.writeInt(u64, ram[0x1100..][0..8], 0x11223344_55667788, .little);
    std.mem.writeInt(i32, ram[0x1108..][0..4], -42, .little);
    std.mem.writeInt(u128, ram[0x1110..][0..16], 0xaabbccdd_eeff0011_22334455_66778899, .little);

    // 0x1000: ldrsb x1, [x0]                (0x39800001) -> x1 = -5 (64-bit)
    // 0x1004: ldrsh w2, [x0, #2]            (0x79c00402) -> x2 = @as(u32, @bitCast(@as(i32, -300)))
    // 0x1008: ldr x3, 0x1100 (+0xf8)        (0x580007c3) -> x3 = 0x11223344_55667788
    // 0x100c: ldrsw x4, 0x1108 (+0xfc)      (0x980007e4) -> x4 = -42 (64-bit)
    // 0x1010: ldr q0, 0x1110 (+0x100)       (0x9c000800) -> v0 = 0xaabbccdd_eeff0011_22334455_66778899
    // 0x1014: movz x5, #100                 (0xd2800c85) -> x5 = 100
    // 0x1018: movz x6, #25                  (0xd2800326) -> x6 = 25
    // 0x101c: udiv x7, x5, x6               (0x9ac608a7) -> x7 = 4
    // 0x1020: sdiv w8, w4, w7               (0x1ac70c88) -> w8 = -42 / 4 = -10
    // 0x1024: add x9, x5, x6, lsr #2        (0x8b4608a9) -> x9 = 100 + (25 >> 2) = 106
    // 0x1028: subs xzr, x5, w6, uxtw #2     (0xeb2648bf) -> 100 - 100 == 0 -> Z=1, C=1
    // 0x102c: ccmp x5, #25, #0, eq          (0xfa5908a0) -> cond EQ true -> 100 - 25 > 0 -> Z=0, C=1
    // 0x1030: smaddl x10, w4, w6, x5        (0x9b26148a) -> x10 = 100 + (-42 * 25) = -950
    // 0x1034: wfi                           (0xd503207f)
    const prog = [_]u32{
        0x39800001,
        0x79c00402,
        0x580007c3,
        0x980007e4,
        0x9c000800,
        0xd2800c85,
        0xd2800326,
        0x9ac608a7,
        0x1ac70c88,
        0x8b4608a9,
        0xeb2648bf,
        0xfa5908a0,
        0x9b26148a,
        0xd503207f,
    };
    for (prog, 0..) |inst, i| {
        std.mem.writeInt(u32, ram[0x1000 + i * 4 ..][0..4], inst, .little);
    }

    const SlotType = @TypeOf(cpu.icache[0]);
    try std.testing.expectEqual(Exec.A64Op.ldrsb64_uimm, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[0]).op)));
    try std.testing.expectEqual(Exec.A64Op.ldrsh32_uimm, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[1]).op)));
    try std.testing.expectEqual(Exec.A64Op.ldr_lit64, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[2]).op)));
    try std.testing.expectEqual(Exec.A64Op.ldrsw_lit, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[3]).op)));
    try std.testing.expectEqual(Exec.A64Op.ldr_fp128_lit, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[4]).op)));
    try std.testing.expectEqual(Exec.A64Op.udiv64, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[7]).op)));
    try std.testing.expectEqual(Exec.A64Op.sdiv32, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[8]).op)));
    try std.testing.expectEqual(Exec.A64Op.dp_shift_reg, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[9]).op)));
    try std.testing.expectEqual(Exec.A64Op.add_sub_ext, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[10]).op)));
    try std.testing.expectEqual(Exec.A64Op.ccmp, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[11]).op)));
    try std.testing.expectEqual(Exec.A64Op.maddl_mulh, @as(Exec.A64Op, @enumFromInt(Exec.decodeA64(SlotType, prog[12]).op)));

    _ = cpu.runSteps(&bus, 32);
    try std.testing.expectEqual(@as(i64, -5), @as(i64, @bitCast(cpu.x[1])));
    try std.testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(i32, -300)))), cpu.x[2]);
    try std.testing.expectEqual(@as(u64, 0x11223344_55667788), cpu.x[3]);
    try std.testing.expectEqual(@as(i64, -42), @as(i64, @bitCast(cpu.x[4])));
    try std.testing.expectEqual(@as(u128, 0xaabbccdd_eeff0011_22334455_66778899), cpu.vfp.v[0]);
    try std.testing.expectEqual(@as(u64, 4), cpu.x[7]);
    try std.testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(i32, -10)))), cpu.x[8]);
    try std.testing.expectEqual(@as(u64, 106), cpu.x[9]);
    try std.testing.expectEqual(@as(u4, 0b0010), @as(u4, @truncate(cpu.cpsr >> 28)));
    try std.testing.expectEqual(@as(i64, -950), @as(i64, @bitCast(cpu.x[10])));
}

test "AArch64 superinstruction fusion (ADRP+ADD, ADRP+LDR, STP+MOV FP, CMP+B.cond)" {
    const arm1176 = @import("arm1176.zig");
    const TestBus = struct {
        ram: []u8,
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

    const allocator = std.testing.allocator;
    const ram = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(ram);
    @memset(ram, 0);

    var bus: TestBus = .{ .ram = ram };
    const Cpu = arm1176.Arm1176(TestBus);
    var cpu: Cpu = .{};
    cpu.initReset64(0x1000, 0);
    cpu.sp_el[2] = 0x4000;
    cpu.x[29] = 0xdead_beef;
    cpu.x[30] = 0xcafe_babe;

    std.mem.writeInt(u64, ram[0x2040..][0..8], 42, .little);
    std.mem.writeInt(u32, ram[0x2048..][0..4], 42, .little);

    // 0x1000: stp x29, x30, [sp, #-16]!  (0xa9bf7bfd)
    // 0x1004: mov x29, sp                (0x910003fd) -> fused with stp
    // 0x1008: adrp x0, 0x2000            (0xb0000000)
    // 0x100c: add x0, x0, #0x40          (0x91010000) -> fused adrp_add: x0 = 0x2040
    // 0x1010: adrp x1, 0x2000            (0xb0000001)
    // 0x1014: ldr x2, [x1, #0x40]        (0xf9402022) -> fused adrp_ldr64: x1 = 0x2000, x2 = 42
    // 0x1018: adrp x3, 0x2000            (0xb0000003)
    // 0x101c: ldr w4, [x3, #0x48]        (0xb9404864) -> fused adrp_ldr32: x3 = 0x2000, w4 = 42
    // 0x1020: cmp x2, #42                (0xf100a85f)
    // 0x1024: b.eq 0x102c (+8)           (0x54000040) -> fused cmp_imm_bcond (taken)
    // 0x1028: movz x5, #99               (0xd2800c65) -> skipped
    // 0x102c: cmp x2, x4                 (0xeb04005f)
    // 0x1030: b.ne 0x1038 (+8)           (0x54000041) -> fused cmp_reg_bcond (not taken)
    // 0x1034: movz x5, #77               (0xd28009a5) -> executed: x5 = 77
    // 0x1038: wfi                        (0xd503207f)
    const prog = [_]u32{
        0xa9bf7bfd,
        0x910003fd,
        0xb0000000,
        0x91010000,
        0xb0000001,
        0xf9402022,
        0xb0000003,
        0xb9404864,
        0xf100a85f,
        0x54000040,
        0xd2800c65,
        0xeb04005f,
        0x54000041,
        0xd28009a5,
        0xd503207f,
    };
    for (prog, 0..) |inst, i| {
        std.mem.writeInt(u32, ram[0x1000 + i * 4 ..][0..4], inst, .little);
    }

    const ran = cpu.runSteps(&bus, 64);
    try std.testing.expectEqual(@as(usize, 14), ran);
    try std.testing.expectEqual(@as(u64, 0x3ff0), cpu.sp_el[2]);
    try std.testing.expectEqual(@as(u64, 0x3ff0), cpu.x[29]);
    try std.testing.expectEqual(@as(u64, 0x2040), cpu.x[0]);
    try std.testing.expectEqual(@as(u64, 0x2000), cpu.x[1]);
    try std.testing.expectEqual(@as(u64, 42), cpu.x[2]);
    try std.testing.expectEqual(@as(u64, 0x2000), cpu.x[3]);
    try std.testing.expectEqual(@as(u64, 42), cpu.x[4]);
    try std.testing.expectEqual(@as(u64, 77), cpu.x[5]);

    // Enable 1:1 MMU identity mapping at EL2 or populate SoftTLB64 for VA 0x1000 -> PA 0x1000
    cpu.mmu.populateSoftTlb64(ram.len, 0x1000, 0x1000, mmu_mod.Mmu.perm_priv_r | mmu_mod.Mmu.perm_priv_x, true);
    cpu.mmu.halted_wfi = false;
    cpu.pc64 = 0x1034;
    _ = cpu.runSteps(&bus, 16);
    const page_idx: usize = ((0x1000 >> 12) ^ (0x1000 >> 16) ^ (0x1000 >> 20)) & (arm1176.icache_pages - 1);
    try std.testing.expectEqual(@as(u32, 0x1000), cpu.icache_page_tags[page_idx]);

    // Overwrite 0x1034 with `movz x5, #123` (0xd2800f65) and issue `ic iallu` + `isb` before branching back
    std.mem.writeInt(u32, ram[0x1034..][0..4], 0xd2800f65, .little);
    std.mem.writeInt(u32, ram[0x103c..][0..4], 0xd508751f, .little); // ic iallu
    std.mem.writeInt(u32, ram[0x1040..][0..4], 0xd5033fdf, .little); // isb
    std.mem.writeInt(u32, ram[0x1044..][0..4], 0x17fffffc, .little); // b 0x1034 (-16)
    cpu.mmu.halted_wfi = false;
    cpu.pc64 = 0x103c;
    _ = cpu.runSteps(&bus, 16);
    try std.testing.expectEqual(@as(u64, 123), cpu.x[5]);

    // Verify hot backward-branch loop triggers baseline x86-64 JIT compilation (.jit_trace)
    // 0x1100: add x10, x10, #3       (0x91000d4a)
    // 0x1104: sub x11, x11, #1       (0xd100056b)
    // 0x1108: cbnz x11, 0x1100 (-8)  (0xb5ffffcb)
    // 0x110c: wfi                    (0xd503207f)
    const jit_loop = [_]u32{
        0x91000d4a,
        0xd100056b,
        0xb5ffffcb,
        0xd503207f,
    };
    for (jit_loop, 0..) |inst, i| {
        std.mem.writeInt(u32, ram[0x1100 + i * 4 ..][0..4], inst, .little);
    }
    cpu.invalidateIcache();
    cpu.mmu.halted_wfi = false;
    cpu.pc64 = 0x1100;
    cpu.x[10] = 0;
    cpu.x[11] = 100;
    const jit_ran = cpu.runSteps(&bus, 500);
    try std.testing.expectEqual(@as(usize, 301), jit_ran);
    try std.testing.expectEqual(@as(u64, 300), cpu.x[10]);
    try std.testing.expectEqual(@as(u64, 0), cpu.x[11]);
    if (jit_mod.is_x86_64_linux) {
        const Exec = Aarch64Exec(Cpu, TestBus);
        try std.testing.expectEqual(Exec.A64Op.jit_trace, @as(Exec.A64Op, @enumFromInt(cpu.icache[page_idx * 1024 + ((0x1100 & 0xfff) >> 2)].op)));
    }
}

