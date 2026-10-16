//! ARM1176JZF-S VFPv2 & Cortex-A53 VFPv4 Floating-Point Coprocessor (CP10 & CP11).
//!
//! Implements the VFPv2/VFPv3/VFPv4 register file (`s0..s31` and `d0..d31`),
//! system registers (`FPSID`, `FPSCR`, `FPEXC`, `FPINST`, `FPINST2`, `MVFR0`, `MVFR1`),
//! lazy context switch trap semantics (`FPEXC.EN` & `CPACR`), single/double-precision
//! arithmetic, VFPv3 `VMOV (immediate)`, VFPv4 fused multiply-accumulate (`VFMA`/`VFMS`/
//! `VFNMA`/`VFNMS`), conversions, comparisons, and load/store multiple operations.

const std = @import("std");

pub const Vfp = struct {
    /// 64 32-bit words backing `s0..s31` (first 32 words) and `d0..d31` (all 64 words)
    s: [64]u32 = @splat(0),
    /// 32 128-bit SIMD/FP registers `V0..V31` (`Q0..Q31` / `D0..D31` / `S0..S31`) for AArch64
    v: [32]u128 = @splat(0),

    /// True when emulating Cortex-A53 VFPv4-D32 instead of ARM1176 VFPv2-D16
    is_vfpv4: bool = false,

    /// Floating-Point System ID Register
    fpsid: u32 = 0x410120b5,
    /// Floating-Point Status and Control Register
    fpscr: u32 = 0,
    /// AArch64 Floating-Point Control Register & Status Register
    fpcr64: u64 = 0,
    fpsr64: u64 = 0,
    /// Floating-Point Exception Control Register (bit 30 = EN)
    fpexc: u32 = 0,
    fpinst: u32 = 0,
    fpinst2: u32 = 0,

    pub inline fn isEnabled(self: *const Vfp) bool {
        return (self.fpexc & (1 << 30)) != 0;
    }

    pub inline fn getS(self: *const Vfp, idx: u5) f32 {
        return @bitCast(self.s[idx]);
    }

    pub inline fn setS(self: *Vfp, idx: u5, val: f32) void {
        self.s[idx] = @bitCast(val);
    }

    pub inline fn getD(self: *const Vfp, idx: u5) f64 {
        const base: usize = @as(usize, idx) * 2;
        const lo: u64 = self.s[base];
        const hi: u64 = self.s[base + 1];
        return @bitCast((hi << 32) | lo);
    }

    pub inline fn setD(self: *Vfp, idx: u5, val: f64) void {
        const base: usize = @as(usize, idx) * 2;
        const bits: u64 = @bitCast(val);
        self.s[base] = @truncate(bits);
        self.s[base + 1] = @truncate(bits >> 32);
    }

    pub inline fn getDU64(self: *const Vfp, idx: u5) u64 {
        const base: usize = @as(usize, idx) * 2;
        const lo: u64 = self.s[base];
        const hi: u64 = self.s[base + 1];
        return (hi << 32) | lo;
    }

    pub inline fn setDU64(self: *Vfp, idx: u5, bits: u64) void {
        const base: usize = @as(usize, idx) * 2;
        self.s[base] = @truncate(bits);
        self.s[base + 1] = @truncate(bits >> 32);
    }

    pub fn readSysReg(self: *const Vfp, reg: u4) u32 {
        return switch (reg) {
            0 => if (self.is_vfpv4) 0x410340f4 else self.fpsid,
            1 => self.fpscr,
            6 => if (self.is_vfpv4) 0x10000011 else 0x00000000, // MVFR1 (FMA = VFPv4)
            7 => if (self.is_vfpv4) 0x10110222 else 0x11110222, // MVFR0 (A_SIMD=2 -> 32 D regs)
            8 => self.fpexc,
            9 => self.fpinst,
            10 => self.fpinst2,
            else => 0,
        };
    }

    pub fn writeSysReg(self: *Vfp, reg: u4, val: u32) void {
        switch (reg) {
            1 => self.fpscr = val,
            8 => self.fpexc = val,
            9 => self.fpinst = val,
            10 => self.fpinst2 = val,
            else => {},
        }
    }

    pub inline fn updateCmpFlags(self: *Vfp, comptime T: type, a: T, b: T) void {
        var nzcv: u32 = 0;
        if (std.math.isNan(a) or std.math.isNan(b)) {
            // Unordered: N=0, Z=0, C=1, V=1
            nzcv = 0b0011;
        } else if (a == b) {
            // Equal: N=0, Z=1, C=1, V=0
            nzcv = 0b0110;
        } else if (a < b) {
            // Less than: N=1, Z=0, C=0, V=0
            nzcv = 0b1000;
        } else {
            // Greater than: N=0, Z=0, C=1, V=0
            nzcv = 0b0010;
        }
        self.fpscr = (self.fpscr & 0x0fff_ffff) | (nzcv << 28);
    }

    fn floatToSignedInt(comptime T: type, val: T, round_zero: bool, fpscr: u32) i32 {
        if (std.math.isNan(val)) return 0;
        const r = if (round_zero) @trunc(val) else switch ((fpscr >> 22) & 3) {
            0 => @round(val), // RN (nearest)
            1 => @ceil(val), // RP (+inf)
            2 => @floor(val), // RM (-inf)
            3 => @trunc(val), // RZ (zero)
            else => unreachable,
        };
        if (r >= 2147483647.0) return std.math.maxInt(i32);
        if (r <= -2147483648.0) return std.math.minInt(i32);
        return @intFromFloat(r);
    }

    fn floatToUnsignedInt(comptime T: type, val: T, round_zero: bool, fpscr: u32) u32 {
        if (std.math.isNan(val) or val <= 0.0) return 0;
        const r = if (round_zero) @trunc(val) else switch ((fpscr >> 22) & 3) {
            0 => @round(val),
            1 => @ceil(val),
            2 => @floor(val),
            3 => @trunc(val),
            else => unreachable,
        };
        if (r >= 4294967295.0) return std.math.maxInt(u32);
        return @intFromFloat(r);
    }

    pub fn expandImmF32(imm8: u8) f32 {
        const sign: u32 = (imm8 >> 7) & 1;
        const not_b6: u32 = ((imm8 >> 6) & 1) ^ 1;
        const exp: u32 = (not_b6 << 7) | (if (not_b6 == 0) @as(u32, 0x1f << 2) else 0) | ((imm8 >> 4) & 3);
        const frac: u32 = (@as(u32, imm8 & 0xf)) << 19;
        return @bitCast((sign << 31) | (exp << 23) | frac);
    }

    pub fn expandImmF64(imm8: u8) f64 {
        const sign: u64 = (imm8 >> 7) & 1;
        const not_b6: u64 = ((imm8 >> 6) & 1) ^ 1;
        const exp: u64 = (not_b6 << 10) | (if (not_b6 == 0) @as(u64, 0xff << 2) else 0) | ((imm8 >> 4) & 3);
        const frac: u64 = (@as(u64, imm8 & 0xf)) << 48;
        return @bitCast((sign << 63) | (exp << 52) | frac);
    }

    /// Executes a VFP data processing instruction (`(inst & 0x0f00_0010) == 0x0e00_0000`).
    pub fn executeDataProc(self: *Vfp, inst: u32) void {
        const is_double = ((inst >> 8) & 0xf) == 11;
        const p: u4 = @truncate((inst >> 23) & 1);
        const q: u4 = @truncate((inst >> 21) & 1);
        const r: u4 = @truncate((inst >> 20) & 1);
        const s: u4 = @truncate((inst >> 6) & 1);
        const op4: u4 = (p << 3) | (q << 2) | (r << 1) | s;

        const sd: u5 = @truncate((((inst >> 12) & 0xf) << 1) | ((inst >> 22) & 1));
        const sn: u5 = @truncate((((inst >> 16) & 0xf) << 1) | ((inst >> 7) & 1));
        const sm: u5 = @truncate(((inst & 0xf) << 1) | ((inst >> 5) & 1));

        const dd: u5 = @truncate((((inst >> 22) & 1) << 4) | ((inst >> 12) & 0xf));
        const dn: u5 = @truncate((((inst >> 7) & 1) << 4) | ((inst >> 16) & 0xf));
        const dm: u5 = @truncate((((inst >> 5) & 1) << 4) | (inst & 0xf));

        if (op4 == 0b1110) {
            // VFPv3 VMOV (immediate)
            const imm8: u8 = @truncate((((inst >> 16) & 0xf) << 4) | (inst & 0xf));
            if (!is_double) {
                self.setS(sd, expandImmF32(imm8));
            } else {
                self.setD(dd, expandImmF64(imm8));
            }
            return;
        }

        if (op4 != 0b1111) {
            // Binary operations
            if (!is_double) {
                const a = self.getS(sn);
                const b = self.getS(sm);
                const d = self.getS(sd);
                const res: f32 = switch (op4) {
                    0b0000 => d + (a * b), // VMLA
                    0b0001 => d - (a * b), // VMLS
                    0b0010 => -d + (a * b), // VNMLS
                    0b0011 => -(d + (a * b)), // VNMLA
                    0b0100 => a * b, // VMUL
                    0b0101 => -(a * b), // VNMUL
                    0b0110 => a + b, // VADD
                    0b0111 => a - b, // VSUB
                    0b1000 => a / b, // VDIV
                    0b1010 => @mulAdd(f32, a, b, -d), // VFNMS
                    0b1011 => @mulAdd(f32, -a, b, -d), // VFNMA
                    0b1100 => @mulAdd(f32, a, b, d), // VFMA
                    0b1101 => @mulAdd(f32, -a, b, d), // VFMS
                    else => d,
                };
                self.setS(sd, res);
            } else {
                const a = self.getD(dn);
                const b = self.getD(dm);
                const d = self.getD(dd);
                const res: f64 = switch (op4) {
                    0b0000 => d + (a * b),
                    0b0001 => d - (a * b),
                    0b0010 => -d + (a * b),
                    0b0011 => -(d + (a * b)),
                    0b0100 => a * b,
                    0b0101 => -(a * b),
                    0b0110 => a + b,
                    0b0111 => a - b,
                    0b1000 => a / b,
                    0b1010 => @mulAdd(f64, a, b, -d), // VFNMS
                    0b1011 => @mulAdd(f64, -a, b, -d), // VFNMA
                    0b1100 => @mulAdd(f64, a, b, d), // VFMA
                    0b1101 => @mulAdd(f64, -a, b, d), // VFMS
                    else => d,
                };
                self.setD(dd, res);
            }
            return;
        }

        // Extension operations (op4 == 0b1111), sub-opcode in Sn (5 bits)
        switch (sn) {
            0b00000 => {
                // VMOV (register)
                if (!is_double) self.s[sd] = self.s[sm] else self.setDU64(dd, self.getDU64(dm));
            },
            0b00001 => {
                // VABS
                if (!is_double) self.setS(sd, @abs(self.getS(sm))) else self.setD(dd, @abs(self.getD(dm)));
            },
            0b00010 => {
                // VNEG
                if (!is_double) self.setS(sd, -self.getS(sm)) else self.setD(dd, -self.getD(dm));
            },
            0b00011 => {
                // VSQRT
                if (!is_double) self.setS(sd, @sqrt(self.getS(sm))) else self.setD(dd, @sqrt(self.getD(dm)));
            },
            0b01000, 0b01001 => {
                // VCMP / VCMPE (register)
                if (!is_double) {
                    self.updateCmpFlags(f32, self.getS(sd), self.getS(sm));
                } else {
                    self.updateCmpFlags(f64, self.getD(dd), self.getD(dm));
                }
            },
            0b01010, 0b01011 => {
                // VCMP / VCMPE (#0.0)
                if (!is_double) {
                    self.updateCmpFlags(f32, self.getS(sd), 0.0);
                } else {
                    self.updateCmpFlags(f64, self.getD(dd), 0.0);
                }
            },
            0b01111 => {
                // VCVT.F64.F32 / VCVT.F32.F64
                if (!is_double) {
                    // Single -> Double: VCVT.F64.F32 Dd, Sm
                    const val: f64 = @floatCast(self.getS(sm));
                    self.setD(dd, val);
                } else {
                    // Double -> Single: VCVT.F32.F64 Sd, Dm
                    const val: f32 = @floatCast(self.getD(dm));
                    self.setS(sd, val);
                }
            },
            0b10000 => {
                // VCVT.F32.U32 / VCVT.F64.U32 (unsigned int in Sm -> float/double)
                const uval: u32 = self.s[sm];
                if (!is_double) {
                    self.setS(sd, @floatFromInt(uval));
                } else {
                    self.setD(dd, @floatFromInt(uval));
                }
            },
            0b10001 => {
                // VCVT.F32.S32 / VCVT.F64.S32 (signed int in Sm -> float/double)
                const ival: i32 = @bitCast(self.s[sm]);
                if (!is_double) {
                    self.setS(sd, @floatFromInt(ival));
                } else {
                    self.setD(dd, @floatFromInt(ival));
                }
            },
            0b11000, 0b11001 => {
                // VCVT.U32.F32 / VCVT.U32.F64 (sn == 0b11000 rounds per FPSCR, sn == 0b11001 rounds towards zero)
                const round_zero = (sn & 1) != 0;
                const ures = if (!is_double)
                    floatToUnsignedInt(f32, self.getS(sm), round_zero, self.fpscr)
                else
                    floatToUnsignedInt(f64, self.getD(dm), round_zero, self.fpscr);
                self.s[sd] = ures;
            },
            0b11010, 0b11011 => {
                // VCVT.S32.F32 / VCVT.S32.F64
                const round_zero = (sn & 1) != 0;
                const ires = if (!is_double)
                    floatToSignedInt(f32, self.getS(sm), round_zero, self.fpscr)
                else
                    floatToSignedInt(f64, self.getD(dm), round_zero, self.fpscr);
                self.s[sd] = @bitCast(ires);
            },
            else => {},
        }
    }
};

test "VFPv2/VFPv4 single and double precision operations, D16..D31, and VMOV immediate" {
    var vfp: Vfp = .{ .is_vfpv4 = true };
    vfp.fpexc = 1 << 30;
    vfp.setS(0, 3.5);
    vfp.setS(1, 2.0);
    // VADD.F32 s2, s0, s1: 0xee301a20 -> sd=2 (Vd=1, D=0), sn=0 (Vn=0, N=0), sm=1 (Vm=0, M=1)
    const vadd_s2_s0_s1: u32 = 0xee30_1a20;
    vfp.executeDataProc(vadd_s2_s0_s1);
    try std.testing.expectEqual(@as(f32, 5.5), vfp.getS(2));

    // VCVT.F64.F32 d3, s2: 0xeeb73ac1 (op4=1111, sn=01111 -> Vn=7, N=1, dd=3, sm=2 -> Vm=1, M=0)
    const vcvt_d3_s2: u32 = 0xeeb7_3ac1;
    vfp.executeDataProc(vcvt_d3_s2);
    try std.testing.expectEqual(@as(f64, 5.5), vfp.getD(3));

    // VMOV.F64 d16, #1.0 (imm8 = 0x70 -> Vn=7, Vm=0, D=1, Vd=0 -> 0xeef70b00)
    vfp.executeDataProc(0xeef7_0b00);
    try std.testing.expectEqual(@as(f64, 1.0), vfp.getD(16));
}
