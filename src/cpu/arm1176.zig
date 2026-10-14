//! ARM1176JZF-S Processor Core Emulator (ARMv6K + Thumb + VFPv2 + CP15 MMU).
//!
//! Designed for high-speed execution of the Linux 6.12 ARMv6 kernel and
//! userland applications:
//! - Flat active register file `r[0..15]` with mode-banked `r8..r14` and `SPSR`
//! - Inline Instruction TLB caching the current 4 KB code page pointer for
//!   zero-overhead instruction fetches within basic blocks
//! - Base-restored Data Abort semantics for Linux demand paging and COW (`fork`)
//! - Immediate `WFI` detection to fast-forward idle time to the next timer/IO IRQ.

const std = @import("std");
const mmu_mod = @import("mmu.zig");
const vfp_mod = @import("vfp.zig");
const dec = @import("decoder.zig");

pub const Mmu = mmu_mod.Mmu;
pub const Vfp = vfp_mod.Vfp;
pub const PsrFlags = dec.PsrFlags;

pub const Mode = enum(u5) {
    usr = 0b10000,
    fiq = 0b10001,
    irq = 0b10010,
    svc = 0b10011,
    abt = 0b10111,
    und = 0b11011,
    sys = 0b11111,

    pub inline fn isPrivileged(self: Mode) bool {
        return self != .usr;
    }
};

pub fn Arm1176(comptime Bus: type) type {
    return struct {
        const Self = @This();

        /// Active general-purpose registers r0..r15 (r13=SP, r14=LR, r15=PC)
        r: [16]u32 = @splat(0),
        /// Current Program Status Register
        cpsr: u32 = PsrFlags.I | PsrFlags.F | @intFromEnum(Mode.svc),

        /// Banked R8..R12 forUsr/Sys vs FIQ
        usr_r8_12: [5]u32 = @splat(0),
        fiq_r8_12: [5]u32 = @splat(0),

        /// Banked R13 (SP) and R14 (LR) per mode
        bank_r13: [6]u32 = @splat(0), // 0=usr/sys, 1=fiq, 2=irq, 3=svc, 4=abt, 5=und
        bank_r14: [6]u32 = @splat(0),
        /// Saved Program Status Register per exception mode
        bank_spsr: [6]u32 = @splat(0),

        /// CP15 MMU & System Control Coprocessor
        mmu: Mmu = .{},
        /// CP10/CP11 VFPv2 Floating-Point Coprocessor
        vfp: Vfp = .{},

        /// Exclusive monitor state (`LDREX` / `STREX` / `CLREX`)
        excl_valid: bool = false,
        excl_paddr: u32 = 0,

        /// Total executed instructions
        cycles: u64 = 0,
        last_inst: u32 = 0,

        /// Inline I-TLB cache for fast instruction fetches within the same 4 KB page
        itlb_vpn: u32 = 0xffff_ffff,
        itlb_ppn: u32 = 0,
        itlb_cpsr_priv: bool = true,
        itlb_mmu_gen: u32 = 0,

        pub fn initReset(self: *Self, entry_pc: u32, r0: u32, r1: u32, r2: u32) void {
            self.* = .{};
            self.r[0] = r0;
            self.r[1] = r1;
            self.r[2] = r2;
            self.r[15] = entry_pc;
            self.cpsr = PsrFlags.I | PsrFlags.F | @intFromEnum(Mode.svc);
        }

        pub inline fn mode(self: *const Self) Mode {
            return switch (@as(u5, @truncate(self.cpsr & 0x1f))) {
                0b10000 => .usr,
                0b10001 => .fiq,
                0b10010 => .irq,
                0b10011 => .svc,
                0b10111 => .abt,
                0b11011 => .und,
                0b11111 => .sys,
                else => .svc,
            };
        }

        pub inline fn isPrivileged(self: *const Self) bool {
            return (self.cpsr & 0x1f) != 0b10000;
        }

        pub inline fn isThumb(self: *const Self) bool {
            return (self.cpsr & PsrFlags.T) != 0;
        }

        fn bankIndex(m: u5) usize {
            return switch (m) {
                0b10000, 0b11111 => 0, // usr / sys
                0b10001 => 1, // fiq
                0b10010 => 2, // irq
                0b10011 => 3, // svc
                0b10111 => 4, // abt
                0b11011 => 5, // und
                else => 3,
            };
        }

        pub fn getSpsr(self: *const Self) u32 {
            const idx = bankIndex(@truncate(self.cpsr & 0x1f));
            return if (idx == 0) self.cpsr else self.bank_spsr[idx];
        }

        pub fn setSpsr(self: *Self, val: u32) void {
            const idx = bankIndex(@truncate(self.cpsr & 0x1f));
            if (idx != 0) self.bank_spsr[idx] = val;
        }

        /// Changes processor mode, swapping banked `r8..r14` registers.
        pub fn switchMode(self: *Self, new_mode_bits: u5) void {
            const old_mode_bits: u5 = @truncate(self.cpsr & 0x1f);
            if (old_mode_bits == new_mode_bits) return;

            const old_idx = bankIndex(old_mode_bits);
            const new_idx = bankIndex(new_mode_bits);

            self.bank_r13[old_idx] = self.r[13];
            self.bank_r14[old_idx] = self.r[14];
            self.r[13] = self.bank_r13[new_idx];
            self.r[14] = self.bank_r14[new_idx];

            if (old_idx == 1 and new_idx != 1) {
                @memcpy(&self.fiq_r8_12, self.r[8..13]);
                @memcpy(self.r[8..13], &self.usr_r8_12);
            } else if (old_idx != 1 and new_idx == 1) {
                @memcpy(&self.usr_r8_12, self.r[8..13]);
                @memcpy(self.r[8..13], &self.fiq_r8_12);
            }

            self.cpsr = (self.cpsr & ~@as(u32, 0x1f)) | new_mode_bits;
            self.itlb_vpn = 0xffff_ffff;
        }

        pub fn setCpsr(self: *Self, new_cpsr: u32) void {
            const new_mode: u5 = @truncate(new_cpsr & 0x1f);
            self.switchMode(new_mode);
            self.cpsr = new_cpsr;
            self.itlb_vpn = 0xffff_ffff;
        }

        fn readUserReg(self: *const Self, reg: u4) u32 {
            if (reg < 8 or reg == 15) return self.r[reg];
            const cur_idx = bankIndex(@truncate(self.cpsr & 0x1f));
            if (reg < 13) {
                return if (cur_idx == 1) self.usr_r8_12[reg - 8] else self.r[reg];
            }
            if (cur_idx == 0) return self.r[reg];
            return if (reg == 13) self.bank_r13[0] else self.bank_r14[0];
        }

        fn writeUserReg(self: *Self, reg: u4, val: u32) void {
            if (reg < 8 or reg == 15) {
                self.r[reg] = val;
                return;
            }
            const cur_idx = bankIndex(@truncate(self.cpsr & 0x1f));
            if (reg < 13) {
                if (cur_idx == 1) self.usr_r8_12[reg - 8] = val else self.r[reg] = val;
                return;
            }
            if (cur_idx == 0) {
                self.r[reg] = val;
            } else if (reg == 13) {
                self.bank_r13[0] = val;
            } else {
                self.bank_r14[0] = val;
            }
        }

        /// Enters an ARM exception vector (`UND`, `SVC`, `PABT`, `DABT`, `IRQ`, `FIQ`).
        pub fn enterException(self: *Self, target_mode: Mode, vector_offset: u32, lr_val: u32, disable_fiq: bool) void {
            const saved_cpsr = self.cpsr;
            self.switchMode(@intFromEnum(target_mode));
            self.setSpsr(saved_cpsr);
            self.r[14] = lr_val;

            // Clear T (enter ARM state), set I (disable IRQ), set A on abort/irq
            self.cpsr &= ~PsrFlags.T;
            self.cpsr |= PsrFlags.I;
            if (disable_fiq) self.cpsr |= PsrFlags.F;
            if (target_mode == .abt or target_mode == .irq or target_mode == .fiq) {
                self.cpsr |= PsrFlags.A;
            }

            const base: u32 = if (self.mmu.highVectors()) 0xffff_0000 else 0x0000_0000;
            self.r[15] = base + vector_offset;
            self.excl_valid = false;
            self.itlb_vpn = 0xffff_ffff;
        }

        pub inline fn checkInterrupts(self: *Self, bus: *const Bus) bool {
            if (bus.hasPendingFiq()) {
                self.mmu.halted_wfi = false;
                if ((self.cpsr & PsrFlags.F) == 0) {
                    self.enterException(.fiq, 0x1c, self.r[15] +% 4, true);
                    return true;
                }
            }
            if (bus.hasPendingIrq()) {
                self.mmu.halted_wfi = false;
                if ((self.cpsr & PsrFlags.I) == 0) {
                    self.enterException(.irq, 0x18, self.r[15] +% 4, false);
                    return true;
                }
            }
            return false;
        }

        // --- Memory Access via MMU & Bus ---

        inline fn read32(self: *Self, bus: *Bus, vaddr: u32) error{Abort}!u32 {
            const paddr = try self.mmu.translate(bus.ram, vaddr, .read, self.isPrivileged());
            if (paddr < bus.ram.len and (vaddr & 3) == 0) {
                return std.mem.readInt(u32, bus.ram[paddr..][0..4], .little);
            }
            // Handle unaligned RAM access or MMIO access
            if ((vaddr & 3) != 0 and (self.mmu.sctlr & (1 << 22)) != 0) {
                // ARMv6 unaligned word load (may cross page boundary)
                const b0: u32 = try self.read8(bus, vaddr);
                const b1: u32 = try self.read8(bus, vaddr +% 1);
                const b2: u32 = try self.read8(bus, vaddr +% 2);
                const b3: u32 = try self.read8(bus, vaddr +% 3);
                return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
            }
            const aligned_val = bus.read32(paddr & ~@as(u32, 3));
            if ((vaddr & 3) != 0) {
                const rot: u5 = @as(u5, @truncate(vaddr & 3)) * 8;
                return std.math.rotr(u32, aligned_val, rot);
            }
            return aligned_val;
        }

        inline fn write32(self: *Self, bus: *Bus, vaddr: u32, val: u32) error{Abort}!void {
            if ((vaddr & 3) != 0 and (self.mmu.sctlr & (1 << 22)) != 0) {
                try self.write8(bus, vaddr, @truncate(val));
                try self.write8(bus, vaddr +% 1, @truncate(val >> 8));
                try self.write8(bus, vaddr +% 2, @truncate(val >> 16));
                try self.write8(bus, vaddr +% 3, @truncate(val >> 24));
                return;
            }
            const paddr = try self.mmu.translate(bus.ram, vaddr, .write, self.isPrivileged());
            if (paddr < bus.ram.len and (paddr & 3) == 0) {
                std.mem.writeInt(u32, bus.ram[paddr..][0..4], val, .little);
                return;
            }
            bus.write32(paddr & ~@as(u32, 3), val);
        }

        inline fn read16(self: *Self, bus: *Bus, vaddr: u32) error{Abort}!u16 {
            if ((vaddr & 1) != 0 and (self.mmu.sctlr & (1 << 22)) != 0) {
                const b0: u16 = try self.read8(bus, vaddr);
                const b1: u16 = try self.read8(bus, vaddr +% 1);
                return b0 | (b1 << 8);
            }
            const paddr = try self.mmu.translate(bus.ram, vaddr, .read, self.isPrivileged());
            if (@as(usize, paddr) + 2 <= bus.ram.len) {
                return std.mem.readInt(u16, bus.ram[paddr..][0..2], .little);
            }
            return bus.read16(paddr);
        }

        inline fn write16(self: *Self, bus: *Bus, vaddr: u32, val: u16) error{Abort}!void {
            if ((vaddr & 1) != 0 and (self.mmu.sctlr & (1 << 22)) != 0) {
                try self.write8(bus, vaddr, @truncate(val));
                try self.write8(bus, vaddr +% 1, @truncate(val >> 8));
                return;
            }
            const paddr = try self.mmu.translate(bus.ram, vaddr, .write, self.isPrivileged());
            if (@as(usize, paddr) + 2 <= bus.ram.len) {
                std.mem.writeInt(u16, bus.ram[paddr..][0..2], val, .little);
                return;
            }
            bus.write16(paddr, val);
        }

        inline fn read8(self: *Self, bus: *Bus, vaddr: u32) error{Abort}!u8 {
            const paddr = try self.mmu.translate(bus.ram, vaddr, .read, self.isPrivileged());
            if (paddr < bus.ram.len) {
                return bus.ram[paddr];
            }
            return bus.read8(paddr);
        }

        inline fn write8(self: *Self, bus: *Bus, vaddr: u32, val: u8) error{Abort}!void {
            const paddr = try self.mmu.translate(bus.ram, vaddr, .write, self.isPrivileged());
            if (paddr < bus.ram.len) {
                bus.ram[paddr] = val;
                return;
            }
            bus.write8(paddr, val);
        }

        inline fn fetch32(self: *Self, bus: *Bus, vaddr: u32) error{Abort}!u32 {
            const paddr = try self.mmu.translate(bus.ram, vaddr, .fetch, self.isPrivileged());
            if (@as(usize, paddr) + 4 <= bus.ram.len) {
                return std.mem.readInt(u32, bus.ram[paddr..][0..4], .little);
            }
            return bus.read32(paddr);
        }

        inline fn fetch16(self: *Self, bus: *Bus, vaddr: u32) error{Abort}!u16 {
            const paddr = try self.mmu.translate(bus.ram, vaddr, .fetch, self.isPrivileged());
            if (@as(usize, paddr) + 2 <= bus.ram.len) {
                return std.mem.readInt(u16, bus.ram[paddr..][0..2], .little);
            }
            return bus.read16(paddr);
        }

        // --- Execution Step ---

        /// Executes up to `max_steps` instructions, stopping early if the CPU
        /// enters `WFI` or an interrupt becomes pending.
        pub fn runSteps(self: *Self, bus: *Bus, max_steps: usize) usize {
            var executed: usize = 0;
            while (executed < max_steps) : (executed += 1) {
                _ = self.checkInterrupts(bus);
                if (self.mmu.halted_wfi) break;
                self.stepOne(bus);
                self.cycles +%= 1;
                if (self.mmu.halted_wfi) break;
            }
            return executed;
        }

        pub inline fn stepOne(self: *Self, bus: *Bus) void {
            if (self.isThumb()) {
                const pc = self.r[15] & ~@as(u32, 1);
                const inst16 = self.fetch16(bus, pc) catch {
                    self.enterException(.abt, 0x0c, pc +% 4, false);
                    return;
                };
                self.r[15] = pc +% 2;
                self.executeThumb(bus, pc, inst16);
                return;
            }

            const pc = self.r[15] & ~@as(u32, 3);
            const inst = self.fetch32(bus, pc) catch {
                self.enterException(.abt, 0x0c, pc +% 4, false);
                return;
            };
            self.r[15] = pc +% 4;
            self.last_inst = inst;
            self.executeArm(bus, pc, inst);
            if (!self.mmu.isMmuEnabled() and self.r[15] >= 0xf000_0000) {
                std.debug.print("WARNING: PC jumped to 0x{x:0>8} from pc=0x{x:0>8} inst=0x{x:0>8} cycle={d}\n", .{ self.r[15], pc, inst, self.cycles });
            }
        }

        inline fn getReg(self: *const Self, idx: u4, inst_pc: u32) u32 {
            return if (idx == 15) (inst_pc +% 8) else self.r[idx];
        }

        inline fn setPcWithInterworking(self: *Self, target: u32) void {
            if ((target & 1) != 0) {
                self.cpsr |= PsrFlags.T;
                self.r[15] = target & ~@as(u32, 1);
            } else {
                self.cpsr &= ~PsrFlags.T;
                self.r[15] = target & ~@as(u32, 3);
            }
        }

        fn exceptionReturn(self: *Self, new_pc: u32) void {
            const spsr = self.getSpsr();
            self.setCpsr(spsr);
            if ((self.cpsr & PsrFlags.T) != 0) {
                self.r[15] = new_pc & ~@as(u32, 1);
            } else {
                self.r[15] = new_pc & ~@as(u32, 3);
            }
        }

        fn executeArm(self: *Self, bus: *Bus, inst_pc: u32, inst: u32) void {
            const cond: u4 = @truncate(inst >> 28);
            if (cond == 0xf) {
                self.executeUnconditional(bus, inst_pc, inst);
                return;
            }
            if (!dec.checkCond(cond, self.cpsr)) return;

            const top3: u3 = @truncate((inst >> 25) & 7);
            switch (top3) {
                0b000 => self.executeGroup000(bus, inst_pc, inst),
                0b001 => self.executeGroup001(inst_pc, inst),
                0b010 => self.executeLoadStoreWordByte(bus, inst_pc, inst, false),
                0b011 => {
                    if ((inst & (1 << 4)) != 0) {
                        self.executeMediaGroup(inst_pc, inst);
                    } else {
                        self.executeLoadStoreWordByte(bus, inst_pc, inst, true);
                    }
                },
                0b100 => self.executeLoadStoreMultiple(bus, inst_pc, inst),
                0b101 => {
                    // B / BL
                    const link = (inst & (1 << 24)) != 0;
                    const imm24: i24 = @bitCast(@as(u24, @truncate(inst)));
                    const offset: u32 = @bitCast(@as(i32, imm24) << 2);
                    if (link) self.r[14] = inst_pc +% 4;
                    self.r[15] = (inst_pc +% 8) +% offset;
                },
                0b110, 0b111 => self.executeCoprocOrSvc(bus, inst_pc, inst),
            }
        }

        fn executeUnconditional(self: *Self, bus: *Bus, inst_pc: u32, inst: u32) void {
            // 1. BLX (immediate): 1111 101H imm24
            if ((inst & 0x0e00_0000) == 0x0a00_0000) {
                const h: u32 = (inst >> 23) & 2;
                const imm24: i24 = @bitCast(@as(u24, @truncate(inst)));
                const offset: u32 = @as(u32, @bitCast(@as(i32, imm24) << 2)) | h;
                self.r[14] = inst_pc +% 4;
                self.cpsr |= PsrFlags.T;
                self.r[15] = (inst_pc +% 8) +% offset;
                return;
            }

            // 2. CPS (Change Processor State) / SETEND: 1111 0001 0000 ...
            if ((inst & 0x0ff0_0000) == 0x0100_0000) {
                if ((inst & 0x0001_0020) == 0x0000_0000) {
                    // CPS
                    if (!self.isPrivileged()) return;
                    const imod: u2 = @truncate((inst >> 18) & 3);
                    const mmod = ((inst >> 17) & 1) != 0;
                    if (imod == 0b10) {
                        // CPSIE (enable -> clear mask bits)
                        if ((inst & (1 << 8)) != 0) self.cpsr &= ~PsrFlags.A;
                        if ((inst & (1 << 7)) != 0) self.cpsr &= ~PsrFlags.I;
                        if ((inst & (1 << 6)) != 0) self.cpsr &= ~PsrFlags.F;
                    } else if (imod == 0b11) {
                        // CPSID (disable -> set mask bits)
                        if ((inst & (1 << 8)) != 0) self.cpsr |= PsrFlags.A;
                        if ((inst & (1 << 7)) != 0) self.cpsr |= PsrFlags.I;
                        if ((inst & (1 << 6)) != 0) self.cpsr |= PsrFlags.F;
                    }
                    if (mmod) {
                        const new_mode: u5 = @truncate(inst & 0x1f);
                        self.switchMode(new_mode);
                    }
                }
                return;
            }

            // 3. CLREX / DSB / DMB / ISB / PLD (`0xf57f_f01f` and `0xf550_f000`)
            if ((inst & 0x0f00_0000) == 0x0500_0000 or (inst & 0x0f00_0000) == 0x0700_0000) {
                if ((inst & 0x0fff_fff0) == 0x057f_f010) {
                    // CLREX
                    self.excl_valid = false;
                }
                // PLD / PLI / DMB / DSB / ISB are memory/cache hints
                return;
            }

            // 4. SRS (Store Return State) and RFE (Return From Exception)
            if ((inst & 0x0e50_0000) == 0x0840_0000) {
                // SRS: stores {LR, SPSR} of current mode into stack of target mode `inst & 0x1f`
                if (!self.isPrivileged()) return;
                const p = ((inst >> 24) & 1) != 0;
                const u = ((inst >> 23) & 1) != 0;
                const w = ((inst >> 21) & 1) != 0;
                const target_mode: u5 = @truncate(inst & 0x1f);
                const t_idx = bankIndex(target_mode);
                const cur_idx = bankIndex(@truncate(self.cpsr & 0x1f));
                const base_sp = if (t_idx == cur_idx) self.r[13] else self.bank_r13[t_idx];
                const start_addr = switch (@as(u2, (@as(u2, @intFromBool(p)) << 1) | @intFromBool(u))) {
                    0b00 => base_sp -% 4, // DA
                    0b01 => base_sp, // IA
                    0b10 => base_sp -% 8, // DB
                    0b11 => base_sp +% 4, // IB
                };
                const lr_val = self.r[14];
                const spsr_val = self.getSpsr();
                self.write32(bus, start_addr, lr_val) catch {
                    self.enterException(.abt, 0x10, inst_pc +% 8, false);
                    return;
                };
                self.write32(bus, start_addr +% 4, spsr_val) catch {
                    self.enterException(.abt, 0x10, inst_pc +% 8, false);
                    return;
                };
                if (w) {
                    const new_sp = if (u) (base_sp +% 8) else (base_sp -% 8);
                    if (t_idx == cur_idx) self.r[13] = new_sp else self.bank_r13[t_idx] = new_sp;
                }
                return;
            }

            if ((inst & 0x0e50_0000) == 0x0810_0000) {
                // RFE: loads {PC, CPSR} from [Rn]
                if (!self.isPrivileged()) return;
                const p = ((inst >> 24) & 1) != 0;
                const u = ((inst >> 23) & 1) != 0;
                const w = ((inst >> 21) & 1) != 0;
                const rn: u4 = @truncate((inst >> 16) & 0xf);
                const base_val = self.r[rn];
                const start_addr = switch (@as(u2, (@as(u2, @intFromBool(p)) << 1) | @intFromBool(u))) {
                    0b00 => base_val -% 4, // DA
                    0b01 => base_val, // IA
                    0b10 => base_val -% 8, // DB
                    0b11 => base_val +% 4, // IB
                };
                const new_pc = self.read32(bus, start_addr) catch {
                    self.enterException(.abt, 0x10, inst_pc +% 8, false);
                    return;
                };
                const new_cpsr = self.read32(bus, start_addr +% 4) catch {
                    self.enterException(.abt, 0x10, inst_pc +% 8, false);
                    return;
                };
                if (w) {
                    self.r[rn] = if (u) (base_val +% 8) else (base_val -% 8);
                }
                self.setCpsr(new_cpsr);
                if ((self.cpsr & PsrFlags.T) != 0) {
                    self.r[15] = new_pc & ~@as(u32, 1);
                } else {
                    self.r[15] = new_pc & ~@as(u32, 3);
                }
                return;
            }
        }

        fn executeGroup000(self: *Self, bus: *Bus, inst_pc: u32, inst: u32) void {
            const bit4 = (inst & (1 << 4)) != 0;
            const bit7 = (inst & (1 << 7)) != 0;

            if (bit4 and bit7) {
                // Multiplies, Synchronization primitives, and Extra Load/Store (`LDRH`/`STRH`/`LDRSB`/`LDRSH`/`LDRD`/`STRD`)
                self.executeMultipliesAndExtraLoadStore(bus, inst_pc, inst);
                return;
            }

            const op: u4 = @truncate((inst >> 21) & 0xf);
            const s = (inst & (1 << 20)) != 0;

            // Miscellaneous instructions (`op` in `0b1000..0b1011` and `s == false`)
            if ((op & 0b1100) == 0b1000 and !s) {
                self.executeMisc000(inst_pc, inst);
                return;
            }

            // Standard Data Processing (register or register-shifted register)
            const rn: u4 = @truncate((inst >> 16) & 0xf);
            const rd: u4 = @truncate((inst >> 12) & 0xf);
            const rm: u4 = @truncate(inst & 0xf);
            const shift_type: u2 = @truncate((inst >> 5) & 3);
            const carry_in: u1 = @truncate((self.cpsr >> 29) & 1);

            const shift_res: dec.ShiftResult = if (!bit4) blk: {
                const shift_imm: u5 = @truncate((inst >> 7) & 0x1f);
                const rm_val = self.getReg(rm, inst_pc);
                break :blk dec.barrelShiftImm(rm_val, shift_type, shift_imm, carry_in);
            } else blk: {
                const rs: u4 = @truncate((inst >> 8) & 0xf);
                const rs_byte: u8 = @truncate(self.r[rs]);
                // Note: when shift is specified by register, reading PC (Rm or Rn == 15) gives inst_pc + 12
                const rm_val = if (rm == 15) (inst_pc +% 12) else self.r[rm];
                break :blk dec.barrelShiftReg(rm_val, shift_type, rs_byte, carry_in);
            };

            const rn_val = if (rn == 15) (if (bit4) inst_pc +% 12 else inst_pc +% 8) else self.r[rn];
            self.applyDataProc(op, s, rd, rn_val, shift_res.val, shift_res.carry);
        }

        fn executeGroup001(self: *Self, inst_pc: u32, inst: u32) void {
            const op: u4 = @truncate((inst >> 21) & 0xf);
            const s = (inst & (1 << 20)) != 0;

            // Check for MSR (immediate) / Hints / MOVW / MOVT (`op` in `0b1000..0b1011` and `s == false`)
            if ((op & 0b1100) == 0b1000 and !s) {
                if (op == 0b1000 or op == 0b1010) {
                    // MOVW (op=1000) / MOVT (op=1010)
                    const rd: u4 = @truncate((inst >> 12) & 0xf);
                    const imm16: u32 = (((inst >> 16) & 0xf) << 12) | (inst & 0xfff);
                    if (op == 0b1000) {
                        self.r[rd] = imm16;
                    } else {
                        self.r[rd] = (self.r[rd] & 0x0000_ffff) | (imm16 << 16);
                    }
                    return;
                }
                const mask: u4 = @truncate((inst >> 16) & 0xf);
                if (op == 0b1001 and mask == 0) {
                    // Architecture hints: NOP (0), YIELD (1), WFE (2), WFI (3), SEV (4)
                    if ((inst & 0xff) == 3) {
                        self.mmu.halted_wfi = true;
                    }
                    return;
                }
                // MSR (immediate)
                const imm8: u32 = inst & 0xff;
                const rot: u5 = @as(u5, @truncate((inst >> 8) & 0xf)) * 2;
                const imm32 = std.math.rotr(u32, imm8, rot);
                const write_spsr = (op == 0b1011);
                self.writePsrByMask(write_spsr, mask, imm32);
                return;
            }

            const rn: u4 = @truncate((inst >> 16) & 0xf);
            const rd: u4 = @truncate((inst >> 12) & 0xf);
            const imm8: u32 = inst & 0xff;
            const rot: u5 = @as(u5, @truncate((inst >> 8) & 0xf)) * 2;
            const imm32 = std.math.rotr(u32, imm8, rot);
            const carry_in: u1 = @truncate((self.cpsr >> 29) & 1);
            const shifter_carry: u1 = if (rot == 0) carry_in else @truncate(imm32 >> 31);

            const rn_val = self.getReg(rn, inst_pc);
            self.applyDataProc(op, s, rd, rn_val, imm32, shifter_carry);
        }

        inline fn applyDataProc(self: *Self, op: u4, s: bool, rd: u4, rn_val: u32, op2_val: u32, shifter_carry: u1) void {
            const carry_in: u1 = @truncate((self.cpsr >> 29) & 1);
            var res: u32 = 0;
            var write_rd = true;
            var new_n: u1 = @truncate((self.cpsr >> 31) & 1);
            var new_z: u1 = @truncate((self.cpsr >> 30) & 1);
            var new_c: u1 = carry_in;
            var new_v: u1 = @truncate((self.cpsr >> 28) & 1);

            switch (op) {
                0x0 => { // AND
                    res = rn_val & op2_val;
                    new_n = @truncate(res >> 31);
                    new_z = if (res == 0) 1 else 0;
                    new_c = shifter_carry;
                },
                0x1 => { // EOR
                    res = rn_val ^ op2_val;
                    new_n = @truncate(res >> 31);
                    new_z = if (res == 0) 1 else 0;
                    new_c = shifter_carry;
                },
                0x2 => { // SUB
                    const sub = dec.addWithCarry(rn_val, ~op2_val, 1);
                    res = sub.val;
                    new_n = sub.n;
                    new_z = sub.z;
                    new_c = sub.c;
                    new_v = sub.v;
                },
                0x3 => { // RSB
                    const rsb = dec.addWithCarry(op2_val, ~rn_val, 1);
                    res = rsb.val;
                    new_n = rsb.n;
                    new_z = rsb.z;
                    new_c = rsb.c;
                    new_v = rsb.v;
                },
                0x4 => { // ADD
                    const add = dec.addWithCarry(rn_val, op2_val, 0);
                    res = add.val;
                    new_n = add.n;
                    new_z = add.z;
                    new_c = add.c;
                    new_v = add.v;
                },
                0x5 => { // ADC
                    const adc = dec.addWithCarry(rn_val, op2_val, carry_in);
                    res = adc.val;
                    new_n = adc.n;
                    new_z = adc.z;
                    new_c = adc.c;
                    new_v = adc.v;
                },
                0x6 => { // SBC
                    const sbc = dec.addWithCarry(rn_val, ~op2_val, carry_in);
                    res = sbc.val;
                    new_n = sbc.n;
                    new_z = sbc.z;
                    new_c = sbc.c;
                    new_v = sbc.v;
                },
                0x7 => { // RSC
                    const rsc = dec.addWithCarry(op2_val, ~rn_val, carry_in);
                    res = rsc.val;
                    new_n = rsc.n;
                    new_z = rsc.z;
                    new_c = rsc.c;
                    new_v = rsc.v;
                },
                0x8 => { // TST
                    res = rn_val & op2_val;
                    new_n = @truncate(res >> 31);
                    new_z = if (res == 0) 1 else 0;
                    new_c = shifter_carry;
                    write_rd = false;
                },
                0x9 => { // TEQ
                    res = rn_val ^ op2_val;
                    new_n = @truncate(res >> 31);
                    new_z = if (res == 0) 1 else 0;
                    new_c = shifter_carry;
                    write_rd = false;
                },
                0xa => { // CMP
                    const cmp = dec.addWithCarry(rn_val, ~op2_val, 1);
                    new_n = cmp.n;
                    new_z = cmp.z;
                    new_c = cmp.c;
                    new_v = cmp.v;
                    write_rd = false;
                },
                0xb => { // CMN
                    const cmn = dec.addWithCarry(rn_val, op2_val, 0);
                    new_n = cmn.n;
                    new_z = cmn.z;
                    new_c = cmn.c;
                    new_v = cmn.v;
                    write_rd = false;
                },
                0xc => { // ORR
                    res = rn_val | op2_val;
                    new_n = @truncate(res >> 31);
                    new_z = if (res == 0) 1 else 0;
                    new_c = shifter_carry;
                },
                0xd => { // MOV
                    res = op2_val;
                    new_n = @truncate(res >> 31);
                    new_z = if (res == 0) 1 else 0;
                    new_c = shifter_carry;
                },
                0xe => { // BIC
                    res = rn_val & ~op2_val;
                    new_n = @truncate(res >> 31);
                    new_z = if (res == 0) 1 else 0;
                    new_c = shifter_carry;
                },
                0xf => { // MVN
                    res = ~op2_val;
                    new_n = @truncate(res >> 31);
                    new_z = if (res == 0) 1 else 0;
                    new_c = shifter_carry;
                },
            }

            if (s and rd == 15 and write_rd) {
                self.exceptionReturn(res);
                return;
            }

            if (write_rd) {
                if (rd == 15) {
                    self.r[15] = res & ~@as(u32, 3);
                } else {
                    self.r[rd] = res;
                }
            }

            if (s) {
                const nzcv: u32 = (@as(u32, new_n) << 31) |
                    (@as(u32, new_z) << 30) |
                    (@as(u32, new_c) << 29) |
                    (@as(u32, new_v) << 28);
                self.cpsr = (self.cpsr & 0x0fff_ffff) | nzcv;
            }
        }

        fn executeMisc000(self: *Self, inst_pc: u32, inst: u32) void {
            const op2: u4 = @truncate((inst >> 4) & 0xf);
            const op1: u2 = @truncate((inst >> 21) & 3);
            const rd: u4 = @truncate((inst >> 12) & 0xf);
            const rm: u4 = @truncate(inst & 0xf);

            switch (op2) {
                0b0000 => {
                    if ((inst & (1 << 21)) == 0) {
                        // MRS Rd, CPSR / SPSR
                        const read_spsr = (inst & (1 << 22)) != 0;
                        self.r[rd] = if (read_spsr) self.getSpsr() else self.cpsr;
                    } else {
                        // MSR CPSR/SPSR, Rm
                        const write_spsr = (inst & (1 << 22)) != 0;
                        const mask: u4 = @truncate((inst >> 16) & 0xf);
                        self.writePsrByMask(write_spsr, mask, self.r[rm]);
                    }
                },
                0b0001 => {
                    if (op1 == 0b01) {
                        // BX Rm
                        const target = self.r[rm];
                        self.setPcWithInterworking(target);
                    } else if (op1 == 0b11) {
                        // CLZ Rd, Rm
                        self.r[rd] = @clz(self.r[rm]);
                    }
                },
                0b0011 => {
                    if (op1 == 0b01) {
                        // BLX Rm
                        const target = self.r[rm];
                        self.r[14] = inst_pc +% 4;
                        self.setPcWithInterworking(target);
                    }
                },
                0b0101 => {
                    // Saturating add/subtract: QADD (00), QSUB (01), QDADD (10), QDSUB (11)
                    const rn: u4 = @truncate((inst >> 16) & 0xf);
                    const a: i64 = @as(i32, @bitCast(self.r[rm]));
                    var b: i64 = @as(i32, @bitCast(self.r[rn]));
                    if ((op1 & 2) != 0) {
                        b *= 2;
                        if (b > std.math.maxInt(i32)) {
                            b = std.math.maxInt(i32);
                            self.cpsr |= PsrFlags.Q;
                        } else if (b < std.math.minInt(i32)) {
                            b = std.math.minInt(i32);
                            self.cpsr |= PsrFlags.Q;
                        }
                    }
                    var sum: i64 = if ((op1 & 1) != 0) (a - b) else (a + b);
                    if (sum > std.math.maxInt(i32)) {
                        sum = std.math.maxInt(i32);
                        self.cpsr |= PsrFlags.Q;
                    } else if (sum < std.math.minInt(i32)) {
                        sum = std.math.minInt(i32);
                        self.cpsr |= PsrFlags.Q;
                    }
                    self.r[rd] = @bitCast(@as(i32, @intCast(sum)));
                },
                0b0111 => {
                    // BKPT
                    self.enterException(.abt, 0x0c, inst_pc +% 4, false);
                },
                0b1000, 0b1010, 0b1100, 0b1110 => {
                    // Signed 16-bit multiplies: SMLAxy (00), SMLAWy/SMULWy (01), SMLALxy (10), SMULxy (11)
                    const rn_idx: u4 = @truncate((inst >> 12) & 0xf);
                    const rd_idx: u4 = @truncate((inst >> 16) & 0xf);
                    const rs_idx: u4 = @truncate((inst >> 8) & 0xf);
                    const x_top = (inst & (1 << 5)) != 0;
                    const y_top = (inst & (1 << 6)) != 0;
                    const m_val = self.r[rm];
                    const s_val = self.r[rs_idx];
                    const op_m: i32 = @as(i16, @bitCast(@as(u16, @truncate(if (x_top) (m_val >> 16) else m_val))));
                    const op_s: i32 = @as(i16, @bitCast(@as(u16, @truncate(if (y_top) (s_val >> 16) else s_val))));
                    switch (op1) {
                        0b00 => { // SMLAxy
                            const prod: i64 = @as(i64, op_m) * op_s;
                            const acc: i64 = @as(i32, @bitCast(self.r[rn_idx]));
                            const sum = prod + acc;
                            if (sum > std.math.maxInt(i32) or sum < std.math.minInt(i32)) {
                                self.cpsr |= PsrFlags.Q;
                            }
                            self.r[rd_idx] = @truncate(@as(u64, @bitCast(sum)));
                        },
                        0b01 => { // SMLAWy (x_top=false) / SMULWy (x_top=true)
                            const prod: i64 = (@as(i64, @as(i32, @bitCast(m_val))) * op_s) >> 16;
                            if (x_top) {
                                self.r[rd_idx] = @truncate(@as(u64, @bitCast(prod)));
                            } else {
                                const acc: i64 = @as(i32, @bitCast(self.r[rn_idx]));
                                const sum = prod + acc;
                                if (sum > std.math.maxInt(i32) or sum < std.math.minInt(i32)) {
                                    self.cpsr |= PsrFlags.Q;
                                }
                                self.r[rd_idx] = @truncate(@as(u64, @bitCast(sum)));
                            }
                        },
                        0b10 => { // SMLALxy
                            const prod: i64 = @as(i64, op_m) * op_s;
                            const acc_u: u64 = (@as(u64, self.r[rd_idx]) << 32) | self.r[rn_idx];
                            const sum: u64 = @bitCast(@as(i64, @bitCast(acc_u)) +% prod);
                            self.r[rn_idx] = @truncate(sum);
                            self.r[rd_idx] = @truncate(sum >> 32);
                        },
                        0b11 => { // SMULxy
                            const prod: i32 = op_m * op_s;
                            self.r[rd_idx] = @bitCast(prod);
                        },
                    }
                },
                else => {},
            }
        }

        fn writePsrByMask(self: *Self, write_spsr: bool, mask: u4, val: u32) void {
            var byte_mask: u32 = 0;
            if ((mask & 0b1000) != 0) byte_mask |= 0xff00_0000; // f (flags)
            if ((mask & 0b0100) != 0) byte_mask |= 0x00ff_0000; // s (status / GE)
            if (self.isPrivileged() or write_spsr) {
                if ((mask & 0b0010) != 0) byte_mask |= 0x0000_ff00; // x (extension)
                if ((mask & 0b0001) != 0) byte_mask |= 0x0000_00ff; // c (control)
            }
            if (write_spsr) {
                const cur = self.getSpsr();
                self.setSpsr((cur & ~byte_mask) | (val & byte_mask));
            } else {
                const new_cpsr = (self.cpsr & ~byte_mask) | (val & byte_mask);
                self.setCpsr(new_cpsr);
            }
        }

        fn executeMultipliesAndExtraLoadStore(self: *Self, bus: *Bus, inst_pc: u32, inst: u32) void {
            const sh: u2 = @truncate((inst >> 5) & 3);
            if (sh == 0b00) {
                const op: u4 = @truncate((inst >> 20) & 0xf);
                // 1. Synchronization primitives (`op >= 0b1000` when bit 24 == 1)
                if ((inst & (1 << 24)) != 0) {
                    const rn: u4 = @truncate((inst >> 16) & 0xf);
                    const rd: u4 = @truncate((inst >> 12) & 0xf);
                    const rm: u4 = @truncate(inst & 0xf);
                    const vaddr = self.r[rn];

                    switch (op) {
                        0b0000, 0b0100 => {
                            // SWP (0000) / SWPB (0100)
                            if (op == 0b0000) {
                                const old_val = self.read32(bus, vaddr) catch {
                                    self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                    return;
                                };
                                self.write32(bus, vaddr, self.r[rm]) catch {
                                    self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                    return;
                                };
                                self.r[rd] = old_val;
                            } else {
                                const old_val = self.read8(bus, vaddr) catch {
                                    self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                    return;
                                };
                                self.write8(bus, vaddr, @truncate(self.r[rm])) catch {
                                    self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                    return;
                                };
                                self.r[rd] = old_val;
                            }
                        },
                        0b1001 => { // LDREX Rd, [Rn]
                            const val = self.read32(bus, vaddr) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return;
                            };
                            self.r[rd] = val;
                            self.excl_valid = true;
                            self.excl_paddr = self.mmu.translate(bus.ram, vaddr, .read, self.isPrivileged()) catch 0;
                        },
                        0b1000 => { // STREX Rd, Rm, [Rn]
                            const paddr = self.mmu.translate(bus.ram, vaddr, .write, self.isPrivileged()) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return;
                            };
                            if (self.excl_valid) {
                                self.write32(bus, vaddr, self.r[rm]) catch {
                                    self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                    return;
                                };
                                self.r[rd] = 0;
                                self.excl_valid = false;
                            } else {
                                _ = paddr;
                                self.r[rd] = 1;
                            }
                        },
                        0b1011 => { // LDREXD Rd, Rd+1, [Rn]
                            const lo = self.read32(bus, vaddr) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return;
                            };
                            const hi = self.read32(bus, vaddr +% 4) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return;
                            };
                            self.r[rd] = lo;
                            self.r[rd +% 1] = hi;
                            self.excl_valid = true;
                        },
                        0b1010 => { // STREXD Rd, Rm, Rm+1, [Rn]
                            _ = self.mmu.translate(bus.ram, vaddr, .write, self.isPrivileged()) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return;
                            };
                            if (self.excl_valid) {
                                const lo = self.r[rm];
                                const hi = self.r[rm +% 1];
                                self.write32(bus, vaddr, lo) catch {
                                    self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                    return;
                                };
                                self.write32(bus, vaddr +% 4, hi) catch {
                                    self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                    return;
                                };
                                self.r[rd] = 0;
                                self.excl_valid = false;
                            } else {
                                self.r[rd] = 1;
                            }
                        },
                        0b1101 => { // LDREXB Rd, [Rn]
                            const val = self.read8(bus, vaddr) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return;
                            };
                            self.r[rd] = val;
                            self.excl_valid = true;
                        },
                        0b1100 => { // STREXB Rd, Rm, [Rn]
                            if (self.excl_valid) {
                                self.write8(bus, vaddr, @truncate(self.r[rm])) catch {
                                    self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                    return;
                                };
                                self.r[rd] = 0;
                                self.excl_valid = false;
                            } else {
                                self.r[rd] = 1;
                            }
                        },
                        0b1111 => { // LDREXH Rd, [Rn]
                            const val = self.read16(bus, vaddr) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return;
                            };
                            self.r[rd] = val;
                            self.excl_valid = true;
                        },
                        0b1110 => { // STREXH Rd, Rm, [Rn]
                            if (self.excl_valid) {
                                self.write16(bus, vaddr, @truncate(self.r[rm])) catch {
                                    self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                    return;
                                };
                                self.r[rd] = 0;
                                self.excl_valid = false;
                            } else {
                                self.r[rd] = 1;
                            }
                        },
                        else => {},
                    }
                    return;
                }

                // 2. Multiplies (`MUL`, `MLA`, `UMAAL`, `UMULL`, `UMLAL`, `SMULL`, `SMLAL`)
                const rd_hi: u4 = @truncate((inst >> 16) & 0xf);
                const rd_lo: u4 = @truncate((inst >> 12) & 0xf);
                const rs: u4 = @truncate((inst >> 8) & 0xf);
                const rm: u4 = @truncate(inst & 0xf);
                const s = (inst & (1 << 20)) != 0;
                const mul_op: u3 = @truncate((inst >> 21) & 7);

                switch (mul_op) {
                    0b000 => { // MUL
                        const res = self.r[rm] *% self.r[rs];
                        self.r[rd_hi] = res;
                        if (s) self.setNZ(res);
                    },
                    0b001 => { // MLA
                        const res = (self.r[rm] *% self.r[rs]) +% self.r[rd_lo];
                        self.r[rd_hi] = res;
                        if (s) self.setNZ(res);
                    },
                    0b010 => { // UMAAL
                        const prod: u64 = @as(u64, self.r[rm]) * @as(u64, self.r[rs]) +
                            @as(u64, self.r[rd_hi]) + @as(u64, self.r[rd_lo]);
                        self.r[rd_lo] = @truncate(prod);
                        self.r[rd_hi] = @truncate(prod >> 32);
                    },
                    0b100 => { // UMULL
                        const prod: u64 = @as(u64, self.r[rm]) * @as(u64, self.r[rs]);
                        self.r[rd_lo] = @truncate(prod);
                        self.r[rd_hi] = @truncate(prod >> 32);
                        if (s) self.setNZ64(prod);
                    },
                    0b101 => { // UMLAL
                        const acc: u64 = (@as(u64, self.r[rd_hi]) << 32) | self.r[rd_lo];
                        const prod: u64 = (@as(u64, self.r[rm]) * @as(u64, self.r[rs])) +% acc;
                        self.r[rd_lo] = @truncate(prod);
                        self.r[rd_hi] = @truncate(prod >> 32);
                        if (s) self.setNZ64(prod);
                    },
                    0b110 => { // SMULL
                        const a: i64 = @as(i32, @bitCast(self.r[rm]));
                        const b: i64 = @as(i32, @bitCast(self.r[rs]));
                        const prod: u64 = @bitCast(a * b);
                        self.r[rd_lo] = @truncate(prod);
                        self.r[rd_hi] = @truncate(prod >> 32);
                        if (s) self.setNZ64(prod);
                    },
                    0b111 => { // SMLAL
                        const a: i64 = @as(i32, @bitCast(self.r[rm]));
                        const b: i64 = @as(i32, @bitCast(self.r[rs]));
                        const acc: i64 = @bitCast((@as(u64, self.r[rd_hi]) << 32) | self.r[rd_lo]);
                        const prod: u64 = @bitCast((a * b) +% acc);
                        self.r[rd_lo] = @truncate(prod);
                        self.r[rd_hi] = @truncate(prod >> 32);
                        if (s) self.setNZ64(prod);
                    },
                    else => {},
                }
                return;
            }

            // 3. Extra Load/Store (`sh` != 0: `STRH`, `LDRH`, `LDRSB`, `LDRSH`, `LDRD`, `STRD`)
            const p = (inst & (1 << 24)) != 0;
            const u = (inst & (1 << 23)) != 0;
            const i_imm = (inst & (1 << 22)) != 0;
            const w = (inst & (1 << 21)) != 0;
            const l = (inst & (1 << 20)) != 0;
            const rn: u4 = @truncate((inst >> 16) & 0xf);
            const rd: u4 = @truncate((inst >> 12) & 0xf);

            const offset: u32 = if (i_imm)
                (((inst >> 8) & 0xf) << 4) | (inst & 0xf)
            else
                self.getReg(@truncate(inst & 0xf), inst_pc);

            const base_val = self.getReg(rn, inst_pc);
            const calc_addr = if (u) (base_val +% offset) else (base_val -% offset);
            const vaddr = if (p) calc_addr else base_val;

            switch (sh) {
                0b01 => { // LDRH / STRH
                    if (l) {
                        const val = self.read16(bus, vaddr) catch {
                            self.enterException(.abt, 0x10, inst_pc +% 8, false);
                            return;
                        };
                        if (!p or w) self.r[rn] = calc_addr;
                        self.r[rd] = val;
                    } else {
                        const val: u16 = @truncate(self.getReg(rd, inst_pc));
                        self.write16(bus, vaddr, val) catch {
                            self.enterException(.abt, 0x10, inst_pc +% 8, false);
                            return;
                        };
                        if (!p or w) self.r[rn] = calc_addr;
                    }
                },
                0b10 => { // LDRSB (L=1) or LDRD (L=0)
                    if (l) {
                        const val = self.read8(bus, vaddr) catch {
                            self.enterException(.abt, 0x10, inst_pc +% 8, false);
                            return;
                        };
                        if (!p or w) self.r[rn] = calc_addr;
                        const sext: i32 = @as(i8, @bitCast(val));
                        self.r[rd] = @bitCast(sext);
                    } else {
                        // LDRD Rd, Rd+1, [Rn, ...]
                        const lo = self.read32(bus, vaddr) catch {
                            self.enterException(.abt, 0x10, inst_pc +% 8, false);
                            return;
                        };
                        const hi = self.read32(bus, vaddr +% 4) catch {
                            self.enterException(.abt, 0x10, inst_pc +% 8, false);
                            return;
                        };
                        if (!p or w) self.r[rn] = calc_addr;
                        self.r[rd] = lo;
                        self.r[rd +% 1] = hi;
                    }
                },
                0b11 => { // LDRSH (L=1) or STRD (L=0)
                    if (l) {
                        const val = self.read16(bus, vaddr) catch {
                            self.enterException(.abt, 0x10, inst_pc +% 8, false);
                            return;
                        };
                        if (!p or w) self.r[rn] = calc_addr;
                        const sext: i32 = @as(i16, @bitCast(val));
                        self.r[rd] = @bitCast(sext);
                    } else {
                        // STRD Rd, Rd+1, [Rn, ...]
                        const lo = self.r[rd];
                        const hi = self.r[rd +% 1];
                        self.write32(bus, vaddr, lo) catch {
                            self.enterException(.abt, 0x10, inst_pc +% 8, false);
                            return;
                        };
                        self.write32(bus, vaddr +% 4, hi) catch {
                            self.enterException(.abt, 0x10, inst_pc +% 8, false);
                            return;
                        };
                        if (!p or w) self.r[rn] = calc_addr;
                    }
                },
                0b00 => unreachable,
            }
        }

        fn executeLoadStoreWordByte(self: *Self, bus: *Bus, inst_pc: u32, inst: u32, reg_offset: bool) void {
            const p = (inst & (1 << 24)) != 0;
            const u = (inst & (1 << 23)) != 0;
            const b = (inst & (1 << 22)) != 0;
            const w = (inst & (1 << 21)) != 0;
            const l = (inst & (1 << 20)) != 0;
            const rn: u4 = @truncate((inst >> 16) & 0xf);
            const rd: u4 = @truncate((inst >> 12) & 0xf);

            const offset: u32 = if (!reg_offset)
                inst & 0xfff
            else blk: {
                const rm: u4 = @truncate(inst & 0xf);
                const shift_type: u2 = @truncate((inst >> 5) & 3);
                const shift_imm: u5 = @truncate((inst >> 7) & 0x1f);
                const carry_in: u1 = @truncate((self.cpsr >> 29) & 1);
                break :blk dec.barrelShiftImm(self.getReg(rm, inst_pc), shift_type, shift_imm, carry_in).val;
            };

            const base_val = self.getReg(rn, inst_pc);
            const calc_addr = if (u) (base_val +% offset) else (base_val -% offset);
            const vaddr = if (p) calc_addr else base_val;

            // Note: When !p and w (LDRT / STRT / LDRBT / STRBT), access uses unprivileged permissions!
            const unpriv_access = (!p and w);
            const saved_cpsr = self.cpsr;
            if (unpriv_access) {
                self.cpsr = (self.cpsr & ~@as(u32, 0x1f)) | @intFromEnum(Mode.usr);
            }
            defer if (unpriv_access) {
                self.cpsr = saved_cpsr;
            };

            if (l) {
                if (b) {
                    const val = self.read8(bus, vaddr) catch {
                        if (unpriv_access) self.cpsr = saved_cpsr;
                        self.enterException(.abt, 0x10, inst_pc +% 8, false);
                        return;
                    };
                    if (!p or w) self.r[rn] = calc_addr;
                    self.r[rd] = val;
                } else {
                    const val = self.read32(bus, vaddr) catch {
                        if (unpriv_access) self.cpsr = saved_cpsr;
                        self.enterException(.abt, 0x10, inst_pc +% 8, false);
                        return;
                    };
                    if (!p or w) self.r[rn] = calc_addr;
                    if (rd == 15) {
                        self.setPcWithInterworking(val);
                    } else {
                        self.r[rd] = val;
                    }
                }
            } else {
                const store_val = if (rd == 15) (inst_pc +% 8) else self.r[rd];
                if (b) {
                    self.write8(bus, vaddr, @truncate(store_val)) catch {
                        if (unpriv_access) self.cpsr = saved_cpsr;
                        self.enterException(.abt, 0x10, inst_pc +% 8, false);
                        return;
                    };
                } else {
                    self.write32(bus, vaddr, store_val) catch {
                        if (unpriv_access) self.cpsr = saved_cpsr;
                        self.enterException(.abt, 0x10, inst_pc +% 8, false);
                        return;
                    };
                }
                if (!p or w) self.r[rn] = calc_addr;
            }
        }

        fn executeLoadStoreMultiple(self: *Self, bus: *Bus, inst_pc: u32, inst: u32) void {
            const p = (inst & (1 << 24)) != 0;
            const u = (inst & (1 << 23)) != 0;
            const s = (inst & (1 << 22)) != 0;
            const w = (inst & (1 << 21)) != 0;
            const l = (inst & (1 << 20)) != 0;
            const rn: u4 = @truncate((inst >> 16) & 0xf);
            const reg_list: u16 = @truncate(inst & 0xffff);

            const count: u32 = @popCount(reg_list);
            const total_bytes = count * 4;
            const base_val = self.r[rn];

            const start_addr = switch (@as(u2, (@as(u2, @intFromBool(p)) << 1) | @intFromBool(u))) {
                0b00 => base_val -% total_bytes +% 4, // DA
                0b01 => base_val, // IA
                0b10 => base_val -% total_bytes, // DB
                0b11 => base_val +% 4, // IB
            };
            const final_base = if (u) (base_val +% total_bytes) else (base_val -% total_bytes);

            const user_bank = s and (!l or (reg_list & (1 << 15)) == 0);

            if (l) {
                var loaded: [16]u32 = undefined;
                var addr = start_addr;
                for (0..16) |i| {
                    if ((reg_list & (@as(u16, 1) << @intCast(i))) != 0) {
                        loaded[i] = self.read32(bus, addr) catch {
                            // Base Restored Abort Model: Rn and previous registers untouched!
                            self.enterException(.abt, 0x10, inst_pc +% 8, false);
                            return;
                        };
                        addr +%= 4;
                    }
                }
                if (w and (reg_list & (@as(u16, 1) << rn)) == 0) {
                    self.r[rn] = final_base;
                }
                for (0..15) |i| {
                    if ((reg_list & (@as(u16, 1) << @intCast(i))) != 0) {
                        if (user_bank) {
                            self.writeUserReg(@intCast(i), loaded[i]);
                        } else {
                            self.r[i] = loaded[i];
                        }
                    }
                }
                if ((reg_list & (1 << 15)) != 0) {
                    if (s) {
                        self.exceptionReturn(loaded[15]);
                    } else {
                        self.setPcWithInterworking(loaded[15]);
                    }
                }
            } else {
                // STM: Pre-validate write translation on first and last address before committing writes
                if (count > 0) {
                    _ = self.mmu.translate(bus.ram, start_addr, .write, self.isPrivileged()) catch {
                        self.enterException(.abt, 0x10, inst_pc +% 8, false);
                        return;
                    };
                    if (total_bytes > 4) {
                        _ = self.mmu.translate(bus.ram, start_addr +% total_bytes -% 4, .write, self.isPrivileged()) catch {
                            self.enterException(.abt, 0x10, inst_pc +% 8, false);
                            return;
                        };
                    }
                }
                var addr = start_addr;
                for (0..16) |i| {
                    if ((reg_list & (@as(u16, 1) << @intCast(i))) != 0) {
                        const val = if (i == 15)
                            (inst_pc +% 8)
                        else if (user_bank)
                            self.readUserReg(@intCast(i))
                        else
                            self.r[i];
                        self.write32(bus, addr, val) catch {
                            self.enterException(.abt, 0x10, inst_pc +% 8, false);
                            return;
                        };
                        addr +%= 4;
                    }
                }
                if (w) {
                    self.r[rn] = final_base;
                }
            }
        }

        fn executeMediaGroup(self: *Self, inst_pc: u32, inst: u32) void {
            // Check for architecturally undefined instruction `0xe7f...f.` (used by Linux BUG() / ptrace / kprobes!)
            const op1: u5 = @truncate((inst >> 20) & 0x1f);
            const op2: u3 = @truncate((inst >> 5) & 7);
            if (op1 == 0b11111 and op2 == 0b111) {
                self.enterException(.und, 0x04, inst_pc +% 4, false);
                return;
            }

            const rn_idx: u4 = @truncate((inst >> 16) & 0xf);
            const rd_idx: u4 = @truncate((inst >> 12) & 0xf);
            const rs_idx: u4 = @truncate((inst >> 8) & 0xf);
            const rm_idx: u4 = @truncate(inst & 0xf);

            // For signed multiplies (`op1[4:3] == 0b10`) and USAD8/USADA8 (`op1 == 0b11000, op2 == 0`),
            // destination register is in bits 19:16 (`rn_idx`), accumulate is in 15:12 (`rd_idx`),
            // multiplier is in 11:8 (`rs_idx`), and multiplicand is in 3:0 (`rm_idx`).
            if ((op1 & 0b11000) == 0b10000 or (op1 == 0b11000 and op2 == 0b000)) {
                const r_rn = self.r[rm_idx];
                const r_rm = self.r[rs_idx];
                const r_ra = if (rd_idx == 15) 0 else self.r[rd_idx];
                if (dec.executeMedia(inst, r_rn, r_rm, self.r[rn_idx], r_ra, &self.cpsr)) |res| {
                    self.r[rn_idx] = res;
                }
                return;
            }

            // For SXTB / UXTB / SXTH / UXTH / SXTB16 / UXTB16, Rn == 15 means 0 (no accumulate)
            const r_rn = if (rn_idx == 15) 0 else self.getReg(rn_idx, inst_pc);
            const r_rm = self.getReg(rm_idx, inst_pc);
            if (dec.executeMedia(inst, r_rn, r_rm, self.r[rd_idx], 0, &self.cpsr)) |res| {
                self.r[rd_idx] = res;
            } else {
                self.enterException(.und, 0x04, inst_pc +% 4, false);
            }
        }

        fn executeCoprocOrSvc(self: *Self, bus: *Bus, inst_pc: u32, inst: u32) void {
            // 1. SVC / SWI: 1111 (bit 27..24 == 0b1111)
            if ((inst & 0x0f00_0000) == 0x0f00_0000) {
                self.enterException(.svc, 0x08, inst_pc +% 4, false);
                return;
            }

            const cp_num: u4 = @truncate((inst >> 8) & 0xf);

            // 2. CP15 System Control Coprocessor
            if (cp_num == 15) {
                if ((inst & 0x0f00_0010) == 0x0e00_0010) {
                    const opc1: u3 = @truncate((inst >> 21) & 7);
                    const l = (inst & (1 << 20)) != 0;
                    const crn: u4 = @truncate((inst >> 16) & 0xf);
                    const rt: u4 = @truncate((inst >> 12) & 0xf);
                    const crm: u4 = @truncate(inst & 0xf);
                    const opc2: u3 = @truncate((inst >> 5) & 7);

                    // Unprivileged access to CP15 is allowed for:
                    // - TPIDRURW (c13, 0, c0, 2) and TPIDRURO (c13, 0, c0, 3)
                    // - ARMv6 memory/instruction barriers (c7, 0, c10, 4/5 = DSB/DMB; c7, 0, c5, 4/6 = ISB/BPIALL)
                    if (!self.isPrivileged()) {
                        const allowed_c13 = (crn == 13 and crm == 0 and (opc2 == 2 or (opc2 == 3 and l)));
                        const allowed_c7 = (crn == 7 and !l and ((crm == 10 and (opc2 == 4 or opc2 == 5)) or (crm == 5 and (opc2 == 4 or opc2 == 6))));
                        if (!allowed_c13 and !allowed_c7) {
                            self.enterException(.und, 0x04, inst_pc +% 4, false);
                            return;
                        }
                    }

                    if (l) {
                        const val = self.mmu.readCp15(opc1, crn, crm, opc2);
                        if (rt == 15) {
                            // MRC with Rt=15 updates CPSR NZCV flags (set Z=1 for cache test-and-clean)
                            self.cpsr = (self.cpsr & 0x0fff_ffff) | PsrFlags.Z;
                        } else {
                            self.r[rt] = val;
                        }
                    } else {
                        self.mmu.writeCp15(opc1, crn, crm, opc2, self.r[rt]);
                    }
                    return;
                }
                // MCRR / MRRC p15 (64-bit cache maintenance) -> no-op
                if ((inst & 0x0fe0_0000) == 0x0c40_0000) return;
                self.enterException(.und, 0x04, inst_pc +% 4, false);
                return;
            }

            // 3. CP10 / CP11 (VFPv2)
            if (cp_num == 10 or cp_num == 11) {
                self.executeVfp(bus, inst_pc, inst, cp_num == 11);
                return;
            }

            // Any other coprocessor traps to Undefined Instruction
            self.enterException(.und, 0x04, inst_pc +% 4, false);
        }

        fn executeVfp(self: *Self, bus: *Bus, inst_pc: u32, inst: u32, is_double: bool) void {
            // Check CPACR bits [21:20] for CP10 access permission
            const cp10_acc: u2 = @truncate((self.mmu.cpacr >> 20) & 3);
            if (cp10_acc == 0b00 or (cp10_acc == 0b01 and !self.isPrivileged())) {
                self.enterException(.und, 0x04, inst_pc +% 4, false);
                return;
            }

            // Check if this is VMRS / VMSR accessing system registers (allowed in privileged mode even when FPEXC.EN == 0)
            if ((inst & 0x0f00_0010) == 0x0e00_0010 and ((inst >> 21) & 7) == 7 and !is_double) {
                const l = (inst & (1 << 20)) != 0;
                const spec_reg: u4 = @truncate((inst >> 16) & 0xf);
                const rt: u4 = @truncate((inst >> 12) & 0xf);
                // Accessing FPSCR (spec_reg == 1) when FPEXC.EN == 0 traps to UND!
                if (!self.vfp.isEnabled() and spec_reg == 1) {
                    self.enterException(.und, 0x04, inst_pc +% 4, false);
                    return;
                }
                if (!self.isPrivileged() and spec_reg != 1) {
                    self.enterException(.und, 0x04, inst_pc +% 4, false);
                    return;
                }
                if (l) {
                    const val = self.vfp.readSysReg(spec_reg);
                    if (rt == 15) {
                        // VMRS APSR_nzcv, FPSCR
                        self.cpsr = (self.cpsr & 0x0fff_ffff) | (val & 0xf000_0000);
                    } else {
                        self.r[rt] = val;
                    }
                } else {
                    self.vfp.writeSysReg(spec_reg, self.r[rt]);
                }
                return;
            }

            // All other VFP instructions trap to UND if FPEXC.EN == 0 (Linux lazy VFP restore!)
            if (!self.vfp.isEnabled()) {
                self.enterException(.und, 0x04, inst_pc +% 4, false);
                return;
            }

            // 1. 64-bit transfers between two ARM core registers and VFP (`VMOV Dm, Rt, Rt2` / `VMOV Sm, Sm1, Rt, Rt2`)
            if ((inst & 0x0fe0_0000) == 0x0c40_0000) {
                const l = (inst & (1 << 20)) != 0;
                const rt2: u4 = @truncate((inst >> 16) & 0xf);
                const rt: u4 = @truncate((inst >> 12) & 0xf);
                if (!is_double) {
                    const sm: u5 = @truncate(((inst & 0xf) << 1) | ((inst >> 5) & 1));
                    if (l) {
                        self.r[rt] = self.vfp.s[sm];
                        if (sm < 31) self.r[rt2] = self.vfp.s[sm + 1];
                    } else {
                        self.vfp.s[sm] = self.r[rt];
                        if (sm < 31) self.vfp.s[sm + 1] = self.r[rt2];
                    }
                } else {
                    const dm: u4 = @truncate(inst & 0xf);
                    if (l) {
                        const val = self.vfp.getDU64(dm);
                        self.r[rt] = @truncate(val);
                        self.r[rt2] = @truncate(val >> 32);
                    } else {
                        const val: u64 = (@as(u64, self.r[rt2]) << 32) | self.r[rt];
                        self.vfp.setDU64(dm, val);
                    }
                }
                return;
            }

            // 2. VFP Load/Store (`VLDR`, `VSTR`, `VLDM`, `VSTM`, `VPUSH`, `VPOP`)
            if ((inst & 0x0e00_0000) == 0x0c00_0000) {
                const p = (inst & (1 << 24)) != 0;
                const u = (inst & (1 << 23)) != 0;
                const d_bit: u5 = @truncate((inst >> 22) & 1);
                const w = (inst & (1 << 21)) != 0;
                const l = (inst & (1 << 20)) != 0;
                const rn: u4 = @truncate((inst >> 16) & 0xf);
                const vd: u5 = @truncate((inst >> 12) & 0xf);
                const imm8: u32 = inst & 0xff;
                const offset_bytes = imm8 * 4;
                const base_val = self.getReg(rn, inst_pc);

                if (p and !w) {
                    // Single register VLDR / VSTR
                    const vaddr = if (u) (base_val +% offset_bytes) else (base_val -% offset_bytes);
                    if (!is_double) {
                        const sd: u5 = (vd << 1) | d_bit;
                        if (l) {
                            const val = self.read32(bus, vaddr) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return;
                            };
                            self.vfp.s[sd] = val;
                        } else {
                            self.write32(bus, vaddr, self.vfp.s[sd]) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return;
                            };
                        }
                    } else {
                        const dd: u4 = @truncate(vd);
                        if (l) {
                            const lo = self.read32(bus, vaddr) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return;
                            };
                            const hi = self.read32(bus, vaddr +% 4) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return;
                            };
                            self.vfp.setDU64(dd, (@as(u64, hi) << 32) | lo);
                        } else {
                            const val = self.vfp.getDU64(dd);
                            self.write32(bus, vaddr, @truncate(val)) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return;
                            };
                            self.write32(bus, vaddr +% 4, @truncate(val >> 32)) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return;
                            };
                        }
                    }
                    return;
                }

                // VLDM / VSTM / FLDMX / FSTMX (multiple registers)
                // Note: for FLDMX/FSTMX, imm8 may be odd (extra alignment word); the number of 32-bit float words is `imm8 & ~1` for double!
                const word_count: u32 = if (is_double) (imm8 & ~@as(u32, 1)) else imm8;
                const start_addr = if (u) base_val else (base_val -% offset_bytes);
                const final_base = if (u) (base_val +% offset_bytes) else (base_val -% offset_bytes);
                const first_s: usize = if (is_double) (@as(usize, vd) * 2) else ((@as(usize, vd) << 1) | d_bit);

                if (l) {
                    var loaded: [32]u32 = undefined;
                    for (0..word_count) |i| {
                        loaded[i] = self.read32(bus, start_addr +% @as(u32, @intCast(i * 4))) catch {
                            self.enterException(.abt, 0x10, inst_pc +% 8, false);
                            return;
                        };
                    }
                    for (0..word_count) |i| {
                        if (first_s + i < 32) self.vfp.s[first_s + i] = loaded[i];
                    }
                    if (w) self.r[rn] = final_base;
                } else {
                    if (word_count > 0) {
                        _ = self.mmu.translate(bus.ram, start_addr, .write, self.isPrivileged()) catch {
                            self.enterException(.abt, 0x10, inst_pc +% 8, false);
                            return;
                        };
                        _ = self.mmu.translate(bus.ram, start_addr +% (word_count - 1) * 4, .write, self.isPrivileged()) catch {
                            self.enterException(.abt, 0x10, inst_pc +% 8, false);
                            return;
                        };
                    }
                    for (0..word_count) |i| {
                        const val = if (first_s + i < 32) self.vfp.s[first_s + i] else 0;
                        self.write32(bus, start_addr +% @as(u32, @intCast(i * 4)), val) catch {
                            self.enterException(.abt, 0x10, inst_pc +% 8, false);
                            return;
                        };
                    }
                    if (w) self.r[rn] = final_base;
                }
                return;
            }

            // 3. 32-bit transfers between ARM core register and VFP (`VMOV Sn, Rt` / `VMOV Dm[x], Rt`)
            if ((inst & 0x0f00_0010) == 0x0e00_0010) {
                const opc1: u3 = @truncate((inst >> 21) & 7);
                const l = (inst & (1 << 20)) != 0;
                const vn: u5 = @truncate((inst >> 16) & 0xf);
                const rt: u4 = @truncate((inst >> 12) & 0xf);
                const n_bit: u5 = @truncate((inst >> 7) & 1);
                if (!is_double and opc1 == 0) {
                    const sn: u5 = (vn << 1) | n_bit;
                    if (l) self.r[rt] = self.vfp.s[sn] else self.vfp.s[sn] = self.r[rt];
                } else if (is_double and (opc1 == 0 or opc1 == 1)) {
                    const s_idx: u5 = (vn << 1) | (opc1 & 1);
                    if (l) self.r[rt] = self.vfp.s[s_idx] else self.vfp.s[s_idx] = self.r[rt];
                }
                return;
            }

            // 4. VFP Data Processing (`VADD`, `VSUB`, `VMUL`, `VDIV`, `VMLA`, `VCMP`, `VCVT`, etc.)
            if ((inst & 0x0f00_0010) == 0x0e00_0000) {
                self.vfp.executeDataProc(inst);
                return;
            }
        }

        // --- 16-bit Thumb Instruction Execution ---

        fn executeThumb(self: *Self, bus: *Bus, inst_pc: u32, inst: u16) void {
            const top3: u3 = @truncate(inst >> 13);
            switch (top3) {
                0b000 => {
                    const op: u2 = @truncate((inst >> 11) & 3);
                    const rd: u4 = @truncate(inst & 7);
                    const rm: u4 = @truncate((inst >> 3) & 7);
                    if (op != 0b11) {
                        // LSL / LSR / ASR immediate
                        const imm5: u5 = @truncate((inst >> 6) & 0x1f);
                        const carry_in: u1 = @truncate((self.cpsr >> 29) & 1);
                        const sh = dec.barrelShiftImm(self.r[rm], op, imm5, carry_in);
                        self.r[rd] = sh.val;
                        self.setNZC(sh.val, sh.carry);
                    } else {
                        // ADD / SUB (3-register or 3-bit immediate)
                        const is_imm = (inst & (1 << 10)) != 0;
                        const is_sub = (inst & (1 << 9)) != 0;
                        const rn_or_imm: u32 = @truncate((inst >> 6) & 7);
                        const op2 = if (is_imm) rn_or_imm else self.r[@as(u4, @truncate(rn_or_imm))];
                        const res = if (is_sub) dec.addWithCarry(self.r[rm], ~op2, 1) else dec.addWithCarry(self.r[rm], op2, 0);
                        self.r[rd] = res.val;
                        self.setNZCV(res);
                    }
                },
                0b001 => {
                    // MOV / CMP / ADD / SUB 8-bit immediate
                    const op: u2 = @truncate((inst >> 11) & 3);
                    const rd: u4 = @truncate((inst >> 8) & 7);
                    const imm8: u32 = inst & 0xff;
                    switch (op) {
                        0b00 => { // MOV
                            self.r[rd] = imm8;
                            self.setNZ(imm8);
                        },
                        0b01 => { // CMP
                            const res = dec.addWithCarry(self.r[rd], ~imm8, 1);
                            self.setNZCV(res);
                        },
                        0b10 => { // ADD
                            const res = dec.addWithCarry(self.r[rd], imm8, 0);
                            self.r[rd] = res.val;
                            self.setNZCV(res);
                        },
                        0b11 => { // SUB
                            const res = dec.addWithCarry(self.r[rd], ~imm8, 1);
                            self.r[rd] = res.val;
                            self.setNZCV(res);
                        },
                    }
                },
                0b010 => {
                    if ((inst & 0xfc00) == 0x4000) {
                        // Thumb ALU operations
                        const alu_op: u4 = @truncate((inst >> 6) & 0xf);
                        const rm: u4 = @truncate((inst >> 3) & 7);
                        const rd: u4 = @truncate(inst & 7);
                        const carry_in: u1 = @truncate((self.cpsr >> 29) & 1);
                        switch (alu_op) {
                            0x0 => {
                                self.r[rd] &= self.r[rm];
                                self.setNZ(self.r[rd]);
                            },
                            0x1 => {
                                self.r[rd] ^= self.r[rm];
                                self.setNZ(self.r[rd]);
                            },
                            0x2 => {
                                const sh = dec.barrelShiftReg(self.r[rd], 0b00, @truncate(self.r[rm]), carry_in);
                                self.r[rd] = sh.val;
                                self.setNZC(sh.val, sh.carry);
                            },
                            0x3 => {
                                const sh = dec.barrelShiftReg(self.r[rd], 0b01, @truncate(self.r[rm]), carry_in);
                                self.r[rd] = sh.val;
                                self.setNZC(sh.val, sh.carry);
                            },
                            0x4 => {
                                const sh = dec.barrelShiftReg(self.r[rd], 0b10, @truncate(self.r[rm]), carry_in);
                                self.r[rd] = sh.val;
                                self.setNZC(sh.val, sh.carry);
                            },
                            0x5 => {
                                const res = dec.addWithCarry(self.r[rd], self.r[rm], carry_in);
                                self.r[rd] = res.val;
                                self.setNZCV(res);
                            },
                            0x6 => {
                                const res = dec.addWithCarry(self.r[rd], ~self.r[rm], carry_in);
                                self.r[rd] = res.val;
                                self.setNZCV(res);
                            },
                            0x7 => {
                                const sh = dec.barrelShiftReg(self.r[rd], 0b11, @truncate(self.r[rm]), carry_in);
                                self.r[rd] = sh.val;
                                self.setNZC(sh.val, sh.carry);
                            },
                            0x8 => self.setNZ(self.r[rd] & self.r[rm]),
                            0x9 => {
                                const res = dec.addWithCarry(0, ~self.r[rm], 1);
                                self.r[rd] = res.val;
                                self.setNZCV(res);
                            },
                            0xa => self.setNZCV(dec.addWithCarry(self.r[rd], ~self.r[rm], 1)),
                            0xb => self.setNZCV(dec.addWithCarry(self.r[rd], self.r[rm], 0)),
                            0xc => {
                                self.r[rd] |= self.r[rm];
                                self.setNZ(self.r[rd]);
                            },
                            0xd => {
                                self.r[rd] *%= self.r[rm];
                                self.setNZ(self.r[rd]);
                            },
                            0xe => {
                                self.r[rd] &= ~self.r[rm];
                                self.setNZ(self.r[rd]);
                            },
                            0xf => {
                                self.r[rd] = ~self.r[rm];
                                self.setNZ(self.r[rd]);
                            },
                        }
                    } else if ((inst & 0xfc00) == 0x4400) {
                        // High register operations / BX / BLX
                        const op: u2 = @truncate((inst >> 8) & 3);
                        const rd: u4 = @truncate(((inst >> 4) & 8) | (inst & 7));
                        const rm: u4 = @truncate((inst >> 3) & 0xf);
                        const rm_val = if (rm == 15) (inst_pc +% 4) else self.r[rm];
                        switch (op) {
                            0b00 => { // ADD
                                const rd_val = if (rd == 15) (inst_pc +% 4) else self.r[rd];
                                const sum = rd_val +% rm_val;
                                if (rd == 15) self.r[15] = sum & ~@as(u32, 1) else self.r[rd] = sum;
                            },
                            0b01 => { // CMP
                                const rd_val = if (rd == 15) (inst_pc +% 4) else self.r[rd];
                                self.setNZCV(dec.addWithCarry(rd_val, ~rm_val, 1));
                            },
                            0b10 => { // MOV
                                if (rd == 15) self.r[15] = rm_val & ~@as(u32, 1) else self.r[rd] = rm_val;
                            },
                            0b11 => { // BX / BLX
                                if ((inst & (1 << 7)) != 0) {
                                    self.r[14] = (inst_pc +% 2) | 1;
                                }
                                self.setPcWithInterworking(rm_val);
                            },
                        }
                    } else if ((inst & 0xf800) == 0x4800) {
                        // LDR Rd, [PC, #imm8*4]
                        const rd: u4 = @truncate((inst >> 8) & 7);
                        const imm: u32 = (@as(u32, inst & 0xff)) * 4;
                        const addr = ((inst_pc +% 4) & ~@as(u32, 3)) +% imm;
                        const val = self.read32(bus, addr) catch {
                            self.enterException(.abt, 0x10, inst_pc +% 8, false);
                            return;
                        };
                        self.r[rd] = val;
                    } else {
                        // Load/Store register offset
                        const op: u3 = @truncate((inst >> 9) & 7);
                        const rm: u4 = @truncate((inst >> 6) & 7);
                        const rn: u4 = @truncate((inst >> 3) & 7);
                        const rd: u4 = @truncate(inst & 7);
                        const addr = self.r[rn] +% self.r[rm];
                        switch (op) {
                            0b000 => self.write32(bus, addr, self.r[rd]) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                            },
                            0b001 => self.write16(bus, addr, @truncate(self.r[rd])) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                            },
                            0b010 => self.write8(bus, addr, @truncate(self.r[rd])) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                            },
                            0b011 => {
                                const bval = self.read8(bus, addr) catch {
                                    self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                    return;
                                };
                                self.r[rd] = @bitCast(@as(i32, @as(i8, @bitCast(bval))));
                            },
                            0b100 => {
                                self.r[rd] = self.read32(bus, addr) catch {
                                    self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                    return;
                                };
                            },
                            0b101 => {
                                self.r[rd] = self.read16(bus, addr) catch {
                                    self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                    return;
                                };
                            },
                            0b110 => {
                                self.r[rd] = self.read8(bus, addr) catch {
                                    self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                    return;
                                };
                            },
                            0b111 => {
                                const hval = self.read16(bus, addr) catch {
                                    self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                    return;
                                };
                                self.r[rd] = @bitCast(@as(i32, @as(i16, @bitCast(hval))));
                            },
                        }
                    }
                },
                0b011 => {
                    // LDR / STR / LDRB / STRB (5-bit immediate offset)
                    const b = (inst & (1 << 12)) != 0;
                    const l = (inst & (1 << 11)) != 0;
                    const imm5: u32 = (inst >> 6) & 0x1f;
                    const rn: u4 = @truncate((inst >> 3) & 7);
                    const rd: u4 = @truncate(inst & 7);
                    const addr = self.r[rn] +% (if (b) imm5 else imm5 * 4);
                    if (l) {
                        if (b) {
                            self.r[rd] = self.read8(bus, addr) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return;
                            };
                        } else {
                            self.r[rd] = self.read32(bus, addr) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return;
                            };
                        }
                    } else {
                        if (b) {
                            self.write8(bus, addr, @truncate(self.r[rd])) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                            };
                        } else {
                            self.write32(bus, addr, self.r[rd]) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                            };
                        }
                    }
                },
                0b100 => {
                    if ((inst & (1 << 12)) == 0) {
                        // LDRH / STRH (5-bit immediate offset)
                        const l = (inst & (1 << 11)) != 0;
                        const imm5: u32 = ((inst >> 6) & 0x1f) * 2;
                        const rn: u4 = @truncate((inst >> 3) & 7);
                        const rd: u4 = @truncate(inst & 7);
                        const addr = self.r[rn] +% imm5;
                        if (l) {
                            self.r[rd] = self.read16(bus, addr) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return;
                            };
                        } else {
                            self.write16(bus, addr, @truncate(self.r[rd])) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                            };
                        }
                    } else {
                        // LDR / STR [SP, #imm8*4]
                        const l = (inst & (1 << 11)) != 0;
                        const rd: u4 = @truncate((inst >> 8) & 7);
                        const imm: u32 = (@as(u32, inst & 0xff)) * 4;
                        const addr = self.r[13] +% imm;
                        if (l) {
                            self.r[rd] = self.read32(bus, addr) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return;
                            };
                        } else {
                            self.write32(bus, addr, self.r[rd]) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                            };
                        }
                    }
                },
                0b101 => {
                    if ((inst & (1 << 12)) == 0) {
                        // ADD Rd, PC/SP, #imm8*4
                        const use_sp = (inst & (1 << 11)) != 0;
                        const rd: u4 = @truncate((inst >> 8) & 7);
                        const imm: u32 = (@as(u32, inst & 0xff)) * 4;
                        const base = if (use_sp) self.r[13] else ((inst_pc +% 4) & ~@as(u32, 3));
                        self.r[rd] = base +% imm;
                    } else {
                        // Misc 16-bit Thumb (ADD/SUB SP, SXTH/SXTB/UXTH/UXTB, PUSH/POP, REV, BKPT)
                        self.executeThumbMisc(bus, inst_pc, inst);
                    }
                },
                0b110 => {
                    if ((inst & (1 << 12)) == 0) {
                        // LDMIA / STMIA
                        const l = (inst & (1 << 11)) != 0;
                        const rn: u4 = @truncate((inst >> 8) & 7);
                        const rlist: u8 = @truncate(inst & 0xff);
                        var addr = self.r[rn];
                        if (l) {
                            var loaded: [8]u32 = undefined;
                            for (0..8) |i| {
                                if ((rlist & (@as(u8, 1) << @intCast(i))) != 0) {
                                    loaded[i] = self.read32(bus, addr) catch {
                                        self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                        return;
                                    };
                                    addr +%= 4;
                                }
                            }
                            self.r[rn] = addr;
                            for (0..8) |i| {
                                if ((rlist & (@as(u8, 1) << @intCast(i))) != 0) self.r[i] = loaded[i];
                            }
                        } else {
                            for (0..8) |i| {
                                if ((rlist & (@as(u8, 1) << @intCast(i))) != 0) {
                                    self.write32(bus, addr, self.r[i]) catch {
                                        self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                        return;
                                    };
                                    addr +%= 4;
                                }
                            }
                            self.r[rn] = addr;
                        }
                    } else {
                        const cond: u4 = @truncate((inst >> 8) & 0xf);
                        if (cond == 0xf) {
                            // SVC (Thumb)
                            self.enterException(.svc, 0x08, inst_pc +% 2, false);
                        } else if (cond == 0xe) {
                            // Permanently undefined
                            self.enterException(.und, 0x04, inst_pc +% 2, false);
                        } else if (dec.checkCond(cond, self.cpsr)) {
                            const imm8: i8 = @bitCast(@as(u8, @truncate(inst)));
                            const offset: u32 = @bitCast(@as(i32, imm8) * 2);
                            self.r[15] = (inst_pc +% 4) +% offset;
                        }
                    }
                },
                0b111 => {
                    const op: u2 = @truncate((inst >> 11) & 3);
                    const imm11: u32 = inst & 0x7ff;
                    switch (op) {
                        0b00 => { // Unconditional B
                            const s11: i11 = @bitCast(@as(u11, @truncate(imm11)));
                            const offset: u32 = @bitCast(@as(i32, s11) * 2);
                            self.r[15] = (inst_pc +% 4) +% offset;
                        },
                        0b10 => { // BL / BLX prefix (high offset)
                            const s11: i11 = @bitCast(@as(u11, @truncate(imm11)));
                            const offset: u32 = @bitCast(@as(i32, s11) << 12);
                            self.r[14] = (inst_pc +% 4) +% offset;
                        },
                        0b11 => { // BL suffix
                            const target = (self.r[14] +% (imm11 << 1)) & ~@as(u32, 1);
                            self.r[14] = (inst_pc +% 2) | 1;
                            self.r[15] = target;
                        },
                        0b01 => { // BLX suffix (switch to ARM state)
                            const target = (self.r[14] +% (imm11 << 1)) & ~@as(u32, 3);
                            self.r[14] = (inst_pc +% 2) | 1;
                            self.cpsr &= ~PsrFlags.T;
                            self.r[15] = target;
                        },
                    }
                },
            }
        }

        fn executeThumbMisc(self: *Self, bus: *Bus, inst_pc: u32, inst: u16) void {
            const sub: u4 = @truncate((inst >> 8) & 0xf);
            switch (sub) {
                0b0000 => { // ADD/SUB SP, #imm7*4
                    const imm: u32 = (@as(u32, inst & 0x7f)) * 4;
                    if ((inst & 0x80) != 0) self.r[13] -%= imm else self.r[13] +%= imm;
                },
                0b0010 => { // SXTH / SXTB / UXTH / UXTB
                    const op: u2 = @truncate((inst >> 6) & 3);
                    const rm: u4 = @truncate((inst >> 3) & 7);
                    const rd: u4 = @truncate(inst & 7);
                    const val = self.r[rm];
                    self.r[rd] = switch (op) {
                        0b00 => @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(val)))))),
                        0b01 => @bitCast(@as(i32, @as(i8, @bitCast(@as(u8, @truncate(val)))))),
                        0b10 => @as(u16, @truncate(val)),
                        0b11 => @as(u8, @truncate(val)),
                    };
                },
                0b0100, 0b0101 => { // PUSH
                    const push_lr = (sub & 1) != 0;
                    const rlist: u8 = @truncate(inst & 0xff);
                    const count: u32 = @as(u32, @popCount(rlist)) + @intFromBool(push_lr);
                    const start_sp = self.r[13] -% (count * 4);
                    var addr = start_sp;
                    for (0..8) |i| {
                        if ((rlist & (@as(u8, 1) << @intCast(i))) != 0) {
                            self.write32(bus, addr, self.r[i]) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return;
                            };
                            addr +%= 4;
                        }
                    }
                    if (push_lr) {
                        self.write32(bus, addr, self.r[14]) catch {
                            self.enterException(.abt, 0x10, inst_pc +% 8, false);
                            return;
                        };
                    }
                    self.r[13] = start_sp;
                },
                0b1010 => { // REV / REV16 / REVSH
                    const op: u2 = @truncate((inst >> 6) & 3);
                    const rm: u4 = @truncate((inst >> 3) & 7);
                    const rd: u4 = @truncate(inst & 7);
                    const val = self.r[rm];
                    self.r[rd] = switch (op) {
                        0b00 => @byteSwap(val),
                        0b01 => (@as(u32, @byteSwap(@as(u16, @truncate(val >> 16)))) << 16) | @byteSwap(@as(u16, @truncate(val))),
                        0b11 => @bitCast(@as(i32, @as(i16, @bitCast(@byteSwap(@as(u16, @truncate(val))))))),
                        else => val,
                    };
                },
                0b1100, 0b1101 => { // POP
                    const pop_pc = (sub & 1) != 0;
                    const rlist: u8 = @truncate(inst & 0xff);
                    var addr = self.r[13];
                    var loaded: [8]u32 = undefined;
                    for (0..8) |i| {
                        if ((rlist & (@as(u8, 1) << @intCast(i))) != 0) {
                            loaded[i] = self.read32(bus, addr) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return;
                            };
                            addr +%= 4;
                        }
                    }
                    var new_pc: u32 = 0;
                    if (pop_pc) {
                        new_pc = self.read32(bus, addr) catch {
                            self.enterException(.abt, 0x10, inst_pc +% 8, false);
                            return;
                        };
                        addr +%= 4;
                    }
                    self.r[13] = addr;
                    for (0..8) |i| {
                        if ((rlist & (@as(u8, 1) << @intCast(i))) != 0) self.r[i] = loaded[i];
                    }
                    if (pop_pc) self.setPcWithInterworking(new_pc);
                },
                else => {},
            }
        }

        inline fn setNZ(self: *Self, val: u32) void {
            const n: u32 = val & PsrFlags.N;
            const z: u32 = if (val == 0) PsrFlags.Z else 0;
            self.cpsr = (self.cpsr & ~(PsrFlags.N | PsrFlags.Z)) | n | z;
        }

        inline fn setNZ64(self: *Self, val: u64) void {
            const n: u32 = @truncate((val >> 32) & PsrFlags.N);
            const z: u32 = if (val == 0) PsrFlags.Z else 0;
            self.cpsr = (self.cpsr & ~(PsrFlags.N | PsrFlags.Z)) | n | z;
        }

        inline fn setNZC(self: *Self, val: u32, carry: u1) void {
            const n: u32 = val & PsrFlags.N;
            const z: u32 = if (val == 0) PsrFlags.Z else 0;
            const c: u32 = @as(u32, carry) << 29;
            self.cpsr = (self.cpsr & ~(PsrFlags.N | PsrFlags.Z | PsrFlags.C)) | n | z | c;
        }

        inline fn setNZCV(self: *Self, res: dec.AddSubResult) void {
            const nzcv: u32 = (@as(u32, res.n) << 31) |
                (@as(u32, res.z) << 30) |
                (@as(u32, res.c) << 29) |
                (@as(u32, res.v) << 28);
            self.cpsr = (self.cpsr & 0x0fff_ffff) | nzcv;
        }
    };
}

test "ARM1176 data processing, load/store, banked modes, and exceptions" {
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
    const Cpu = Arm1176(TestBus);
    var cpu: Cpu = .{};
    cpu.initReset(0x1000, 0, 0xffffffff, 0x2000);

    // Program at 0x1000:
    // 0x1000: mov r0, #42       (0xe3a0002a)
    // 0x1004: add r1, r0, #58   (0xe280103a)
    // 0x1008: str r1, [r2, #4]  (0xe5821004)
    // 0x100c: ldr r3, [r2, #4]  (0xe5923004)
    // 0x1010: rev r4, r3        (0xe6bf4f33)
    const prog = [_]u32{
        0xe3a0002a,
        0xe280103a,
        0xe5821004,
        0xe5923004,
        0xe6bf4f33,
    };
    for (prog, 0..) |inst, i| {
        std.mem.writeInt(u32, ram[0x1000 + i * 4 ..][0..4], inst, .little);
    }

    _ = cpu.runSteps(&bus, 5);
    try std.testing.expectEqual(@as(u32, 42), cpu.r[0]);
    try std.testing.expectEqual(@as(u32, 100), cpu.r[1]);
    try std.testing.expectEqual(@as(u32, 100), cpu.r[3]);
    try std.testing.expectEqual(@as(u32, 0x64000000), cpu.r[4]);
}
