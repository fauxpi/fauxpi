//! ARMv6K & Thumb-1 instruction decoding and arithmetic helpers.

const std = @import("std");

pub const PsrFlags = struct {
    pub const N: u32 = 1 << 31;
    pub const Z: u32 = 1 << 30;
    pub const C: u32 = 1 << 29;
    pub const V: u32 = 1 << 28;
    pub const Q: u32 = 1 << 27;
    pub const GE_MASK: u32 = 0x000f_0000;
    pub const E: u32 = 1 << 9;
    pub const A: u32 = 1 << 8;
    pub const I: u32 = 1 << 7;
    pub const F: u32 = 1 << 6;
    pub const T: u32 = 1 << 5;
    pub const MODE_MASK: u32 = 0x1f;
};

/// Evaluates the 4-bit ARM condition code `cond` against `cpsr`.
pub inline fn checkCond(cond: u4, cpsr: u32) bool {
    if (cond == 0xe) return true; // AL (fast path)
    const n = (cpsr >> 31) & 1;
    const z = (cpsr >> 30) & 1;
    const c = (cpsr >> 29) & 1;
    const v = (cpsr >> 28) & 1;
    return switch (cond) {
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
        0xe => true, // AL
        0xf => true, // Unconditional space
    };
}

pub const ShiftResult = struct {
    val: u32,
    carry: u1,
};

/// Barrel shifter for immediate shift amounts (`shift_imm` in `0..31`).
pub inline fn barrelShiftImm(rm_val: u32, shift_type: u2, shift_imm: u5, carry_in: u1) ShiftResult {
    switch (shift_type) {
        0b00 => { // LSL
            if (shift_imm == 0) return .{ .val = rm_val, .carry = carry_in };
            const inv: u5 = @truncate(@as(u6, 32) -% shift_imm);
            return .{
                .val = rm_val << shift_imm,
                .carry = @truncate(rm_val >> inv),
            };
        },
        0b01 => { // LSR
            if (shift_imm == 0) {
                // LSR #32
                return .{ .val = 0, .carry = @truncate(rm_val >> 31) };
            }
            const m1: u5 = shift_imm -% 1;
            return .{
                .val = rm_val >> shift_imm,
                .carry = @truncate(rm_val >> m1),
            };
        },
        0b10 => { // ASR
            if (shift_imm == 0) {
                // ASR #32
                const sign: u1 = @truncate(rm_val >> 31);
                return .{ .val = if (sign == 1) 0xffff_ffff else 0, .carry = sign };
            }
            const m1: u5 = shift_imm -% 1;
            const sval: i32 = @bitCast(rm_val);
            return .{
                .val = @bitCast(sval >> shift_imm),
                .carry = @truncate(rm_val >> m1),
            };
        },
        0b11 => { // ROR / RRX
            if (shift_imm == 0) {
                // RRX #1
                return .{
                    .val = (@as(u32, carry_in) << 31) | (rm_val >> 1),
                    .carry = @truncate(rm_val),
                };
            }
            const m1: u5 = shift_imm -% 1;
            return .{
                .val = std.math.rotr(u32, rm_val, shift_imm),
                .carry = @truncate(rm_val >> m1),
            };
        },
    }
}

/// Barrel shifter for register-specified shift amounts (`rs_val & 0xff`).
pub inline fn barrelShiftReg(rm_val: u32, shift_type: u2, rs_byte: u8, carry_in: u1) ShiftResult {
    if (rs_byte == 0) return .{ .val = rm_val, .carry = carry_in };
    switch (shift_type) {
        0b00 => { // LSL
            if (rs_byte < 32) {
                const sh: u5 = @truncate(rs_byte);
                const inv: u5 = @truncate(32 -% rs_byte);
                return .{ .val = rm_val << sh, .carry = @truncate(rm_val >> inv) };
            } else if (rs_byte == 32) {
                return .{ .val = 0, .carry = @truncate(rm_val) };
            } else {
                return .{ .val = 0, .carry = 0 };
            }
        },
        0b01 => { // LSR
            if (rs_byte < 32) {
                const sh: u5 = @truncate(rs_byte);
                const m1: u5 = @truncate(rs_byte -% 1);
                return .{ .val = rm_val >> sh, .carry = @truncate(rm_val >> m1) };
            } else if (rs_byte == 32) {
                return .{ .val = 0, .carry = @truncate(rm_val >> 31) };
            } else {
                return .{ .val = 0, .carry = 0 };
            }
        },
        0b10 => { // ASR
            if (rs_byte < 32) {
                const sh: u5 = @truncate(rs_byte);
                const m1: u5 = @truncate(rs_byte -% 1);
                const sval: i32 = @bitCast(rm_val);
                return .{ .val = @bitCast(sval >> sh), .carry = @truncate(rm_val >> m1) };
            } else {
                const sign: u1 = @truncate(rm_val >> 31);
                return .{ .val = if (sign == 1) 0xffff_ffff else 0, .carry = sign };
            }
        },
        0b11 => { // ROR
            const rot5: u5 = @truncate(rs_byte & 31);
            if (rot5 == 0) {
                return .{ .val = rm_val, .carry = @truncate(rm_val >> 31) };
            }
            const m1: u5 = rot5 -% 1;
            return .{
                .val = std.math.rotr(u32, rm_val, rot5),
                .carry = @truncate(rm_val >> m1),
            };
        },
    }
}

pub const AddSubResult = struct {
    val: u32,
    n: u1,
    z: u1,
    c: u1,
    v: u1,
};

pub inline fn addWithCarry(a: u32, b: u32, carry_in: u1) AddSubResult {
    const ua: u64 = a;
    const ub: u64 = b;
    const uc: u64 = carry_in;
    const usum: u64 = ua + ub + uc;
    const res: u32 = @truncate(usum);
    const c_out: u1 = @truncate(usum >> 32);

    const sa: i64 = @as(i32, @bitCast(a));
    const sb: i64 = @as(i32, @bitCast(b));
    const ssum: i64 = sa + sb + @as(i64, carry_in);
    const sres: i64 = @as(i32, @bitCast(res));
    const v_out: u1 = if (ssum != sres) 1 else 0;

    return .{
        .val = res,
        .n = @truncate(res >> 31),
        .z = if (res == 0) 1 else 0,
        .c = c_out,
        .v = v_out,
    };
}

/// ARMv6 media instructions (`(inst & 0x0e00_0010) == 0x0600_0010`).
pub fn executeMedia(inst: u32, r_rn: u32, r_rm: u32, r_rd: u32, r_ra: u32, cpsr: *u32) ?u32 {
    const op1: u5 = @truncate((inst >> 20) & 0x1f);
    const op2: u3 = @truncate((inst >> 5) & 0x7);

    // 1. Parallel add/subtract (`op1[4:3] == 0b00`)
    if ((op1 & 0b11000) == 0b00000) {
        return executeParallelAddSub(op1, op2, r_rn, r_rm, cpsr);
    }

    // 2. Packing, unpacking, saturation, reversal (`op1[4:3] == 0b01`)
    if ((op1 & 0b11000) == 0b01000) {
        const sub_op = op1 & 0b00111;
        switch (sub_op) {
            0b000 => {
                if ((op2 & 1) == 0) {
                    // PKHBT / PKHTB
                    const tb = (op2 & 0b010) != 0;
                    const sh: u5 = @truncate((inst >> 7) & 0x1f);
                    if (!tb) {
                        // PKHBT: low half of Rn, high half of (Rm << sh)
                        const hi = (r_rm << sh) & 0xffff_0000;
                        return (r_rn & 0x0000_ffff) | hi;
                    } else {
                        // PKHTB: high half of Rn, low half of (Rm asr sh)
                        const sval: i32 = @bitCast(r_rm);
                        const shifted: u32 = if (sh == 0) (if (sval < 0) 0xffff_ffff else 0) else @bitCast(sval >> sh);
                        return (r_rn & 0xffff_0000) | (shifted & 0x0000_ffff);
                    }
                } else if (op2 == 0b101) {
                    // SEL: select bytes according to CPSR.GE[3:0]
                    const ge = (cpsr.* >> 16) & 0xf;
                    var out: u32 = 0;
                    inline for (0..4) |i| {
                        const shift: u5 = @intCast(i * 8);
                        const mask: u32 = @as(u32, 0xff) << shift;
                        const src = if (((ge >> @intCast(i)) & 1) != 0) r_rn else r_rm;
                        out |= src & mask;
                    }
                    return out;
                } else if (op2 == 0b011) {
                    // SXTAB16
                    const rot: u5 = @as(u5, @truncate((inst >> 10) & 3)) * 8;
                    const rot_rm = std.math.rotr(u32, r_rm, rot);
                    const b0: i16 = @as(i8, @bitCast(@as(u8, @truncate(rot_rm))));
                    const b2: i16 = @as(i8, @bitCast(@as(u8, @truncate(rot_rm >> 16))));
                    const rn_lo: u16 = @truncate(r_rn);
                    const rn_hi: u16 = @truncate(r_rn >> 16);
                    const lo: u16 = rn_lo +% @as(u16, @bitCast(b0));
                    const hi: u16 = rn_hi +% @as(u16, @bitCast(b2));
                    return (@as(u32, hi) << 16) | lo;
                }
            },
            0b010, 0b011 => {
                // SSAT / SSAT16
                if (sub_op == 0b010 and op2 == 0b001) {
                    // SSAT16
                    const sat_imm: u5 = @truncate((inst >> 16) & 0xf); // sat_imm + 1 bits (1..16)
                    const max_v: i32 = (@as(i32, 1) << sat_imm) - 1;
                    const min_v: i32 = -(@as(i32, 1) << sat_imm);
                    const lo_in: i32 = @as(i16, @bitCast(@as(u16, @truncate(r_rm))));
                    const hi_in: i32 = @as(i16, @bitCast(@as(u16, @truncate(r_rm >> 16))));
                    var q_set = false;
                    const lo_sat: i16 = @intCast(clampSat(lo_in, min_v, max_v, &q_set));
                    const hi_sat: i16 = @intCast(clampSat(hi_in, min_v, max_v, &q_set));
                    if (q_set) cpsr.* |= PsrFlags.Q;
                    return (@as(u32, @as(u16, @bitCast(hi_sat))) << 16) | @as(u16, @bitCast(lo_sat));
                } else if (sub_op == 0b010 and op2 == 0b011) {
                    // SXTAB
                    const rot: u5 = @as(u5, @truncate((inst >> 10) & 3)) * 8;
                    const rot_rm = std.math.rotr(u32, r_rm, rot);
                    const sext: i32 = @as(i8, @bitCast(@as(u8, @truncate(rot_rm))));
                    return r_rn +% @as(u32, @bitCast(sext));
                } else if (sub_op == 0b011 and op2 == 0b001) {
                    // REV
                    if (((inst >> 16) & 0xf) == 0xf) return @byteSwap(r_rm);
                } else if (sub_op == 0b011 and op2 == 0b101) {
                    // REV16
                    const lo: u16 = @byteSwap(@as(u16, @truncate(r_rm)));
                    const hi: u16 = @byteSwap(@as(u16, @truncate(r_rm >> 16)));
                    return (@as(u32, hi) << 16) | lo;
                } else if (sub_op == 0b011 and op2 == 0b011) {
                    // SXTAH
                    const rot: u5 = @as(u5, @truncate((inst >> 10) & 3)) * 8;
                    const rot_rm = std.math.rotr(u32, r_rm, rot);
                    const sext: i32 = @as(i16, @bitCast(@as(u16, @truncate(rot_rm))));
                    return r_rn +% @as(u32, @bitCast(sext));
                }
                // SSAT (when op2 & 1 == 0)
                if ((op2 & 1) == 0) {
                    const sat_bit: u5 = @truncate(((inst >> 16) & 0x1f)); // saturates to (sat_bit + 1)-bit signed
                    const sh: u5 = @truncate((inst >> 7) & 0x1f);
                    const asr = (op2 & 0b010) != 0;
                    const sval: i32 = @bitCast(r_rm);
                    const shifted: i32 = if (!asr) (sval << sh) else if (sh == 0) (if (sval < 0) -1 else 0) else (sval >> sh);
                    if (sat_bit == 31) return @bitCast(shifted);
                    const max_v: i32 = (@as(i32, 1) << sat_bit) - 1;
                    const min_v: i32 = -(@as(i32, 1) << sat_bit);
                    var q_set = false;
                    const res = clampSat(shifted, min_v, max_v, &q_set);
                    if (q_set) cpsr.* |= PsrFlags.Q;
                    return @bitCast(res);
                }
            },
            0b100 => {
                if (op2 == 0b011) {
                    // UXTAB16
                    const rot: u5 = @as(u5, @truncate((inst >> 10) & 3)) * 8;
                    const rot_rm = std.math.rotr(u32, r_rm, rot);
                    const b0: u16 = @as(u8, @truncate(rot_rm));
                    const b2: u16 = @as(u8, @truncate(rot_rm >> 16));
                    const rn_lo: u16 = @truncate(r_rn);
                    const rn_hi: u16 = @truncate(r_rn >> 16);
                    return (@as(u32, rn_hi +% b2) << 16) | (rn_lo +% b0);
                }
            },
            0b110, 0b111 => {
                if (sub_op == 0b110 and op2 == 0b001) {
                    // USAT16
                    const sat_imm: u5 = @truncate((inst >> 16) & 0xf);
                    const max_v: i32 = (@as(i32, 1) << sat_imm) - 1;
                    const lo_in: i32 = @as(i16, @bitCast(@as(u16, @truncate(r_rm))));
                    const hi_in: i32 = @as(i16, @bitCast(@as(u16, @truncate(r_rm >> 16))));
                    var q_set = false;
                    const lo_sat: u16 = @intCast(clampSat(lo_in, 0, max_v, &q_set));
                    const hi_sat: u16 = @intCast(clampSat(hi_in, 0, max_v, &q_set));
                    if (q_set) cpsr.* |= PsrFlags.Q;
                    return (@as(u32, hi_sat) << 16) | lo_sat;
                } else if (sub_op == 0b110 and op2 == 0b011) {
                    // UXTAB / UXTB (when Rn == 15, r_rn is passed as 0)
                    const rot: u5 = @as(u5, @truncate((inst >> 10) & 3)) * 8;
                    const rot_rm = std.math.rotr(u32, r_rm, rot);
                    const uext: u32 = @as(u8, @truncate(rot_rm));
                    return r_rn +% uext;
                } else if (sub_op == 0b111 and op2 == 0b011) {
                    // UXTAH / UXTH (when Rn == 15, r_rn is passed as 0)
                    const rot: u5 = @as(u5, @truncate((inst >> 10) & 3)) * 8;
                    const rot_rm = std.math.rotr(u32, r_rm, rot);
                    const uext: u32 = @as(u16, @truncate(rot_rm));
                    return r_rn +% uext;
                } else if (sub_op == 0b111 and op2 == 0b101) {
                    // REVSH
                    const lo: u16 = @byteSwap(@as(u16, @truncate(r_rm)));
                    const sext: i32 = @as(i16, @bitCast(lo));
                    return @bitCast(sext);
                }
                // USAT (when op2 & 1 == 0)
                if ((op2 & 1) == 0) {
                    const sat_bit: u5 = @truncate((inst >> 16) & 0x1f);
                    const sh: u5 = @truncate((inst >> 7) & 0x1f);
                    const asr = (op2 & 0b010) != 0;
                    const sval: i32 = @bitCast(r_rm);
                    const shifted: i32 = if (!asr) (sval << sh) else if (sh == 0) (if (sval < 0) -1 else 0) else (sval >> sh);
                    const max_v: i64 = (@as(i64, 1) << sat_bit) - 1;
                    var res: i64 = shifted;
                    if (res < 0) {
                        res = 0;
                        cpsr.* |= PsrFlags.Q;
                    } else if (res > max_v) {
                        res = max_v;
                        cpsr.* |= PsrFlags.Q;
                    }
                    return @truncate(@as(u64, @bitCast(res)));
                }
            },
            else => {},
        }
    }

    // 3. Signed multiplies (`op1[4:3] == 0b10`)
    if ((op1 & 0b11000) == 0b10000) {
        const sub = op1 & 0b00111;
        switch (sub) {
            0b000 => {
                // SMLAD / SMUAD / SMLSD / SMUSD
                const m_swap = (op2 & 1) != 0;
                const is_sub = (op2 & 0b010) != 0;
                const n_lo: i32 = @as(i16, @bitCast(@as(u16, @truncate(r_rn))));
                const n_hi: i32 = @as(i16, @bitCast(@as(u16, @truncate(r_rn >> 16))));
                const m_0: i32 = @as(i16, @bitCast(@as(u16, @truncate(r_rm))));
                const m_1: i32 = @as(i16, @bitCast(@as(u16, @truncate(r_rm >> 16))));
                const m_lo = if (m_swap) m_1 else m_0;
                const m_hi = if (m_swap) m_0 else m_1;
                const p1: i64 = @as(i64, n_lo) * m_lo;
                const p2: i64 = @as(i64, n_hi) * m_hi;
                const sum: i64 = (if (is_sub) (p1 - p2) else (p1 + p2)) + @as(i64, @as(i32, @bitCast(r_ra)));
                return @truncate(@as(u64, @bitCast(sum)));
            },
            0b101 => {
                // SMMUL / SMMLA / SMMLS
                const round = (op2 & 1) != 0;
                const is_mls = (op2 & 0b110) == 0b110;
                // Note: In SMMUL/SMMLA/SMMLS, Rd is in bits 19:16 (r_rn), Rn is in bits 3:0 (r_rm), Rm is in bits 11:8, Ra is in bits 15:12 (r_rd)!
                const a: i64 = @as(i32, @bitCast(r_rn));
                const b: i64 = @as(i32, @bitCast(r_rm));
                var prod: i64 = a * b;
                if (round) prod += 0x8000_0000;
                const acc: i64 = if (((inst >> 12) & 0xf) == 0xf and !is_mls) 0 else (@as(i64, @as(i32, @bitCast(r_ra))) << 32);
                const total: i64 = if (is_mls) (acc - prod) else (acc + prod);
                return @truncate(@as(u64, @bitCast(total)) >> 32);
            },
            else => {},
        }
    }

    // 4. USAD8 / USADA8 / Bitfield (`op1[4:3] == 0b11`)
    if (op1 == 0b11000 and op2 == 0b000) {
        // USAD8 / USADA8
        var diff_sum: u32 = if (((inst >> 12) & 0xf) == 0xf) 0 else r_ra;
        inline for (0..4) |i| {
            const sh: u5 = @intCast(i * 8);
            const a: i32 = @as(u8, @truncate(r_rn >> sh));
            const b: i32 = @as(u8, @truncate(r_rm >> sh));
            diff_sum +%= @abs(a - b);
        }
        return diff_sum;
    }

    // UBFX / SBFX / BFI / BFC (ARMv6T2/v7 extensions sometimes emitted if enabled)
    if ((op1 == 0b11010 or op1 == 0b11011 or op1 == 0b11110 or op1 == 0b11111) and (op2 == 0b010)) {
        // SBFX / UBFX
        const lsb: u5 = @truncate((inst >> 7) & 0x1f);
        const widthm1: u5 = @truncate((inst >> 16) & 0x1f);
        const width: u6 = @as(u6, widthm1) + 1;
        const shifted = r_rm >> lsb;
        const mask: u32 = if (width >= 32) 0xffff_ffff else (@as(u32, 1) << @truncate(width)) -% 1;
        const val = shifted & mask;
        if ((op1 & 0b00100) == 0 and width < 32) {
            // SBFX: sign-extend
            const sign_bit: u5 = @truncate(width -% 1);
            if (((val >> sign_bit) & 1) != 0) {
                return val | ~mask;
            }
        }
        return val;
    }
    if ((op1 == 0b11100 or op1 == 0b11101) and (op2 == 0b000)) {
        // BFI / BFC
        const lsb: u5 = @truncate((inst >> 7) & 0x1f);
        const msb: u5 = @truncate((inst >> 16) & 0x1f);
        if (msb >= lsb) {
            const width: u6 = @as(u6, msb -% lsb) + 1;
            const mask: u32 = if (width >= 32) 0xffff_ffff else ((@as(u32, 1) << @truncate(width)) -% 1) << lsb;
            const src: u32 = if ((inst & 0xf) == 0xf) 0 else (r_rm << lsb);
            return (r_rd & ~mask) | (src & mask);
        }
    }

    return null;
}

fn clampSat(val: i32, min_v: i32, max_v: i32, q_set: *bool) i32 {
    if (val < min_v) {
        q_set.* = true;
        return min_v;
    }
    if (val > max_v) {
        q_set.* = true;
        return max_v;
    }
    return val;
}

fn executeParallelAddSub(op1: u5, op2: u3, r_rn: u32, r_rm: u32, cpsr: *u32) u32 {
    const prefix: u2 = @truncate(op1 & 3);
    const is_unsigned = (op1 & 0b00100) != 0;

    // UADD8 / SADD8 / USUB8 / SSUB8 / UQADD8 / UQSUB8 (op2 == 0b010)
    if (op2 == 0b010) {
        const is_sub = (op2 & 0b100) != 0; // wait: for 8-bit, op2 is 0b010 for ADD8 and 0b110 for SUB8
        _ = is_sub;
    }
    const is_8bit = (op2 & 0b011) == 0b010;
    const is_sub8 = op2 == 0b110;

    if (is_8bit) {
        var out: u32 = 0;
        var ge: u32 = 0;
        inline for (0..4) |i| {
            const sh: u5 = @intCast(i * 8);
            const u_a: u8 = @truncate(r_rn >> sh);
            const u_b: u8 = @truncate(r_rm >> sh);
            const s_a: i32 = @as(i8, @bitCast(u_a));
            const s_b: i32 = @as(i8, @bitCast(u_b));
            var res_byte: u8 = 0;
            if (is_unsigned) {
                const a: i32 = u_a;
                const b: i32 = u_b;
                const sum: i32 = if (is_sub8) (a - b) else (a + b);
                if (prefix == 0b01) { // Modulo (UADD8 / USUB8)
                    if (!is_sub8 and sum >= 0x100) ge |= (@as(u32, 1) << @intCast(i));
                    if (is_sub8 and sum >= 0) ge |= (@as(u32, 1) << @intCast(i));
                    res_byte = @truncate(@as(u32, @bitCast(sum)));
                } else if (prefix == 0b10) { // Saturating (UQADD8 / UQSUB8)
                    res_byte = @intCast(std.math.clamp(sum, 0, 255));
                } else if (prefix == 0b11) { // Halving (UHADD8 / UHSUB8)
                    res_byte = @truncate(@as(u32, @bitCast(sum >> 1)));
                }
            } else {
                const sum: i32 = if (is_sub8) (s_a - s_b) else (s_a + s_b);
                if (prefix == 0b01) { // Modulo (SADD8 / SSUB8)
                    if (sum >= 0) ge |= (@as(u32, 1) << @intCast(i));
                    res_byte = @truncate(@as(u32, @bitCast(sum)));
                } else if (prefix == 0b10) { // Saturating (QADD8 / QSUB8)
                    const clamped: i8 = @intCast(std.math.clamp(sum, -128, 127));
                    res_byte = @bitCast(clamped);
                } else if (prefix == 0b11) { // Halving (SHADD8 / SHSUB8)
                    res_byte = @truncate(@as(u32, @bitCast(sum >> 1)));
                }
            }
            out |= (@as(u32, res_byte) << sh);
        }
        if (prefix == 0b01) {
            cpsr.* = (cpsr.* & ~PsrFlags.GE_MASK) | (ge << 16);
        }
        return out;
    }

    // 16-bit parallel operations (SADD16 / UADD16 / SSUB16 / USUB16 / etc.)
    const is_sub16 = op2 == 0b011;
    var out16: u32 = 0;
    var ge16: u32 = 0;
    inline for (0..2) |i| {
        const sh: u5 = @intCast(i * 16);
        const u_a: u16 = @truncate(r_rn >> sh);
        const u_b: u16 = @truncate(r_rm >> sh);
        const s_a: i32 = @as(i16, @bitCast(u_a));
        const s_b: i32 = @as(i16, @bitCast(u_b));
        var res_half: u16 = 0;
        if (is_unsigned) {
            const a: i32 = u_a;
            const b: i32 = u_b;
            const sum: i32 = if (is_sub16) (a - b) else (a + b);
            if (prefix == 0b01) {
                if (!is_sub16 and sum >= 0x10000) ge16 |= (@as(u32, 0b11) << @intCast(i * 2));
                if (is_sub16 and sum >= 0) ge16 |= (@as(u32, 0b11) << @intCast(i * 2));
                res_half = @truncate(@as(u32, @bitCast(sum)));
            } else if (prefix == 0b10) {
                res_half = @intCast(std.math.clamp(sum, 0, 65535));
            } else {
                res_half = @truncate(@as(u32, @bitCast(sum >> 1)));
            }
        } else {
            const sum: i32 = if (is_sub16) (s_a - s_b) else (s_a + s_b);
            if (prefix == 0b01) {
                if (sum >= 0) ge16 |= (@as(u32, 0b11) << @intCast(i * 2));
                res_half = @truncate(@as(u32, @bitCast(sum)));
            } else if (prefix == 0b10) {
                const clamped: i16 = @intCast(std.math.clamp(sum, -32768, 32767));
                res_half = @bitCast(clamped);
            } else {
                res_half = @truncate(@as(u32, @bitCast(sum >> 1)));
            }
        }
        out16 |= (@as(u32, res_half) << sh);
    }
    if (prefix == 0b01) {
        cpsr.* = (cpsr.* & ~PsrFlags.GE_MASK) | (ge16 << 16);
    }
    return out16;
}
