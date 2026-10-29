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

const cond_lut: [16]u16 = blk: {
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
                0xe, 0xf => true, // AL / Unconditional
            };
            if (ok) mask |= (@as(u16, 1) << @intCast(nzcv));
        }
        lut[c_idx] = mask;
    }
    break :blk lut;
};

/// Evaluates the 4-bit ARM condition code `cond` against `cpsr`.
pub inline fn checkCond(cond: u4, cpsr: u32) bool {
    const nzcv: u4 = @truncate(cpsr >> 28);
    return ((cond_lut[cond] >> nzcv) & 1) != 0;
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
    const usum: u64 = @as(u64, a) + @as(u64, b) + @as(u64, carry_in);
    const res: u32 = @truncate(usum);
    return .{
        .val = res,
        .n = @truncate(res >> 31),
        .z = @intFromBool(res == 0),
        .c = @truncate(usum >> 32),
        .v = @truncate(((~(a ^ b)) & (a ^ res)) >> 31),
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
                } else if (sub_op == 0b111 and op2 == 0b001) {
                    // RBIT (Reverse Bits)
                    return @bitReverse(r_rm);
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
            0b001 => {
                // SDIV Rd, Rn, Rm (op2 == 0b000)
                if (op2 == 0b000) {
                    if (r_rm == 0) return 0;
                    const num: i32 = @bitCast(r_rn);
                    const den: i32 = @bitCast(r_rm);
                    if (num == std.math.minInt(i32) and den == -1) return @bitCast(num);
                    return @bitCast(@divTrunc(num, den));
                }
            },
            0b011 => {
                // UDIV Rd, Rn, Rm (op2 == 0b000)
                if (op2 == 0b000) {
                    if (r_rm == 0) return 0;
                    return r_rn / r_rm;
                }
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

    // UBFX / SBFX / BFI / BFC (bit 7 of inst is lsb[0], i.e. bit 2 of op2)
    if ((op1 == 0b11010 or op1 == 0b11011 or op1 == 0b11110 or op1 == 0b11111) and ((op2 & 0b011) == 0b010)) {
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
    if ((op1 == 0b11100 or op1 == 0b11101) and ((op2 & 0b011) == 0b000)) {
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

/// One lane of a parallel add/subtract: the result, and whether it sets the lane's GE flags.
fn parallelLane(comptime bits: u5, a_raw: u32, b_raw: u32, sub: bool, is_unsigned: bool, prefix: u2) struct { u32, bool } {
    const mask: u32 = (@as(u32, 1) << bits) - 1;
    const a: i64 = if (is_unsigned) a_raw & mask else signExtend(a_raw & mask, bits);
    const b: i64 = if (is_unsigned) b_raw & mask else signExtend(b_raw & mask, bits);
    const r: i64 = if (sub) a - b else a + b;
    const value: i64 = switch (prefix) {
        0b10 => if (is_unsigned)
            std.math.clamp(r, 0, @as(i64, mask))
        else
            std.math.clamp(r, -(@as(i64, 1) << (bits - 1)), (@as(i64, 1) << (bits - 1)) - 1),
        0b11 => r >> 1,
        else => r,
    };
    // GE: unsigned add carries out, unsigned subtract does not borrow, signed result is non-negative
    const ge = if (is_unsigned) (if (sub) r >= 0 else r > mask) else r >= 0;
    return .{ @as(u32, @truncate(@as(u64, @bitCast(value)))) & mask, ge };
}

fn signExtend(v: u32, comptime bits: u5) i64 {
    const shift: u6 = @intCast(64 - @as(u7, bits));
    return @as(i64, @bitCast(@as(u64, v) << shift)) >> shift;
}

/// ARMv6 parallel add/subtract: `op1[1:0]` selects modulo (01, which sets GE), saturating (10)
/// or halving (11), `op1[2]` unsigned, and `op2` the operation: ADD16 (000), ASX (001), SAX (010),
/// SUB16 (011), ADD8 (100) or SUB8 (111). Other encodings are undefined.
fn executeParallelAddSub(op1: u5, op2: u3, r_rn: u32, r_rm: u32, cpsr: *u32) ?u32 {
    const prefix: u2 = @truncate(op1 & 3);
    const is_unsigned = (op1 & 0b00100) != 0;
    if (prefix == 0b00 or op2 == 0b101 or op2 == 0b110) return null;

    var out: u32 = 0;
    var ge: u32 = 0;
    if (op2 == 0b100 or op2 == 0b111) {
        inline for (0..4) |i| {
            const sh: u5 = @intCast(i * 8);
            const lane = parallelLane(8, r_rn >> sh, r_rm >> sh, op2 == 0b111, is_unsigned, prefix);
            out |= lane[0] << sh;
            if (lane[1]) ge |= @as(u32, 1) << @intCast(i);
        }
    } else {
        // 16-bit lanes; ASX/SAX exchange Rm's halves and add in one lane while subtracting in the other
        const rm_lo = if (op2 == 0b001 or op2 == 0b010) r_rm >> 16 else r_rm;
        const rm_hi = if (op2 == 0b001 or op2 == 0b010) r_rm else r_rm >> 16;
        const lo = parallelLane(16, r_rn, rm_lo, op2 == 0b011 or op2 == 0b001, is_unsigned, prefix);
        const hi = parallelLane(16, r_rn >> 16, rm_hi, op2 == 0b011 or op2 == 0b010, is_unsigned, prefix);
        out = lo[0] | (hi[0] << 16);
        if (lo[1]) ge |= 0b0011;
        if (hi[1]) ge |= 0b1100;
    }
    if (prefix == 0b01) {
        cpsr.* = (cpsr.* & ~PsrFlags.GE_MASK) | (ge << 16);
    }
    return out;
}

test "ARMv6 parallel add/subtract decodes ADD8/SUB8/ADD16/SUB16/ASX/SAX" {
    const enc = struct {
        fn inst(op1: u32, op2: u32) u32 {
            return 0xe600_0f10 | (op1 << 20) | (1 << 16) | (2 << 12) | (op2 << 5) | 3;
        }
    };
    var cpsr: u32 = 0;
    // UQSUB8: 1 - byte saturates to 1 where the byte is zero (glibc's string search)
    try std.testing.expectEqual(@as(?u32, 0x0100_0100), executeMedia(enc.inst(0b00110, 0b111), 0x0101_0101, 0x0041_0062, 0, 0, &cpsr));
    // UADD8 sets GE for lanes that carry out
    try std.testing.expectEqual(@as(?u32, 0x0000_0002), executeMedia(enc.inst(0b00101, 0b100), 0x80ff_0001, 0x8001_0001, 0, 0, &cpsr));
    try std.testing.expectEqual(@as(u32, 0b1100), (cpsr & PsrFlags.GE_MASK) >> 16);
    // SSUB16 sets GE for non-negative lanes
    try std.testing.expectEqual(@as(?u32, 0xffff_0002), executeMedia(enc.inst(0b00001, 0b011), 0x0001_0005, 0x0002_0003, 0, 0, &cpsr));
    try std.testing.expectEqual(@as(u32, 0b0011), (cpsr & PsrFlags.GE_MASK) >> 16);
    // UASX: low = Rn.lo - Rm.hi, high = Rn.hi + Rm.lo
    try std.testing.expectEqual(@as(?u32, 0x0013_001b), executeMedia(enc.inst(0b00101, 0b001), 0x0010_0020, 0x0005_0003, 0, 0, &cpsr));
    try std.testing.expectEqual(@as(u32, 0b0011), (cpsr & PsrFlags.GE_MASK) >> 16);
    // SHADD8 halves signed sums
    try std.testing.expectEqual(@as(?u32, 0x0000_0003), executeMedia(enc.inst(0b00011, 0b100), 0x0000_fe04, 0x0000_0202, 0, 0, &cpsr));
    // op2 = 0b101 is unallocated
    try std.testing.expectEqual(@as(?u32, null), executeMedia(enc.inst(0b00101, 0b101), 0, 0, 0, 0, &cpsr));
}
