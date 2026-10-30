//! Cortex-A53 AArch32 Advanced SIMD (NEON).
//!
//! Executes the Advanced SIMD data-processing instructions, the element and structure loads and
//! stores (`VLD1`-`VLD4`, `VST1`-`VST4`), and the transfers between ARM core registers and scalars
//! (`VMOV`, `VDUP`). The registers are the VFP register file: `D0`-`D31`, with `Q0`-`Q15` as pairs.
//!
//! Advanced SIMD floating-point arithmetic always uses the standard FPSCR value: round to nearest,
//! denormal inputs and results flushed to zero, and the default NaN. Saturating operations set
//! `FPSCR.QC`. The BCM2837's Cortex-A53 implements ARMv8.0 without the Cryptography Extension, so
//! those instructions and the later ARMv8.x additions are Undefined.

const std = @import("std");
const vfp_mod = @import("vfp.zig");
const Vfp = vfp_mod.Vfp;

pub const FPSCR_QC: u32 = 1 << 27;

// --- Register file -------------------------------------------------------------------------------

inline fn getD(v: *const Vfp, n: u5) u64 {
    return v.getDU64(n);
}

inline fn setD(v: *Vfp, n: u5, x: u64) void {
    v.setDU64(n, x);
}

/// The 64-bit halves of a D register (`regs == 1`) or a Q register (`regs == 2`) starting at `n`.
fn getRegs(v: *const Vfp, n: u5, regs: u2) [2]u64 {
    return .{ getD(v, n), if (regs == 2) getD(v, n +% 1) else 0 };
}

fn setRegs(v: *Vfp, n: u5, regs: u2, x: [2]u64) void {
    setD(v, n, x[0]);
    if (regs == 2) setD(v, n +% 1, x[1]);
}

inline fn bit(inst: u32, n: u5) u1 {
    return @truncate(inst >> n);
}

/// `D:Vd`, `N:Vn`, `M:Vm`
inline fn regD(inst: u32) u5 {
    return @truncate((@as(u32, bit(inst, 22)) << 4) | ((inst >> 12) & 0xf));
}
inline fn regN(inst: u32) u5 {
    return @truncate((@as(u32, bit(inst, 7)) << 4) | ((inst >> 16) & 0xf));
}
inline fn regM(inst: u32) u5 {
    return @truncate((@as(u32, bit(inst, 5)) << 4) | (inst & 0xf));
}

// --- Elements ------------------------------------------------------------------------------------

inline fn emask(esize: u7) u64 {
    return if (esize >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(esize)) - 1;
}

/// Element `i` of a 128-bit value held as two 64-bit halves.
inline fn elem(x: [2]u64, i: usize, esize: u7) u64 {
    const per: usize = 64 / @as(usize, esize);
    const sh: u6 = @intCast((i % per) * esize);
    return (x[i / per] >> sh) & emask(esize);
}

inline fn setElem(x: *[2]u64, i: usize, esize: u7, val: u64) void {
    const per: usize = 64 / @as(usize, esize);
    const sh: u6 = @intCast((i % per) * esize);
    const m = emask(esize) << sh;
    x[i / per] = (x[i / per] & ~m) | ((val << sh) & m);
}

inline fn sext(val: u64, esize: u7) i64 {
    if (esize >= 64) return @bitCast(val);
    const sh: u6 = @intCast(64 - @as(u7, esize));
    return @as(i64, @bitCast(val << sh)) >> sh;
}

/// The element as an integer: sign-extended when `signed`, else zero-extended.
inline fn ival(val: u64, esize: u7, signed: bool) i128 {
    return if (signed) sext(val, esize) else val;
}

inline fn smax(esize: u7) i128 {
    return (@as(i128, 1) << @intCast(esize - 1)) - 1;
}
inline fn smin(esize: u7) i128 {
    return -(@as(i128, 1) << @intCast(esize - 1));
}
inline fn umax(esize: u7) i128 {
    return (@as(i128, 1) << @intCast(esize)) - 1;
}

/// Saturates `x` to an `esize`-bit signed or unsigned integer, setting `QC` if it does not fit.
fn sat(v: *Vfp, x: i128, esize: u7, signed: bool) u64 {
    const lo: i128 = if (signed) smin(esize) else 0;
    const hi: i128 = if (signed) smax(esize) else umax(esize);
    var r = x;
    if (r < lo) {
        r = lo;
        v.fpscr |= FPSCR_QC;
    } else if (r > hi) {
        r = hi;
        v.fpscr |= FPSCR_QC;
    }
    return @as(u64, @truncate(@as(u128, @bitCast(r)))) & emask(esize);
}

inline fn trunc(x: i128, esize: u7) u64 {
    return @as(u64, @truncate(@as(u128, @bitCast(x)))) & emask(esize);
}

/// Shifts `x` (an `esize`-bit element, as an integer) by the signed amount `sh`: left if
/// positive, right (arithmetic for signed values, optionally rounding) if negative.
fn shiftBy(x: i128, sh: i64, esize: u7, round: bool) i128 {
    if (sh >= 0) {
        if (x == 0) return 0;
        // Shifting by the element's width or more leaves nothing in the element but always saturates
        if (sh >= esize) return if (x > 0) @as(i128, 1) << @intCast(esize) else -(@as(i128, 1) << @intCast(esize));
        return x << @intCast(sh);
    }
    const n: u7 = @intCast(@min(-sh, 100));
    if (round) return (x + (@as(i128, 1) << (n - 1))) >> n;
    return x >> n;
}

// --- Floating point (standard FPSCR value) -------------------------------------------------------

const DEFAULT_NAN32: u32 = 0x7fc0_0000;

inline fn isNan32(b: u32) bool {
    return (b & 0x7f80_0000) == 0x7f80_0000 and (b & 0x007f_ffff) != 0;
}
inline fn isSNan32(b: u32) bool {
    return isNan32(b) and (b & 0x0040_0000) == 0;
}
inline fn flush32(b: u32) u32 {
    return if ((b & 0x7f80_0000) == 0) b & 0x8000_0000 else b;
}
inline fn fin(b: u64) f32 {
    return @bitCast(flush32(@truncate(b)));
}
/// Rounds back to the register value: NaNs become the default NaN and denormals are flushed.
inline fn fout(x: f32) u64 {
    const b: u32 = @bitCast(x);
    if (isNan32(b)) return DEFAULT_NAN32;
    return flush32(b);
}

fn fpMax(a: f32, b: f32, is_max: bool) u64 {
    if (std.math.isNan(a) or std.math.isNan(b)) return DEFAULT_NAN32;
    if (a == 0 and b == 0) {
        const sa = std.math.signbit(a);
        const sb = std.math.signbit(b);
        // max(+0, -0) is +0 and min(+0, -0) is -0
        return fout(if (is_max) (if (sa and sb) a else @as(f32, 0)) else (if (sa or sb) -@as(f32, 0) else @as(f32, 0)));
    }
    return fout(if (is_max) @max(a, b) else @min(a, b));
}

/// `FPMaxNum` / `FPMinNum`: a quiet NaN operand loses to a number.
fn fpMaxNum(ab: u32, bb: u32, is_max: bool) u64 {
    var a = flush32(ab);
    var b = flush32(bb);
    const inf: u32 = if (is_max) 0xff80_0000 else 0x7f80_0000;
    if (isNan32(a) and !isSNan32(a) and !isNan32(b)) a = inf;
    if (isNan32(b) and !isSNan32(b) and !isNan32(a)) b = inf;
    return fpMax(@bitCast(a), @bitCast(b), is_max);
}

/// Converts to an integer, rounding as `mode` says and saturating; NaN converts to 0.
fn fpToInt(x: f32, signed: bool, mode: RoundMode) u64 {
    if (std.math.isNan(x)) return 0;
    const r: f64 = roundF64(x, mode);
    if (signed) {
        if (r >= 2147483647.0) return 0x7fff_ffff;
        if (r <= -2147483648.0) return 0x8000_0000;
        return @as(u32, @bitCast(@as(i32, @intFromFloat(r))));
    }
    if (r <= 0) return 0;
    if (r >= 4294967295.0) return 0xffff_ffff;
    return @as(u32, @intFromFloat(r));
}

const RoundMode = enum { nearest_even, plus_inf, minus_inf, zero, nearest_away };

fn roundF64(x: f32, mode: RoundMode) f64 {
    const d: f64 = x;
    return switch (mode) {
        .nearest_even => @round(d) - (if (@abs(d - @trunc(d)) == 0.5 and @mod(@round(d), 2) != 0) std.math.sign(d) else 0),
        .plus_inf => @ceil(d),
        .minus_inf => @floor(d),
        .zero => @trunc(d),
        .nearest_away => @round(d),
    };
}

/// `VRINT*`: rounds to an integral value in floating point, keeping the sign of zero.
fn fpRoundInt(xb: u32, mode: RoundMode) u64 {
    const b = flush32(xb);
    if (isNan32(b)) return DEFAULT_NAN32;
    const x: f32 = @bitCast(b);
    if (std.math.isInf(x) or x == 0) return b;
    const r: f32 = @floatCast(roundF64(x, mode));
    if (r == 0) return @as(u32, @bitCast(r)) | (b & 0x8000_0000);
    return @as(u32, @bitCast(r));
}

fn recipEstimate(a_in: u32) u32 {
    const a = a_in * 2 + 1;
    const b = (@as(u32, 1) << 19) / a;
    return (b + 1) / 2;
}

fn recipSqrtEstimate(a_in: u32) u32 {
    var a: u64 = a_in;
    if (a < 256) {
        a = a * 2 + 1;
    } else {
        a = (a >> 1) << 1;
        a = (a + 1) * 2;
    }
    var b: u64 = 512;
    while (a * (b + 1) * (b + 1) < (@as(u64, 1) << 28)) b += 1;
    return @intCast((b + 1) / 2);
}

fn fpRecipEstimate(xb: u32) u64 {
    const b = flush32(xb);
    const sign = b & 0x8000_0000;
    if (isNan32(b)) return DEFAULT_NAN32;
    if ((b & 0x7fff_ffff) == 0x7f80_0000) return sign;
    if ((b & 0x7fff_ffff) == 0) return sign | 0x7f80_0000;
    const exp: i32 = @intCast((b >> 23) & 0xff);
    if (exp >= 253) return sign; // underflows, flushed to zero
    const scaled: u32 = 256 | ((b >> 15) & 0xff);
    const result_exp: u32 = @intCast(253 - exp);
    const est = recipEstimate(scaled);
    return sign | (result_exp << 23) | ((est & 0xff) << 15);
}

fn fpRSqrtEstimate(xb: u32) u64 {
    const b = flush32(xb);
    if (isNan32(b)) return DEFAULT_NAN32;
    if ((b & 0x7fff_ffff) == 0) return (b & 0x8000_0000) | 0x7f80_0000;
    if ((b & 0x8000_0000) != 0) return DEFAULT_NAN32;
    if (b == 0x7f80_0000) return 0;
    const exp: u32 = (b >> 23) & 0xff;
    const scaled: u32 = if ((exp & 1) == 0) 256 | ((b >> 15) & 0xff) else 128 | ((b >> 16) & 0x7f);
    const result_exp: u32 = (380 - exp) / 2;
    const est = recipSqrtEstimate(scaled);
    return (result_exp << 23) | ((est & 0xff) << 15);
}

fn unsignedRecipEstimate(x: u32) u64 {
    if ((x & 0x8000_0000) == 0) return 0xffff_ffff;
    return recipEstimate(x >> 23) << 23;
}

fn unsignedRSqrtEstimate(x: u32) u64 {
    if ((x & 0xc000_0000) == 0) return 0xffff_ffff;
    const dp: u32 = if ((x & 0x8000_0000) != 0) x >> 23 else (x >> 23) & 0xff;
    return recipSqrtEstimate(dp) << 23;
}

// --- Dispatch ------------------------------------------------------------------------------------

/// Executes an Advanced SIMD data-processing instruction (`1111 001U ...`). Returns false if it is
/// Undefined.
pub fn executeDataProcessing(v: *Vfp, inst: u32) bool {
    const u = bit(inst, 24) == 1;
    const a: u5 = @truncate(inst >> 19);
    const b: u4 = @truncate(inst >> 8);
    const c: u4 = @truncate(inst >> 4);
    if ((a & 0b10000) == 0) return threeSame(v, inst);
    if ((c & 0b1001) == 0b0001) {
        if ((a & 0b10111) == 0b10000) return oneRegImm(v, inst);
        return twoRegShift(v, inst);
    }
    if ((c & 0b1001) == 0b1001) return twoRegShift(v, inst);
    if ((a & 0b10110) == 0b10110) {
        if (!u) return vext(v, inst);
        if ((b & 0b1000) == 0) return twoRegMisc(v, inst);
        if ((b & 0b1100) == 0b1000) return vtbl(v, inst);
        if (b == 0b1100 and (c & 0b1001) == 0) return vdupScalar(v, inst);
        return false;
    }
    if ((c & 0b0101) == 0b0000) return threeDiff(v, inst);
    if ((c & 0b0101) == 0b0100) return twoRegScalar(v, inst);
    return false;
}

// --- Three registers of the same length ----------------------------------------------------------

fn threeSame(v: *Vfp, inst: u32) bool {
    const u = bit(inst, 24) == 1;
    const op: u4 = @truncate(inst >> 8);
    const bb = bit(inst, 4) == 1;
    const size: u2 = @truncate(inst >> 20);
    const q = bit(inst, 6) == 1;
    const d = regD(inst);
    const n = regN(inst);
    const m = regM(inst);
    if (q and ((d | n | m) & 1) != 0) return false;
    const regs: u2 = if (q) 2 else 1;
    const esize: u7 = @as(u7, 8) << size;
    const lanes: usize = (@as(usize, regs) * 64) / esize;
    const xn = getRegs(v, n, regs);
    const xm = getRegs(v, m, regs);
    const xd = getRegs(v, d, regs);
    var r = xd;

    // Bitwise operations (A = 0001, B = 1)
    if (op == 0b0001 and bb) {
        for (0..regs) |i| {
            r[i] = switch (@as(u3, @intFromBool(u)) << 2 | size) {
                0b000 => xn[i] & xm[i], // VAND
                0b001 => xn[i] & ~xm[i], // VBIC
                0b010 => xn[i] | xm[i], // VORR
                0b011 => xn[i] | ~xm[i], // VORN
                0b100 => xn[i] ^ xm[i], // VEOR
                0b101 => (xn[i] & xd[i]) | (xm[i] & ~xd[i]), // VBSL
                0b110 => (xn[i] & xm[i]) | (xd[i] & ~xm[i]), // VBIT
                0b111 => (xd[i] & xm[i]) | (xn[i] & ~xm[i]), // VBIF
            };
        }
        setRegs(v, d, regs, r);
        return true;
    }

    // Floating point (A = 11xx, sz = 0)
    if ((op & 0b1100) == 0b1100) return threeSameFloat(v, inst, xn, xm, xd, regs);

    // Only VQADD, VQSUB, the register shifts, VADD and VSUB have 64-bit forms
    if (size == 3 and !((op == 0b0000 or op == 0b0010) and bb) and op != 0b0100 and op != 0b0101 and !(op == 0b1000 and !bb)) return false;
    const signed = !u;
    switch (op) {
        0b0000, 0b0010 => { // VHADD / VQADD, VHSUB / VQSUB
            const sub = op == 0b0010;
            for (0..lanes) |e| {
                const x = ival(elem(xn, e, esize), esize, signed);
                const y = ival(elem(xm, e, esize), esize, signed);
                const s = if (sub) x - y else x + y;
                setElem(&r, e, esize, if (bb) sat(v, s, esize, signed) else trunc(s >> 1, esize));
            }
        },
        0b0001 => { // VRHADD
            for (0..lanes) |e| {
                const x = ival(elem(xn, e, esize), esize, signed);
                const y = ival(elem(xm, e, esize), esize, signed);
                setElem(&r, e, esize, trunc((x + y + 1) >> 1, esize));
            }
        },
        0b0011 => { // VCGT / VCGE
            for (0..lanes) |e| {
                const x = ival(elem(xn, e, esize), esize, signed);
                const y = ival(elem(xm, e, esize), esize, signed);
                const t = if (bb) x >= y else x > y;
                setElem(&r, e, esize, if (t) emask(esize) else 0);
            }
        },
        0b0100, 0b0101 => { // VSHL / VQSHL / VRSHL / VQRSHL (register): shift Vm by Vn
            const round = op == 0b0101;
            for (0..lanes) |e| {
                const x = ival(elem(xm, e, esize), esize, signed);
                const sh: i64 = @as(i8, @bitCast(@as(u8, @truncate(elem(xn, e, esize)))));
                const s = shiftBy(x, sh, esize, round);
                setElem(&r, e, esize, if (bb) sat(v, s, esize, signed) else trunc(s, esize));
            }
        },
        0b0110 => { // VMAX / VMIN
            for (0..lanes) |e| {
                const x = ival(elem(xn, e, esize), esize, signed);
                const y = ival(elem(xm, e, esize), esize, signed);
                setElem(&r, e, esize, trunc(if (bb) @min(x, y) else @max(x, y), esize));
            }
        },
        0b0111 => { // VABD / VABA
            for (0..lanes) |e| {
                const x = ival(elem(xn, e, esize), esize, signed);
                const y = ival(elem(xm, e, esize), esize, signed);
                const ad: i128 = @intCast(@abs(x - y));
                const base: i128 = if (bb) elem(xd, e, esize) else 0;
                setElem(&r, e, esize, trunc(base + ad, esize));
            }
        },
        0b1000 => {
            for (0..lanes) |e| {
                const x = elem(xn, e, esize);
                const y = elem(xm, e, esize);
                const res: u64 = if (!bb)
                    (if (u) x -% y else x +% y) & emask(esize) // VADD / VSUB
                else if (u)
                    (if (x == y) emask(esize) else 0) // VCEQ
                else
                    (if ((x & y) != 0) emask(esize) else 0); // VTST
                setElem(&r, e, esize, res);
            }
        },
        0b1001 => {
            if (bb and u and size != 0) return false; // VMUL.P8 only
            if (size == 3) return false;
            for (0..lanes) |e| {
                const x = elem(xn, e, esize);
                const y = elem(xm, e, esize);
                const res: u64 = if (bb)
                    (if (u) polyMul(x, y, esize) else x *% y) // VMUL
                else if (u)
                    elem(xd, e, esize) -% (x *% y) // VMLS
                else
                    elem(xd, e, esize) +% (x *% y); // VMLA
                setElem(&r, e, esize, res & emask(esize));
            }
        },
        0b1010 => { // VPMAX / VPMIN
            if (q or size == 3) return false;
            return pairwiseInt(v, d, xn, xm, esize, signed, if (bb) .min else .max);
        },
        0b1011 => {
            if (bb) { // VPADD (integer); U = 1 is VQRDMLAH (ARMv8.1)
                if (u or q or size == 3) return false;
                return pairwiseInt(v, d, xn, xm, esize, false, .add);
            }
            // VQDMULH / VQRDMULH
            if (size == 0 or size == 3) return false;
            for (0..lanes) |e| {
                const x = ival(elem(xn, e, esize), esize, true);
                const y = ival(elem(xm, e, esize), esize, true);
                var p = 2 * x * y;
                if (u) p += @as(i128, 1) << @intCast(esize - 1);
                setElem(&r, e, esize, sat(v, p >> @intCast(esize), esize, true));
            }
        },
        else => return false,
    }
    setRegs(v, d, regs, r);
    return true;
}

const PairOp = enum { add, max, min };

fn pairwiseInt(v: *Vfp, d: u5, xn: [2]u64, xm: [2]u64, esize: u7, signed: bool, op: PairOp) bool {
    const lanes: usize = 64 / @as(usize, esize);
    var r: [2]u64 = .{ 0, 0 };
    for (0..lanes) |e| {
        const src = if (e < lanes / 2) xn else xm;
        const i = (e % (lanes / 2)) * 2;
        const x = ival(elem(src, i, esize), esize, signed);
        const y = ival(elem(src, i + 1, esize), esize, signed);
        const res = switch (op) {
            .add => x + y,
            .max => @max(x, y),
            .min => @min(x, y),
        };
        setElem(&r, e, esize, trunc(res, esize));
    }
    setD(v, d, r[0]);
    return true;
}

fn polyMul(x: u64, y: u64, esize: u7) u64 {
    var r: u64 = 0;
    for (0..esize) |i| {
        if (((y >> @intCast(i)) & 1) != 0) r ^= x << @intCast(i);
    }
    return r & emask(esize);
}

fn polyMulLong(x: u64, y: u64, esize: u7) u64 {
    var r: u64 = 0;
    for (0..esize) |i| {
        if (((y >> @intCast(i)) & 1) != 0) r ^= x << @intCast(i);
    }
    return r & emask(esize * 2);
}

fn threeSameFloat(v: *Vfp, inst: u32, xn: [2]u64, xm: [2]u64, xd: [2]u64, regs: u2) bool {
    const u = bit(inst, 24) == 1;
    const op: u4 = @truncate(inst >> 8);
    const bb = bit(inst, 4) == 1;
    const sz = bit(inst, 20);
    const op21 = bit(inst, 21) == 1;
    const d = regD(inst);
    if (sz != 0) return false; // half-precision arithmetic is ARMv8.2
    const lanes: usize = @as(usize, regs) * 2;
    var r = xd;
    switch (op) {
        0b1100 => { // VFMA / VFMS
            if (!bb or u) return false;
            for (0..lanes) |e| {
                var x = fin(elem(xn, e, 32));
                if (op21) x = -x;
                const res = @mulAdd(f32, x, fin(elem(xm, e, 32)), fin(elem(xd, e, 32)));
                setElem(&r, e, 32, fout(res));
            }
        },
        0b1101 => {
            if (!bb) {
                if (!u) { // VADD / VSUB
                    for (0..lanes) |e| {
                        const x = fin(elem(xn, e, 32));
                        const y = fin(elem(xm, e, 32));
                        setElem(&r, e, 32, fout(if (op21) x - y else x + y));
                    }
                } else if (!op21) { // VPADD
                    if (regs == 2) return false;
                    const res: [2]u64 = .{ fout(fin(elem(xn, 0, 32)) + fin(elem(xn, 1, 32))) | (fout(fin(elem(xm, 0, 32)) + fin(elem(xm, 1, 32))) << 32), 0 };
                    setD(v, d, res[0]);
                    return true;
                } else { // VABD
                    for (0..lanes) |e| {
                        const diff = fout(fin(elem(xn, e, 32)) - fin(elem(xm, e, 32)));
                        setElem(&r, e, 32, diff & 0x7fff_ffff);
                    }
                }
            } else if (!u) { // VMLA / VMLS
                for (0..lanes) |e| {
                    const p = fin(fout(fin(elem(xn, e, 32)) * fin(elem(xm, e, 32))));
                    const acc = fin(elem(xd, e, 32));
                    setElem(&r, e, 32, fout(if (op21) acc - p else acc + p));
                }
            } else { // VMUL
                if (op21) return false;
                for (0..lanes) |e| setElem(&r, e, 32, fout(fin(elem(xn, e, 32)) * fin(elem(xm, e, 32))));
            }
        },
        0b1110 => { // Comparisons
            for (0..lanes) |e| {
                const x = fin(elem(xn, e, 32));
                const y = fin(elem(xm, e, 32));
                const t = if (!bb) blk: {
                    if (!u) {
                        if (op21) return false;
                        break :blk x == y; // VCEQ
                    }
                    break :blk if (op21) x > y else x >= y; // VCGT / VCGE
                } else blk: {
                    if (!u) return false;
                    break :blk if (op21) @abs(x) > @abs(y) else @abs(x) >= @abs(y); // VACGT / VACGE
                };
                setElem(&r, e, 32, if (t) 0xffff_ffff else 0);
            }
        },
        0b1111 => {
            if (!bb) {
                if (!u) { // VMAX / VMIN
                    for (0..lanes) |e| setElem(&r, e, 32, fpMax(fin(elem(xn, e, 32)), fin(elem(xm, e, 32)), !op21));
                } else { // VPMAX / VPMIN
                    if (regs == 2) return false;
                    const lo = fpMax(fin(elem(xn, 0, 32)), fin(elem(xn, 1, 32)), !op21);
                    const hi = fpMax(fin(elem(xm, 0, 32)), fin(elem(xm, 1, 32)), !op21);
                    setD(v, d, lo | (hi << 32));
                    return true;
                }
            } else if (!u) { // VRECPS / VRSQRTS
                for (0..lanes) |e| {
                    const x = fin(elem(xn, e, 32));
                    const y = fin(elem(xm, e, 32));
                    const special = (std.math.isInf(x) and y == 0) or (x == 0 and std.math.isInf(y));
                    const res: u64 = if (std.math.isNan(x) or std.math.isNan(y))
                        DEFAULT_NAN32
                    else if (special)
                        @as(u32, @bitCast(@as(f32, if (op21) 1.5 else 2.0)))
                    else blk: {
                        const p = fin(fout(x * y));
                        break :blk if (op21) fout((3.0 - p) / 2.0) else fout(2.0 - p);
                    };
                    setElem(&r, e, 32, res);
                }
            } else { // VMAXNM / VMINNM
                for (0..lanes) |e| setElem(&r, e, 32, fpMaxNum(@truncate(elem(xn, e, 32)), @truncate(elem(xm, e, 32)), !op21));
            }
        },
        else => return false, // A = 1100 with B = 0: SHA (Cryptography Extension)
    }
    setRegs(v, d, regs, r);
    return true;
}

// --- Three registers of different lengths --------------------------------------------------------

fn threeDiff(v: *Vfp, inst: u32) bool {
    const u = bit(inst, 24) == 1;
    const op: u4 = @truncate(inst >> 8);
    const size: u2 = @truncate(inst >> 20);
    const d = regD(inst);
    const n = regN(inst);
    const m = regM(inst);
    const esize: u7 = @as(u7, 8) << size;
    const signed = !u;
    const lanes: usize = 64 / @as(usize, esize);

    const wide_n = op == 0b0001 or op == 0b0011; // VADDW / VSUBW
    const narrow = op == 0b0100 or op == 0b0110; // VADDHN / VSUBHN and rounding forms
    if (narrow) {
        if (((n | m) & 1) != 0) return false;
    } else {
        if ((d & 1) != 0) return false;
        if (wide_n and (n & 1) != 0) return false;
    }
    const xn = getRegs(v, n, if (narrow or wide_n) 2 else 1);
    const xm = getRegs(v, m, if (narrow) 2 else 1);
    const xd = getRegs(v, d, 2);
    var r: [2]u64 = xd;
    const wsize: u7 = esize * 2;

    switch (op) {
        0b0000, 0b0001, 0b0010, 0b0011, 0b0101, 0b0111, 0b1000, 0b1010, 0b1100 => {
            for (0..lanes) |e| {
                const x = if (wide_n) ival(elem(xn, e, wsize), wsize, signed) else ival(elem(xn, e, esize), esize, signed);
                const y = ival(elem(xm, e, esize), esize, signed);
                const acc: i128 = @as(i128, elem(xd, e, wsize));
                const res: i128 = switch (op) {
                    0b0000, 0b0001 => x + y, // VADDL / VADDW
                    0b0010, 0b0011 => x - y, // VSUBL / VSUBW
                    0b0101 => acc + @as(i128, @intCast(@abs(x - y))), // VABAL
                    0b0111 => @intCast(@abs(x - y)), // VABDL
                    0b1000 => acc + x * y, // VMLAL
                    0b1010 => acc - x * y, // VMLSL
                    else => x * y, // VMULL
                };
                setElem(&r, e, wsize, trunc(res, wsize));
            }
        },
        0b0100, 0b0110 => { // VADDHN / VRADDHN / VSUBHN / VRSUBHN
            if (size == 3) return false;
            var res: [2]u64 = .{ 0, 0 };
            for (0..lanes) |e| {
                const x = elem(xn, e, wsize);
                const y = elem(xm, e, wsize);
                var s: u128 = if (op == 0b0100) @as(u128, x) + y else @as(u128, x) -% @as(u128, y);
                if (u) s +%= @as(u128, 1) << @intCast(esize - 1);
                setElem(&res, e, esize, @as(u64, @truncate(s >> @intCast(esize))) & emask(esize));
            }
            setD(v, d, res[0]);
            return true;
        },
        0b1001, 0b1011, 0b1101 => { // VQDMLAL / VQDMLSL / VQDMULL
            if (u or size == 0) return false;
            for (0..lanes) |e| {
                const x = ival(elem(xn, e, esize), esize, true);
                const y = ival(elem(xm, e, esize), esize, true);
                const p = sat(v, 2 * x * y, wsize, true);
                const pr = ival(p, wsize, true);
                const res = switch (op) {
                    0b1001 => sat(v, ival(elem(xd, e, wsize), wsize, true) + pr, wsize, true),
                    0b1011 => sat(v, ival(elem(xd, e, wsize), wsize, true) - pr, wsize, true),
                    else => p,
                };
                setElem(&r, e, wsize, res);
            }
        },
        0b1110 => { // VMULL.P8 (VMULL.P64 is the Cryptography Extension)
            if (u or size != 0) return false;
            for (0..lanes) |e| setElem(&r, e, 16, polyMulLong(elem(xn, e, 8), elem(xm, e, 8), 8));
        },
        else => return false,
    }
    if (size == 3) return false;
    setRegs(v, d, 2, r);
    return true;
}

// --- Two registers and a scalar ------------------------------------------------------------------

fn twoRegScalar(v: *Vfp, inst: u32) bool {
    const u = bit(inst, 24) == 1;
    const op: u4 = @truncate(inst >> 8);
    const size: u2 = @truncate(inst >> 20);
    const d = regD(inst);
    const n = regN(inst);
    if (size == 0) return false;
    const esize: u7 = @as(u7, 8) << size;
    // The scalar: Dm[index]
    const mm: u5 = if (esize == 16) @truncate(inst & 7) else @truncate(inst & 0xf);
    const index: usize = if (esize == 16) (@as(usize, bit(inst, 5)) << 1) | bit(inst, 3) else bit(inst, 5);
    const scalar = elem(.{ getD(v, mm), 0 }, index, esize);
    const float = (op & 0b1011) == 0b0001 or op == 0b1001; // VMLA / VMLS / VMUL (floating point)
    if (float and size != 2) return false;

    switch (op) {
        0b0000, 0b0001, 0b0100, 0b0101, 0b1000, 0b1001, 0b1100, 0b1101 => {
            // Q = U for these
            const regs: u2 = if (u) 2 else 1;
            if (u and ((d | n) & 1) != 0) return false;
            const xn = getRegs(v, n, regs);
            const xd = getRegs(v, d, regs);
            var r = xd;
            const lanes: usize = (@as(usize, regs) * 64) / esize;
            for (0..lanes) |e| {
                const x = elem(xn, e, esize);
                const res: u64 = switch (op) {
                    0b0000 => (elem(xd, e, esize) +% x *% scalar) & emask(esize), // VMLA
                    0b0100 => (elem(xd, e, esize) -% x *% scalar) & emask(esize), // VMLS
                    0b1000 => (x *% scalar) & emask(esize), // VMUL
                    0b0001, 0b0101 => blk: { // VMLA / VMLS (floating point)
                        const p = fin(fout(fin(x) * fin(scalar)));
                        const acc = fin(elem(xd, e, 32));
                        break :blk fout(if (op == 0b0101) acc - p else acc + p);
                    },
                    0b1001 => fout(fin(x) * fin(scalar)), // VMUL (floating point)
                    else => blk: { // VQDMULH / VQRDMULH
                        var p = 2 * ival(x, esize, true) * ival(scalar, esize, true);
                        if (op == 0b1101) p += @as(i128, 1) << @intCast(esize - 1);
                        break :blk sat(v, p >> @intCast(esize), esize, true);
                    },
                };
                setElem(&r, e, esize, res);
            }
            setRegs(v, d, regs, r);
            return true;
        },
        0b0010, 0b0110, 0b1010, 0b0011, 0b0111, 0b1011 => {
            // Long forms: Qd, Dn, scalar
            if ((d & 1) != 0) return false;
            const qd = (op & 1) == 1; // VQDMLAL / VQDMLSL / VQDMULL
            if (qd and u) return false;
            const signed = !u;
            const wsize = esize * 2;
            const xn = getRegs(v, n, 1);
            const xd = getRegs(v, d, 2);
            var r = xd;
            const lanes: usize = 64 / @as(usize, esize);
            for (0..lanes) |e| {
                const x = ival(elem(xn, e, esize), esize, if (qd) true else signed);
                const y = ival(scalar, esize, if (qd) true else signed);
                const res: u64 = if (qd) blk: {
                    const p = sat(v, 2 * x * y, wsize, true);
                    break :blk switch (op) {
                        0b0011 => sat(v, ival(elem(xd, e, wsize), wsize, true) + ival(p, wsize, true), wsize, true),
                        0b0111 => sat(v, ival(elem(xd, e, wsize), wsize, true) - ival(p, wsize, true), wsize, true),
                        else => p,
                    };
                } else switch (op) {
                    0b0010 => trunc(@as(i128, elem(xd, e, wsize)) + x * y, wsize), // VMLAL
                    0b0110 => trunc(@as(i128, elem(xd, e, wsize)) - x * y, wsize), // VMLSL
                    else => trunc(x * y, wsize), // VMULL
                };
                setElem(&r, e, wsize, res);
            }
            setRegs(v, d, 2, r);
            return true;
        },
        else => return false, // VQRDMLAH / VQRDMLSH are ARMv8.1
    }
}

// --- Two registers and a shift amount ------------------------------------------------------------

fn twoRegShift(v: *Vfp, inst: u32) bool {
    const u = bit(inst, 24) == 1;
    const op: u4 = @truncate(inst >> 8);
    const l = bit(inst, 7) == 1;
    const q = bit(inst, 6) == 1;
    const imm6: u7 = @truncate(inst >> 16 & 0x3f);
    const d = regD(inst);
    const m = regM(inst);
    const esize: u7 = if (l) 64 else if ((imm6 & 0b100000) != 0) 32 else if ((imm6 & 0b010000) != 0) 16 else 8;
    const lsh: u7 = if (l) imm6 else imm6 - esize; // left shift amount
    const rsh: u7 = if (l) 64 - imm6 else esize * 2 - imm6; // right shift amount
    const signed = !u;

    if ((op & 0b1110) == 0b1110) return vcvtFixed(v, inst);
    if (op >= 0b1000) {
        if (l) return false;
        return shiftNarrowOrLong(v, inst, esize, lsh, rsh);
    }

    if (q and ((d | m) & 1) != 0) return false;
    const regs: u2 = if (q) 2 else 1;
    const xm = getRegs(v, m, regs);
    const xd = getRegs(v, d, regs);
    var r = xd;
    const lanes: usize = (@as(usize, regs) * 64) / esize;
    for (0..lanes) |e| {
        const x = elem(xm, e, esize);
        const xi = ival(x, esize, signed);
        const res: u64 = switch (op) {
            0b0000 => trunc(shiftBy(xi, -@as(i64, rsh), esize, false), esize), // VSHR
            0b0001 => (elem(xd, e, esize) +% trunc(shiftBy(xi, -@as(i64, rsh), esize, false), esize)) & emask(esize), // VSRA
            0b0010 => trunc(shiftBy(xi, -@as(i64, rsh), esize, true), esize), // VRSHR
            0b0011 => (elem(xd, e, esize) +% trunc(shiftBy(xi, -@as(i64, rsh), esize, true), esize)) & emask(esize), // VRSRA
            0b0100 => blk: { // VSRI
                if (!u) return false;
                const keep: u64 = if (rsh >= esize) emask(esize) else ~(emask(esize) >> @intCast(rsh)) & emask(esize);
                const shifted: u64 = if (rsh >= esize) 0 else x >> @intCast(rsh);
                break :blk (elem(xd, e, esize) & keep) | shifted;
            },
            0b0101 => blk: {
                const shifted = if (lsh >= esize) 0 else (x << @intCast(lsh)) & emask(esize);
                if (!u) break :blk shifted; // VSHL
                const keep: u64 = if (lsh == 0) 0 else emask(lsh); // VSLI
                break :blk (elem(xd, e, esize) & keep) | shifted;
            },
            0b0110 => blk: { // VQSHLU: signed input, unsigned result
                if (!u) return false;
                break :blk sat(v, shiftBy(ival(x, esize, true), lsh, esize, false), esize, false);
            },
            0b0111 => sat(v, shiftBy(xi, lsh, esize, false), esize, signed), // VQSHL
            else => unreachable,
        };
        setElem(&r, e, esize, res);
    }
    setRegs(v, d, regs, r);
    return true;
}

fn shiftNarrowOrLong(v: *Vfp, inst: u32, esize: u7, lsh: u7, rsh: u7) bool {
    const u = bit(inst, 24) == 1;
    const op: u4 = @truncate(inst >> 8);
    const b6 = bit(inst, 6) == 1;
    const d = regD(inst);
    const m = regM(inst);
    const lanes: usize = 64 / @as(usize, esize);
    switch (op) {
        0b1000, 0b1001 => { // VSHRN / VRSHRN / VQSHRUN / VQRSHRUN, VQSHRN / VQRSHRN
            if ((m & 1) != 0) return false;
            const wsize = esize * 2;
            const xm = getRegs(v, m, 2);
            var r: [2]u64 = .{ 0, 0 };
            for (0..lanes) |e| {
                const x = elem(xm, e, wsize);
                const res: u64 = if (op == 0b1000 and !u)
                    trunc(shiftBy(x, -@as(i64, rsh), wsize, b6), esize)
                else if (op == 0b1000)
                    sat(v, shiftBy(ival(x, wsize, true), -@as(i64, rsh), wsize, b6), esize, false)
                else
                    sat(v, shiftBy(ival(x, wsize, !u), -@as(i64, rsh), wsize, b6), esize, !u);
                setElem(&r, e, esize, res);
            }
            setD(v, d, r[0]);
            return true;
        },
        0b1010 => { // VSHLL / VMOVL
            if (b6 or (d & 1) != 0) return false;
            const wsize = esize * 2;
            const xm = getRegs(v, m, 1);
            var r: [2]u64 = .{ 0, 0 };
            for (0..lanes) |e| setElem(&r, e, wsize, trunc(ival(elem(xm, e, esize), esize, !u) << @intCast(lsh), wsize));
            setRegs(v, d, 2, r);
            return true;
        },
        else => return false,
    }
}

fn vcvtFixed(v: *Vfp, inst: u32) bool {
    const u = bit(inst, 24) == 1;
    const to_fixed = bit(inst, 8) == 1;
    const q = bit(inst, 6) == 1;
    const imm6: u7 = @truncate(inst >> 16 & 0x3f);
    const d = regD(inst);
    const m = regM(inst);
    if (bit(inst, 7) == 1 or (imm6 & 0b100000) == 0) return false;
    if (q and ((d | m) & 1) != 0) return false;
    const fbits: u7 = 64 - imm6;
    const regs: u2 = if (q) 2 else 1;
    const xm = getRegs(v, m, regs);
    var r = xm;
    const scale: f64 = std.math.pow(f64, 2, @floatFromInt(fbits));
    for (0..@as(usize, regs) * 2) |e| {
        const x = elem(xm, e, 32);
        const res: u64 = if (to_fixed) blk: {
            const f = fin(x);
            if (std.math.isNan(f)) break :blk 0;
            const t = @trunc(@as(f64, f) * scale);
            if (u) break :blk if (t <= 0) 0 else if (t >= 4294967295.0) 0xffff_ffff else @as(u32, @intFromFloat(t));
            break :blk if (t >= 2147483647.0) 0x7fff_ffff else if (t <= -2147483648.0) 0x8000_0000 else @as(u32, @bitCast(@as(i32, @intFromFloat(t))));
        } else blk: {
            const i: f64 = if (u) @floatFromInt(@as(u32, @truncate(x))) else @floatFromInt(@as(i32, @bitCast(@as(u32, @truncate(x)))));
            break :blk fout(@floatCast(i / scale));
        };
        setElem(&r, e, 32, res);
    }
    setRegs(v, d, regs, r);
    return true;
}

// --- One register and a modified immediate -------------------------------------------------------

fn oneRegImm(v: *Vfp, inst: u32) bool {
    const q = bit(inst, 6) == 1;
    const op = bit(inst, 5) == 1;
    const cmode: u4 = @truncate(inst >> 8);
    const d = regD(inst);
    if (q and (d & 1) != 0) return false;
    const imm8: u64 = (@as(u64, bit(inst, 24)) << 7) | ((inst >> 12) & 0x70) | (inst & 0xf);
    const rep32 = struct {
        fn f(x: u64) u64 {
            return x | (x << 32);
        }
    }.f;
    const rep16 = struct {
        fn f(x: u64) u64 {
            return x | (x << 16) | (x << 32) | (x << 48);
        }
    }.f;
    const imm64: u64 = switch (cmode) {
        0, 1 => rep32(imm8),
        2, 3 => rep32(imm8 << 8),
        4, 5 => rep32(imm8 << 16),
        6, 7 => rep32(imm8 << 24),
        8, 9 => rep16(imm8),
        10, 11 => rep16(imm8 << 8),
        12 => rep32((imm8 << 8) | 0xff),
        13 => rep32((imm8 << 16) | 0xffff),
        14 => if (!op) rep16(imm8 | (imm8 << 8)) else blk: {
            var x: u64 = 0;
            for (0..8) |i| {
                if (((imm8 >> @intCast(i)) & 1) != 0) x |= @as(u64, 0xff) << @intCast(i * 8);
            }
            break :blk x;
        },
        15 => blk: {
            if (op) return false;
            const bb: u64 = (imm8 >> 6) & 1;
            const f: u64 = ((imm8 >> 7) << 31) | ((bb ^ 1) << 30) | ((if (bb == 1) @as(u64, 0x1f) else 0) << 25) | ((imm8 & 0x3f) << 19);
            break :blk rep32(f);
        },
    };
    const regs: u2 = if (q) 2 else 1;
    var r = getRegs(v, d, regs);
    const orr = (cmode & 1) == 1 and cmode < 12; // VORR / VBIC
    for (0..regs) |i| {
        r[i] = if (orr) (if (op) r[i] & ~imm64 else r[i] | imm64) else if (op and cmode != 14) ~imm64 else imm64;
    }
    setRegs(v, d, regs, r);
    return true;
}

// --- Two registers, miscellaneous ----------------------------------------------------------------

fn twoRegMisc(v: *Vfp, inst: u32) bool {
    const size: u2 = @truncate(inst >> 18);
    const opc1: u2 = @truncate(inst >> 16);
    const opc2: u4 = @truncate(inst >> 7);
    const q = bit(inst, 6) == 1;
    const d = regD(inst);
    const m = regM(inst);
    const esize: u7 = @as(u7, 8) << size;
    const regs: u2 = if (q) 2 else 1;

    // Narrowing / lengthening forms with D and Q operands of different sizes
    if (opc1 == 0b10 and (opc2 == 0b0100 or opc2 == 0b0101 or opc2 == 0b0110)) return miscNarrowLong(v, inst);
    if (opc1 == 0b10 and (opc2 == 0b1100 or opc2 == 0b1110)) return vcvtHalf(v, inst);

    if (q and ((d | m) & 1) != 0) return false;
    if (size == 3) return false;
    const xm = getRegs(v, m, regs);
    const xd = getRegs(v, d, regs);
    var r = xd;
    const lanes: usize = (@as(usize, regs) * 64) / esize;

    switch (opc1) {
        0b00 => switch (opc2) {
            0b0000, 0b0001, 0b0010 => { // VREV64 / VREV32 / VREV16
                const group: u7 = @as(u7, 64) >> @intCast(opc2);
                if (esize >= group) return false;
                const per: usize = group / esize;
                for (0..lanes) |e| {
                    const base = (e / per) * per;
                    setElem(&r, e, esize, elem(xm, base + (per - 1 - (e - base)), esize));
                }
            },
            0b0100, 0b0101, 0b1100, 0b1101 => { // VPADDL / VPADAL
                const unsigned = (opc2 & 1) == 1;
                const acc = (opc2 & 0b1000) != 0;
                const wsize = esize * 2;
                for (0..lanes / 2) |e| {
                    const s = ival(elem(xm, 2 * e, esize), esize, !unsigned) + ival(elem(xm, 2 * e + 1, esize), esize, !unsigned);
                    const base: i128 = if (acc) elem(xd, e, wsize) else 0;
                    setElem(&r, e, wsize, trunc(base + s, wsize));
                }
            },
            0b1000 => { // VCLS
                for (0..lanes) |e| {
                    const x = elem(xm, e, esize);
                    const sign = (x >> @intCast(esize - 1)) & 1;
                    const y = if (sign == 1) ~x & emask(esize) else x;
                    const lz: u64 = if (y == 0) esize else @clz(y) - (64 - @as(u64, esize));
                    setElem(&r, e, esize, lz - 1);
                }
            },
            0b1001 => { // VCLZ
                for (0..lanes) |e| {
                    const x = elem(xm, e, esize);
                    setElem(&r, e, esize, if (x == 0) esize else @clz(x) - (64 - @as(u64, esize)));
                }
            },
            0b1010 => { // VCNT
                if (size != 0) return false;
                for (0..lanes) |e| setElem(&r, e, 8, @popCount(elem(xm, e, 8)));
            },
            0b1011 => { // VMVN
                if (size != 0) return false;
                r = .{ ~xm[0], ~xm[1] };
            },
            0b1110, 0b1111 => { // VQABS / VQNEG
                for (0..lanes) |e| {
                    const x = ival(elem(xm, e, esize), esize, true);
                    setElem(&r, e, esize, sat(v, if (opc2 == 0b1110) @as(i128, @intCast(@abs(x))) else -x, esize, true));
                }
            },
            else => return false, // AESE / AESD / AESMC / AESIMC (Cryptography Extension)
        },
        0b01 => {
            const float = (opc2 & 0b1000) != 0;
            if (float and size != 2) return false;
            const kind: u3 = @truncate(opc2);
            if (kind == 0b101) return false; // SHA1H (Cryptography Extension)
            for (0..lanes) |e| {
                const x = elem(xm, e, esize);
                const res: u64 = if (float) blk: {
                    const f = fin(x);
                    break :blk switch (kind) {
                        0b000 => if (f > 0) 0xffff_ffff else 0, // VCGT #0
                        0b001 => if (f >= 0) 0xffff_ffff else 0, // VCGE #0
                        0b010 => if (f == 0) 0xffff_ffff else 0, // VCEQ #0
                        0b011 => if (f <= 0) 0xffff_ffff else 0, // VCLE #0
                        0b100 => if (f < 0) 0xffff_ffff else 0, // VCLT #0
                        0b110 => x & 0x7fff_ffff, // VABS
                        0b111 => x ^ 0x8000_0000, // VNEG
                        else => unreachable,
                    };
                } else blk: {
                    const s = sext(x, esize);
                    break :blk switch (kind) {
                        0b000 => if (s > 0) emask(esize) else 0,
                        0b001 => if (s >= 0) emask(esize) else 0,
                        0b010 => if (s == 0) emask(esize) else 0,
                        0b011 => if (s <= 0) emask(esize) else 0,
                        0b100 => if (s < 0) emask(esize) else 0,
                        0b110 => trunc(@intCast(@abs(@as(i128, s))), esize),
                        0b111 => trunc(-@as(i128, s), esize),
                        else => unreachable,
                    };
                };
                setElem(&r, e, esize, res);
            }
        },
        0b10 => switch (opc2) {
            0b0000 => { // VSWP
                if (size != 0) return false;
                setRegs(v, d, regs, xm);
                setRegs(v, m, regs, xd);
                return true;
            },
            0b0001, 0b0010, 0b0011 => return vtrnUzpZip(v, opc2, d, m, regs, esize, xd, xm),
            0b1000, 0b1001, 0b1010, 0b1011, 0b1101, 0b1111 => { // VRINTN / X / A / Z / M / P
                if (size != 2) return false;
                const mode: RoundMode = switch (opc2) {
                    0b1000, 0b1001 => .nearest_even,
                    0b1010 => .nearest_away,
                    0b1011 => .zero,
                    0b1101 => .minus_inf,
                    else => .plus_inf,
                };
                for (0..lanes) |e| setElem(&r, e, 32, fpRoundInt(@truncate(elem(xm, e, 32)), mode));
            },
            else => return false, // SHA1SU1 / SHA256SU0 (Cryptography Extension)
        },
        0b11 => {
            if (size != 2) return false;
            if ((opc2 & 0b1000) == 0) { // VCVTA / VCVTN / VCVTP / VCVTM
                const mode: RoundMode = switch ((opc2 >> 1) & 3) {
                    0 => .nearest_away,
                    1 => .nearest_even,
                    2 => .plus_inf,
                    else => .minus_inf,
                };
                const unsigned = (opc2 & 1) == 1;
                for (0..lanes) |e| setElem(&r, e, 32, fpToInt(fin(elem(xm, e, 32)), !unsigned, mode));
            } else if ((opc2 & 0b1100) == 0b1000) { // VRECPE / VRSQRTE
                const float = (opc2 & 0b0010) != 0;
                const sqrt = (opc2 & 1) == 1;
                for (0..lanes) |e| {
                    const x: u32 = @truncate(elem(xm, e, 32));
                    setElem(&r, e, 32, if (float)
                        (if (sqrt) fpRSqrtEstimate(x) else fpRecipEstimate(x))
                    else if (sqrt) unsignedRSqrtEstimate(x) else unsignedRecipEstimate(x));
                }
            } else { // VCVT between floating point and integer
                const to_int = (opc2 & 0b0010) != 0;
                const unsigned = (opc2 & 1) == 1;
                for (0..lanes) |e| {
                    const x: u32 = @truncate(elem(xm, e, 32));
                    setElem(&r, e, 32, if (to_int)
                        fpToInt(fin(x), !unsigned, .zero)
                    else
                        fout(if (unsigned) @floatFromInt(x) else @floatFromInt(@as(i32, @bitCast(x)))));
                }
            }
        },
    }
    setRegs(v, d, regs, r);
    return true;
}

fn vtrnUzpZip(v: *Vfp, opc2: u4, d: u5, m: u5, regs: u2, esize: u7, xd: [2]u64, xm: [2]u64) bool {
    const lanes: usize = (@as(usize, regs) * 64) / esize;
    var rd = xd;
    var rm = xm;
    switch (opc2) {
        0b0001 => { // VTRN
            var e: usize = 0;
            while (e < lanes) : (e += 2) {
                setElem(&rd, e + 1, esize, elem(xm, e, esize));
                setElem(&rm, e, esize, elem(xd, e + 1, esize));
            }
        },
        0b0010 => { // VUZP
            if (regs == 1 and esize == 32) return false;
            for (0..lanes) |e| {
                const src = 2 * e;
                setElem(&rd, e, esize, if (src < lanes) elem(xd, src, esize) else elem(xm, src - lanes, esize));
                setElem(&rm, e, esize, if (src + 1 < lanes) elem(xd, src + 1, esize) else elem(xm, src + 1 - lanes, esize));
            }
        },
        else => { // VZIP
            if (regs == 1 and esize == 32) return false;
            for (0..lanes) |e| {
                const half = lanes / 2;
                // Interleave: result[2i] = d[i], result[2i+1] = m[i]; Dd gets the low half, Dm the high
                const i_lo = e / 2;
                const src_lo = if ((e & 1) == 0) elem(xd, i_lo, esize) else elem(xm, i_lo, esize);
                const i_hi = half + e / 2;
                const src_hi = if ((e & 1) == 0) elem(xd, i_hi, esize) else elem(xm, i_hi, esize);
                setElem(&rd, e, esize, src_lo);
                setElem(&rm, e, esize, src_hi);
            }
        },
    }
    setRegs(v, d, regs, rd);
    setRegs(v, m, regs, rm);
    return true;
}

fn miscNarrowLong(v: *Vfp, inst: u32) bool {
    const size: u2 = @truncate(inst >> 18);
    const opc2: u4 = @truncate(inst >> 7);
    const q = bit(inst, 6) == 1;
    const d = regD(inst);
    const m = regM(inst);
    if (size == 3) return false;
    const esize: u7 = @as(u7, 8) << size;
    const wsize = esize * 2;
    const lanes: usize = 64 / @as(usize, esize);
    if (opc2 == 0b0110) { // VSHLL (shift by the element size)
        if (q or (d & 1) != 0) return false;
        const xm = getRegs(v, m, 1);
        var r: [2]u64 = .{ 0, 0 };
        for (0..lanes) |e| setElem(&r, e, wsize, (elem(xm, e, esize) << @intCast(esize)) & emask(wsize));
        setRegs(v, d, 2, r);
        return true;
    }
    if ((m & 1) != 0) return false;
    const xm = getRegs(v, m, 2);
    var r: [2]u64 = .{ 0, 0 };
    for (0..lanes) |e| {
        const x = elem(xm, e, wsize);
        const res: u64 = if (opc2 == 0b0100 and !q)
            x & emask(esize) // VMOVN
        else if (opc2 == 0b0100)
            sat(v, ival(x, wsize, true), esize, false) // VQMOVUN
        else
            sat(v, ival(x, wsize, !q), esize, !q); // VQMOVN (Q bit = unsigned)
        setElem(&r, e, esize, res);
    }
    setD(v, d, r[0]);
    return true;
}

fn vcvtHalf(v: *Vfp, inst: u32) bool {
    const size: u2 = @truncate(inst >> 18);
    const to_single = bit(inst, 8) == 1;
    const d = regD(inst);
    const m = regM(inst);
    if (size != 1 or bit(inst, 6) == 1) return false;
    // The standard FPSCR value: default NaN, flush to zero, round to nearest, but FPSCR.AHP kept
    const mode: vfp_mod.HalfMode = .{ .ahp = (v.fpscr & (1 << 26)) != 0, .dn = true, .fz = true };
    if (to_single) {
        if ((d & 1) != 0) return false;
        const xm = getRegs(v, m, 1);
        var r: [2]u64 = .{ 0, 0 };
        for (0..4) |e| setElem(&r, e, 32, vfp_mod.halfToSingle(@truncate(elem(xm, e, 16)), mode));
        setRegs(v, d, 2, r);
    } else {
        if ((m & 1) != 0) return false;
        const xm = getRegs(v, m, 2);
        var r: [2]u64 = .{ 0, 0 };
        for (0..4) |e| setElem(&r, e, 16, vfp_mod.singleToHalf(@truncate(elem(xm, e, 32)), mode));
        setD(v, d, r[0]);
    }
    return true;
}

// --- VEXT, VTBL / VTBX, VDUP (scalar) ------------------------------------------------------------

fn vext(v: *Vfp, inst: u32) bool {
    const q = bit(inst, 6) == 1;
    const imm4: usize = (inst >> 8) & 0xf;
    const d = regD(inst);
    const n = regN(inst);
    const m = regM(inst);
    if (q and ((d | n | m) & 1) != 0) return false;
    if (!q and imm4 >= 8) return false;
    const regs: u2 = if (q) 2 else 1;
    const bytes: usize = @as(usize, regs) * 8;
    const xn = getRegs(v, n, regs);
    const xm = getRegs(v, m, regs);
    var r: [2]u64 = .{ 0, 0 };
    for (0..bytes) |i| {
        const src = i + imm4;
        setElem(&r, i, 8, if (src < bytes) elem(xn, src, 8) else elem(xm, src - bytes, 8));
    }
    setRegs(v, d, regs, r);
    return true;
}

fn vtbl(v: *Vfp, inst: u32) bool {
    const len: usize = ((inst >> 8) & 3) + 1;
    const extension = bit(inst, 6) == 1;
    const d = regD(inst);
    const n = regN(inst);
    const m = regM(inst);
    if (@as(usize, n) + len > 32) return false;
    var table: [32]u8 = undefined;
    for (0..len) |i| std.mem.writeInt(u64, table[i * 8 ..][0..8], getD(v, @intCast(n + i)), .little);
    const idx = getD(v, m);
    const old = getD(v, d);
    var r: u64 = 0;
    for (0..8) |i| {
        const j: usize = @as(u8, @truncate(idx >> @intCast(i * 8)));
        const byte: u64 = if (j < len * 8) table[j] else if (extension) (old >> @intCast(i * 8)) & 0xff else 0;
        r |= byte << @intCast(i * 8);
    }
    setD(v, d, r);
    return true;
}

fn vdupScalar(v: *Vfp, inst: u32) bool {
    const q = bit(inst, 6) == 1;
    const imm4: u4 = @truncate(inst >> 16);
    const d = regD(inst);
    const m = regM(inst);
    if (q and (d & 1) != 0) return false;
    const esize: u7, const index: usize = if ((imm4 & 1) != 0)
        .{ 8, imm4 >> 1 }
    else if ((imm4 & 2) != 0)
        .{ 16, imm4 >> 2 }
    else if ((imm4 & 4) != 0)
        .{ 32, imm4 >> 3 }
    else
        return false;
    const x = elem(.{ getD(v, m), 0 }, index, esize);
    const regs: u2 = if (q) 2 else 1;
    var r: [2]u64 = .{ 0, 0 };
    for (0..(@as(usize, regs) * 64) / esize) |e| setElem(&r, e, esize, x);
    setRegs(v, d, regs, r);
    return true;
}

// --- Transfers between ARM core registers and scalars --------------------------------------------

/// `VMOV` between an ARM core register and a scalar (8, 16 or 32 bits) and `VDUP` from a core
/// register (`cond 1110 xxxx xxxx xxxx 1011 xxx1 0000`). Returns false if it is Undefined.
pub fn executeCoreTransfer(v: *Vfp, regs: *[16]u32, inst: u32) bool {
    const l = bit(inst, 20) == 1;
    const rt: u4 = @truncate(inst >> 12);
    if (rt == 15) return false;
    const vn: u5 = @truncate((@as(u32, bit(inst, 7)) << 4) | ((inst >> 16) & 0xf));
    if (!l and bit(inst, 23) == 1) { // VDUP
        if (bit(inst, 6) == 1) return false;
        const q = bit(inst, 21) == 1;
        if (q and (vn & 1) != 0) return false;
        const esize: u7 = switch ((@as(u2, bit(inst, 22)) << 1) | bit(inst, 5)) {
            0b00 => 32,
            0b01 => 16,
            0b10 => 8,
            else => return false,
        };
        const nregs: u2 = if (q) 2 else 1;
        var r: [2]u64 = .{ 0, 0 };
        for (0..(@as(usize, nregs) * 64) / esize) |e| setElem(&r, e, esize, regs[rt]);
        setRegs(v, vn, nregs, r);
        return true;
    }
    const opc: u5 = @truncate(((inst >> 21) & 3) << 2 | ((inst >> 5) & 3));
    const unsigned = bit(inst, 23) == 1;
    const esize: u7, const index: usize = if ((opc & 0b01000) != 0)
        .{ 8, opc & 7 }
    else if ((opc & 1) != 0)
        .{ 16, (opc >> 1) & 3 }
    else if ((opc & 0b10) == 0)
        .{ 32, (opc >> 2) & 1 }
    else
        return false;
    if (esize == 32 and unsigned) return false;
    var x: [2]u64 = .{ getD(v, vn), 0 };
    if (l) {
        const e = elem(x, index, esize);
        regs[rt] = @truncate(if (unsigned or esize == 32) e else @as(u64, @bitCast(sext(e, esize))));
    } else {
        setElem(&x, index, esize, regs[rt]);
        setD(v, vn, x[0]);
    }
    return true;
}

// --- Element and structure loads and stores ------------------------------------------------------

pub const MemError = error{ Undefined, Abort, Alignment };

/// Executes `VLD1`-`VLD4` / `VST1`-`VST4` (`1111 0100 xxx0 ...`). `cpu` provides the registers
/// (`r`, `vfp`) and the memory accessors (`read8` ... `write32`), which raise `error.Abort`.
/// Returns `error.Alignment` (with the address in `fault_addr`) for a misaligned access whose
/// encoding requires alignment.
pub fn executeLoadStore(cpu: anytype, bus: anytype, inst: u32, fault_addr: *u32) MemError!void {
    const a = bit(inst, 23) == 1;
    const l = bit(inst, 21) == 1;
    const rn: u4 = @truncate(inst >> 16);
    const rm: u4 = @truncate(inst);
    const d = regD(inst);
    const b: u4 = @truncate(inst >> 8);
    if (rn == 15) return error.Undefined;
    const base = cpu.r[rn];
    var layout: Layout = undefined;
    if (!a) {
        layout = try multipleLayout(inst, b, d);
    } else if ((b & 0b1100) == 0b1100) {
        if (!l) return error.Undefined;
        layout = try allLanesLayout(inst, b, d);
    } else {
        layout = try laneLayout(inst, b, d);
    }
    if (layout.alignment > 1 and (base & (layout.alignment - 1)) != 0) {
        fault_addr.* = base;
        return error.Alignment;
    }

    const ebytes: u32 = layout.esize / 8;
    var addr = base;
    const v = &cpu.vfp;
    switch (layout.kind) {
        .multiple => {
            const lanes: usize = 64 / @as(usize, layout.esize);
            for (0..layout.groups) |g| {
                for (0..lanes) |e| {
                    for (0..layout.nstruct) |s| {
                        const reg: u5 = @intCast(d + g * layout.group_stride + s * layout.inc);
                        var x: [2]u64 = .{ getD(v, reg), 0 };
                        if (l) {
                            setElem(&x, e, layout.esize, try readElem(cpu, bus, addr, ebytes));
                            setD(v, reg, x[0]);
                        } else {
                            try writeElem(cpu, bus, addr, ebytes, elem(x, e, layout.esize));
                        }
                        addr +%= ebytes;
                    }
                }
            }
        },
        .lane => {
            for (0..layout.nstruct) |s| {
                const reg: u5 = @intCast(d + s * layout.inc);
                var x: [2]u64 = .{ getD(v, reg), 0 };
                if (l) {
                    setElem(&x, layout.index, layout.esize, try readElem(cpu, bus, addr, ebytes));
                    setD(v, reg, x[0]);
                } else {
                    try writeElem(cpu, bus, addr, ebytes, elem(x, layout.index, layout.esize));
                }
                addr +%= ebytes;
            }
        },
        .all_lanes => {
            var vals: [4]u64 = undefined;
            for (0..layout.nstruct) |s| {
                vals[s] = try readElem(cpu, bus, addr, ebytes);
                addr +%= ebytes;
            }
            for (0..layout.nstruct) |s| {
                var x: [2]u64 = .{ 0, 0 };
                for (0..64 / @as(usize, layout.esize)) |e| setElem(&x, e, layout.esize, vals[s]);
                for (0..layout.groups) |g| setD(v, @intCast(d + s * layout.inc + g), x[0]);
            }
        },
    }

    if (rm != 15) {
        cpu.r[rn] = base +% (if (rm == 13) addr -% base else cpu.r[rm]);
    }
}

const Layout = struct {
    kind: enum { multiple, lane, all_lanes },
    esize: u7,
    /// Structure size (VLDn: n)
    nstruct: usize,
    /// Register spacing within a structure
    inc: usize,
    /// VLD1/VLD2 multiple: number of register groups; all lanes: registers written per element
    groups: usize = 1,
    group_stride: usize = 0,
    index: usize = 0,
    alignment: u32 = 1,
};

fn multipleLayout(inst: u32, ty: u4, d: u5) MemError!Layout {
    const size: u2 = @truncate(inst >> 6);
    const align_f: u2 = @truncate(inst >> 4);
    const esize: u7 = @as(u7, 8) << size;
    var lay: Layout = .{ .kind = .multiple, .esize = esize, .nstruct = 1, .inc = 1 };
    switch (ty) {
        0b0111, 0b1010, 0b0110, 0b0010 => { // VLD1 / VST1: 1, 2, 3 or 4 registers
            const nregs: usize = switch (ty) {
                0b0111 => 1,
                0b1010 => 2,
                0b0110 => 3,
                else => 4,
            };
            if ((nregs == 1 or nregs == 3) and (align_f & 2) != 0) return error.Undefined;
            if (nregs == 2 and align_f == 3) return error.Undefined;
            lay.groups = nregs;
            lay.group_stride = 1;
        },
        0b1000, 0b1001, 0b0011 => { // VLD2 / VST2
            if (size == 3) return error.Undefined;
            if (ty != 0b0011 and align_f == 3) return error.Undefined;
            lay.nstruct = 2;
            lay.inc = if (ty == 0b1000) 1 else 2;
            if (ty == 0b0011) {
                // Two structures of register pairs: {Dd, Dd+2}, then {Dd+1, Dd+3}
                lay.groups = 2;
                lay.group_stride = 1;
            }
        },
        0b0100, 0b0101 => { // VLD3 / VST3
            if (size == 3 or (align_f & 2) != 0) return error.Undefined;
            lay.nstruct = 3;
            lay.inc = if (ty == 0b0101) 2 else 1;
        },
        0b0000, 0b0001 => { // VLD4 / VST4
            if (size == 3) return error.Undefined;
            lay.nstruct = 4;
            lay.inc = if (ty == 0b0001) 2 else 1;
        },
        else => return error.Undefined,
    }
    const last: usize = @as(usize, d) + (lay.groups - 1) * lay.group_stride + (lay.nstruct - 1) * lay.inc;
    if (last > 31) return error.Undefined;
    if (align_f != 0) lay.alignment = @as(u32, 4) << align_f;
    return lay;
}

fn laneLayout(inst: u32, b: u4, d: u5) MemError!Layout {
    const size: u2 = @truncate(b >> 2);
    const n: usize = (b & 3) + 1;
    const ia: u4 = @truncate(inst >> 4);
    const esize: u7 = @as(u7, 8) << size;
    var lay: Layout = .{ .kind = .lane, .esize = esize, .nstruct = n, .inc = 1 };
    switch (size) {
        0 => {
            lay.index = ia >> 1;
            switch (n) {
                1, 3 => if ((ia & 1) != 0) return error.Undefined,
                2 => if ((ia & 1) != 0) {
                    lay.alignment = 2;
                },
                else => if ((ia & 1) != 0) {
                    lay.alignment = 4;
                },
            }
        },
        1 => {
            lay.index = ia >> 2;
            if (n != 1 and (ia & 2) != 0) lay.inc = 2;
            switch (n) {
                1 => {
                    if ((ia & 2) != 0) return error.Undefined;
                    if ((ia & 1) != 0) lay.alignment = 2;
                },
                2 => if ((ia & 1) != 0) {
                    lay.alignment = 4;
                },
                3 => if ((ia & 1) != 0) return error.Undefined,
                else => if ((ia & 1) != 0) {
                    lay.alignment = 8;
                },
            }
        },
        2 => {
            lay.index = ia >> 3;
            if (n != 1 and (ia & 4) != 0) lay.inc = 2;
            switch (n) {
                1 => {
                    if ((ia & 4) != 0) return error.Undefined;
                    switch (ia & 3) {
                        0 => {},
                        3 => lay.alignment = 4,
                        else => return error.Undefined,
                    }
                },
                2 => {
                    if ((ia & 2) != 0) return error.Undefined;
                    if ((ia & 1) != 0) lay.alignment = 8;
                },
                3 => if ((ia & 3) != 0) return error.Undefined,
                else => switch (ia & 3) {
                    0 => {},
                    1 => lay.alignment = 8,
                    2 => lay.alignment = 16,
                    else => return error.Undefined,
                },
            }
        },
        3 => return error.Undefined,
    }
    if (@as(usize, d) + (n - 1) * lay.inc > 31) return error.Undefined;
    return lay;
}

fn allLanesLayout(inst: u32, b: u4, d: u5) MemError!Layout {
    const n: usize = (b & 3) + 1;
    const size: u2 = @truncate(inst >> 6);
    const t = bit(inst, 5) == 1;
    const a = bit(inst, 4) == 1;
    var esize: u7 = @as(u7, 8) << size;
    var lay: Layout = .{ .kind = .all_lanes, .esize = esize, .nstruct = n, .inc = if (t) 2 else 1 };
    switch (n) {
        1 => {
            if (size == 3 or (size == 0 and a)) return error.Undefined;
            lay.inc = 1;
            lay.groups = if (t) 2 else 1;
            if (a) lay.alignment = esize / 8;
        },
        2 => {
            if (size == 3) return error.Undefined;
            if (a) lay.alignment = (esize / 8) * 2;
        },
        3 => {
            if (size == 3 or a) return error.Undefined;
        },
        else => {
            if (size == 3) {
                if (!a) return error.Undefined;
                esize = 32;
                lay.esize = 32;
                lay.alignment = 16;
            } else if (a) {
                lay.alignment = if (size == 2) 8 else (esize / 8) * 4;
            }
        },
    }
    const last = @as(usize, d) + (lay.groups - 1) + (n - 1) * lay.inc;
    if (last > 31) return error.Undefined;
    return lay;
}

fn readElem(cpu: anytype, bus: anytype, addr: u32, ebytes: u32) MemError!u64 {
    return switch (ebytes) {
        1 => try cpu.read8(bus, addr),
        2 => try cpu.read16(bus, addr),
        4 => try cpu.read32(bus, addr),
        else => blk: {
            const lo: u64 = try cpu.read32(bus, addr);
            const hi: u64 = try cpu.read32(bus, addr +% 4);
            // A big-endian doubleword has its most significant word first
            break :blk if (cpu.bigEndianData()) (lo << 32) | hi else lo | (hi << 32);
        },
    };
}

fn writeElem(cpu: anytype, bus: anytype, addr: u32, ebytes: u32, val: u64) MemError!void {
    switch (ebytes) {
        1 => try cpu.write8(bus, addr, @truncate(val)),
        2 => try cpu.write16(bus, addr, @truncate(val)),
        4 => try cpu.write32(bus, addr, @truncate(val)),
        else => {
            const first: u32 = @truncate(if (cpu.bigEndianData()) val >> 32 else val);
            const second: u32 = @truncate(if (cpu.bigEndianData()) val else val >> 32);
            try cpu.write32(bus, addr, first);
            try cpu.write32(bus, addr +% 4, second);
        },
    }
}

// --- Tests ---------------------------------------------------------------------------------------

const arm1176 = @import("arm1176.zig");

/// The test bus: RAM at 0, with the oracle's buffer (at `BUF_ADDR`) mapped after the code.
const TestBus = struct {
    ram: []u8,
    const BUF_ADDR: u32 = 0x4010_0000;
    const BUF_OFFSET: u32 = 0x1_0000;
    fn at(self: *@This(), paddr: u32) usize {
        if (paddr >= BUF_ADDR and paddr < BUF_ADDR + 0x1_0000) return BUF_OFFSET + (paddr - BUF_ADDR);
        return paddr % @as(u32, @intCast(self.ram.len));
    }
    pub fn hasPendingIrq(_: *const @This()) bool {
        return false;
    }
    pub fn hasPendingFiq(_: *const @This()) bool {
        return false;
    }
    pub fn read32(self: *@This(), paddr: u32) u32 {
        return std.mem.readInt(u32, self.ram[self.at(paddr)..][0..4], .little);
    }
    pub fn write32(self: *@This(), paddr: u32, val: u32) void {
        std.mem.writeInt(u32, self.ram[self.at(paddr)..][0..4], val, .little);
    }
    pub fn read16(self: *@This(), paddr: u32) u16 {
        return std.mem.readInt(u16, self.ram[self.at(paddr)..][0..2], .little);
    }
    pub fn write16(self: *@This(), paddr: u32, val: u16) void {
        std.mem.writeInt(u16, self.ram[self.at(paddr)..][0..2], val, .little);
    }
    pub fn read8(self: *@This(), paddr: u32) u8 {
        return self.ram[self.at(paddr)];
    }
    pub fn write8(self: *@This(), paddr: u32, val: u8) void {
        self.ram[self.at(paddr)] = val;
    }
};

const Oracle = struct {
    // Must match scripts/neon-oracle/oracle.h and harness.c
    const BUF_SIZE = 2048;
    const BUF_PTR_MIN = 0x100;
    const BUF_PTR_SPAN = 0x500;
    const CPSR_MASK: u32 = 0xf80f_0000;
    const FPSCR_MASK: u32 = 0xf800_0000;
    const FPSCR_INPUT_MASK: u32 = 0xffc0_0000;
    const special = [20]u32{
        0x00000000, 0x80000000, 0x3f800000, 0xbf800000, 0x7f800000, 0xff800000, 0x7fc00000,
        0x7f800001, 0x00000001, 0x807fffff, 0x00800000, 0x7f7fffff, 0x7fffffff, 0x80008000,
        0x7f7f7f7f, 0xffffffff, 0x4f000000, 0xcf000000, 0x3f000000, 0x00400000,
    };

    rng: u64,

    fn next(self: *Oracle) u64 {
        self.rng +%= 0x9e37_79b9_7f4a_7c15;
        var z = self.rng;
        z = (z ^ (z >> 30)) *% 0xbf58_476d_1ce4_e5b9;
        z = (z ^ (z >> 27)) *% 0x94d0_49bb_1331_11eb;
        return z ^ (z >> 31);
    }

    fn fnv(h: *u64, bytes: []const u8) void {
        for (bytes) |b| {
            h.* ^= b;
            h.* *%= 0x100_0000_01b3;
        }
    }
};

test "Advanced SIMD matches QEMU on the oracle's test vectors" {
    const Cpu = arm1176.Arm1176(TestBus);
    const allocator = std.testing.allocator;
    const ram = try allocator.alloc(u8, 0x2_0000);
    defer allocator.free(ram);
    @memset(ram, 0);
    var bus: TestBus = .{ .ram = ram };
    const cpu = try allocator.create(Cpu);
    defer allocator.destroy(cpu);
    cpu.* = .{};
    cpu.initReset(0x1000, 0, 0, 0);
    cpu.mmu.is_cortex_a53 = true;
    cpu.vfp.is_vfpv4 = true;
    cpu.mmu.cpacr = 0xf << 20;
    cpu.mmu.sctlr |= 1 << 22;
    cpu.vfp.fpexc = 1 << 30;
    // Exception vectors: b .
    for (0..8) |i| std.mem.writeInt(u32, ram[i * 4 ..][0..4], 0xeafffffe, .little);
    std.mem.writeInt(u32, ram[0x1004..][0..4], 0xeafffffe, .little);

    var failures: usize = 0;
    var count: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, @embedFile("testdata/neon_vectors.txt"), '\n');
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const inst = try std.fmt.parseInt(u32, fields.next().?, 16);
        const want_status = try std.fmt.parseInt(u32, fields.next().?, 10);
        const want_hash = try std.fmt.parseInt(u32, fields.next().?, 16);
        const index = try std.fmt.parseInt(u64, fields.next().?, 16);
        count += 1;

        var o: Oracle = .{ .rng = index *% 0x9e37_79b9_7f4a_7c15 +% 1 };
        for (0..32) |i| cpu.vfp.setDU64(@intCast(i), o.next());
        for (0..8) |i| cpu.r[i] = @truncate(o.next());
        for (8..13) |i| cpu.r[i] = TestBus.BUF_ADDR + Oracle.BUF_PTR_MIN + @as(u32, @intCast(o.next() % Oracle.BUF_PTR_SPAN));
        const flags: u32 = @as(u32, @truncate(o.next())) & Oracle.CPSR_MASK;
        cpu.setCpsr(flags | PsrFlags.I | PsrFlags.F | @backingInt(arm1176.Mode.svc));
        cpu.vfp.fpscr = @as(u32, @truncate(o.next())) & Oracle.FPSCR_INPUT_MASK;
        const buf = ram[TestBus.BUF_OFFSET..][0..Oracle.BUF_SIZE];
        for (0..Oracle.BUF_SIZE / 8) |i| std.mem.writeInt(u64, buf[i * 8 ..][0..8], o.next(), .little);
        if (index % 3 == 1) {
            for (0..64) |i| {
                const sel = o.next() % 24;
                if (sel < 20) cpu.vfp.s[i] = Oracle.special[sel];
            }
        }

        std.mem.writeInt(u32, ram[0x1000..][0..4], inst, .little);
        cpu.invalidateIcache();
        cpu.r[15] = 0x1000;
        _ = cpu.runSteps(&bus, 1);

        const status: u32 = switch (cpu.mode()) {
            .und => 1,
            .abt => 2,
            else => 0,
        };
        var h: u64 = 0xcbf2_9ce4_8422_2325;
        Oracle.fnv(&h, std.mem.asBytes(&status));
        for (0..32) |i| Oracle.fnv(&h, std.mem.asBytes(&cpu.vfp.getDU64(@intCast(i))));
        for (0..13) |i| Oracle.fnv(&h, std.mem.asBytes(&cpu.r[i]));
        Oracle.fnv(&h, std.mem.asBytes(&(cpu.cpsr & Oracle.CPSR_MASK)));
        Oracle.fnv(&h, std.mem.asBytes(&(cpu.vfp.fpscr & Oracle.FPSCR_MASK)));
        Oracle.fnv(&h, buf);
        if (@as(u32, @truncate(h)) != want_hash) {
            if (failures < 40) std.debug.print("neon vector {x:0>8} (test {x}): status {d}, expected {d}\n", .{ inst, index, status, want_status });
            failures += 1;
        }
    }
    if (failures != 0) std.debug.print("neon vectors: {d} of {d} failed\n", .{ failures, count });
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "Advanced SIMD alignment faults, register limits, big-endian elements and enables" {
    const Cpu = arm1176.Arm1176(TestBus);
    const allocator = std.testing.allocator;
    const ram = try allocator.alloc(u8, 0x2_0000);
    defer allocator.free(ram);
    @memset(ram, 0);
    var bus: TestBus = .{ .ram = ram };
    const cpu = try allocator.create(Cpu);
    defer allocator.destroy(cpu);
    for (0..8) |i| std.mem.writeInt(u32, ram[i * 4 ..][0..4], 0xeafffffe, .little);
    for (0..8) |i| ram[TestBus.BUF_OFFSET + 0x200 + i] = @intCast(i);

    const run = struct {
        fn f(c: *Cpu, b: *TestBus, prog: []const u32, a53: bool) void {
            c.* = .{};
            c.initReset(0x1000, 0, 0, 0);
            c.mmu.is_cortex_a53 = a53;
            c.vfp.is_vfpv4 = a53;
            c.mmu.cpacr = 0xf << 20;
            c.vfp.fpexc = 1 << 30;
            for (prog, 0..) |inst, i| std.mem.writeInt(u32, b.ram[0x1000 + i * 4 ..][0..4], inst, .little);
            c.invalidateIcache();
        }
    }.f;

    // A single-element load with an alignment hint faults on a misaligned address, without writeback
    run(cpu, &bus, &.{0xf4a0045d}, true); // vld1.16 {d0[1]}, [r0:16]!
    cpu.r[0] = TestBus.BUF_ADDR + 0x101;
    _ = cpu.runSteps(&bus, 1);
    try std.testing.expectEqual(arm1176.Mode.abt, cpu.mode());
    try std.testing.expectEqual(@as(u32, 0x001), cpu.mmu.dfsr);
    try std.testing.expectEqual(TestBus.BUF_ADDR + 0x101, cpu.mmu.dfar);
    try std.testing.expectEqual(TestBus.BUF_ADDR + 0x101, cpu.r[0]);

    // A register list running past D31 is Undefined: vld4.8 {d30, d32, d34, d36}, [r1]
    run(cpu, &bus, &.{0xf461e10f}, true);
    cpu.r[1] = TestBus.BUF_ADDR + 0x200;
    _ = cpu.runSteps(&bus, 1);
    try std.testing.expectEqual(arm1176.Mode.und, cpu.mode());

    // Big-endian data reverses the bytes of each element:
    // setend be; vld1.16 {d1}, [r1]; vld1.64 {d2}, [r1]; vst1.32 {d1}, [r2]; setend le
    run(cpu, &bus, &.{ 0xf1010200, 0xf421174f, 0xf42127cf, 0xf402178f, 0xf1010000, 0xeafffffe }, true);
    cpu.r[1] = TestBus.BUF_ADDR + 0x200;
    cpu.r[2] = TestBus.BUF_ADDR + 0x300;
    for (0..20) |_| _ = cpu.runSteps(&bus, 1);
    try std.testing.expectEqual(@as(u32, 0x1014), cpu.r[15]);
    try std.testing.expectEqual(@as(u64, 0x0607_0405_0203_0001), cpu.vfp.getDU64(1));
    try std.testing.expectEqual(@as(u64, 0x0001_0203_0405_0607), cpu.vfp.getDU64(2));
    try std.testing.expectEqualSlices(u8, &.{ 2, 3, 0, 1, 6, 7, 4, 5 }, ram[TestBus.BUF_OFFSET + 0x300 ..][0..8]);

    // Advanced SIMD needs FPEXC.EN, CPACR.ASEDIS clear, and a Cortex-A53: vadd.i8 d0, d0, d0
    run(cpu, &bus, &.{0xf2000800}, true);
    cpu.vfp.fpexc = 0;
    _ = cpu.runSteps(&bus, 1);
    try std.testing.expectEqual(arm1176.Mode.und, cpu.mode());
    run(cpu, &bus, &.{0xf2000800}, true);
    cpu.mmu.cpacr |= 1 << 31;
    _ = cpu.runSteps(&bus, 1);
    try std.testing.expectEqual(arm1176.Mode.und, cpu.mode());
    run(cpu, &bus, &.{0xf2000800}, false);
    _ = cpu.runSteps(&bus, 1);
    try std.testing.expectEqual(arm1176.Mode.und, cpu.mode());

    // PLI is a hint; other unallocated unconditional encodings are Undefined
    run(cpu, &bus, &.{ 0xf4d0f000, 0xfc000000 }, true); // pli [r0]
    _ = cpu.runSteps(&bus, 1);
    try std.testing.expectEqual(arm1176.Mode.svc, cpu.mode());
    try std.testing.expectEqual(@as(u32, 0x1004), cpu.r[15]);
    _ = cpu.runSteps(&bus, 1);
    try std.testing.expectEqual(arm1176.Mode.und, cpu.mode());
}

const PsrFlags = @import("decoder.zig").PsrFlags;
