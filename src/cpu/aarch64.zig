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

pub fn evalCond(pstate: u32, cond: u4) bool {
    const n = (pstate & PstateFlags.N) != 0;
    const z = (pstate & PstateFlags.Z) != 0;
    const c = (pstate & PstateFlags.C) != 0;
    const v = (pstate & PstateFlags.V) != 0;
    return switch (cond) {
        0x0 => z, // EQ
        0x1 => !z, // NE
        0x2 => c, // CS / HS
        0x3 => !c, // CC / LO
        0x4 => n, // MI
        0x5 => !n, // PL
        0x6 => v, // VS
        0x7 => !v, // VC
        0x8 => c and !z, // HI
        0x9 => !c or z, // LS
        0xa => n == v, // GE
        0xb => n != v, // LT
        0xc => !z and (n == v), // GT
        0xd => z or (n != v), // LE
        0xe, 0xf => true, // AL / NV
    };
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
            return if (reg == 31) 0 else cpu.x[reg];
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
            return if (reg == 31) 0 else @truncate(cpu.x[reg]);
        }

        pub inline fn setW(cpu: *CpuType, reg: u5, val: u32) void {
            if (reg != 31) cpu.x[reg] = @as(u64, val);
        }

        pub inline fn setWOrSp(cpu: *CpuType, reg: u5, val: u32) void {
            if (reg == 31) setSp(cpu, @as(u64, val)) else cpu.x[reg] = @as(u64, val);
        }

        pub inline fn setNzcv(cpu: *CpuType, n: bool, z: bool, c: bool, v: bool) void {
            var flags: u32 = 0;
            if (n) flags |= PstateFlags.N;
            if (z) flags |= PstateFlags.Z;
            if (c) flags |= PstateFlags.C;
            if (v) flags |= PstateFlags.V;
            cpu.pstate = (cpu.pstate & 0x0fff_ffff) | flags;
        }

        pub fn takeException64(
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
            cpu.invalidateInlineTlb();
        }

        pub fn readData8(cpu: *CpuType, bus: *Bus, vaddr: u64) error{Abort}!u8 {
            const vbase = vaddr & ~@as(u64, 0xfff);
            if (vbase == cpu.dtlb64_r_vbase) {
                return bus.ram[cpu.dtlb_r_pbase | @as(u32, @truncate(vaddr & 0xfff))];
            }
            const paddr = try cpu.mmu.translate64(bus.ram, vaddr, .read, isPrivileged64(cpu));
            if (paddr < bus.ram.len) {
                cpu.dtlb64_r_vbase = vbase;
                cpu.dtlb_r_pbase = paddr & 0xffff_f000;
                return bus.ram[paddr];
            }
            return bus.read8(paddr);
        }

        pub fn readData16(cpu: *CpuType, bus: *Bus, vaddr: u64) error{Abort}!u16 {
            if ((vaddr & 0xfff) <= 0xffe) {
                const vbase = vaddr & ~@as(u64, 0xfff);
                if (vbase == cpu.dtlb64_r_vbase) {
                    const paddr = cpu.dtlb_r_pbase | @as(u32, @truncate(vaddr & 0xfff));
                    return std.mem.readInt(u16, bus.ram[paddr..][0..2], .little);
                }
                const paddr = try cpu.mmu.translate64(bus.ram, vaddr, .read, isPrivileged64(cpu));
                if (paddr + 2 <= bus.ram.len) {
                    cpu.dtlb64_r_vbase = vbase;
                    cpu.dtlb_r_pbase = paddr & 0xffff_f000;
                    return std.mem.readInt(u16, bus.ram[paddr..][0..2], .little);
                }
                return bus.read16(paddr);
            }
            const b0: u16 = try readData8(cpu, bus, vaddr);
            const b1: u16 = try readData8(cpu, bus, vaddr +% 1);
            return b0 | (b1 << 8);
        }

        pub fn readData32(cpu: *CpuType, bus: *Bus, vaddr: u64) error{Abort}!u32 {
            if ((vaddr & 0xfff) <= 0xffc) {
                const vbase = vaddr & ~@as(u64, 0xfff);
                if (vbase == cpu.dtlb64_r_vbase) {
                    const paddr = cpu.dtlb_r_pbase | @as(u32, @truncate(vaddr & 0xfff));
                    return std.mem.readInt(u32, bus.ram[paddr..][0..4], .little);
                }
                const paddr = try cpu.mmu.translate64(bus.ram, vaddr, .read, isPrivileged64(cpu));
                if (paddr + 4 <= bus.ram.len) {
                    cpu.dtlb64_r_vbase = vbase;
                    cpu.dtlb_r_pbase = paddr & 0xffff_f000;
                    return std.mem.readInt(u32, bus.ram[paddr..][0..4], .little);
                }
                return bus.read32(paddr);
            }
            const lo: u32 = try readData16(cpu, bus, vaddr);
            const hi: u32 = try readData16(cpu, bus, vaddr +% 2);
            return lo | (hi << 16);
        }

        pub fn readData64(cpu: *CpuType, bus: *Bus, vaddr: u64) error{Abort}!u64 {
            if ((vaddr & 0xfff) <= 0xff8) {
                const vbase = vaddr & ~@as(u64, 0xfff);
                if (vbase == cpu.dtlb64_r_vbase) {
                    const paddr = cpu.dtlb_r_pbase | @as(u32, @truncate(vaddr & 0xfff));
                    return std.mem.readInt(u64, bus.ram[paddr..][0..8], .little);
                }
                const paddr = try cpu.mmu.translate64(bus.ram, vaddr, .read, isPrivileged64(cpu));
                if (paddr + 8 <= bus.ram.len) {
                    cpu.dtlb64_r_vbase = vbase;
                    cpu.dtlb_r_pbase = paddr & 0xffff_f000;
                    return std.mem.readInt(u64, bus.ram[paddr..][0..8], .little);
                }
            }
            const lo: u64 = try readData32(cpu, bus, vaddr);
            const hi: u64 = try readData32(cpu, bus, vaddr +% 4);
            return lo | (hi << 32);
        }

        pub fn writeData8(cpu: *CpuType, bus: *Bus, vaddr: u64, val: u8) error{Abort}!void {
            const vbase = vaddr & ~@as(u64, 0xfff);
            if (vbase == cpu.dtlb64_w_vbase) {
                bus.ram[cpu.dtlb_w_pbase | @as(u32, @truncate(vaddr & 0xfff))] = val;
                return;
            }
            const paddr = try cpu.mmu.translate64(bus.ram, vaddr, .write, isPrivileged64(cpu));
            if (paddr < bus.ram.len) {
                cpu.dtlb64_w_vbase = vbase;
                cpu.dtlb_w_pbase = paddr & 0xffff_f000;
                bus.ram[paddr] = val;
                return;
            }
            bus.write8(paddr, val);
        }

        pub fn writeData16(cpu: *CpuType, bus: *Bus, vaddr: u64, val: u16) error{Abort}!void {
            if ((vaddr & 0xfff) <= 0xffe) {
                const vbase = vaddr & ~@as(u64, 0xfff);
                if (vbase == cpu.dtlb64_w_vbase) {
                    const paddr = cpu.dtlb_w_pbase | @as(u32, @truncate(vaddr & 0xfff));
                    std.mem.writeInt(u16, bus.ram[paddr..][0..2], val, .little);
                    return;
                }
                const paddr = try cpu.mmu.translate64(bus.ram, vaddr, .write, isPrivileged64(cpu));
                if (paddr + 2 <= bus.ram.len) {
                    cpu.dtlb64_w_vbase = vbase;
                    cpu.dtlb_w_pbase = paddr & 0xffff_f000;
                    std.mem.writeInt(u16, bus.ram[paddr..][0..2], val, .little);
                    return;
                }
                bus.write16(paddr, val);
                return;
            }
            try writeData8(cpu, bus, vaddr, @truncate(val));
            try writeData8(cpu, bus, vaddr +% 1, @truncate(val >> 8));
        }

        pub fn writeData32(cpu: *CpuType, bus: *Bus, vaddr: u64, val: u32) error{Abort}!void {
            if ((vaddr & 0xfff) <= 0xffc) {
                const vbase = vaddr & ~@as(u64, 0xfff);
                if (vbase == cpu.dtlb64_w_vbase) {
                    const paddr = cpu.dtlb_w_pbase | @as(u32, @truncate(vaddr & 0xfff));
                    std.mem.writeInt(u32, bus.ram[paddr..][0..4], val, .little);
                    return;
                }
                const paddr = try cpu.mmu.translate64(bus.ram, vaddr, .write, isPrivileged64(cpu));
                if (paddr + 4 <= bus.ram.len) {
                    cpu.dtlb64_w_vbase = vbase;
                    cpu.dtlb_w_pbase = paddr & 0xffff_f000;
                    std.mem.writeInt(u32, bus.ram[paddr..][0..4], val, .little);
                    return;
                }
                bus.write32(paddr, val);
                return;
            }
            try writeData16(cpu, bus, vaddr, @truncate(val));
            try writeData16(cpu, bus, vaddr +% 2, @truncate(val >> 16));
        }

        pub fn writeData64(cpu: *CpuType, bus: *Bus, vaddr: u64, val: u64) error{Abort}!void {
            if ((vaddr & 0xfff) <= 0xff8) {
                const vbase = vaddr & ~@as(u64, 0xfff);
                if (vbase == cpu.dtlb64_w_vbase) {
                    const paddr = cpu.dtlb_w_pbase | @as(u32, @truncate(vaddr & 0xfff));
                    std.mem.writeInt(u64, bus.ram[paddr..][0..8], val, .little);
                    return;
                }
                const paddr = try cpu.mmu.translate64(bus.ram, vaddr, .write, isPrivileged64(cpu));
                if (paddr + 8 <= bus.ram.len) {
                    cpu.dtlb64_w_vbase = vbase;
                    cpu.dtlb_w_pbase = paddr & 0xffff_f000;
                    std.mem.writeInt(u64, bus.ram[paddr..][0..8], val, .little);
                    return;
                }
            }
            try writeData32(cpu, bus, vaddr, @truncate(val));
            try writeData32(cpu, bus, vaddr +% 4, @truncate(val >> 32));
        }

        pub fn fetchInst64(cpu: *CpuType, bus: *Bus, pc: u64) error{Abort}!u32 {
            const vbase = pc & ~@as(u64, 0xfff);
            if (vbase == cpu.itlb64_vbase) {
                const paddr = cpu.itlb_pbase | @as(u32, @truncate(pc & 0xffc));
                return std.mem.readInt(u32, bus.ram[paddr..][0..4], .little);
            }
            const paddr = try cpu.mmu.translate64(bus.ram, pc, .fetch, isPrivileged64(cpu));
            if (paddr + 4 <= bus.ram.len) {
                cpu.itlb64_vbase = vbase;
                cpu.itlb_pbase = paddr & 0xffff_f000;
                return std.mem.readInt(u32, bus.ram[paddr..][0..4], .little);
            }
            return bus.read32(paddr);
        }

        pub fn checkInterrupts64(cpu: *CpuType, bus: *const Bus) bool {
            const cid = cpu.mmu.core_id;
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
            return false;
        }

        pub fn step64(cpu: *CpuType, bus: *Bus) void {
            if (checkInterrupts64(cpu, bus)) return;
            if (cpu.mmu.halted_wfi) return;

            const cur_pc = cpu.pc64;
            const inst = fetchInst64(cpu, bus, cur_pc) catch {
                const target_el: u2 = @max(currentEl(cpu), 1);
                takeException64(cpu, target_el, 0x000, cpu.mmu.esr_el1, cur_pc, cur_pc);
                return;
            };

            cpu.last_inst = inst;
            cpu.pc64 = cur_pc +% 4;
            cpu.cycles +%= 1;
            cpu.mmu.pmccntr +%= 1;

            executeInst64(cpu, bus, inst, cur_pc) catch {
                const target_el: u2 = @max(currentEl(cpu), 1);
                takeException64(cpu, target_el, 0x000, cpu.mmu.esr_el1, cpu.mmu.far_el1, cur_pc);
            };
            cpu.r[15] = @truncate(cpu.pc64);
            cpu.cpsr = cpu.pstate;
        }

        fn executeInst64(cpu: *CpuType, bus: *Bus, inst: u32, cur_pc: u64) error{Abort}!void {
            const op0: u4 = @truncate(inst >> 25);
            switch (op0) {
                0b1000, 0b1001 => executeDpImm(cpu, inst, cur_pc),
                0b1010, 0b1011 => try executeBranchSys(cpu, bus, inst, cur_pc),
                0b0100, 0b0110, 0b1100, 0b1110 => try executeLoadStore(cpu, bus, inst, cur_pc),
                0b0101, 0b1101 => executeDpReg(cpu, inst),
                0b0111, 0b1111 => executeFpSimd(cpu, inst),
                else => {},
            }
        }

        fn executeDpImm(cpu: *CpuType, inst: u32, cur_pc: u64) void {
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

        fn addSub(
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

        fn executeBranchSys(cpu: *CpuType, bus: *Bus, inst: u32, cur_pc: u64) error{Abort}!void {
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
                try executeSystem(cpu, bus, inst);
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
                        cpu.invalidateInlineTlb();
                    },
                    else => {},
                }
                return;
            }
            _ = op0;
            _ = op1;
        }

        fn executeSystem(cpu: *CpuType, bus: *Bus, inst: u32) error{Abort}!void {
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
                    const hint = (crm << 3) | op2;
                    if (hint == 1 or hint == 2) {
                        cpu.yield_slice = true;
                    } else if (hint == 3) {
                        cpu.mmu.halted_wfi = true;
                    }
                } else if (crn == 3) {
                    if (op2 == 2) cpu.excl_valid = false; // CLREX
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
                        var off: u64 = 0;
                        while (off < 64) : (off += 8) {
                            try writeData64(cpu, bus, base_va +% off, 0);
                        }
                    } else if (crn == 8) {
                        // TLBI maintenance
                        cpu.mmu.flushTlb();
                        cpu.invalidateInlineTlb();
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
            }
        }

        fn sysRegId(op0: u2, op1: u3, crn: u4, crm: u4, op2: u3) u16 {
            return (@as(u16, op0) << 14) | (@as(u16, op1) << 11) | (@as(u16, crn) << 7) | (@as(u16, crm) << 3) | @as(u16, op2);
        }

        pub fn readSysReg(cpu: *CpuType, op0: u2, op1: u3, crn: u4, crm: u4, op2: u3) u64 {
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
                sysRegId(3, 0, 0, 6, 0) => 0x0000_0000_0001_1120, // ID_AA64ISAR0_EL1 (CRC32 + AES/SHA)
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
                sysRegId(3, 3, 14, 0, 1) => cpu.mmu.cntpct, // CNTPCT_EL0
                sysRegId(3, 3, 14, 0, 2) => cpu.mmu.cntpct -% cpu.mmu.cntvoff, // CNTVCT_EL0
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

        pub fn writeSysReg(cpu: *CpuType, op0: u2, op1: u3, crn: u4, crm: u4, op2: u3, val: u64) void {
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

        fn executeLoadStore(cpu: *CpuType, bus: *Bus, inst: u32, cur_pc: u64) error{Abort}!void {
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
                                const l1: u128 = try readData64(cpu, bus, addr);
                                const h1: u128 = try readData64(cpu, bus, addr +% 8);
                                const l2: u128 = try readData64(cpu, bus, addr +% 16);
                                const h2: u128 = try readData64(cpu, bus, addr +% 24);
                                cpu.vfp.v[rt] = l1 | (h1 << 64);
                                cpu.vfp.v[rt2] = l2 | (h2 << 64);
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
                                try writeData64(cpu, bus, addr, @truncate(cpu.vfp.v[rt]));
                                try writeData64(cpu, bus, addr +% 8, @truncate(cpu.vfp.v[rt] >> 64));
                                try writeData64(cpu, bus, addr +% 16, @truncate(cpu.vfp.v[rt2]));
                                try writeData64(cpu, bus, addr +% 24, @truncate(cpu.vfp.v[rt2] >> 64));
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
                            else => {
                                const lo: u128 = try readData64(cpu, bus, addr);
                                const hi: u128 = try readData64(cpu, bus, addr +% 8);
                                cpu.vfp.v[rt] = lo | (hi << 64);
                            },
                        }
                    } else {
                        switch (scale) {
                            0 => try writeData8(cpu, bus, addr, @truncate(cpu.vfp.v[rt])),
                            1 => try writeData16(cpu, bus, addr, @truncate(cpu.vfp.v[rt])),
                            2 => try writeData32(cpu, bus, addr, @truncate(cpu.vfp.v[rt])),
                            3 => try writeData64(cpu, bus, addr, @truncate(cpu.vfp.v[rt])),
                            else => {
                                try writeData64(cpu, bus, addr, @truncate(cpu.vfp.v[rt]));
                                try writeData64(cpu, bus, addr +% 8, @truncate(cpu.vfp.v[rt] >> 64));
                            },
                        }
                    }
                }

                if (writeback_addr) |wb| {
                    setXOrSp(cpu, rn, wb);
                }
                return;
            }

            // 5. AdvSIMD Load/Store multiple/single structures (`0x0c00_0000` / `0x0d00_0000`)
            if ((inst & 0xbf00_0000) == 0x0c00_0000) {
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
                    const paddr = try cpu.mmu.translate64(bus.ram, addr, .read, isPrivileged64(cpu));
                    cpu.excl_valid = true;
                    cpu.excl_paddr = paddr & ~@as(u32, 7);
                    if (!o1) {
                        switch (size) {
                            0 => setW(cpu, rt, try readData8(cpu, bus, addr)),
                            1 => setW(cpu, rt, try readData16(cpu, bus, addr)),
                            2 => setW(cpu, rt, try readData32(cpu, bus, addr)),
                            3 => setX(cpu, rt, try readData64(cpu, bus, addr)),
                        }
                    } else {
                        if (size == 2) {
                            const v1 = try readData32(cpu, bus, addr);
                            const v2 = try readData32(cpu, bus, addr +% 4);
                            setW(cpu, rt, v1);
                            setW(cpu, rt2, v2);
                        } else {
                            const v1 = try readData64(cpu, bus, addr);
                            const v2 = try readData64(cpu, bus, addr +% 8);
                            setX(cpu, rt, v1);
                            setX(cpu, rt2, v2);
                        }
                    }
                } else {
                    const paddr = try cpu.mmu.translate64(bus.ram, addr, .write, isPrivileged64(cpu));
                    if (!cpu.excl_valid or (paddr & ~@as(u32, 7)) != cpu.excl_paddr) {
                        cpu.excl_valid = false;
                        setW(cpu, rs, 1);
                        return;
                    }
                    cpu.excl_valid = false;
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

        fn executeSimdStructLoadStore(cpu: *CpuType, bus: *Bus, inst: u32) error{Abort}!void {
            const q = ((inst >> 30) & 1) != 0;
            const is_post = ((inst >> 23) & 1) != 0;
            const is_load = ((inst >> 22) & 1) != 0;
            const rm: u5 = @truncate(inst >> 16);
            const opcode: u4 = @truncate(inst >> 12);
            const rn: u5 = @truncate(inst >> 5);
            const rt: u5 = @truncate(inst);

            const regs: u5 = switch (opcode) {
                0b0111 => 1, // LD1/ST1 (1 reg)
                0b1010 => 2, // LD1/ST1 (2 regs)
                0b0110 => 3, // LD1/ST1 (3 regs)
                0b0010, 0b0000 => 4, // LD1/ST1 (4 regs) or LD4/ST4
                0b1000 => 2, // LD2/ST2
                0b0100 => 3, // LD3/ST3
                else => 1,
            };
            const bytes_per_reg: u64 = if (q) 16 else 8;
            var addr = getXOrSp(cpu, rn);

            var r_idx: u5 = 0;
            while (r_idx < regs) : (r_idx += 1) {
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

        fn executeDpReg(cpu: *CpuType, inst: u32) void {
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
                    // Data-processing (2-source): UDIV (2), SDIV (3), LSLV (8), LSRV (9), ASRV (10), RORV (11)
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

        fn executeFpSimd(cpu: *CpuType, inst: u32) void {
            const rd: u5 = @truncate(inst);
            const rn: u5 = @truncate(inst >> 5);
            const rm: u5 = @truncate(inst >> 16);

            // 1. Scalar FP <-> GPR conversions & FMOV (`(inst & 0x5f20_0000) == 0x1e20_0000`)
            if ((inst & 0x5f20_0000) == 0x1e20_0000) {
                const sf = ((inst >> 31) & 1) != 0;
                const ftype: u2 = @truncate(inst >> 22);
                const is_dbl = (ftype == 1);

                if ((inst & 0x0000_fc00) == 0x0000_0000 and ((inst >> 21) & 1) == 1) {
                    // Conversion between FP and Int (`SCVTF`, `UCVTF`, `FCVTZS`, `FCVTZU`, `FMOV` GPR<->FP)
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
                    if (opcode == 0b000 or opcode == 0b001) { // FCVTZS / FCVTZU
                        const fv: f64 = if (is_dbl) @bitCast(@as(u64, @truncate(cpu.vfp.v[rn]))) else @as(f64, @as(f32, @bitCast(@as(u32, @truncate(cpu.vfp.v[rn])))));
                        if (std.math.isNan(fv)) {
                            if (sf) setX(cpu, rd, 0) else setW(cpu, rd, 0);
                        } else if (opcode == 0b000) {
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

                // Scalar FP 2-source (`FMUL`, `FDIV`, `FADD`, `FSUB`)
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
                            else => a,
                        };
                        cpu.vfp.v[rd] = @as(u32, @bitCast(res));
                    }
                    return;
                }

                // Scalar FP 1-source (`FMOV`, `FABS`, `FNEG`, `FSQRT`, `FCVT`)
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
                            else => {},
                        }
                    }
                    return;
                }

                // Scalar FP compare (`FCMP`, `FCMPE`)
                if ((inst & 0xffa0_fc10) == 0x1e20_2000) {
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
            }

            // 2. AdvSIMD modified immediate (`MOVI`, `MVNI`, `ORR`, `BIC`) (`(inst & 0x9f80_0400) == 0x0f00_0400`)
            if ((inst & 0x9f80_0400) == 0x0f00_0400) {
                const q = ((inst >> 30) & 1) != 0;
                const op = ((inst >> 29) & 1) != 0;
                const cmode: u4 = @truncate(inst >> 12);
                const abc: u8 = @truncate((inst >> 16) & 7);
                const defgh: u8 = @truncate((inst >> 5) & 0x1f);
                const imm8: u8 = (abc << 5) | defgh;

                var val64: u64 = 0;
                if (cmode == 0b1110 and !op) {
                    val64 = @as(u64, imm8) * 0x0101_0101_0101_0101;
                } else if (cmode == 0b1110 and op) {
                    var i: u6 = 0;
                    while (i < 8) : (i += 1) {
                        if (((imm8 >> @intCast(i)) & 1) != 0) {
                            val64 |= @as(u64, 0xff) << (i * 8);
                        }
                    }
                } else {
                    const byte_val: u64 = if (op) ~@as(u64, imm8) & 0xff else imm8;
                    const sh: u5 = @intCast(((cmode >> 1) & 3) * 8);
                    const elem32: u64 = (byte_val << sh) & 0xffff_ffff;
                    val64 = elem32 | (elem32 << 32);
                }
                cpu.vfp.v[rd] = if (q) (@as(u128, val64) | (@as(u128, val64) << 64)) else @as(u128, val64);
                return;
            }

            // 3. AdvSIMD copy (`DUP`, `INS`, `UMOV`, `SMOV`) (`(inst & 0x9fe0_0400) == 0x0e00_0400`)
            if ((inst & 0x9fe0_0400) == 0x0e00_0400) {
                const q = ((inst >> 30) & 1) != 0;
                const imm5: u5 = @truncate(inst >> 16);
                const imm4: u4 = @truncate(inst >> 11);
                const tz = @ctz(@as(u6, imm5));
                const esize_bytes: u5 = if (tz >= 4) 8 else (@as(u5, 1) << @intCast(tz));
                const src_idx: u5 = imm5 >> @intCast(tz + 1);

                if (imm4 == 0b0001) {
                    // DUP (general): replicate GPR X[rn] across vector
                    const gval = getX(cpu, rn);
                    var rep64: u64 = switch (esize_bytes) {
                        1 => (@as(u64, @as(u8, @truncate(gval))) * 0x0101_0101_0101_0101),
                        2 => (@as(u64, @as(u16, @truncate(gval))) * 0x0001_0001_0001_0001),
                        4 => (@as(u64, @as(u32, @truncate(gval))) * 0x0000_0001_0000_0001),
                        else => gval,
                    };
                    _ = &rep64;
                    cpu.vfp.v[rd] = if (q) (@as(u128, rep64) | (@as(u128, rep64) << 64)) else @as(u128, rep64);
                } else if (imm4 == 0b0111) {
                    // UMOV (vector element -> GPR)
                    const shift_bits: u7 = @as(u7, src_idx) * (@as(u7, esize_bytes) * 8);
                    const elem: u64 = @truncate(cpu.vfp.v[rn] >> shift_bits);
                    switch (esize_bytes) {
                        1 => setW(cpu, rd, @as(u8, @truncate(elem))),
                        2 => setW(cpu, rd, @as(u16, @truncate(elem))),
                        4 => setW(cpu, rd, @as(u32, @truncate(elem))),
                        else => setX(cpu, rd, elem),
                    }
                } else if (imm4 == 0b0011) {
                    // INS (general -> vector element)
                    const shift_bits: u7 = @as(u7, src_idx) * (@as(u7, esize_bytes) * 8);
                    const width_bits: u7 = @as(u7, esize_bytes) * 8;
                    const mask128: u128 = if (width_bits >= 64) (@as(u128, 0xffff_ffff_ffff_ffff) << shift_bits) else (((@as(u128, 1) << width_bits) - 1) << shift_bits);
                    const gval: u128 = getX(cpu, rn);
                    cpu.vfp.v[rd] = (cpu.vfp.v[rd] & ~mask128) | ((gval << shift_bits) & mask128);
                }
                return;
            }

            // 4. AdvSIMD three same (`AND`, `BIC`, `ORR`, `ORN`, `EOR`, `ADD`, `SUB`, `CMEQ`, `CMHI`, `UMIN`, `UMAX`) (`(inst & 0x9f20_0400) == 0x0e20_0400`)
            if ((inst & 0x9f20_0400) == 0x0e20_0400) {
                const q = ((inst >> 30) & 1) != 0;
                const u = ((inst >> 29) & 1) != 0;
                const size: u2 = @truncate(inst >> 22);
                const opcode: u5 = @truncate(inst >> 11);
                const mask: u128 = if (q) ~@as(u128, 0) else 0xffff_ffff_ffff_ffff;
                const va = cpu.vfp.v[rn];
                const vb = cpu.vfp.v[rm];

                if (opcode == 0b00011) {
                    // Bitwise logical: AND (u=0, size=0), BIC (u=0, size=1), ORR/MOV (u=0, size=2), ORN (u=0, size=3), EOR (u=1, size=0), BSL (u=1, size=1)
                    const res: u128 = if (!u) switch (size) {
                        0 => va & vb,
                        1 => va & ~vb,
                        2 => va | vb,
                        3 => va | ~vb,
                    } else switch (size) {
                        0 => va ^ vb,
                        1 => (vb & cpu.vfp.v[rd]) | (va & ~cpu.vfp.v[rd]), // BSL
                        else => va ^ vb,
                    };
                    cpu.vfp.v[rd] = res & mask;
                } else if (opcode == 0b10001 and size == 0) {
                    // CMEQ / CMTST (byte-wise compare used heavily in glibc strlen/memchr/strcmp!)
                    var out: u128 = 0;
                    const count: usize = if (q) 16 else 8;
                    for (0..count) |i| {
                        const sh: u7 = @intCast(i * 8);
                        const ba: u8 = @truncate(va >> sh);
                        const bb: u8 = @truncate(vb >> sh);
                        const match = if (u) (ba == bb) else ((ba & bb) != 0);
                        if (match) out |= (@as(u128, 0xff) << sh);
                    }
                    cpu.vfp.v[rd] = out & mask;
                }
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
}

