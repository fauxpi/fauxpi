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
const aarch64_mod = @import("aarch64.zig");
const atomic_ram = @import("atomic_ram.zig");

pub const Mmu = mmu_mod.Mmu;
pub const Vfp = vfp_mod.Vfp;
pub const PsrFlags = dec.PsrFlags;
pub const PstateFlags = aarch64_mod.PstateFlags;

pub const icache_size: usize = 16384;
pub const icache_mask: usize = icache_size - 1;

pub const DecodedSlot = struct {
    raw: u32 = 0xffff_ffff,
    op: u8 = 0,
    rd: u8 = 0,
    rn: u8 = 0,
    rm: u8 = 0,
    imm: u64 = 0,
};

pub const ArmOp = enum(u8) {
    // Data Processing Immediate (S == 0, rd != 15, rn != 15)
    add_imm_al,
    sub_imm_al,
    rsb_imm_al,
    adc_imm_al,
    sbc_imm_al,
    rsc_imm_al,
    and_imm_al,
    orr_imm_al,
    eor_imm_al,
    bic_imm_al,
    mov_imm_al,
    mvn_imm_al,
    // Compare / Test Immediate (S == 1, rn != 15)
    cmp_imm_al,
    cmn_imm_al,
    tst_imm_al,
    teq_imm_al,
    // Data Processing Immediate with flags (S == 1, rd != 15, rn != 15)
    adds_imm_al,
    subs_imm_al,
    adcs_imm_al,
    sbcs_imm_al,
    // MOVW / MOVT (rd != 15)
    movw_al,
    movt_al,
    // Unshifted Register Data Processing (S == 0, shift == 0, rd != 15, rn != 15, rm != 15)
    add_reg_al,
    sub_reg_al,
    rsb_reg_al,
    adc_reg_al,
    sbc_reg_al,
    rsc_reg_al,
    and_reg_al,
    orr_reg_al,
    eor_reg_al,
    bic_reg_al,
    mov_reg_al,
    mvn_reg_al,
    adds_reg_al,
    subs_reg_al,
    adcs_reg_al,
    sbcs_reg_al,
    // Unshifted Register Compare / Test (S == 1, shift == 0, rn != 15, rm != 15)
    cmp_reg_al,
    cmn_reg_al,
    tst_reg_al,
    teq_reg_al,
    // Shifted Register Data Processing (bit4 == 0, S == 0, shift_imm != 0, rd != 15, rn != 15, rm != 15)
    lsl_imm_al,
    lsr_imm_al,
    asr_imm_al,
    mvn_lsl_imm_al,
    mvn_lsr_imm_al,
    add_lsl_reg_al,
    sub_lsl_reg_al,
    rsb_lsl_reg_al,
    orr_lsl_reg_al,
    eor_lsl_reg_al,
    and_lsl_reg_al,
    bic_lsl_reg_al,
    add_lsr_reg_al,
    sub_lsr_reg_al,
    rsb_lsr_reg_al,
    orr_lsr_reg_al,
    eor_lsr_reg_al,
    and_lsr_reg_al,
    bic_lsr_reg_al,
    add_asr_reg_al,
    sub_asr_reg_al,
    orr_asr_reg_al,
    and_asr_reg_al,
    bic_asr_reg_al,
    cmp_lsl_reg_al,
    cmp_lsr_reg_al,
    tst_lsl_reg_al,
    tst_lsr_reg_al,
    // Single Load/Store Immediate & Register Offset
    ldr_imm_al,
    str_imm_al,
    ldrb_imm_al,
    strb_imm_al,
    ldr_lit_al,
    ldrh_imm_al,
    strh_imm_al,
    ldrsb_imm_al,
    ldrsh_imm_al,
    ldrh_reg_al,
    strh_reg_al,
    ldrsb_reg_al,
    ldrsh_reg_al,
    ldrd_imm_al,
    strd_imm_al,
    ldr_wb_al,
    str_wb_al,
    ldrb_wb_al,
    strb_wb_al,
    ldr_reg_lsl_al,
    str_reg_lsl_al,
    ldrb_reg_lsl_al,
    strb_reg_lsl_al,
    ldr_reg_sub_lsl_al,
    str_reg_sub_lsl_al,
    ldrb_reg_sub_lsl_al,
    strb_reg_sub_lsl_al,
    ldr_reg_lsr_al,
    str_reg_lsr_al,
    ldm_al,
    ldm_pc_al,
    stm_al,
    // Branches, Multiply, Atomics & Media
    b_al,
    bl_al,
    bx_lr_al,
    bx_reg_al,
    blx_reg_al,
    clz_al,
    mul_al,
    mla_al,
    mls_al,
    umull_al,
    umlal_al,
    smull_al,
    smlal_al,
    ldrex_al,
    strex_al,
    ldrexd_al,
    strexd_al,
    ldrexb_al,
    strexb_al,
    ldrexh_al,
    strexh_al,
    uxtb_al,
    uxth_al,
    sxtb_al,
    sxth_al,
    uxtab_al,
    uxtah_al,
    sxtab_al,
    sxtah_al,
    rev_al,
    rev16_al,
    rbit_al,
    ubfx_al,
    sbfx_al,
    bfi_al,
    bfc_al,
    udiv_al,
    sdiv_al,
    vldr_f64_al,
    vstr_f64_al,
    vldr_f32_al,
    vstr_f32_al,
    vldm_al,
    vstm_al,
    vmov_r_f64_al,
    vmov_f64_r_al,
    vmov_r_f32_al,
    vmov_f32_r_al,
    vmrs_apsr_al,
    vadd_f64_al,
    vsub_f64_al,
    vmul_f64_al,
    vdiv_f64_al,
    vmla_f64_al,
    vmls_f64_al,
    vmov_f64_al,
    vcmp_f64_al,
    vcmpz_f64_al,
    vadd_f32_al,
    vsub_f32_al,
    vmul_f32_al,
    vdiv_f32_al,
    vmla_f32_al,
    vmls_f32_al,
    vmov_f32_al,
    vfp_dp_al,
    vfp_ls_multi_al,
    // Pre-classified group fallbacks
    dp_imm_general,
    dp_reg_general,
    misc_000,
    mul_extra_ls,
    ls_wb_imm,
    ls_wb_reg,
    ls_multiple,
    media,
    coproc_svc,
    unconditional,
};

pub fn decodeArm32(inst: u32) DecodedSlot {
    const cond: u4 = @truncate(inst >> 28);
    if (cond == 0xf) {
        return .{ .raw = inst, .op = @intFromEnum(ArmOp.unconditional) };
    }
    const top3: u3 = @truncate((inst >> 25) & 7);
    switch (top3) {
        0b000 => {
            const bit4 = (inst & (1 << 4)) != 0;
            const bit7 = (inst & (1 << 7)) != 0;
            if (bit4 and bit7) {
                const sh: u2 = @truncate((inst >> 5) & 3);
                if (sh == 0b00) {
                    if ((inst & (1 << 24)) == 0) {
                        const mul_op: u3 = @truncate((inst >> 21) & 7);
                        const s = (inst & (1 << 20)) != 0;
                        const rd_hi: u4 = @truncate((inst >> 16) & 0xf);
                        const rn_lo: u4 = @truncate((inst >> 12) & 0xf);
                        const rs: u4 = @truncate((inst >> 8) & 0xf);
                        const rm: u4 = @truncate(inst & 0xf);
                        if (!s and rd_hi != 15 and rs != 15 and rm != 15) {
                            if (mul_op == 0b000) {
                                return .{
                                    .raw = inst,
                                    .op = @intFromEnum(ArmOp.mul_al),
                                    .rd = rd_hi,
                                    .rn = rs,
                                    .rm = rm,
                                };
                            } else if (rn_lo != 15) {
                                const m_op: ?ArmOp = switch (mul_op) {
                                    0b001 => .mla_al,
                                    0b011 => .mls_al,
                                    0b100 => .umull_al,
                                    0b101 => .umlal_al,
                                    0b110 => .smull_al,
                                    0b111 => .smlal_al,
                                    else => null,
                                };
                                if (m_op) |mop| {
                                    return .{
                                        .raw = inst,
                                        .op = @intFromEnum(mop),
                                        .rd = rd_hi,
                                        .rn = rs,
                                        .rm = rm,
                                        .imm = rn_lo,
                                    };
                                }
                            }
                        }
                    } else {
                        const sync_op: u4 = @truncate((inst >> 20) & 0xf);
                        const rn: u4 = @truncate((inst >> 16) & 0xf);
                        const rd: u4 = @truncate((inst >> 12) & 0xf);
                        const rm: u4 = @truncate(inst & 0xf);
                        if (rd != 15 and rn != 15) {
                            switch (sync_op) {
                                0b1001 => return .{ .raw = inst, .op = @intFromEnum(ArmOp.ldrex_al), .rd = rd, .rn = rn },
                                0b1000 => if (rm != 15) return .{ .raw = inst, .op = @intFromEnum(ArmOp.strex_al), .rd = rd, .rn = rn, .rm = rm },
                                0b1011 => if ((rd & 1) == 0 and rd != 14) return .{ .raw = inst, .op = @intFromEnum(ArmOp.ldrexd_al), .rd = rd, .rn = rn },
                                0b1010 => if ((rm & 1) == 0 and rm != 14) return .{ .raw = inst, .op = @intFromEnum(ArmOp.strexd_al), .rd = rd, .rn = rn, .rm = rm },
                                0b1101 => return .{ .raw = inst, .op = @intFromEnum(ArmOp.ldrexb_al), .rd = rd, .rn = rn },
                                0b1100 => if (rm != 15) return .{ .raw = inst, .op = @intFromEnum(ArmOp.strexb_al), .rd = rd, .rn = rn, .rm = rm },
                                0b1111 => return .{ .raw = inst, .op = @intFromEnum(ArmOp.ldrexh_al), .rd = rd, .rn = rn },
                                0b1110 => if (rm != 15) return .{ .raw = inst, .op = @intFromEnum(ArmOp.strexh_al), .rd = rd, .rn = rn, .rm = rm },
                                else => {},
                            }
                        }
                    }
                } else if ((inst & (1 << 24)) != 0 and (inst & (1 << 21)) == 0) {
                    const rn: u4 = @truncate((inst >> 16) & 0xf);
                    const rd: u4 = @truncate((inst >> 12) & 0xf);
                    const u = (inst & (1 << 23)) != 0;
                    const l = (inst & (1 << 20)) != 0;
                    if (rd != 15 and rn != 15) {
                        if ((inst & (1 << 22)) != 0) {
                            const imm8: u32 = (((inst >> 8) & 0xf) << 4) | (inst & 0xf);
                            const signed_off: u32 = if (u) imm8 else (0 -% imm8);
                            if (sh == 0b01) {
                                return .{
                                    .raw = inst,
                                    .op = @intFromEnum(if (l) ArmOp.ldrh_imm_al else ArmOp.strh_imm_al),
                                    .rd = rd,
                                    .rn = rn,
                                    .imm = signed_off,
                                };
                            } else if (l) {
                                return .{
                                    .raw = inst,
                                    .op = @intFromEnum(if (sh == 0b10) ArmOp.ldrsb_imm_al else ArmOp.ldrsh_imm_al),
                                    .rd = rd,
                                    .rn = rn,
                                    .imm = signed_off,
                                };
                            } else if ((rd & 1) == 0 and rd != 14) {
                                return .{
                                    .raw = inst,
                                    .op = @intFromEnum(if (sh == 0b10) ArmOp.ldrd_imm_al else ArmOp.strd_imm_al),
                                    .rd = rd,
                                    .rn = rn,
                                    .imm = signed_off,
                                };
                            }
                        } else if (u) {
                            const rm: u4 = @truncate(inst & 0xf);
                            if (rm != 15) {
                                if (sh == 0b01) {
                                    return .{
                                        .raw = inst,
                                        .op = @intFromEnum(if (l) ArmOp.ldrh_reg_al else ArmOp.strh_reg_al),
                                        .rd = rd,
                                        .rn = rn,
                                        .rm = rm,
                                    };
                                } else if (l) {
                                    return .{
                                        .raw = inst,
                                        .op = @intFromEnum(if (sh == 0b10) ArmOp.ldrsb_reg_al else ArmOp.ldrsh_reg_al),
                                        .rd = rd,
                                        .rn = rn,
                                        .rm = rm,
                                    };
                                }
                            }
                        }
                    }
                }
                return .{ .raw = inst, .op = @intFromEnum(ArmOp.mul_extra_ls) };
            }

            const op: u4 = @truncate((inst >> 21) & 0xf);
            const s = (inst & (1 << 20)) != 0;
            if ((op & 0b1100) == 0b1000 and !s) {
                if ((inst & 0x0fff_ffff) == 0x012f_ff1e) {
                    return .{ .raw = inst, .op = @intFromEnum(ArmOp.bx_lr_al) };
                }
                const rm: u4 = @truncate(inst & 0xf);
                if (rm != 15) {
                    if ((inst & 0x0fff_fff0) == 0x012f_ff10) {
                        return .{ .raw = inst, .op = @intFromEnum(ArmOp.bx_reg_al), .rm = rm };
                    }
                    if ((inst & 0x0fff_fff0) == 0x012f_ff30) {
                        return .{ .raw = inst, .op = @intFromEnum(ArmOp.blx_reg_al), .rm = rm };
                    }
                    if ((inst & 0x0fff_0ff0) == 0x016f_0f10) {
                        const rd: u4 = @truncate((inst >> 12) & 0xf);
                        if (rd != 15) {
                            return .{ .raw = inst, .op = @intFromEnum(ArmOp.clz_al), .rd = rd, .rm = rm };
                        }
                    }
                }
                return .{ .raw = inst, .op = @intFromEnum(ArmOp.misc_000) };
            }

            if (!bit4) {
                const rn: u4 = @truncate((inst >> 16) & 0xf);
                const rd: u4 = @truncate((inst >> 12) & 0xf);
                const rm: u4 = @truncate(inst & 0xf);
                const shift_type: u2 = @truncate((inst >> 5) & 3);
                const shift_imm: u5 = @truncate((inst >> 7) & 0x1f);

                if (shift_imm == 0 and shift_type == 0 and rm != 15) {
                    if (!s and rd != 15 and rn != 15) {
                        const fast_op: ?ArmOp = switch (op) {
                            0x0 => .and_reg_al,
                            0x1 => .eor_reg_al,
                            0x2 => .sub_reg_al,
                            0x3 => .rsb_reg_al,
                            0x4 => .add_reg_al,
                            0x5 => .adc_reg_al,
                            0x6 => .sbc_reg_al,
                            0x7 => .rsc_reg_al,
                            0xc => .orr_reg_al,
                            0xd => .mov_reg_al,
                            0xe => .bic_reg_al,
                            0xf => .mvn_reg_al,
                            else => null,
                        };
                        if (fast_op) |fop| {
                            return .{ .raw = inst, .op = @intFromEnum(fop), .rd = rd, .rn = rn, .rm = rm };
                        }
                    } else if (s and rn != 15) {
                        const fast_s: ?ArmOp = switch (op) {
                            0x2 => if (rd != 15) .subs_reg_al else null,
                            0x4 => if (rd != 15) .adds_reg_al else null,
                            0x5 => if (rd != 15) .adcs_reg_al else null,
                            0x6 => if (rd != 15) .sbcs_reg_al else null,
                            0x8 => .tst_reg_al,
                            0x9 => .teq_reg_al,
                            0xa => .cmp_reg_al,
                            0xb => .cmn_reg_al,
                            else => null,
                        };
                        if (fast_s) |fs| {
                            return .{ .raw = inst, .op = @intFromEnum(fs), .rd = rd, .rn = rn, .rm = rm };
                        }
                    }
                } else if (!s and shift_imm != 0 and rd != 15 and rm != 15) {
                    if (op == 0xd) {
                        const sh_op: ?ArmOp = switch (shift_type) {
                            0b00 => .lsl_imm_al,
                            0b01 => .lsr_imm_al,
                            0b10 => .asr_imm_al,
                            else => null,
                        };
                        if (sh_op) |sop| {
                            return .{ .raw = inst, .op = @intFromEnum(sop), .rd = rd, .rm = rm, .imm = shift_imm };
                        }
                    } else if (op == 0xf and (shift_type == 0b00 or shift_type == 0b01)) {
                        return .{
                            .raw = inst,
                            .op = @intFromEnum(if (shift_type == 0b00) ArmOp.mvn_lsl_imm_al else ArmOp.mvn_lsr_imm_al),
                            .rd = rd,
                            .rm = rm,
                            .imm = shift_imm,
                        };
                    } else if (rn != 15) {
                        if (shift_type == 0b00) {
                            const lsl_op: ?ArmOp = switch (op) {
                                0x0 => .and_lsl_reg_al,
                                0x1 => .eor_lsl_reg_al,
                                0x2 => .sub_lsl_reg_al,
                                0x3 => .rsb_lsl_reg_al,
                                0x4 => .add_lsl_reg_al,
                                0xc => .orr_lsl_reg_al,
                                0xe => .bic_lsl_reg_al,
                                else => null,
                            };
                            if (lsl_op) |lop| {
                                return .{ .raw = inst, .op = @intFromEnum(lop), .rd = rd, .rn = rn, .rm = rm, .imm = shift_imm };
                            }
                        } else if (shift_type == 0b01) {
                            const lsr_op: ?ArmOp = switch (op) {
                                0x0 => .and_lsr_reg_al,
                                0x1 => .eor_lsr_reg_al,
                                0x2 => .sub_lsr_reg_al,
                                0x3 => .rsb_lsr_reg_al,
                                0x4 => .add_lsr_reg_al,
                                0xc => .orr_lsr_reg_al,
                                0xe => .bic_lsr_reg_al,
                                else => null,
                            };
                            if (lsr_op) |lop| {
                                return .{ .raw = inst, .op = @intFromEnum(lop), .rd = rd, .rn = rn, .rm = rm, .imm = shift_imm };
                            }
                        } else if (shift_type == 0b10) {
                            const asr_op: ?ArmOp = switch (op) {
                                0x0 => .and_asr_reg_al,
                                0x2 => .sub_asr_reg_al,
                                0x4 => .add_asr_reg_al,
                                0xc => .orr_asr_reg_al,
                                0xe => .bic_asr_reg_al,
                                else => null,
                            };
                            if (asr_op) |aop| {
                                return .{ .raw = inst, .op = @intFromEnum(aop), .rd = rd, .rn = rn, .rm = rm, .imm = shift_imm };
                            }
                        }
                    }
                } else if (s and shift_imm != 0 and rn != 15 and rm != 15 and (shift_type == 0b00 or shift_type == 0b01)) {
                    if (op == 0xa) {
                        return .{
                            .raw = inst,
                            .op = @intFromEnum(if (shift_type == 0b00) ArmOp.cmp_lsl_reg_al else ArmOp.cmp_lsr_reg_al),
                            .rn = rn,
                            .rm = rm,
                            .imm = shift_imm,
                        };
                    } else if (op == 0x8) {
                        return .{
                            .raw = inst,
                            .op = @intFromEnum(if (shift_type == 0b00) ArmOp.tst_lsl_reg_al else ArmOp.tst_lsr_reg_al),
                            .rn = rn,
                            .rm = rm,
                            .imm = shift_imm,
                        };
                    }
                }
            }
            return .{ .raw = inst, .op = @intFromEnum(ArmOp.dp_reg_general) };
        },
        0b001 => {
            const op: u4 = @truncate((inst >> 21) & 0xf);
            const s = (inst & (1 << 20)) != 0;
            const rn: u4 = @truncate((inst >> 16) & 0xf);
            const rd: u4 = @truncate((inst >> 12) & 0xf);
            if ((op & 0b1100) == 0b1000 and !s) {
                if ((op == 0b1000 or op == 0b1010) and rd != 15) {
                    const imm16: u32 = (((inst >> 16) & 0xf) << 12) | (inst & 0xfff);
                    return .{
                        .raw = inst,
                        .op = @intFromEnum(if (op == 0b1000) ArmOp.movw_al else ArmOp.movt_al),
                        .rd = rd,
                        .imm = imm16,
                    };
                }
                return .{ .raw = inst, .op = @intFromEnum(ArmOp.dp_imm_general) };
            }

            const imm8: u32 = inst & 0xff;
            const rot: u5 = @as(u5, @truncate((inst >> 8) & 0xf)) * 2;
            const imm32 = std.math.rotr(u32, imm8, rot);

            if (!s and rd != 15 and rn != 15) {
                const fast_op: ?ArmOp = switch (op) {
                    0x0 => .and_imm_al,
                    0x1 => .eor_imm_al,
                    0x2 => .sub_imm_al,
                    0x3 => .rsb_imm_al,
                    0x4 => .add_imm_al,
                    0x5 => .adc_imm_al,
                    0x6 => .sbc_imm_al,
                    0x7 => .rsc_imm_al,
                    0xc => .orr_imm_al,
                    0xd => .mov_imm_al,
                    0xe => .bic_imm_al,
                    0xf => .mvn_imm_al,
                    else => null,
                };
                if (fast_op) |fop| {
                    return .{ .raw = inst, .op = @intFromEnum(fop), .rd = rd, .rn = rn, .imm = imm32 };
                }
            } else if (s and rn != 15) {
                const fast_s: ?ArmOp = switch (op) {
                    0xa => .cmp_imm_al,
                    0xb => .cmn_imm_al,
                    0x8 => if (rot == 0) .tst_imm_al else null,
                    0x9 => if (rot == 0) .teq_imm_al else null,
                    0x4 => if (rd != 15) .adds_imm_al else null,
                    0x2 => if (rd != 15) .subs_imm_al else null,
                    0x5 => if (rd != 15) .adcs_imm_al else null,
                    0x6 => if (rd != 15) .sbcs_imm_al else null,
                    else => null,
                };
                if (fast_s) |fs| {
                    return .{ .raw = inst, .op = @intFromEnum(fs), .rd = rd, .rn = rn, .imm = imm32 };
                }
            }
            return .{ .raw = inst, .op = @intFromEnum(ArmOp.dp_imm_general) };
        },
        0b010 => {
            const p = (inst & (1 << 24)) != 0;
            const u = (inst & (1 << 23)) != 0;
            const b = (inst & (1 << 22)) != 0;
            const w = (inst & (1 << 21)) != 0;
            const l = (inst & (1 << 20)) != 0;
            const rn: u4 = @truncate((inst >> 16) & 0xf);
            const rd: u4 = @truncate((inst >> 12) & 0xf);
            const imm12: u32 = inst & 0xfff;
            const signed_off: u32 = if (u) imm12 else (0 -% imm12);
            if (p and !w and rd != 15) {
                if (rn != 15) {
                    const ls_op: ArmOp = if (l)
                        (if (b) .ldrb_imm_al else .ldr_imm_al)
                    else
                        (if (b) .strb_imm_al else .str_imm_al);
                    return .{ .raw = inst, .op = @intFromEnum(ls_op), .rd = rd, .rn = rn, .imm = signed_off };
                } else if (l and !b) {
                    return .{ .raw = inst, .op = @intFromEnum(ArmOp.ldr_lit_al), .rd = rd, .imm = signed_off };
                }
            } else if ((p and w) or (!p and !w)) {
                // Pre-index with writeback (`p and w`) or post-index (`!p and !w`, not LDRT/STRT)
                if (rn != 15 and rd != rn and (l or rd != 15) and (!b or rd != 15)) {
                    const addr_off: u32 = if (p) signed_off else 0;
                    const packed_imm: u64 = @as(u64, addr_off) | (@as(u64, signed_off) << 32);
                    const wb_op: ArmOp = if (l)
                        (if (b) .ldrb_wb_al else .ldr_wb_al)
                    else
                        (if (b) .strb_wb_al else .str_wb_al);
                    return .{ .raw = inst, .op = @intFromEnum(wb_op), .rd = rd, .rn = rn, .imm = packed_imm };
                }
            }
            return .{ .raw = inst, .op = @intFromEnum(ArmOp.ls_wb_imm) };
        },
        0b011 => {
            if ((inst & (1 << 4)) != 0) {
                const op1: u5 = @truncate((inst >> 20) & 0x1f);
                const op2: u3 = @truncate((inst >> 5) & 7);
                const rn: u4 = @truncate((inst >> 16) & 0xf);
                const rd: u4 = @truncate((inst >> 12) & 0xf);
                const rm: u4 = @truncate(inst & 0xf);
                if (op2 == 0b000 and (op1 == 0b10001 or op1 == 0b10011) and rd == 15) {
                    const div_rd: u4 = rn;
                    const div_rn: u4 = rm;
                    const div_rm: u4 = @truncate((inst >> 8) & 0xf);
                    if (div_rd != 15 and div_rn != 15 and div_rm != 15) {
                        return .{
                            .raw = inst,
                            .op = @intFromEnum(if (op1 == 0b10011) ArmOp.udiv_al else ArmOp.sdiv_al),
                            .rd = div_rd,
                            .rn = div_rn,
                            .rm = div_rm,
                        };
                    }
                }
                if (rd != 15) {
                    if (rm != 15) {
                        if (op2 == 0b011) {
                            const rot: u5 = @as(u5, @truncate((inst >> 10) & 3)) * 8;
                            switch (op1) {
                                0b01110 => return .{
                                    .raw = inst,
                                    .op = @intFromEnum(if (rn == 15) ArmOp.uxtb_al else ArmOp.uxtab_al),
                                    .rd = rd,
                                    .rn = rn,
                                    .rm = rm,
                                    .imm = rot,
                                },
                                0b01111 => return .{
                                    .raw = inst,
                                    .op = @intFromEnum(if (rn == 15) ArmOp.uxth_al else ArmOp.uxtah_al),
                                    .rd = rd,
                                    .rn = rn,
                                    .rm = rm,
                                    .imm = rot,
                                },
                                0b01010 => return .{
                                    .raw = inst,
                                    .op = @intFromEnum(if (rn == 15) ArmOp.sxtb_al else ArmOp.sxtab_al),
                                    .rd = rd,
                                    .rn = rn,
                                    .rm = rm,
                                    .imm = rot,
                                },
                                0b01011 => return .{
                                    .raw = inst,
                                    .op = @intFromEnum(if (rn == 15) ArmOp.sxth_al else ArmOp.sxtah_al),
                                    .rd = rd,
                                    .rn = rn,
                                    .rm = rm,
                                    .imm = rot,
                                },
                                else => {},
                            }
                        } else if (op1 == 0b01011) {
                            if (op2 == 0b001 and rn == 15) {
                                return .{ .raw = inst, .op = @intFromEnum(ArmOp.rev_al), .rd = rd, .rm = rm };
                            } else if (op2 == 0b101) {
                                return .{ .raw = inst, .op = @intFromEnum(ArmOp.rev16_al), .rd = rd, .rm = rm };
                            }
                        } else if (op1 == 0b01111 and op2 == 0b001) {
                            return .{ .raw = inst, .op = @intFromEnum(ArmOp.rbit_al), .rd = rd, .rm = rm };
                        } else if ((op1 == 0b11110 or op1 == 0b11111) and (op2 & 0b011) == 0b010) {
                            const lsb: u5 = @truncate((inst >> 7) & 0x1f);
                            const widthm1: u5 = @truncate((inst >> 16) & 0x1f);
                            const width: u6 = @as(u6, widthm1) + 1;
                            const mask: u32 = if (width >= 32) 0xffff_ffff else (@as(u32, 1) << @truncate(width)) -% 1;
                            return .{ .raw = inst, .op = @intFromEnum(ArmOp.ubfx_al), .rd = rd, .rn = lsb, .rm = rm, .imm = mask };
                        } else if ((op1 == 0b11010 or op1 == 0b11011) and (op2 & 0b011) == 0b010) {
                            const lsb: u5 = @truncate((inst >> 7) & 0x1f);
                            const widthm1: u5 = @truncate((inst >> 16) & 0x1f);
                            const width: u6 = @as(u6, widthm1) + 1;
                            if (width <= 32 - @as(u6, lsb)) {
                                const sh_left: u5 = @truncate(32 - (width + @as(u6, lsb)));
                                const sh_right: u5 = @truncate(32 - width);
                                return .{ .raw = inst, .op = @intFromEnum(ArmOp.sbfx_al), .rd = rd, .rn = sh_left, .rm = rm, .imm = sh_right };
                            }
                        }
                    }
                    if ((op1 == 0b11100 or op1 == 0b11101) and (op2 & 0b011) == 0b000) {
                        const lsb: u5 = @truncate((inst >> 7) & 0x1f);
                        const msb: u5 = @truncate((inst >> 16) & 0x1f);
                        if (msb >= lsb) {
                            const width: u6 = @as(u6, msb -% lsb) + 1;
                            const mask: u32 = if (width >= 32) 0xffff_ffff else ((@as(u32, 1) << @truncate(width)) -% 1) << lsb;
                            return .{
                                .raw = inst,
                                .op = @intFromEnum(if (rm == 15) ArmOp.bfc_al else ArmOp.bfi_al),
                                .rd = rd,
                                .rn = lsb,
                                .rm = rm,
                                .imm = mask,
                            };
                        }
                    }
                }
                return .{ .raw = inst, .op = @intFromEnum(ArmOp.media) };
            }
            // Scaled register offset LDR/STR/LDRB/STRB (P == 1, W == 0)
            const p = (inst & (1 << 24)) != 0;
            const u = (inst & (1 << 23)) != 0;
            const b = (inst & (1 << 22)) != 0;
            const w = (inst & (1 << 21)) != 0;
            const l = (inst & (1 << 20)) != 0;
            const shift_type: u2 = @truncate((inst >> 5) & 3);
            const rn: u4 = @truncate((inst >> 16) & 0xf);
            const rd: u4 = @truncate((inst >> 12) & 0xf);
            const rm: u4 = @truncate(inst & 0xf);
            if (p and !w and rd != 15 and rn != 15 and rm != 15) {
                const shift_imm: u5 = @truncate((inst >> 7) & 0x1f);
                if (shift_type == 0) {
                    const reg_op: ArmOp = if (u)
                        (if (l) (if (b) .ldrb_reg_lsl_al else .ldr_reg_lsl_al) else (if (b) .strb_reg_lsl_al else .str_reg_lsl_al))
                    else
                        (if (l) (if (b) .ldrb_reg_sub_lsl_al else .ldr_reg_sub_lsl_al) else (if (b) .strb_reg_sub_lsl_al else .str_reg_sub_lsl_al));
                    return .{ .raw = inst, .op = @intFromEnum(reg_op), .rd = rd, .rn = rn, .rm = rm, .imm = shift_imm };
                } else if (shift_type == 0b01 and u and shift_imm != 0 and !b) {
                    return .{
                        .raw = inst,
                        .op = @intFromEnum(if (l) ArmOp.ldr_reg_lsr_al else ArmOp.str_reg_lsr_al),
                        .rd = rd,
                        .rn = rn,
                        .rm = rm,
                        .imm = shift_imm,
                    };
                }
            }
            return .{ .raw = inst, .op = @intFromEnum(ArmOp.ls_wb_reg) };
        },
        0b100 => {
            const p = (inst & (1 << 24)) != 0;
            const u = (inst & (1 << 23)) != 0;
            const s = (inst & (1 << 22)) != 0;
            const w = (inst & (1 << 21)) != 0;
            const l = (inst & (1 << 20)) != 0;
            const rn: u4 = @truncate((inst >> 16) & 0xf);
            const reg_list: u16 = @truncate(inst & 0xffff);
            if (!s and reg_list != 0 and rn != 15) {
                const count: i32 = @intCast(@popCount(reg_list));
                const total_bytes: i32 = count * 4;
                const start_off: i16 = @intCast(switch (@as(u2, (@as(u2, @intFromBool(p)) << 1) | @intFromBool(u))) {
                    0b00 => -total_bytes + 4, // DA
                    0b01 => 0, // IA
                    0b10 => -total_bytes, // DB
                    0b11 => 4, // IB
                });
                const has_wb = w and (!l or (reg_list & (@as(u16, 1) << rn)) == 0);
                const wb_off: i16 = if (has_wb) @intCast(if (u) total_bytes else -total_bytes) else 0;
                const last_off: u16 = @intCast((count - 1) * 4);
                const packed_imm: u64 = @as(u64, reg_list) |
                    (@as(u64, last_off) << 16) |
                    (@as(u64, @as(u16, @bitCast(start_off))) << 32) |
                    (@as(u64, @as(u16, @bitCast(wb_off))) << 48);
                const op: ArmOp = if (l)
                    (if ((reg_list & (1 << 15)) != 0) .ldm_pc_al else .ldm_al)
                else
                    .stm_al;
                // Pre-detect contiguous register range in r0..r13 (+ optional r14/lr) for single-@memcpy burst
                const low14: u32 = reg_list & 0x3fff;
                const low14_contig = (low14 == 0) or ((low14 & (low14 + (@as(u32, 1) << @intCast(@ctz(low14))))) == 0);
                var first_byte: u8 = 0;
                var contig_meta: u8 = 0;
                if (low14_contig and (l or (reg_list & (1 << 15)) == 0)) {
                    first_byte = if (low14 != 0) @intCast(@ctz(low14) * 4) else 0;
                    const nbytes: u8 = @intCast(@popCount(low14) * 4);
                    const has_lr: u8 = if ((reg_list & (1 << 14)) != 0) 0x40 else 0;
                    contig_meta = 0x80 | has_lr | nbytes;
                }
                return .{
                    .raw = inst,
                    .op = @intFromEnum(op),
                    .rd = first_byte,
                    .rn = rn,
                    .rm = contig_meta,
                    .imm = packed_imm,
                };
            }
            return .{ .raw = inst, .op = @intFromEnum(ArmOp.ls_multiple) };
        },
        0b101 => {
            const link = (inst & (1 << 24)) != 0;
            const imm24: i24 = @bitCast(@as(u24, @truncate(inst)));
            const shift_imm: i32 = @as(i32, imm24) << 2;
            const offset: u32 = @bitCast(shift_imm);
            return .{
                .raw = inst,
                .op = @intFromEnum(if (link) ArmOp.bl_al else ArmOp.b_al),
                .imm = offset,
            };
        },
        0b110, 0b111 => {
            if ((inst & 0x0f00_0000) != 0x0f00_0000) {
                const cp_num: u4 = @truncate((inst >> 8) & 0xf);
                if (cp_num == 10 or cp_num == 11) {
                    const is_double = cp_num == 11;
                    if (top3 == 0b110) {
                        if ((inst & 0x0fe0_0000) == 0x0c40_0000) {
                            if (is_double) {
                                const l = (inst & (1 << 20)) != 0;
                                const rt2: u8 = @truncate((inst >> 16) & 0xf);
                                const rt: u8 = @truncate((inst >> 12) & 0xf);
                                const dm: u8 = @truncate((((inst >> 5) & 1) << 4) | (inst & 0xf));
                                if (rt != 15 and rt2 != 15 and (!l or rt != rt2)) {
                                    return .{
                                        .raw = inst,
                                        .op = @intFromEnum(if (l) ArmOp.vmov_r_f64_al else ArmOp.vmov_f64_r_al),
                                        .rd = rt,
                                        .rn = rt2,
                                        .rm = dm * 2,
                                    };
                                }
                            }
                        } else {
                            const p = (inst & (1 << 24)) != 0;
                            const u = (inst & (1 << 23)) != 0;
                            const d_bit: u8 = @truncate((inst >> 22) & 1);
                            const w = (inst & (1 << 21)) != 0;
                            const l = (inst & (1 << 20)) != 0;
                            const rn: u8 = @truncate((inst >> 16) & 0xf);
                            const vd: u8 = @truncate((inst >> 12) & 0xf);
                            const imm8: u32 = inst & 0xff;
                            const offset_bytes: u32 = imm8 * 4;
                            const signed_off: u32 = if (u) offset_bytes else (0 -% offset_bytes);
                            if (p and !w) {
                                if (is_double) {
                                    const dd: u8 = (d_bit << 4) | vd;
                                    return .{
                                        .raw = inst,
                                        .op = @intFromEnum(if (l) ArmOp.vldr_f64_al else ArmOp.vstr_f64_al),
                                        .rd = dd * 2,
                                        .rn = rn,
                                        .imm = signed_off,
                                    };
                                } else {
                                    const sd: u8 = (vd << 1) | d_bit;
                                    return .{
                                        .raw = inst,
                                        .op = @intFromEnum(if (l) ArmOp.vldr_f32_al else ArmOp.vstr_f32_al),
                                        .rd = sd,
                                        .rn = rn,
                                        .imm = signed_off,
                                    };
                                }
                            }
                            const word_count: u32 = if (is_double) (imm8 & ~@as(u32, 1)) else imm8;
                            const first_s: u32 = if (is_double) (@as(u32, (d_bit << 4) | vd) * 2) else ((@as(u32, vd) << 1) | d_bit);
                            if (rn != 15 and word_count > 0 and first_s + word_count <= 64) {
                                const off_i16: i16 = @intCast(offset_bytes);
                                const start_off: i16 = if (u) 0 else -off_i16;
                                const wb_off: i16 = if (w) (if (u) off_i16 else -off_i16) else 0;
                                const last_off: u16 = @intCast((word_count - 1) * 4);
                                const nbytes: u16 = @intCast(word_count * 4);
                                const packed_imm: u64 = @as(u64, nbytes) |
                                    (@as(u64, last_off) << 16) |
                                    (@as(u64, @as(u16, @bitCast(start_off))) << 32) |
                                    (@as(u64, @as(u16, @bitCast(wb_off))) << 48);
                                return .{
                                    .raw = inst,
                                    .op = @intFromEnum(if (l) ArmOp.vldm_al else ArmOp.vstm_al),
                                    .rd = @intCast(first_s),
                                    .rn = rn,
                                    .rm = @intFromBool(is_double),
                                    .imm = packed_imm,
                                };
                            }
                            return .{ .raw = inst, .op = @intFromEnum(ArmOp.vfp_ls_multi_al), .rm = @intFromBool(is_double) };
                        }
                    } else {
                        if ((inst & 0x0f00_0010) == 0x0e00_0010) {
                            if ((inst & 0x0fff_ffff) == 0x0ef1_fa10) {
                                return .{ .raw = inst, .op = @intFromEnum(ArmOp.vmrs_apsr_al) };
                            }
                            if (!is_double and ((inst >> 21) & 7) == 0) {
                                const l = (inst & (1 << 20)) != 0;
                                const sn: u8 = @truncate((((inst >> 16) & 0xf) << 1) | ((inst >> 7) & 1));
                                const rt: u8 = @truncate((inst >> 12) & 0xf);
                                if (rt != 15) {
                                    return .{
                                        .raw = inst,
                                        .op = @intFromEnum(if (l) ArmOp.vmov_r_f32_al else ArmOp.vmov_f32_r_al),
                                        .rd = rt,
                                        .rn = sn,
                                    };
                                }
                            }
                        } else if ((inst & 0x0f00_0010) == 0x0e00_0000) {
                            const p_b: u4 = @truncate((inst >> 23) & 1);
                            const q_b: u4 = @truncate((inst >> 21) & 1);
                            const r_b: u4 = @truncate((inst >> 20) & 1);
                            const s_b: u4 = @truncate((inst >> 6) & 1);
                            const op4: u4 = (p_b << 3) | (q_b << 2) | (r_b << 1) | s_b;
                            const ext_op: u5 = @truncate((((inst >> 16) & 0xf) << 1) | ((inst >> 7) & 1));
                            if (is_double) {
                                const dd: u8 = @truncate((((inst >> 22) & 1) << 4) | ((inst >> 12) & 0xf));
                                const dn: u8 = @truncate((((inst >> 7) & 1) << 4) | ((inst >> 16) & 0xf));
                                const dm: u8 = @truncate((((inst >> 5) & 1) << 4) | (inst & 0xf));
                                const f64_op: ?ArmOp = switch (op4) {
                                    0b0000 => .vmla_f64_al,
                                    0b0001 => .vmls_f64_al,
                                    0b0100 => .vmul_f64_al,
                                    0b0110 => .vadd_f64_al,
                                    0b0111 => .vsub_f64_al,
                                    0b1000 => .vdiv_f64_al,
                                    0b1111 => switch (ext_op) {
                                        0b00000 => .vmov_f64_al,
                                        0b01000, 0b01001 => .vcmp_f64_al,
                                        0b01010, 0b01011 => .vcmpz_f64_al,
                                        else => null,
                                    },
                                    else => null,
                                };
                                if (f64_op) |fop| {
                                    return .{ .raw = inst, .op = @intFromEnum(fop), .rd = dd, .rn = dn, .rm = dm };
                                }
                            } else {
                                const sd: u8 = @truncate((((inst >> 12) & 0xf) << 1) | ((inst >> 22) & 1));
                                const sn: u8 = @truncate((((inst >> 16) & 0xf) << 1) | ((inst >> 7) & 1));
                                const sm: u8 = @truncate(((inst & 0xf) << 1) | ((inst >> 5) & 1));
                                const f32_op: ?ArmOp = switch (op4) {
                                    0b0000 => .vmla_f32_al,
                                    0b0001 => .vmls_f32_al,
                                    0b0100 => .vmul_f32_al,
                                    0b0110 => .vadd_f32_al,
                                    0b0111 => .vsub_f32_al,
                                    0b1000 => .vdiv_f32_al,
                                    0b1111 => if (sn == 0b00000) .vmov_f32_al else null,
                                    else => null,
                                };
                                if (f32_op) |fop| {
                                    return .{ .raw = inst, .op = @intFromEnum(fop), .rd = sd, .rn = sn, .rm = sm };
                                }
                            }
                            return .{ .raw = inst, .op = @intFromEnum(ArmOp.vfp_dp_al) };
                        }
                    }
                }
            }
            return .{ .raw = inst, .op = @intFromEnum(ArmOp.coproc_svc) };
        },
    }
}

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

        /// True when executing in 64-bit ARMv8 AArch64 (A64) state (`EL3` / `EL2` / `EL1` / `EL0`)
        is_aarch64: bool = false,
        /// AArch64 64-bit general-purpose registers `X0..X30` (`X30` = LR; `XZR`/`WZR` is reg 31)
        x: [31]u64 = @splat(0),
        /// AArch64 Stack Pointers `SP_EL0`, `SP_EL1`, `SP_EL2`, `SP_EL3`
        sp_el: [4]u64 = @splat(0),
        /// AArch64 64-bit Program Counter
        pc64: u64 = 0,
        /// AArch64 Processor State (`NZCV`, `DAIF`, `EL`, `SPSel`)
        pstate: u32 = PstateFlags.D | PstateFlags.A | PstateFlags.I | PstateFlags.F | PstateFlags.M_EL2h,
        /// AArch64 Exception Link Registers (`ELR_EL1..ELR_EL3`)
        elr_el: [4]u64 = @splat(0),
        /// AArch64 Saved Program Status Registers (`SPSR_EL1..SPSR_EL3`)
        spsr_el: [4]u32 = @splat(0),

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
        /// Value returned by the last load-exclusive (`excl_val_hi` holds the upper half of a 128-bit pair);
        /// the store-exclusive is a compare-and-swap against it so it fails if another core wrote in between
        excl_val: u64 = 0,
        excl_val_hi: u64 = 0,
        /// Private word for host memory barriers (`DMB` / `DSB` while cores run in parallel)
        fence_word: u32 = 0,
        /// True for secondary SMP cores (`1..3`) before wakeup via Mailbox 3 or spin-table
        halted_spin: bool = false,
        /// True when `WFE` or `YIELD` executes so the SMP scheduler switches to the next core immediately
        yield_slice: bool = false,

        /// Total executed instructions
        cycles: u64 = 0,
        last_inst: u32 = 0,
        last_dmb_pc: u32 = 0xffff_ffff,

        /// Direct-mapped decoded instruction cache (`icache_size` entries)
        icache: [icache_size]DecodedSlot = @splat(.{}),

        pub inline fn invalidateInlineTlb(self: *Self) void {
            self.mmu.flushTlb();
        }

        pub fn initReset(self: *Self, entry_pc: u32, r0: u32, r1: u32, r2: u32) void {
            self.* = .{};
            self.r[0] = r0;
            self.r[1] = r1;
            self.r[2] = r2;
            self.r[15] = entry_pc;
            self.cpsr = PsrFlags.I | PsrFlags.F | @intFromEnum(Mode.svc);
        }

        pub fn initReset64(self: *Self, entry_pc: u64, x0_dtb: u64) void {
            self.* = .{};
            self.is_aarch64 = true;
            self.mmu.is_cortex_a53 = true;
            self.vfp.is_vfpv4 = true;
            self.x[0] = x0_dtb;
            self.pc64 = entry_pc;
            self.r[15] = @truncate(entry_pc);
            self.pstate = PstateFlags.D | PstateFlags.A | PstateFlags.I | PstateFlags.F | PstateFlags.M_EL2h;
            self.cpsr = self.pstate;
        }

        pub fn initSecondaryCore(self: *Self, core_id: u2) void {
            self.* = .{};
            self.mmu.core_id = core_id;
            self.mmu.is_cortex_a53 = true;
            self.vfp.is_vfpv4 = true;
            self.halted_spin = true;
            self.cpsr = PsrFlags.I | PsrFlags.F | @intFromEnum(Mode.svc);
        }

        pub fn initSecondaryCore64(self: *Self, core_id: u2) void {
            self.* = .{};
            self.is_aarch64 = true;
            self.mmu.core_id = core_id;
            self.mmu.is_cortex_a53 = true;
            self.vfp.is_vfpv4 = true;
            self.halted_spin = true;
            self.pstate = PstateFlags.D | PstateFlags.A | PstateFlags.I | PstateFlags.F | PstateFlags.M_EL2h;
            self.cpsr = self.pstate;
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
        }

        pub fn setCpsr(self: *Self, new_cpsr: u32) void {
            const new_mode: u5 = @truncate(new_cpsr & 0x1f);
            self.switchMode(new_mode);
            self.cpsr = new_cpsr;
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

            const base: u32 = if (self.mmu.highVectors()) 0xffff_0000 else self.mmu.vbar;
            self.r[15] = base + vector_offset;
            self.excl_valid = false;
        }

        pub inline fn checkInterrupts(self: *Self, bus: *const Bus) bool {
            const halted = self.mmu.halted_wfi;
            if (halted or (self.cpsr & PsrFlags.F) == 0) {
                const pending_fiq = if (@hasDecl(Bus, "hasPendingFiqForCore"))
                    bus.hasPendingFiqForCore(self.mmu.core_id)
                else
                    bus.hasPendingFiq();
                if (pending_fiq) {
                    self.mmu.halted_wfi = false;
                    if ((self.cpsr & PsrFlags.F) == 0) {
                        self.enterException(.fiq, 0x1c, self.r[15] +% 4, true);
                        return true;
                    }
                }
            }
            if (halted or (self.cpsr & PsrFlags.I) == 0) {
                const pending_irq = if (@hasDecl(Bus, "hasPendingIrqForCore"))
                    bus.hasPendingIrqForCore(self.mmu.core_id)
                else
                    bus.hasPendingIrq();
                if (pending_irq) {
                    self.mmu.halted_wfi = false;
                    if ((self.cpsr & PsrFlags.I) == 0) {
                        self.enterException(.irq, 0x18, self.r[15] +% 4, false);
                        return true;
                    }
                }
            }
            return false;
        }

        // --- Memory Access via SoftMMU & Bus ---

        inline fn read64(self: *Self, bus: *Bus, vaddr: u32) error{Abort}!u64 {
            const priv: u1 = @intFromBool(self.isPrivileged());
            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
            if ((vaddr & 0xfff) <= 0xff8 and (vaddr & ~@as(u32, 0xffc)) == slot.r_vbase) {
                const paddr = slot.pbase | (vaddr & 0xfff);
                return std.mem.readInt(u64, bus.ram[paddr..][0..8], .little);
            }
            const lo: u64 = try self.read32(bus, vaddr);
            const hi: u64 = try self.read32(bus, vaddr +% 4);
            return lo | (hi << 32);
        }

        /// Completes a store-exclusive of `val` at `vaddr` and returns the `STREX` status (0 = stored).
        /// RAM stores are a compare-and-swap against the value the load-exclusive returned.
        fn storeExclusive(self: *Self, bus: *Bus, comptime T: type, vaddr: u32, val: T, privileged: bool) error{Abort}!u32 {
            const paddr = try self.mmu.translate(bus.ram, vaddr, .write, privileged);
            if (!self.excl_valid) return 1;
            self.excl_valid = false;
            if (paddr < bus.ram.len) {
                return if (atomic_ram.compareAndSwap(T, bus.ram, paddr, @truncate(self.excl_val), val)) 0 else 1;
            }
            switch (T) {
                u8 => try self.write8(bus, vaddr, val),
                u16 => try self.write16(bus, vaddr, val),
                u32 => try self.write32(bus, vaddr, val),
                u64 => try self.write64(bus, vaddr, val),
                else => @compileError("unsupported store-exclusive size"),
            }
            return 0;
        }

        /// Guest `DMB` / `DSB`: a host barrier while cores run in parallel. `DSB` also completes this
        /// core's `TLBI*IS` invalidations on the other cores.
        inline fn memoryBarrier(self: *Self, bus: *Bus, is_dsb: bool) void {
            if (!atomic_ram.busParallel(bus)) return;
            atomic_ram.fence(&self.fence_word);
            if (is_dsb) bus.smp.broadcastTlb(self.mmu.core_id, &self.mmu);
        }

        fn syncCoreTimerLines(self: *Self, bus: *Bus) void {
            if (@hasDecl(Bus, "setCoreTimerLines")) {
                bus.setCoreTimerLines(self.mmu.core_id, self.mmu.timer_irq_lines);
            } else if (@hasField(Bus, "local_intc")) {
                bus.local_intc.core_timer_lines[self.mmu.core_id] = self.mmu.timer_irq_lines;
            }
        }

        inline fn write64(self: *Self, bus: *Bus, vaddr: u32, val: u64) error{Abort}!void {
            const priv: u1 = @intFromBool(self.isPrivileged());
            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
            if ((vaddr & 0xfff) <= 0xff8 and (vaddr & ~@as(u32, 0xffc)) == slot.w_vbase) {
                const paddr = slot.pbase | (vaddr & 0xfff);
                std.mem.writeInt(u64, bus.ram[paddr..][0..8], val, .little);
                return;
            }
            try self.write32(bus, vaddr, @truncate(val));
            try self.write32(bus, vaddr +% 4, @truncate(val >> 32));
        }

        inline fn read32(self: *Self, bus: *Bus, vaddr: u32) error{Abort}!u32 {
            const priv: u1 = @intFromBool(self.isPrivileged());
            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
            if ((vaddr & ~@as(u32, 0xffc)) == slot.r_vbase) {
                const paddr = slot.pbase | (vaddr & 0xfff);
                return std.mem.readInt(u32, bus.ram[paddr..][0..4], .little);
            }
            const paddr = try self.mmu.translate(bus.ram, vaddr, .read, priv != 0);
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
            const priv: u1 = @intFromBool(self.isPrivileged());
            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
            if ((vaddr & ~@as(u32, 0xffc)) == slot.w_vbase) {
                const paddr = slot.pbase | (vaddr & 0xfff);
                std.mem.writeInt(u32, bus.ram[paddr..][0..4], val, .little);
                return;
            }
            if ((vaddr & 3) != 0 and (self.mmu.sctlr & (1 << 22)) != 0) {
                try self.write8(bus, vaddr, @truncate(val));
                try self.write8(bus, vaddr +% 1, @truncate(val >> 8));
                try self.write8(bus, vaddr +% 2, @truncate(val >> 16));
                try self.write8(bus, vaddr +% 3, @truncate(val >> 24));
                return;
            }
            const paddr = try self.mmu.translate(bus.ram, vaddr, .write, priv != 0);
            if (paddr < bus.ram.len and (paddr & 3) == 0) {
                std.mem.writeInt(u32, bus.ram[paddr..][0..4], val, .little);
                return;
            }
            bus.write32(paddr & ~@as(u32, 3), val);
        }

        inline fn read16(self: *Self, bus: *Bus, vaddr: u32) error{Abort}!u16 {
            const priv: u1 = @intFromBool(self.isPrivileged());
            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
            if ((vaddr & ~@as(u32, 0xffe)) == slot.r_vbase) {
                const paddr = slot.pbase | (vaddr & 0xfff);
                return std.mem.readInt(u16, bus.ram[paddr..][0..2], .little);
            }
            if ((vaddr & 1) != 0 and (self.mmu.sctlr & (1 << 22)) != 0) {
                const b0: u16 = try self.read8(bus, vaddr);
                const b1: u16 = try self.read8(bus, vaddr +% 1);
                return b0 | (b1 << 8);
            }
            const paddr = try self.mmu.translate(bus.ram, vaddr, .read, priv != 0);
            if (@as(usize, paddr) + 2 <= bus.ram.len) {
                return std.mem.readInt(u16, bus.ram[paddr..][0..2], .little);
            }
            return bus.read16(paddr);
        }

        inline fn write16(self: *Self, bus: *Bus, vaddr: u32, val: u16) error{Abort}!void {
            const priv: u1 = @intFromBool(self.isPrivileged());
            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
            if ((vaddr & ~@as(u32, 0xffe)) == slot.w_vbase) {
                const paddr = slot.pbase | (vaddr & 0xfff);
                std.mem.writeInt(u16, bus.ram[paddr..][0..2], val, .little);
                return;
            }
            if ((vaddr & 1) != 0 and (self.mmu.sctlr & (1 << 22)) != 0) {
                try self.write8(bus, vaddr, @truncate(val));
                try self.write8(bus, vaddr +% 1, @truncate(val >> 8));
                return;
            }
            const paddr = try self.mmu.translate(bus.ram, vaddr, .write, priv != 0);
            if (@as(usize, paddr) + 2 <= bus.ram.len) {
                std.mem.writeInt(u16, bus.ram[paddr..][0..2], val, .little);
                return;
            }
            bus.write16(paddr, val);
        }

        inline fn read8(self: *Self, bus: *Bus, vaddr: u32) error{Abort}!u8 {
            const priv: u1 = @intFromBool(self.isPrivileged());
            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
            if ((vaddr & 0xffff_f000) == slot.r_vbase) {
                return bus.ram[slot.pbase | (vaddr & 0xfff)];
            }
            const paddr = try self.mmu.translate(bus.ram, vaddr, .read, priv != 0);
            if (paddr < bus.ram.len) {
                return bus.ram[paddr];
            }
            return bus.read8(paddr);
        }

        inline fn write8(self: *Self, bus: *Bus, vaddr: u32, val: u8) error{Abort}!void {
            const priv: u1 = @intFromBool(self.isPrivileged());
            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
            if ((vaddr & 0xffff_f000) == slot.w_vbase) {
                bus.ram[slot.pbase | (vaddr & 0xfff)] = val;
                return;
            }
            const paddr = try self.mmu.translate(bus.ram, vaddr, .write, priv != 0);
            if (paddr < bus.ram.len) {
                bus.ram[paddr] = val;
                return;
            }
            bus.write8(paddr, val);
        }

        inline fn fetch32(self: *Self, bus: *Bus, vaddr: u32) error{Abort}!u32 {
            const priv: u1 = @intFromBool(self.isPrivileged());
            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
            if ((vaddr & 0xffff_f000) == slot.x_vbase) {
                const paddr = slot.pbase | (vaddr & 0xfff);
                return std.mem.readInt(u32, bus.ram[paddr..][0..4], .little);
            }
            const paddr = try self.mmu.translate(bus.ram, vaddr, .fetch, priv != 0);
            if (@as(usize, paddr) + 4 <= bus.ram.len) {
                return std.mem.readInt(u32, bus.ram[paddr..][0..4], .little);
            }
            return bus.read32(paddr);
        }

        inline fn fetch16(self: *Self, bus: *Bus, vaddr: u32) error{Abort}!u16 {
            const priv: u1 = @intFromBool(self.isPrivileged());
            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
            if ((vaddr & 0xffff_f000) == slot.x_vbase) {
                const paddr = slot.pbase | (vaddr & 0xfff);
                return std.mem.readInt(u16, bus.ram[paddr..][0..2], .little);
            }
            const paddr = try self.mmu.translate(bus.ram, vaddr, .fetch, priv != 0);
            if (@as(usize, paddr) + 2 <= bus.ram.len) {
                return std.mem.readInt(u16, bus.ram[paddr..][0..2], .little);
            }
            return bus.read16(paddr);
        }

        // --- Execution Step ---

        /// Executes up to `max_steps` instructions, stopping early if the CPU
        /// enters `WFI` or an interrupt becomes pending.
        pub fn runSteps(self: *Self, bus: *Bus, max_steps: usize) usize {
            @setEvalBranchQuota(10000);
            if (self.halted_spin) return 0;
            if (self.is_aarch64) {
                const A64 = aarch64_mod.Aarch64Exec(Self, Bus);
                return A64.runSteps64(self, bus, max_steps);
            }
            _ = self.checkInterrupts(bus);
            if (self.mmu.halted_wfi) return 0;

            self.yield_slice = false;
            self.last_dmb_pc = 0xffff_ffff;

            const limit = if (max_steps == 4096) max_steps + 256 else max_steps;
            var executed: usize = 0;
            var cur_last_inst: u32 = self.last_inst;
            defer {
                self.cycles +%= executed;
                self.mmu.pmccntr +%= @truncate(executed);
                self.last_inst = cur_last_inst;
                self.excl_valid = false;
            }
            var priv: u1 = @intFromBool(self.isPrivileged());
            var code_vbase: u32 = 0xffff_ffff;
            var code_pbase: u32 = 0;
            var code_page_ptr: [*]const u8 = bus.ram.ptr;
            var data_r_vbase: u32 = 0xffff_ffff;
            var data_w_vbase: u32 = 0xffff_ffff;
            var data_page_ptr: [*]u8 = bus.ram.ptr;

            while (executed < limit) {
                if (executed >= max_steps and (self.cpsr & PsrFlags.I) == 0) break;
                if ((executed & 255) == 0 and atomic_ram.busParallel(bus)) {
                    // Apply TLB invalidations other cores broadcast while this slice runs
                    if (bus.smp.serviceTlb(self.mmu.core_id, &self.mmu)) {
                        code_vbase = 0xffff_ffff;
                        data_r_vbase = 0xffff_ffff;
                        data_w_vbase = 0xffff_ffff;
                    }
                }
                if (self.isThumb()) {
                    const pc = self.r[15] & ~@as(u32, 1);
                    const inst16: u16 = if ((pc & 0xffff_f000) == code_vbase)
                        std.mem.readInt(u16, code_page_ptr[pc & 0xffe ..][0..2], .little)
                    else blk: {
                        const islot = self.mmu.soft_tlb32[priv][(pc >> 12) & Mmu.soft_tlb_mask];
                        if ((pc & 0xffff_f000) == islot.x_vbase) {
                            code_vbase = islot.x_vbase;
                            code_pbase = islot.pbase;
                            code_page_ptr = bus.ram.ptr + code_pbase;
                            break :blk std.mem.readInt(u16, code_page_ptr[pc & 0xffe ..][0..2], .little);
                        }
                        const fetched = self.fetch16(bus, pc) catch {
                            self.enterException(.abt, 0x0c, pc +% 4, false);
                            priv = 1;
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                            executed += 1;
                            continue;
                        };
                        const islot2 = self.mmu.soft_tlb32[priv][(pc >> 12) & Mmu.soft_tlb_mask];
                        if ((pc & 0xffff_f000) == islot2.x_vbase) {
                            code_vbase = islot2.x_vbase;
                            code_pbase = islot2.pbase;
                            code_page_ptr = bus.ram.ptr + code_pbase;
                        }
                        break :blk fetched;
                    };
                    self.r[15] = pc +% 2;
                    executed += 1;
                    if (self.executeThumb(bus, pc, inst16, priv, code_vbase, code_pbase, &data_r_vbase, &data_w_vbase, &data_page_ptr)) {
                        if (self.mmu.halted_wfi or self.yield_slice) break;
                        _ = self.checkInterrupts(bus);
                        priv = @intFromBool(self.isPrivileged());
                        code_vbase = 0xffff_ffff;
                        data_r_vbase = 0xffff_ffff;
                        data_w_vbase = 0xffff_ffff;
                    }
                    continue;
                }

                const pc = self.r[15] & ~@as(u32, 3);
                const inst: u32 = if ((pc & 0xffff_f000) == code_vbase)
                    std.mem.readInt(u32, code_page_ptr[pc & 0xfff ..][0..4], .little)
                else blk: {
                    const islot = self.mmu.soft_tlb32[priv][(pc >> 12) & Mmu.soft_tlb_mask];
                    if ((pc & 0xffff_f000) == islot.x_vbase) {
                        code_vbase = islot.x_vbase;
                        code_pbase = islot.pbase;
                        code_page_ptr = bus.ram.ptr + code_pbase;
                        break :blk std.mem.readInt(u32, code_page_ptr[pc & 0xfff ..][0..4], .little);
                    }
                    const fetched = self.fetch32(bus, pc) catch {
                        self.enterException(.abt, 0x0c, pc +% 4, false);
                        priv = 1;
                        code_vbase = 0xffff_ffff;
                        data_r_vbase = 0xffff_ffff;
                        data_w_vbase = 0xffff_ffff;
                        executed += 1;
                        continue;
                    };
                    const islot2 = self.mmu.soft_tlb32[priv][(pc >> 12) & Mmu.soft_tlb_mask];
                    if ((pc & 0xffff_f000) == islot2.x_vbase) {
                        code_vbase = islot2.x_vbase;
                        code_pbase = islot2.pbase;
                        code_page_ptr = bus.ram.ptr + code_pbase;
                    }
                    break :blk fetched;
                };

                self.r[15] = pc +% 4;
                cur_last_inst = inst;
                executed += 1;

                if (inst < 0xe000_0000) {
                    if (!dec.checkCond(@truncate(inst >> 28), self.cpsr)) continue;
                }

                const ic_idx: usize = @truncate(((pc >> 2) ^ (pc >> 16)) & icache_mask);
                var d = self.icache[ic_idx];
                if (d.raw != inst) {
                    d = decodeArm32(inst);
                    self.icache[ic_idx] = d;
                }

                const imm32: u32 = @truncate(d.imm);
                const op: ArmOp = @enumFromInt(d.op);
                switch (op) {
                    .add_imm_al => self.r[d.rd] = self.r[d.rn] +% imm32,
                    .sub_imm_al => self.r[d.rd] = self.r[d.rn] -% imm32,
                    .rsb_imm_al => self.r[d.rd] = imm32 -% self.r[d.rn],
                    .adc_imm_al => self.r[d.rd] = self.r[d.rn] +% imm32 +% ((self.cpsr >> 29) & 1),
                    .sbc_imm_al => self.r[d.rd] = self.r[d.rn] +% ~imm32 +% ((self.cpsr >> 29) & 1),
                    .rsc_imm_al => self.r[d.rd] = imm32 +% ~self.r[d.rn] +% ((self.cpsr >> 29) & 1),
                    .and_imm_al => self.r[d.rd] = self.r[d.rn] & imm32,
                    .orr_imm_al => self.r[d.rd] = self.r[d.rn] | imm32,
                    .eor_imm_al => self.r[d.rd] = self.r[d.rn] ^ imm32,
                    .bic_imm_al => self.r[d.rd] = self.r[d.rn] & ~imm32,
                    .mov_imm_al => self.r[d.rd] = imm32,
                    .mvn_imm_al => self.r[d.rd] = ~imm32,
                    .cmp_imm_al => self.setNZCV(dec.addWithCarry(self.r[d.rn], ~imm32, 1)),
                    .cmn_imm_al => self.setNZCV(dec.addWithCarry(self.r[d.rn], imm32, 0)),
                    .tst_imm_al => self.setNZ(self.r[d.rn] & imm32),
                    .teq_imm_al => self.setNZ(self.r[d.rn] ^ imm32),
                    .adds_imm_al => {
                        const res = dec.addWithCarry(self.r[d.rn], imm32, 0);
                        self.r[d.rd] = res.val;
                        self.setNZCV(res);
                    },
                    .subs_imm_al => {
                        const res = dec.addWithCarry(self.r[d.rn], ~imm32, 1);
                        self.r[d.rd] = res.val;
                        self.setNZCV(res);
                    },
                    .adcs_imm_al => {
                        const res = dec.addWithCarry(self.r[d.rn], imm32, @truncate((self.cpsr >> 29) & 1));
                        self.r[d.rd] = res.val;
                        self.setNZCV(res);
                    },
                    .sbcs_imm_al => {
                        const res = dec.addWithCarry(self.r[d.rn], ~imm32, @truncate((self.cpsr >> 29) & 1));
                        self.r[d.rd] = res.val;
                        self.setNZCV(res);
                    },
                    .movw_al => self.r[d.rd] = imm32,
                    .movt_al => self.r[d.rd] = (self.r[d.rd] & 0x0000_ffff) | (imm32 << 16),
                    .add_reg_al => self.r[d.rd] = self.r[d.rn] +% self.r[d.rm],
                    .sub_reg_al => self.r[d.rd] = self.r[d.rn] -% self.r[d.rm],
                    .rsb_reg_al => self.r[d.rd] = self.r[d.rm] -% self.r[d.rn],
                    .adc_reg_al => self.r[d.rd] = self.r[d.rn] +% self.r[d.rm] +% ((self.cpsr >> 29) & 1),
                    .sbc_reg_al => self.r[d.rd] = self.r[d.rn] +% ~self.r[d.rm] +% ((self.cpsr >> 29) & 1),
                    .rsc_reg_al => self.r[d.rd] = self.r[d.rm] +% ~self.r[d.rn] +% ((self.cpsr >> 29) & 1),
                    .and_reg_al => self.r[d.rd] = self.r[d.rn] & self.r[d.rm],
                    .orr_reg_al => self.r[d.rd] = self.r[d.rn] | self.r[d.rm],
                    .eor_reg_al => self.r[d.rd] = self.r[d.rn] ^ self.r[d.rm],
                    .bic_reg_al => self.r[d.rd] = self.r[d.rn] & ~self.r[d.rm],
                    .mov_reg_al => self.r[d.rd] = self.r[d.rm],
                    .mvn_reg_al => self.r[d.rd] = ~self.r[d.rm],
                    .adds_reg_al => {
                        const res = dec.addWithCarry(self.r[d.rn], self.r[d.rm], 0);
                        self.r[d.rd] = res.val;
                        self.setNZCV(res);
                    },
                    .subs_reg_al => {
                        const res = dec.addWithCarry(self.r[d.rn], ~self.r[d.rm], 1);
                        self.r[d.rd] = res.val;
                        self.setNZCV(res);
                    },
                    .adcs_reg_al => {
                        const res = dec.addWithCarry(self.r[d.rn], self.r[d.rm], @truncate((self.cpsr >> 29) & 1));
                        self.r[d.rd] = res.val;
                        self.setNZCV(res);
                    },
                    .sbcs_reg_al => {
                        const res = dec.addWithCarry(self.r[d.rn], ~self.r[d.rm], @truncate((self.cpsr >> 29) & 1));
                        self.r[d.rd] = res.val;
                        self.setNZCV(res);
                    },
                    .cmp_reg_al => self.setNZCV(dec.addWithCarry(self.r[d.rn], ~self.r[d.rm], 1)),
                    .cmn_reg_al => self.setNZCV(dec.addWithCarry(self.r[d.rn], self.r[d.rm], 0)),
                    .tst_reg_al => self.setNZ(self.r[d.rn] & self.r[d.rm]),
                    .teq_reg_al => self.setNZ(self.r[d.rn] ^ self.r[d.rm]),
                    .lsl_imm_al => self.r[d.rd] = self.r[d.rm] << @as(u5, @truncate(imm32)),
                    .lsr_imm_al => self.r[d.rd] = self.r[d.rm] >> @as(u5, @truncate(imm32)),
                    .asr_imm_al => self.r[d.rd] = @bitCast(@as(i32, @bitCast(self.r[d.rm])) >> @as(u5, @truncate(imm32))),
                    .mvn_lsl_imm_al => self.r[d.rd] = ~(self.r[d.rm] << @as(u5, @truncate(imm32))),
                    .mvn_lsr_imm_al => self.r[d.rd] = ~(self.r[d.rm] >> @as(u5, @truncate(imm32))),
                    .add_lsl_reg_al => self.r[d.rd] = self.r[d.rn] +% (self.r[d.rm] << @as(u5, @truncate(imm32))),
                    .sub_lsl_reg_al => self.r[d.rd] = self.r[d.rn] -% (self.r[d.rm] << @as(u5, @truncate(imm32))),
                    .rsb_lsl_reg_al => self.r[d.rd] = (self.r[d.rm] << @as(u5, @truncate(imm32))) -% self.r[d.rn],
                    .orr_lsl_reg_al => self.r[d.rd] = self.r[d.rn] | (self.r[d.rm] << @as(u5, @truncate(imm32))),
                    .eor_lsl_reg_al => self.r[d.rd] = self.r[d.rn] ^ (self.r[d.rm] << @as(u5, @truncate(imm32))),
                    .and_lsl_reg_al => self.r[d.rd] = self.r[d.rn] & (self.r[d.rm] << @as(u5, @truncate(imm32))),
                    .bic_lsl_reg_al => self.r[d.rd] = self.r[d.rn] & ~(self.r[d.rm] << @as(u5, @truncate(imm32))),
                    .add_lsr_reg_al => self.r[d.rd] = self.r[d.rn] +% (self.r[d.rm] >> @as(u5, @truncate(imm32))),
                    .sub_lsr_reg_al => self.r[d.rd] = self.r[d.rn] -% (self.r[d.rm] >> @as(u5, @truncate(imm32))),
                    .rsb_lsr_reg_al => self.r[d.rd] = (self.r[d.rm] >> @as(u5, @truncate(imm32))) -% self.r[d.rn],
                    .orr_lsr_reg_al => self.r[d.rd] = self.r[d.rn] | (self.r[d.rm] >> @as(u5, @truncate(imm32))),
                    .eor_lsr_reg_al => self.r[d.rd] = self.r[d.rn] ^ (self.r[d.rm] >> @as(u5, @truncate(imm32))),
                    .and_lsr_reg_al => self.r[d.rd] = self.r[d.rn] & (self.r[d.rm] >> @as(u5, @truncate(imm32))),
                    .bic_lsr_reg_al => self.r[d.rd] = self.r[d.rn] & ~(self.r[d.rm] >> @as(u5, @truncate(imm32))),
                    .add_asr_reg_al => self.r[d.rd] = self.r[d.rn] +% @as(u32, @bitCast(@as(i32, @bitCast(self.r[d.rm])) >> @as(u5, @truncate(imm32)))),
                    .sub_asr_reg_al => self.r[d.rd] = self.r[d.rn] -% @as(u32, @bitCast(@as(i32, @bitCast(self.r[d.rm])) >> @as(u5, @truncate(imm32)))),
                    .orr_asr_reg_al => self.r[d.rd] = self.r[d.rn] | @as(u32, @bitCast(@as(i32, @bitCast(self.r[d.rm])) >> @as(u5, @truncate(imm32)))),
                    .and_asr_reg_al => self.r[d.rd] = self.r[d.rn] & @as(u32, @bitCast(@as(i32, @bitCast(self.r[d.rm])) >> @as(u5, @truncate(imm32)))),
                    .bic_asr_reg_al => self.r[d.rd] = self.r[d.rn] & ~@as(u32, @bitCast(@as(i32, @bitCast(self.r[d.rm])) >> @as(u5, @truncate(imm32)))),
                    .cmp_lsl_reg_al => self.setNZCV(dec.addWithCarry(self.r[d.rn], ~(self.r[d.rm] << @as(u5, @truncate(imm32))), 1)),
                    .cmp_lsr_reg_al => self.setNZCV(dec.addWithCarry(self.r[d.rn], ~(self.r[d.rm] >> @as(u5, @truncate(imm32))), 1)),
                    .tst_lsl_reg_al => {
                        const sh: u5 = @truncate(imm32);
                        const inv: u5 = @truncate(@as(u6, 32) -% sh);
                        const rm_val = self.r[d.rm];
                        self.setNZC(self.r[d.rn] & (rm_val << sh), @truncate(rm_val >> inv));
                    },
                    .tst_lsr_reg_al => {
                        const sh: u5 = @truncate(imm32);
                        const m1: u5 = sh -% 1;
                        const rm_val = self.r[d.rm];
                        self.setNZC(self.r[d.rn] & (rm_val >> sh), @truncate(rm_val >> m1));
                    },
                    .mul_al => self.r[d.rd] = self.r[d.rm] *% self.r[d.rn],
                    .mla_al => self.r[d.rd] = self.r[d.rm] *% self.r[d.rn] +% self.r[@as(u4, @truncate(imm32))],
                    .mls_al => self.r[d.rd] = self.r[@as(u4, @truncate(imm32))] -% (self.r[d.rm] *% self.r[d.rn]),
                    .umull_al => {
                        const prod: u64 = @as(u64, self.r[d.rm]) * @as(u64, self.r[d.rn]);
                        self.r[@as(u4, @truncate(imm32))] = @truncate(prod);
                        self.r[d.rd] = @truncate(prod >> 32);
                    },
                    .umlal_al => {
                        const rd_lo: u4 = @truncate(imm32);
                        const acc: u64 = (@as(u64, self.r[d.rd]) << 32) | self.r[rd_lo];
                        const prod: u64 = (@as(u64, self.r[d.rm]) * @as(u64, self.r[d.rn])) +% acc;
                        self.r[rd_lo] = @truncate(prod);
                        self.r[d.rd] = @truncate(prod >> 32);
                    },
                    .smull_al => {
                        const a: i64 = @as(i32, @bitCast(self.r[d.rm]));
                        const b: i64 = @as(i32, @bitCast(self.r[d.rn]));
                        const prod: u64 = @bitCast(a * b);
                        self.r[@as(u4, @truncate(imm32))] = @truncate(prod);
                        self.r[d.rd] = @truncate(prod >> 32);
                    },
                    .smlal_al => {
                        const rd_lo: u4 = @truncate(imm32);
                        const a: i64 = @as(i32, @bitCast(self.r[d.rm]));
                        const b: i64 = @as(i32, @bitCast(self.r[d.rn]));
                        const acc: i64 = @bitCast((@as(u64, self.r[d.rd]) << 32) | self.r[rd_lo]);
                        const prod: u64 = @bitCast((a * b) +% acc);
                        self.r[rd_lo] = @truncate(prod);
                        self.r[d.rd] = @truncate(prod >> 32);
                    },
                    .ldrex_al => {
                        const vaddr = self.r[d.rn];
                        const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
                        if ((vaddr & ~@as(u32, 0xffc)) == slot.r_vbase) {
                            data_r_vbase = slot.r_vbase;
                            data_w_vbase = slot.w_vbase;
                            data_page_ptr = bus.ram.ptr + slot.pbase;
                            const paddr = slot.pbase | (vaddr & 0xfff);
                            self.r[d.rd] = std.mem.readInt(u32, data_page_ptr[vaddr & 0xffc ..][0..4], .little);
                            self.excl_valid = true;
                            self.excl_paddr = paddr;
                            self.excl_val = self.r[d.rd];
                        } else {
                            self.r[d.rd] = self.read32(bus, vaddr) catch {
                                self.enterException(.abt, 0x10, pc +% 8, false);
                                priv = 1;
                                code_vbase = 0xffff_ffff;
                                data_r_vbase = 0xffff_ffff;
                                data_w_vbase = 0xffff_ffff;
                                continue;
                            };
                            self.excl_valid = true;
                            self.excl_val = self.r[d.rd];
                            const slot2 = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
                            self.excl_paddr = if ((vaddr & 0xffff_f000) == slot2.r_vbase) (slot2.pbase | (vaddr & 0xfff)) else 0;
                        }
                    },
                    .strex_al => {
                        const vaddr = self.r[d.rn];
                        const val = self.r[d.rm];
                        const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
                        if ((vaddr & ~@as(u32, 0xffc)) == slot.w_vbase) {
                            data_r_vbase = slot.r_vbase;
                            data_w_vbase = slot.w_vbase;
                            data_page_ptr = bus.ram.ptr + slot.pbase;
                            if (self.excl_valid) {
                                const stored = atomic_ram.compareAndSwap(u32, bus.ram, slot.pbase | (vaddr & 0xfff), @truncate(self.excl_val), val);
                                self.r[d.rd] = if (stored) 0 else 1;
                                self.excl_valid = false;
                            } else {
                                self.r[d.rd] = 1;
                            }
                        } else {
                            self.r[d.rd] = self.storeExclusive(bus, u32, vaddr, val, priv != 0) catch {
                                self.enterException(.abt, 0x10, pc +% 8, false);
                                priv = 1;
                                code_vbase = 0xffff_ffff;
                                data_r_vbase = 0xffff_ffff;
                                data_w_vbase = 0xffff_ffff;
                                continue;
                            };
                        }
                    },
                    .ldrexd_al => {
                        const vaddr = self.r[d.rn];
                        const pair = self.read64(bus, vaddr) catch {
                            self.enterException(.abt, 0x10, pc +% 8, false);
                            priv = 1;
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                            continue;
                        };
                        self.r[d.rd] = @truncate(pair);
                        self.r[d.rd + 1] = @truncate(pair >> 32);
                        self.excl_valid = true;
                        self.excl_val = pair;
                    },
                    .strexd_al => {
                        const vaddr = self.r[d.rn];
                        const val: u64 = @as(u64, self.r[d.rm]) | (@as(u64, self.r[d.rm + 1]) << 32);
                        self.r[d.rd] = self.storeExclusive(bus, u64, vaddr, val, priv != 0) catch {
                            self.enterException(.abt, 0x10, pc +% 8, false);
                            priv = 1;
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                            continue;
                        };
                    },
                    .ldrexb_al => {
                        const vaddr = self.r[d.rn];
                        if ((vaddr & 0xffff_f000) == data_r_vbase) {
                            self.r[d.rd] = data_page_ptr[vaddr & 0xfff];
                        } else {
                            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
                            if ((vaddr & 0xffff_f000) == slot.r_vbase) {
                                data_r_vbase = slot.r_vbase;
                                data_w_vbase = slot.w_vbase;
                                data_page_ptr = bus.ram.ptr + slot.pbase;
                                self.r[d.rd] = data_page_ptr[vaddr & 0xfff];
                            } else {
                                self.r[d.rd] = self.read8(bus, vaddr) catch {
                                    self.enterException(.abt, 0x10, pc +% 8, false);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff;
                                    data_r_vbase = 0xffff_ffff;
                                    data_w_vbase = 0xffff_ffff;
                                    continue;
                                };
                            }
                        }
                        self.excl_valid = true;
                        self.excl_val = self.r[d.rd];
                    },
                    .strexb_al => {
                        const vaddr = self.r[d.rn];
                        const val: u8 = @truncate(self.r[d.rm]);
                        self.r[d.rd] = self.storeExclusive(bus, u8, vaddr, val, priv != 0) catch {
                            self.enterException(.abt, 0x10, pc +% 8, false);
                            priv = 1;
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                            continue;
                        };
                    },
                    .ldrexh_al => {
                        const vaddr = self.r[d.rn];
                        if ((vaddr & ~@as(u32, 0xffe)) == data_r_vbase) {
                            self.r[d.rd] = std.mem.readInt(u16, data_page_ptr[vaddr & 0xffe ..][0..2], .little);
                        } else {
                            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
                            if ((vaddr & ~@as(u32, 0xffe)) == slot.r_vbase) {
                                data_r_vbase = slot.r_vbase;
                                data_w_vbase = slot.w_vbase;
                                data_page_ptr = bus.ram.ptr + slot.pbase;
                                self.r[d.rd] = std.mem.readInt(u16, data_page_ptr[vaddr & 0xffe ..][0..2], .little);
                            } else {
                                self.r[d.rd] = self.read16(bus, vaddr) catch {
                                    self.enterException(.abt, 0x10, pc +% 8, false);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff;
                                    data_r_vbase = 0xffff_ffff;
                                    data_w_vbase = 0xffff_ffff;
                                    continue;
                                };
                            }
                        }
                        self.excl_valid = true;
                        self.excl_val = self.r[d.rd];
                    },
                    .strexh_al => {
                        const vaddr = self.r[d.rn];
                        const val: u16 = @truncate(self.r[d.rm]);
                        self.r[d.rd] = self.storeExclusive(bus, u16, vaddr, val, priv != 0) catch {
                            self.enterException(.abt, 0x10, pc +% 8, false);
                            priv = 1;
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                            continue;
                        };
                    },
                    .clz_al => self.r[d.rd] = @clz(self.r[d.rm]),
                    .uxtb_al => self.r[d.rd] = std.math.rotr(u32, self.r[d.rm], @as(u5, @truncate(imm32))) & 0xff,
                    .uxth_al => self.r[d.rd] = std.math.rotr(u32, self.r[d.rm], @as(u5, @truncate(imm32))) & 0xffff,
                    .sxtb_al => {
                        const rot_rm = std.math.rotr(u32, self.r[d.rm], @as(u5, @truncate(imm32)));
                        self.r[d.rd] = @bitCast(@as(i32, @as(i8, @bitCast(@as(u8, @truncate(rot_rm))))));
                    },
                    .sxth_al => {
                        const rot_rm = std.math.rotr(u32, self.r[d.rm], @as(u5, @truncate(imm32)));
                        self.r[d.rd] = @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(rot_rm))))));
                    },
                    .uxtab_al => self.r[d.rd] = self.r[d.rn] +% (std.math.rotr(u32, self.r[d.rm], @as(u5, @truncate(imm32))) & 0xff),
                    .uxtah_al => self.r[d.rd] = self.r[d.rn] +% (std.math.rotr(u32, self.r[d.rm], @as(u5, @truncate(imm32))) & 0xffff),
                    .sxtab_al => {
                        const rot_rm = std.math.rotr(u32, self.r[d.rm], @as(u5, @truncate(imm32)));
                        const sext: u32 = @bitCast(@as(i32, @as(i8, @bitCast(@as(u8, @truncate(rot_rm))))));
                        self.r[d.rd] = self.r[d.rn] +% sext;
                    },
                    .sxtah_al => {
                        const rot_rm = std.math.rotr(u32, self.r[d.rm], @as(u5, @truncate(imm32)));
                        const sext: u32 = @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(rot_rm))))));
                        self.r[d.rd] = self.r[d.rn] +% sext;
                    },
                    .rev_al => self.r[d.rd] = @byteSwap(self.r[d.rm]),
                    .rev16_al => {
                        const v = self.r[d.rm];
                        const lo: u16 = @byteSwap(@as(u16, @truncate(v)));
                        const hi: u16 = @byteSwap(@as(u16, @truncate(v >> 16)));
                        self.r[d.rd] = (@as(u32, hi) << 16) | lo;
                    },
                    .rbit_al => self.r[d.rd] = @bitReverse(self.r[d.rm]),
                    .ubfx_al => self.r[d.rd] = (self.r[d.rm] >> @as(u5, @truncate(d.rn))) & imm32,
                    .sbfx_al => {
                        const sh_left: u5 = @truncate(d.rn);
                        const sh_right: u5 = @truncate(imm32);
                        const shifted: i32 = @as(i32, @bitCast(self.r[d.rm] << sh_left)) >> sh_right;
                        self.r[d.rd] = @bitCast(shifted);
                    },
                    .bfi_al => {
                        const lsb: u5 = @truncate(d.rn);
                        self.r[d.rd] = (self.r[d.rd] & ~imm32) | ((self.r[d.rm] << lsb) & imm32);
                    },
                    .bfc_al => self.r[d.rd] &= ~imm32,
                    .udiv_al => {
                        const den = self.r[d.rm];
                        self.r[d.rd] = if (den == 0) 0 else self.r[d.rn] / den;
                    },
                    .sdiv_al => {
                        const den_u = self.r[d.rm];
                        if (den_u == 0) {
                            self.r[d.rd] = 0;
                        } else {
                            const num: i32 = @bitCast(self.r[d.rn]);
                            const den: i32 = @bitCast(den_u);
                            self.r[d.rd] = if (num == std.math.minInt(i32) and den == -1)
                                @bitCast(num)
                            else
                                @bitCast(@divTrunc(num, den));
                        }
                    },
                    .ldr_imm_al => {
                        const vaddr = self.r[d.rn] +% imm32;
                        if ((vaddr & ~@as(u32, 0xffc)) == data_r_vbase) {
                            self.r[d.rd] = std.mem.readInt(u32, data_page_ptr[vaddr & 0xffc ..][0..4], .little);
                        } else {
                            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
                            if ((vaddr & ~@as(u32, 0xffc)) == slot.r_vbase) {
                                data_r_vbase = slot.r_vbase;
                                data_w_vbase = slot.w_vbase;
                                data_page_ptr = bus.ram.ptr + slot.pbase;
                                self.r[d.rd] = std.mem.readInt(u32, data_page_ptr[vaddr & 0xffc ..][0..4], .little);
                            } else {
                                self.r[d.rd] = self.read32(bus, vaddr) catch {
                                    self.enterException(.abt, 0x10, pc +% 8, false);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff;
                                    data_r_vbase = 0xffff_ffff;
                                    data_w_vbase = 0xffff_ffff;
                                    continue;
                                };
                            }
                        }
                    },
                    .str_imm_al => {
                        const vaddr = self.r[d.rn] +% imm32;
                        if ((vaddr & ~@as(u32, 0xffc)) == data_w_vbase) {
                            std.mem.writeInt(u32, data_page_ptr[vaddr & 0xffc ..][0..4], self.r[d.rd], .little);
                        } else {
                            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
                            if ((vaddr & ~@as(u32, 0xffc)) == slot.w_vbase) {
                                data_r_vbase = slot.r_vbase;
                                data_w_vbase = slot.w_vbase;
                                data_page_ptr = bus.ram.ptr + slot.pbase;
                                std.mem.writeInt(u32, data_page_ptr[vaddr & 0xffc ..][0..4], self.r[d.rd], .little);
                            } else {
                                self.write32(bus, vaddr, self.r[d.rd]) catch {
                                    self.enterException(.abt, 0x10, pc +% 8, false);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff;
                                    data_r_vbase = 0xffff_ffff;
                                    data_w_vbase = 0xffff_ffff;
                                    continue;
                                };
                                if ((vaddr & 0xffff_f000) != self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask].w_vbase) {
                                    if (self.checkInterrupts(bus)) {
                                        priv = 1;
                                        code_vbase = 0xffff_ffff;
                                        data_r_vbase = 0xffff_ffff;
                                        data_w_vbase = 0xffff_ffff;
                                    }
                                }
                            }
                        }
                    },
                    .ldrb_imm_al => {
                        const vaddr = self.r[d.rn] +% imm32;
                        if ((vaddr & 0xffff_f000) == data_r_vbase) {
                            self.r[d.rd] = data_page_ptr[vaddr & 0xfff];
                        } else {
                            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
                            if ((vaddr & 0xffff_f000) == slot.r_vbase) {
                                data_r_vbase = slot.r_vbase;
                                data_w_vbase = slot.w_vbase;
                                data_page_ptr = bus.ram.ptr + slot.pbase;
                                self.r[d.rd] = data_page_ptr[vaddr & 0xfff];
                            } else {
                                self.r[d.rd] = self.read8(bus, vaddr) catch {
                                    self.enterException(.abt, 0x10, pc +% 8, false);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff;
                                    data_r_vbase = 0xffff_ffff;
                                    data_w_vbase = 0xffff_ffff;
                                    continue;
                                };
                            }
                        }
                    },
                    .strb_imm_al => {
                        const vaddr = self.r[d.rn] +% imm32;
                        if ((vaddr & 0xffff_f000) == data_w_vbase) {
                            data_page_ptr[vaddr & 0xfff] = @truncate(self.r[d.rd]);
                        } else {
                            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
                            if ((vaddr & 0xffff_f000) == slot.w_vbase) {
                                data_r_vbase = slot.r_vbase;
                                data_w_vbase = slot.w_vbase;
                                data_page_ptr = bus.ram.ptr + slot.pbase;
                                data_page_ptr[vaddr & 0xfff] = @truncate(self.r[d.rd]);
                            } else {
                                self.write8(bus, vaddr, @truncate(self.r[d.rd])) catch {
                                    self.enterException(.abt, 0x10, pc +% 8, false);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff;
                                    data_r_vbase = 0xffff_ffff;
                                    data_w_vbase = 0xffff_ffff;
                                    continue;
                                };
                                if ((vaddr & 0xffff_f000) != self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask].w_vbase) {
                                    if (self.checkInterrupts(bus)) {
                                        priv = 1;
                                        code_vbase = 0xffff_ffff;
                                        data_r_vbase = 0xffff_ffff;
                                        data_w_vbase = 0xffff_ffff;
                                    }
                                }
                            }
                        }
                    },
                    .ldr_lit_al => {
                        const vaddr = (pc +% 8) +% imm32;
                        if ((vaddr & ~@as(u32, 0xffc)) == code_vbase) {
                            self.r[d.rd] = std.mem.readInt(u32, code_page_ptr[vaddr & 0xffc ..][0..4], .little);
                        } else if ((vaddr & ~@as(u32, 0xffc)) == data_r_vbase) {
                            self.r[d.rd] = std.mem.readInt(u32, data_page_ptr[vaddr & 0xffc ..][0..4], .little);
                        } else {
                            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
                            if ((vaddr & ~@as(u32, 0xffc)) == slot.r_vbase) {
                                data_r_vbase = slot.r_vbase;
                                data_w_vbase = slot.w_vbase;
                                data_page_ptr = bus.ram.ptr + slot.pbase;
                                self.r[d.rd] = std.mem.readInt(u32, data_page_ptr[vaddr & 0xffc ..][0..4], .little);
                            } else {
                                self.r[d.rd] = self.read32(bus, vaddr) catch {
                                    self.enterException(.abt, 0x10, pc +% 8, false);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff;
                                    data_r_vbase = 0xffff_ffff;
                                    data_w_vbase = 0xffff_ffff;
                                    continue;
                                };
                            }
                        }
                    },
                    .ldrh_imm_al => {
                        const vaddr = self.r[d.rn] +% imm32;
                        if ((vaddr & ~@as(u32, 0xffe)) == data_r_vbase) {
                            self.r[d.rd] = std.mem.readInt(u16, data_page_ptr[vaddr & 0xffe ..][0..2], .little);
                        } else {
                            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
                            if ((vaddr & ~@as(u32, 0xffe)) == slot.r_vbase) {
                                data_r_vbase = slot.r_vbase;
                                data_w_vbase = slot.w_vbase;
                                data_page_ptr = bus.ram.ptr + slot.pbase;
                                self.r[d.rd] = std.mem.readInt(u16, data_page_ptr[vaddr & 0xffe ..][0..2], .little);
                            } else {
                                self.r[d.rd] = self.read16(bus, vaddr) catch {
                                    self.enterException(.abt, 0x10, pc +% 8, false);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff;
                                    data_r_vbase = 0xffff_ffff;
                                    data_w_vbase = 0xffff_ffff;
                                    continue;
                                };
                            }
                        }
                    },
                    .strh_imm_al => {
                        const vaddr = self.r[d.rn] +% imm32;
                        if ((vaddr & ~@as(u32, 0xffe)) == data_w_vbase) {
                            std.mem.writeInt(u16, data_page_ptr[vaddr & 0xffe ..][0..2], @truncate(self.r[d.rd]), .little);
                        } else {
                            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
                            if ((vaddr & ~@as(u32, 0xffe)) == slot.w_vbase) {
                                data_r_vbase = slot.r_vbase;
                                data_w_vbase = slot.w_vbase;
                                data_page_ptr = bus.ram.ptr + slot.pbase;
                                std.mem.writeInt(u16, data_page_ptr[vaddr & 0xffe ..][0..2], @truncate(self.r[d.rd]), .little);
                            } else {
                                self.write16(bus, vaddr, @truncate(self.r[d.rd])) catch {
                                    self.enterException(.abt, 0x10, pc +% 8, false);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff;
                                    data_r_vbase = 0xffff_ffff;
                                    data_w_vbase = 0xffff_ffff;
                                    continue;
                                };
                                if ((vaddr & 0xffff_f000) != self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask].w_vbase) {
                                    if (self.checkInterrupts(bus)) {
                                        priv = 1;
                                        code_vbase = 0xffff_ffff;
                                        data_r_vbase = 0xffff_ffff;
                                        data_w_vbase = 0xffff_ffff;
                                    }
                                }
                            }
                        }
                    },
                    .ldrsb_imm_al => {
                        const vaddr = self.r[d.rn] +% imm32;
                        const byte_val: u8 = if ((vaddr & 0xffff_f000) == data_r_vbase)
                            data_page_ptr[vaddr & 0xfff]
                        else blk: {
                            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
                            if ((vaddr & 0xffff_f000) == slot.r_vbase) {
                                data_r_vbase = slot.r_vbase;
                                data_w_vbase = slot.w_vbase;
                                data_page_ptr = bus.ram.ptr + slot.pbase;
                                break :blk data_page_ptr[vaddr & 0xfff];
                            }
                            break :blk self.read8(bus, vaddr) catch {
                                self.enterException(.abt, 0x10, pc +% 8, false);
                                priv = 1;
                                code_vbase = 0xffff_ffff;
                                data_r_vbase = 0xffff_ffff;
                                data_w_vbase = 0xffff_ffff;
                                continue;
                            };
                        };
                        self.r[d.rd] = @bitCast(@as(i32, @as(i8, @bitCast(byte_val))));
                    },
                    .ldrsh_imm_al => {
                        const vaddr = self.r[d.rn] +% imm32;
                        const half_val: u16 = if ((vaddr & ~@as(u32, 0xffe)) == data_r_vbase)
                            std.mem.readInt(u16, data_page_ptr[vaddr & 0xffe ..][0..2], .little)
                        else blk: {
                            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
                            if ((vaddr & ~@as(u32, 0xffe)) == slot.r_vbase) {
                                data_r_vbase = slot.r_vbase;
                                data_w_vbase = slot.w_vbase;
                                data_page_ptr = bus.ram.ptr + slot.pbase;
                                break :blk std.mem.readInt(u16, data_page_ptr[vaddr & 0xffe ..][0..2], .little);
                            }
                            break :blk self.read16(bus, vaddr) catch {
                                self.enterException(.abt, 0x10, pc +% 8, false);
                                priv = 1;
                                code_vbase = 0xffff_ffff;
                                data_r_vbase = 0xffff_ffff;
                                data_w_vbase = 0xffff_ffff;
                                continue;
                            };
                        };
                        self.r[d.rd] = @bitCast(@as(i32, @as(i16, @bitCast(half_val))));
                    },
                    .ldrh_reg_al => {
                        const vaddr = self.r[d.rn] +% self.r[d.rm];
                        if ((vaddr & ~@as(u32, 0xffe)) == data_r_vbase) {
                            self.r[d.rd] = std.mem.readInt(u16, data_page_ptr[vaddr & 0xffe ..][0..2], .little);
                        } else {
                            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
                            if ((vaddr & ~@as(u32, 0xffe)) == slot.r_vbase) {
                                data_r_vbase = slot.r_vbase;
                                data_w_vbase = slot.w_vbase;
                                data_page_ptr = bus.ram.ptr + slot.pbase;
                                self.r[d.rd] = std.mem.readInt(u16, data_page_ptr[vaddr & 0xffe ..][0..2], .little);
                            } else {
                                self.r[d.rd] = self.read16(bus, vaddr) catch {
                                    self.enterException(.abt, 0x10, pc +% 8, false);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff;
                                    data_r_vbase = 0xffff_ffff;
                                    data_w_vbase = 0xffff_ffff;
                                    continue;
                                };
                            }
                        }
                    },
                    .strh_reg_al => {
                        const vaddr = self.r[d.rn] +% self.r[d.rm];
                        if ((vaddr & ~@as(u32, 0xffe)) == data_w_vbase) {
                            std.mem.writeInt(u16, data_page_ptr[vaddr & 0xffe ..][0..2], @truncate(self.r[d.rd]), .little);
                        } else {
                            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
                            if ((vaddr & ~@as(u32, 0xffe)) == slot.w_vbase) {
                                data_r_vbase = slot.r_vbase;
                                data_w_vbase = slot.w_vbase;
                                data_page_ptr = bus.ram.ptr + slot.pbase;
                                std.mem.writeInt(u16, data_page_ptr[vaddr & 0xffe ..][0..2], @truncate(self.r[d.rd]), .little);
                            } else {
                                self.write16(bus, vaddr, @truncate(self.r[d.rd])) catch {
                                    self.enterException(.abt, 0x10, pc +% 8, false);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff;
                                    data_r_vbase = 0xffff_ffff;
                                    data_w_vbase = 0xffff_ffff;
                                    continue;
                                };
                                if ((vaddr & 0xffff_f000) != self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask].w_vbase) {
                                    if (self.checkInterrupts(bus)) {
                                        priv = 1;
                                        code_vbase = 0xffff_ffff;
                                        data_r_vbase = 0xffff_ffff;
                                        data_w_vbase = 0xffff_ffff;
                                    }
                                }
                            }
                        }
                    },
                    .ldrsb_reg_al => {
                        const vaddr = self.r[d.rn] +% self.r[d.rm];
                        const byte_val: u8 = if ((vaddr & 0xffff_f000) == data_r_vbase)
                            data_page_ptr[vaddr & 0xfff]
                        else blk: {
                            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
                            if ((vaddr & 0xffff_f000) == slot.r_vbase) {
                                data_r_vbase = slot.r_vbase;
                                data_w_vbase = slot.w_vbase;
                                data_page_ptr = bus.ram.ptr + slot.pbase;
                                break :blk data_page_ptr[vaddr & 0xfff];
                            }
                            break :blk self.read8(bus, vaddr) catch {
                                self.enterException(.abt, 0x10, pc +% 8, false);
                                priv = 1;
                                code_vbase = 0xffff_ffff;
                                data_r_vbase = 0xffff_ffff;
                                data_w_vbase = 0xffff_ffff;
                                continue;
                            };
                        };
                        self.r[d.rd] = @bitCast(@as(i32, @as(i8, @bitCast(byte_val))));
                    },
                    .ldrsh_reg_al => {
                        const vaddr = self.r[d.rn] +% self.r[d.rm];
                        const half_val: u16 = if ((vaddr & ~@as(u32, 0xffe)) == data_r_vbase)
                            std.mem.readInt(u16, data_page_ptr[vaddr & 0xffe ..][0..2], .little)
                        else blk: {
                            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
                            if ((vaddr & ~@as(u32, 0xffe)) == slot.r_vbase) {
                                data_r_vbase = slot.r_vbase;
                                data_w_vbase = slot.w_vbase;
                                data_page_ptr = bus.ram.ptr + slot.pbase;
                                break :blk std.mem.readInt(u16, data_page_ptr[vaddr & 0xffe ..][0..2], .little);
                            }
                            break :blk self.read16(bus, vaddr) catch {
                                self.enterException(.abt, 0x10, pc +% 8, false);
                                priv = 1;
                                code_vbase = 0xffff_ffff;
                                data_r_vbase = 0xffff_ffff;
                                data_w_vbase = 0xffff_ffff;
                                continue;
                            };
                        };
                        self.r[d.rd] = @bitCast(@as(i32, @as(i16, @bitCast(half_val))));
                    },
                    .ldrd_imm_al => {
                        const vaddr = self.r[d.rn] +% imm32;
                        const pair: u64 = if ((vaddr & 0xfff) <= 0xff8 and (vaddr & ~@as(u32, 0xffc)) == data_r_vbase)
                            std.mem.readInt(u64, data_page_ptr[vaddr & 0xffc ..][0..8], .little)
                        else blk: {
                            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
                            if ((vaddr & 0xfff) <= 0xff8 and (vaddr & ~@as(u32, 0xffc)) == slot.r_vbase) {
                                data_r_vbase = slot.r_vbase;
                                data_w_vbase = slot.w_vbase;
                                data_page_ptr = bus.ram.ptr + slot.pbase;
                                break :blk std.mem.readInt(u64, data_page_ptr[vaddr & 0xffc ..][0..8], .little);
                            }
                            break :blk self.read64(bus, vaddr) catch {
                                self.enterException(.abt, 0x10, pc +% 8, false);
                                priv = 1;
                                code_vbase = 0xffff_ffff;
                                data_r_vbase = 0xffff_ffff;
                                data_w_vbase = 0xffff_ffff;
                                continue;
                            };
                        };
                        self.r[d.rd] = @truncate(pair);
                        self.r[d.rd + 1] = @truncate(pair >> 32);
                    },
                    .strd_imm_al => {
                        const vaddr = self.r[d.rn] +% imm32;
                        const val: u64 = @as(u64, self.r[d.rd]) | (@as(u64, self.r[d.rd + 1]) << 32);
                        if ((vaddr & 0xfff) <= 0xff8 and (vaddr & ~@as(u32, 0xffc)) == data_w_vbase) {
                            std.mem.writeInt(u64, data_page_ptr[vaddr & 0xffc ..][0..8], val, .little);
                        } else {
                            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
                            if ((vaddr & 0xfff) <= 0xff8 and (vaddr & ~@as(u32, 0xffc)) == slot.w_vbase) {
                                data_r_vbase = slot.r_vbase;
                                data_w_vbase = slot.w_vbase;
                                data_page_ptr = bus.ram.ptr + slot.pbase;
                                std.mem.writeInt(u64, data_page_ptr[vaddr & 0xffc ..][0..8], val, .little);
                            } else {
                                self.write64(bus, vaddr, val) catch {
                                    self.enterException(.abt, 0x10, pc +% 8, false);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff;
                                    data_r_vbase = 0xffff_ffff;
                                    data_w_vbase = 0xffff_ffff;
                                    continue;
                                };
                                if ((vaddr & 0xffff_f000) != self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask].w_vbase) {
                                    if (self.checkInterrupts(bus)) {
                                        priv = 1;
                                        code_vbase = 0xffff_ffff;
                                        data_r_vbase = 0xffff_ffff;
                                        data_w_vbase = 0xffff_ffff;
                                    }
                                }
                            }
                        }
                    },
                    .ldr_wb_al => {
                        const base_val = self.r[d.rn];
                        const vaddr = base_val +% imm32;
                        const wb_off: u32 = @truncate(d.imm >> 32);
                        const val: u32 = if ((vaddr & ~@as(u32, 0xffc)) == data_r_vbase)
                            std.mem.readInt(u32, data_page_ptr[vaddr & 0xffc ..][0..4], .little)
                        else blk: {
                            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
                            if ((vaddr & ~@as(u32, 0xffc)) == slot.r_vbase) {
                                data_r_vbase = slot.r_vbase;
                                data_w_vbase = slot.w_vbase;
                                data_page_ptr = bus.ram.ptr + slot.pbase;
                                break :blk std.mem.readInt(u32, data_page_ptr[vaddr & 0xffc ..][0..4], .little);
                            }
                            break :blk self.read32(bus, vaddr) catch {
                                self.enterException(.abt, 0x10, pc +% 8, false);
                                priv = 1;
                                code_vbase = 0xffff_ffff;
                                data_r_vbase = 0xffff_ffff;
                                data_w_vbase = 0xffff_ffff;
                                continue;
                            };
                        };
                        self.r[d.rn] = base_val +% wb_off;
                        if (d.rd == 15) {
                            self.setPcWithInterworking(val);
                        } else {
                            self.r[d.rd] = val;
                        }
                    },
                    .str_wb_al => {
                        const base_val = self.r[d.rn];
                        const vaddr = base_val +% imm32;
                        const wb_off: u32 = @truncate(d.imm >> 32);
                        if ((vaddr & ~@as(u32, 0xffc)) == data_w_vbase) {
                            std.mem.writeInt(u32, data_page_ptr[vaddr & 0xffc ..][0..4], self.r[d.rd], .little);
                            self.r[d.rn] = base_val +% wb_off;
                        } else {
                            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
                            if ((vaddr & ~@as(u32, 0xffc)) == slot.w_vbase) {
                                data_r_vbase = slot.r_vbase;
                                data_w_vbase = slot.w_vbase;
                                data_page_ptr = bus.ram.ptr + slot.pbase;
                                std.mem.writeInt(u32, data_page_ptr[vaddr & 0xffc ..][0..4], self.r[d.rd], .little);
                                self.r[d.rn] = base_val +% wb_off;
                            } else {
                                self.write32(bus, vaddr, self.r[d.rd]) catch {
                                    self.enterException(.abt, 0x10, pc +% 8, false);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff;
                                    data_r_vbase = 0xffff_ffff;
                                    data_w_vbase = 0xffff_ffff;
                                    continue;
                                };
                                self.r[d.rn] = base_val +% wb_off;
                                if ((vaddr & 0xffff_f000) != self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask].w_vbase) {
                                    if (self.checkInterrupts(bus)) {
                                        priv = 1;
                                        code_vbase = 0xffff_ffff;
                                        data_r_vbase = 0xffff_ffff;
                                        data_w_vbase = 0xffff_ffff;
                                    }
                                }
                            }
                        }
                    },
                    .ldrb_wb_al => {
                        const base_val = self.r[d.rn];
                        const vaddr = base_val +% imm32;
                        const wb_off: u32 = @truncate(d.imm >> 32);
                        if ((vaddr & 0xffff_f000) == data_r_vbase) {
                            self.r[d.rd] = data_page_ptr[vaddr & 0xfff];
                        } else {
                            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
                            if ((vaddr & 0xffff_f000) == slot.r_vbase) {
                                data_r_vbase = slot.r_vbase;
                                data_w_vbase = slot.w_vbase;
                                data_page_ptr = bus.ram.ptr + slot.pbase;
                                self.r[d.rd] = data_page_ptr[vaddr & 0xfff];
                            } else {
                                self.r[d.rd] = self.read8(bus, vaddr) catch {
                                    self.enterException(.abt, 0x10, pc +% 8, false);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff;
                                    data_r_vbase = 0xffff_ffff;
                                    data_w_vbase = 0xffff_ffff;
                                    continue;
                                };
                            }
                        }
                        self.r[d.rn] = base_val +% wb_off;
                    },
                    .strb_wb_al => {
                        const base_val = self.r[d.rn];
                        const vaddr = base_val +% imm32;
                        const wb_off: u32 = @truncate(d.imm >> 32);
                        if ((vaddr & 0xffff_f000) == data_w_vbase) {
                            data_page_ptr[vaddr & 0xfff] = @truncate(self.r[d.rd]);
                            self.r[d.rn] = base_val +% wb_off;
                        } else {
                            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
                            if ((vaddr & 0xffff_f000) == slot.w_vbase) {
                                data_r_vbase = slot.r_vbase;
                                data_w_vbase = slot.w_vbase;
                                data_page_ptr = bus.ram.ptr + slot.pbase;
                                data_page_ptr[vaddr & 0xfff] = @truncate(self.r[d.rd]);
                                self.r[d.rn] = base_val +% wb_off;
                            } else {
                                self.write8(bus, vaddr, @truncate(self.r[d.rd])) catch {
                                    self.enterException(.abt, 0x10, pc +% 8, false);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff;
                                    data_r_vbase = 0xffff_ffff;
                                    data_w_vbase = 0xffff_ffff;
                                    continue;
                                };
                                self.r[d.rn] = base_val +% wb_off;
                                if ((vaddr & 0xffff_f000) != self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask].w_vbase) {
                                    if (self.checkInterrupts(bus)) {
                                        priv = 1;
                                        code_vbase = 0xffff_ffff;
                                        data_r_vbase = 0xffff_ffff;
                                        data_w_vbase = 0xffff_ffff;
                                    }
                                }
                            }
                        }
                    },
                    .ldr_reg_lsl_al, .ldr_reg_sub_lsl_al, .ldr_reg_lsr_al => {
                        const scaled = if (op == .ldr_reg_lsr_al)
                            (self.r[d.rm] >> @as(u5, @truncate(imm32)))
                        else
                            (self.r[d.rm] << @as(u5, @truncate(imm32)));
                        const vaddr = if (op == .ldr_reg_sub_lsl_al) (self.r[d.rn] -% scaled) else (self.r[d.rn] +% scaled);
                        if ((vaddr & ~@as(u32, 0xffc)) == data_r_vbase) {
                            self.r[d.rd] = std.mem.readInt(u32, data_page_ptr[vaddr & 0xffc ..][0..4], .little);
                        } else {
                            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
                            if ((vaddr & ~@as(u32, 0xffc)) == slot.r_vbase) {
                                data_r_vbase = slot.r_vbase;
                                data_w_vbase = slot.w_vbase;
                                data_page_ptr = bus.ram.ptr + slot.pbase;
                                self.r[d.rd] = std.mem.readInt(u32, data_page_ptr[vaddr & 0xffc ..][0..4], .little);
                            } else {
                                self.r[d.rd] = self.read32(bus, vaddr) catch {
                                    self.enterException(.abt, 0x10, pc +% 8, false);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff;
                                    data_r_vbase = 0xffff_ffff;
                                    data_w_vbase = 0xffff_ffff;
                                    continue;
                                };
                            }
                        }
                    },
                    .str_reg_lsl_al, .str_reg_sub_lsl_al, .str_reg_lsr_al => {
                        const scaled = if (op == .str_reg_lsr_al)
                            (self.r[d.rm] >> @as(u5, @truncate(imm32)))
                        else
                            (self.r[d.rm] << @as(u5, @truncate(imm32)));
                        const vaddr = if (op == .str_reg_sub_lsl_al) (self.r[d.rn] -% scaled) else (self.r[d.rn] +% scaled);
                        if ((vaddr & ~@as(u32, 0xffc)) == data_w_vbase) {
                            std.mem.writeInt(u32, data_page_ptr[vaddr & 0xffc ..][0..4], self.r[d.rd], .little);
                        } else {
                            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
                            if ((vaddr & ~@as(u32, 0xffc)) == slot.w_vbase) {
                                data_r_vbase = slot.r_vbase;
                                data_w_vbase = slot.w_vbase;
                                data_page_ptr = bus.ram.ptr + slot.pbase;
                                std.mem.writeInt(u32, data_page_ptr[vaddr & 0xffc ..][0..4], self.r[d.rd], .little);
                            } else {
                                self.write32(bus, vaddr, self.r[d.rd]) catch {
                                    self.enterException(.abt, 0x10, pc +% 8, false);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff;
                                    data_r_vbase = 0xffff_ffff;
                                    data_w_vbase = 0xffff_ffff;
                                    continue;
                                };
                                if ((vaddr & 0xffff_f000) != self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask].w_vbase) {
                                    if (self.checkInterrupts(bus)) {
                                        priv = 1;
                                        code_vbase = 0xffff_ffff;
                                        data_r_vbase = 0xffff_ffff;
                                        data_w_vbase = 0xffff_ffff;
                                    }
                                }
                            }
                        }
                    },
                    .ldrb_reg_lsl_al, .ldrb_reg_sub_lsl_al => {
                        const scaled = self.r[d.rm] << @as(u5, @truncate(imm32));
                        const vaddr = if (op == .ldrb_reg_sub_lsl_al) (self.r[d.rn] -% scaled) else (self.r[d.rn] +% scaled);
                        if ((vaddr & 0xffff_f000) == data_r_vbase) {
                            self.r[d.rd] = data_page_ptr[vaddr & 0xfff];
                        } else {
                            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
                            if ((vaddr & 0xffff_f000) == slot.r_vbase) {
                                data_r_vbase = slot.r_vbase;
                                data_w_vbase = slot.w_vbase;
                                data_page_ptr = bus.ram.ptr + slot.pbase;
                                self.r[d.rd] = data_page_ptr[vaddr & 0xfff];
                            } else {
                                self.r[d.rd] = self.read8(bus, vaddr) catch {
                                    self.enterException(.abt, 0x10, pc +% 8, false);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff;
                                    data_r_vbase = 0xffff_ffff;
                                    data_w_vbase = 0xffff_ffff;
                                    continue;
                                };
                            }
                        }
                    },
                    .strb_reg_lsl_al, .strb_reg_sub_lsl_al => {
                        const scaled = self.r[d.rm] << @as(u5, @truncate(imm32));
                        const vaddr = if (op == .strb_reg_sub_lsl_al) (self.r[d.rn] -% scaled) else (self.r[d.rn] +% scaled);
                        if ((vaddr & 0xffff_f000) == data_w_vbase) {
                            data_page_ptr[vaddr & 0xfff] = @truncate(self.r[d.rd]);
                        } else {
                            const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
                            if ((vaddr & 0xffff_f000) == slot.w_vbase) {
                                data_r_vbase = slot.r_vbase;
                                data_w_vbase = slot.w_vbase;
                                data_page_ptr = bus.ram.ptr + slot.pbase;
                                data_page_ptr[vaddr & 0xfff] = @truncate(self.r[d.rd]);
                            } else {
                                self.write8(bus, vaddr, @truncate(self.r[d.rd])) catch {
                                    self.enterException(.abt, 0x10, pc +% 8, false);
                                    priv = 1;
                                    code_vbase = 0xffff_ffff;
                                    data_r_vbase = 0xffff_ffff;
                                    data_w_vbase = 0xffff_ffff;
                                    continue;
                                };
                                if ((vaddr & 0xffff_f000) != self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask].w_vbase) {
                                    if (self.checkInterrupts(bus)) {
                                        priv = 1;
                                        code_vbase = 0xffff_ffff;
                                        data_r_vbase = 0xffff_ffff;
                                        data_w_vbase = 0xffff_ffff;
                                    }
                                }
                            }
                        }
                    },
                    .ldm_al, .ldm_pc_al => {
                        const base_val = self.r[d.rn];
                        const start_off: i32 = @as(i16, @bitCast(@as(u16, @truncate(d.imm >> 32))));
                        const start_addr = base_val +% @as(u32, @bitCast(start_off));
                        const last_off: u32 = @as(u16, @truncate(d.imm >> 16));
                        const last_addr = start_addr +% last_off;
                        const hit_page: ?[*]u8 = if ((start_addr & ~@as(u32, 0xffc)) == data_r_vbase and
                            (last_addr & ~@as(u32, 0xffc)) == data_r_vbase)
                            data_page_ptr
                        else blk: {
                            const slot = self.mmu.soft_tlb32[priv][(start_addr >> 12) & Mmu.soft_tlb_mask];
                            if ((start_addr & ~@as(u32, 0xffc)) == slot.r_vbase and
                                (last_addr & ~@as(u32, 0xffc)) == slot.r_vbase)
                            {
                                data_r_vbase = slot.r_vbase;
                                data_w_vbase = slot.w_vbase;
                                data_page_ptr = bus.ram.ptr + slot.pbase;
                                break :blk data_page_ptr;
                            }
                            break :blk null;
                        };
                        if (hit_page) |page_ptr| {
                            var off: usize = start_addr & 0xfff;
                            if (comptime @import("builtin").cpu.arch.endian() == .little) {
                                if ((d.rm & 0x80) != 0) {
                                    const nbytes: usize = d.rm & 0x3f;
                                    if (nbytes != 0) {
                                        const r_bytes: *[64]u8 = @ptrCast(&self.r);
                                        @memcpy(r_bytes[d.rd..][0..nbytes], page_ptr[off..][0..nbytes]);
                                        off += nbytes;
                                    }
                                    if ((d.rm & 0x40) != 0) {
                                        self.r[14] = std.mem.readInt(u32, page_ptr[off..][0..4], .little);
                                        off += 4;
                                    }
                                } else {
                                    var rem: u16 = @truncate(d.imm & 0x7fff);
                                    while (rem != 0) : (rem &= rem - 1) {
                                        const i: u4 = @intCast(@ctz(rem));
                                        self.r[i] = std.mem.readInt(u32, page_ptr[off..][0..4], .little);
                                        off += 4;
                                    }
                                }
                            } else {
                                var rem: u16 = @truncate(d.imm & 0x7fff);
                                while (rem != 0) : (rem &= rem - 1) {
                                    const i: u4 = @intCast(@ctz(rem));
                                    self.r[i] = std.mem.readInt(u32, page_ptr[off..][0..4], .little);
                                    off += 4;
                                }
                            }
                            const wb_off: i32 = @as(i16, @bitCast(@as(u16, @truncate(d.imm >> 48))));
                            if (wb_off != 0) self.r[d.rn] = base_val +% @as(u32, @bitCast(wb_off));
                            if (op == .ldm_pc_al) {
                                const pc_val = std.mem.readInt(u32, page_ptr[off..][0..4], .little);
                                self.setPcWithInterworking(pc_val);
                            }
                        } else {
                            self.executeLoadStoreMultiple(bus, pc, inst);
                            priv = @intFromBool(self.isPrivileged());
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                        }
                    },
                    .stm_al => {
                        const base_val = self.r[d.rn];
                        const start_off: i32 = @as(i16, @bitCast(@as(u16, @truncate(d.imm >> 32))));
                        const start_addr = base_val +% @as(u32, @bitCast(start_off));
                        const last_off: u32 = @as(u16, @truncate(d.imm >> 16));
                        const last_addr = start_addr +% last_off;
                        const hit_page: ?[*]u8 = if ((start_addr & ~@as(u32, 0xffc)) == data_w_vbase and
                            (last_addr & ~@as(u32, 0xffc)) == data_w_vbase)
                            data_page_ptr
                        else blk: {
                            const slot = self.mmu.soft_tlb32[priv][(start_addr >> 12) & Mmu.soft_tlb_mask];
                            if ((start_addr & ~@as(u32, 0xffc)) == slot.w_vbase and
                                (last_addr & ~@as(u32, 0xffc)) == slot.w_vbase)
                            {
                                data_r_vbase = slot.r_vbase;
                                data_w_vbase = slot.w_vbase;
                                data_page_ptr = bus.ram.ptr + slot.pbase;
                                break :blk data_page_ptr;
                            }
                            break :blk null;
                        };
                        if (hit_page) |page_ptr| {
                            var off: usize = start_addr & 0xfff;
                            if (comptime @import("builtin").cpu.arch.endian() == .little) {
                                if ((d.rm & 0x80) != 0) {
                                    const nbytes: usize = d.rm & 0x3f;
                                    if (nbytes != 0) {
                                        const r_bytes: *const [64]u8 = @ptrCast(&self.r);
                                        @memcpy(page_ptr[off..][0..nbytes], r_bytes[d.rd..][0..nbytes]);
                                        off += nbytes;
                                    }
                                    if ((d.rm & 0x40) != 0) {
                                        std.mem.writeInt(u32, page_ptr[off..][0..4], self.r[14], .little);
                                    }
                                } else {
                                    var rem: u16 = @truncate(d.imm);
                                    while (rem != 0) : (rem &= rem - 1) {
                                        const i: u4 = @intCast(@ctz(rem));
                                        const val = if (i == 15) (pc +% 8) else self.r[i];
                                        std.mem.writeInt(u32, page_ptr[off..][0..4], val, .little);
                                        off += 4;
                                    }
                                }
                            } else {
                                var rem: u16 = @truncate(d.imm);
                                while (rem != 0) : (rem &= rem - 1) {
                                    const i: u4 = @intCast(@ctz(rem));
                                    const val = if (i == 15) (pc +% 8) else self.r[i];
                                    std.mem.writeInt(u32, page_ptr[off..][0..4], val, .little);
                                    off += 4;
                                }
                            }
                            const wb_off: i32 = @as(i16, @bitCast(@as(u16, @truncate(d.imm >> 48))));
                            if (wb_off != 0) self.r[d.rn] = base_val +% @as(u32, @bitCast(wb_off));
                        } else {
                            self.executeLoadStoreMultiple(bus, pc, inst);
                            if ((last_addr & 0xffff_f000) != self.mmu.soft_tlb32[priv][(last_addr >> 12) & Mmu.soft_tlb_mask].w_vbase) {
                                _ = self.checkInterrupts(bus);
                            }
                            priv = @intFromBool(self.isPrivileged());
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                        }
                    },
                    .b_al => {
                        const shift_imm: i32 = @bitCast(imm32);
                        if (shift_imm >= -28 and shift_imm < 0) {
                            if (self.last_dmb_pc == pc) {
                                self.yield_slice = true;
                            } else if ((pc & 0xfff) < 0xffc and (pc & 0xffff_f000) == code_vbase) {
                                const next_paddr = code_pbase | ((pc +% 4) & 0xfff);
                                const next_inst = std.mem.readInt(u32, bus.ram[next_paddr..][0..4], .little);
                                if ((next_inst & 0x0fff_ffe0) == 0x057f_f040) {
                                    self.last_dmb_pc = pc;
                                }
                            }
                        }
                        self.r[15] = (pc +% 8) +% imm32;
                        if (self.yield_slice) break;
                    },
                    .bl_al => {
                        const target_pc = (pc +% 8) +% imm32;
                        self.r[14] = pc +% 4;
                        if (inst >= 0xe000_0000) {
                            if (self.last_dmb_pc == pc) {
                                self.yield_slice = true;
                            } else {
                                const tslot = self.mmu.soft_tlb32[priv][(target_pc >> 12) & Mmu.soft_tlb_mask];
                                if ((target_pc & 0xffff_f000) == tslot.x_vbase) {
                                    const target_paddr = tslot.pbase | (target_pc & 0xfff);
                                    const target_inst = std.mem.readInt(u32, bus.ram[target_paddr..][0..4], .little);
                                    if (target_inst == 0xe12fff1e) {
                                        self.last_dmb_pc = pc;
                                    }
                                }
                            }
                        }
                        self.r[15] = target_pc;
                        if (self.yield_slice) break;
                    },
                    .bx_lr_al => {
                        self.setPcWithInterworking(self.r[14]);
                    },
                    .bx_reg_al => {
                        self.setPcWithInterworking(self.r[d.rm]);
                    },
                    .blx_reg_al => {
                        const target = self.r[d.rm];
                        self.r[14] = pc +% 4;
                        self.setPcWithInterworking(target);
                    },
                    .dp_imm_general => {
                        self.executeGroup001(pc, inst);
                        if (self.mmu.halted_wfi or self.yield_slice) break;
                        _ = self.checkInterrupts(bus);
                        priv = @intFromBool(self.isPrivileged());
                        code_vbase = 0xffff_ffff;
                        data_r_vbase = 0xffff_ffff;
                        data_w_vbase = 0xffff_ffff;
                    },
                    .dp_reg_general => {
                        self.executeGroup000(bus, pc, inst);
                        if (self.mmu.halted_wfi or self.yield_slice) break;
                        _ = self.checkInterrupts(bus);
                        priv = @intFromBool(self.isPrivileged());
                        code_vbase = 0xffff_ffff;
                        data_r_vbase = 0xffff_ffff;
                        data_w_vbase = 0xffff_ffff;
                    },
                    .misc_000 => {
                        self.executeMisc000(pc, inst);
                        _ = self.checkInterrupts(bus);
                        priv = @intFromBool(self.isPrivileged());
                        code_vbase = 0xffff_ffff;
                        data_r_vbase = 0xffff_ffff;
                        data_w_vbase = 0xffff_ffff;
                    },
                    .mul_extra_ls => {
                        self.executeMultipliesAndExtraLoadStore(bus, pc, inst);
                        _ = self.checkInterrupts(bus);
                        priv = @intFromBool(self.isPrivileged());
                        code_vbase = 0xffff_ffff;
                        data_r_vbase = 0xffff_ffff;
                        data_w_vbase = 0xffff_ffff;
                    },
                    .ls_wb_imm => {
                        self.executeLoadStoreWordByte(bus, pc, inst, false);
                        _ = self.checkInterrupts(bus);
                        priv = @intFromBool(self.isPrivileged());
                        code_vbase = 0xffff_ffff;
                        data_r_vbase = 0xffff_ffff;
                        data_w_vbase = 0xffff_ffff;
                    },
                    .ls_wb_reg => {
                        self.executeLoadStoreWordByte(bus, pc, inst, true);
                        _ = self.checkInterrupts(bus);
                        priv = @intFromBool(self.isPrivileged());
                        code_vbase = 0xffff_ffff;
                        data_r_vbase = 0xffff_ffff;
                        data_w_vbase = 0xffff_ffff;
                    },
                    .ls_multiple => {
                        self.executeLoadStoreMultiple(bus, pc, inst);
                        _ = self.checkInterrupts(bus);
                        priv = @intFromBool(self.isPrivileged());
                        code_vbase = 0xffff_ffff;
                        data_r_vbase = 0xffff_ffff;
                        data_w_vbase = 0xffff_ffff;
                    },
                    .media => {
                        self.executeMediaGroup(pc, inst);
                    },
                    .coproc_svc => {
                        self.executeCoprocOrSvc(bus, pc, inst);
                        if (self.mmu.halted_wfi or self.yield_slice) break;
                        _ = self.checkInterrupts(bus);
                        priv = @intFromBool(self.isPrivileged());
                        code_vbase = 0xffff_ffff;
                        data_r_vbase = 0xffff_ffff;
                        data_w_vbase = 0xffff_ffff;
                    },
                    .vldr_f64_al => {
                        if (self.vfpReady(priv)) {
                            const base = if (d.rn == 15) (pc +% 8) else self.r[d.rn];
                            const vaddr = base +% imm32;
                            if ((vaddr & 0xfff) <= 0xff8 and (vaddr & 0xffff_f000) == data_r_vbase) {
                                const off: usize = vaddr & 0xfff;
                                self.vfp.s[d.rd] = std.mem.readInt(u32, data_page_ptr[off..][0..4], .little);
                                self.vfp.s[d.rd + 1] = std.mem.readInt(u32, data_page_ptr[off + 4 ..][0..4], .little);
                            } else if ((vaddr & 0xfff) <= 0xff8 and (vaddr & 0xffff_f000) == code_vbase) {
                                const off: usize = vaddr & 0xfff;
                                self.vfp.s[d.rd] = std.mem.readInt(u32, code_page_ptr[off..][0..4], .little);
                                self.vfp.s[d.rd + 1] = std.mem.readInt(u32, code_page_ptr[off + 4 ..][0..4], .little);
                            } else {
                                const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
                                if ((vaddr & 0xfff) <= 0xff8 and (vaddr & 0xffff_f000) == slot.r_vbase) {
                                    data_r_vbase = slot.r_vbase;
                                    data_w_vbase = slot.w_vbase;
                                    data_page_ptr = bus.ram.ptr + slot.pbase;
                                    const off: usize = vaddr & 0xfff;
                                    self.vfp.s[d.rd] = std.mem.readInt(u32, data_page_ptr[off..][0..4], .little);
                                    self.vfp.s[d.rd + 1] = std.mem.readInt(u32, data_page_ptr[off + 4 ..][0..4], .little);
                                } else {
                                    self.executeVfp(bus, pc, inst, true);
                                    priv = @intFromBool(self.isPrivileged());
                                    data_r_vbase = 0xffff_ffff;
                                    data_w_vbase = 0xffff_ffff;
                                }
                            }
                        } else {
                            self.executeVfp(bus, pc, inst, true);
                            priv = @intFromBool(self.isPrivileged());
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                        }
                    },
                    .vstr_f64_al => {
                        if (self.vfpReady(priv)) {
                            const base = if (d.rn == 15) (pc +% 8) else self.r[d.rn];
                            const vaddr = base +% imm32;
                            if ((vaddr & 0xfff) <= 0xff8 and (vaddr & 0xffff_f000) == data_w_vbase) {
                                const off: usize = vaddr & 0xfff;
                                std.mem.writeInt(u32, data_page_ptr[off..][0..4], self.vfp.s[d.rd], .little);
                                std.mem.writeInt(u32, data_page_ptr[off + 4 ..][0..4], self.vfp.s[d.rd + 1], .little);
                            } else {
                                const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
                                if ((vaddr & 0xfff) <= 0xff8 and (vaddr & 0xffff_f000) == slot.w_vbase) {
                                    data_r_vbase = slot.r_vbase;
                                    data_w_vbase = slot.w_vbase;
                                    data_page_ptr = bus.ram.ptr + slot.pbase;
                                    const off: usize = vaddr & 0xfff;
                                    std.mem.writeInt(u32, data_page_ptr[off..][0..4], self.vfp.s[d.rd], .little);
                                    std.mem.writeInt(u32, data_page_ptr[off + 4 ..][0..4], self.vfp.s[d.rd + 1], .little);
                                } else {
                                    self.executeVfp(bus, pc, inst, true);
                                    _ = self.checkInterrupts(bus);
                                    priv = @intFromBool(self.isPrivileged());
                                    data_r_vbase = 0xffff_ffff;
                                    data_w_vbase = 0xffff_ffff;
                                }
                            }
                        } else {
                            self.executeVfp(bus, pc, inst, true);
                            priv = @intFromBool(self.isPrivileged());
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                        }
                    },
                    .vldr_f32_al => {
                        if (self.vfpReady(priv)) {
                            const base = if (d.rn == 15) (pc +% 8) else self.r[d.rn];
                            const vaddr = base +% imm32;
                            if ((vaddr & 0xfff) <= 0xffc and (vaddr & 0xffff_f000) == data_r_vbase) {
                                self.vfp.s[d.rd] = std.mem.readInt(u32, data_page_ptr[vaddr & 0xfff ..][0..4], .little);
                            } else if ((vaddr & 0xfff) <= 0xffc and (vaddr & 0xffff_f000) == code_vbase) {
                                self.vfp.s[d.rd] = std.mem.readInt(u32, code_page_ptr[vaddr & 0xfff ..][0..4], .little);
                            } else {
                                const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
                                if ((vaddr & 0xfff) <= 0xffc and (vaddr & 0xffff_f000) == slot.r_vbase) {
                                    data_r_vbase = slot.r_vbase;
                                    data_w_vbase = slot.w_vbase;
                                    data_page_ptr = bus.ram.ptr + slot.pbase;
                                    self.vfp.s[d.rd] = std.mem.readInt(u32, data_page_ptr[vaddr & 0xfff ..][0..4], .little);
                                } else {
                                    self.executeVfp(bus, pc, inst, false);
                                    priv = @intFromBool(self.isPrivileged());
                                    data_r_vbase = 0xffff_ffff;
                                    data_w_vbase = 0xffff_ffff;
                                }
                            }
                        } else {
                            self.executeVfp(bus, pc, inst, false);
                            priv = @intFromBool(self.isPrivileged());
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                        }
                    },
                    .vstr_f32_al => {
                        if (self.vfpReady(priv)) {
                            const base = if (d.rn == 15) (pc +% 8) else self.r[d.rn];
                            const vaddr = base +% imm32;
                            if ((vaddr & 0xfff) <= 0xffc and (vaddr & 0xffff_f000) == data_w_vbase) {
                                std.mem.writeInt(u32, data_page_ptr[vaddr & 0xfff ..][0..4], self.vfp.s[d.rd], .little);
                            } else {
                                const slot = self.mmu.soft_tlb32[priv][(vaddr >> 12) & Mmu.soft_tlb_mask];
                                if ((vaddr & 0xfff) <= 0xffc and (vaddr & 0xffff_f000) == slot.w_vbase) {
                                    data_r_vbase = slot.r_vbase;
                                    data_w_vbase = slot.w_vbase;
                                    data_page_ptr = bus.ram.ptr + slot.pbase;
                                    std.mem.writeInt(u32, data_page_ptr[vaddr & 0xfff ..][0..4], self.vfp.s[d.rd], .little);
                                } else {
                                    self.executeVfp(bus, pc, inst, false);
                                    _ = self.checkInterrupts(bus);
                                    priv = @intFromBool(self.isPrivileged());
                                    data_r_vbase = 0xffff_ffff;
                                    data_w_vbase = 0xffff_ffff;
                                }
                            }
                        } else {
                            self.executeVfp(bus, pc, inst, false);
                            priv = @intFromBool(self.isPrivileged());
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                        }
                    },
                    .vmov_r_f64_al => {
                        if (self.vfpReady(priv)) {
                            self.r[d.rd] = self.vfp.s[d.rm];
                            self.r[d.rn] = self.vfp.s[d.rm + 1];
                        } else {
                            self.executeVfp(bus, pc, inst, true);
                            priv = @intFromBool(self.isPrivileged());
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                        }
                    },
                    .vmov_f64_r_al => {
                        if (self.vfpReady(priv)) {
                            self.vfp.s[d.rm] = self.r[d.rd];
                            self.vfp.s[d.rm + 1] = self.r[d.rn];
                        } else {
                            self.executeVfp(bus, pc, inst, true);
                            priv = @intFromBool(self.isPrivileged());
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                        }
                    },
                    .vmov_r_f32_al => {
                        if (self.vfpReady(priv)) {
                            self.r[d.rd] = self.vfp.s[d.rn];
                        } else {
                            self.executeVfp(bus, pc, inst, false);
                            priv = @intFromBool(self.isPrivileged());
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                        }
                    },
                    .vmov_f32_r_al => {
                        if (self.vfpReady(priv)) {
                            self.vfp.s[d.rn] = self.r[d.rd];
                        } else {
                            self.executeVfp(bus, pc, inst, false);
                            priv = @intFromBool(self.isPrivileged());
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                        }
                    },
                    .vmrs_apsr_al => {
                        if (self.vfpReady(priv)) {
                            self.cpsr = (self.cpsr & 0x0fff_ffff) | (self.vfp.fpscr & 0xf000_0000);
                        } else {
                            self.executeVfp(bus, pc, inst, false);
                            priv = @intFromBool(self.isPrivileged());
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                        }
                    },
                    .vadd_f64_al => {
                        if (self.vfpReady(priv)) {
                            self.vfp.setD(@truncate(d.rd), self.vfp.getD(@truncate(d.rn)) + self.vfp.getD(@truncate(d.rm)));
                        } else {
                            self.executeVfp(bus, pc, inst, true);
                            priv = @intFromBool(self.isPrivileged());
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                        }
                    },
                    .vsub_f64_al => {
                        if (self.vfpReady(priv)) {
                            self.vfp.setD(@truncate(d.rd), self.vfp.getD(@truncate(d.rn)) - self.vfp.getD(@truncate(d.rm)));
                        } else {
                            self.executeVfp(bus, pc, inst, true);
                            priv = @intFromBool(self.isPrivileged());
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                        }
                    },
                    .vmul_f64_al => {
                        if (self.vfpReady(priv)) {
                            self.vfp.setD(@truncate(d.rd), self.vfp.getD(@truncate(d.rn)) * self.vfp.getD(@truncate(d.rm)));
                        } else {
                            self.executeVfp(bus, pc, inst, true);
                            priv = @intFromBool(self.isPrivileged());
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                        }
                    },
                    .vdiv_f64_al => {
                        if (self.vfpReady(priv)) {
                            self.vfp.setD(@truncate(d.rd), self.vfp.getD(@truncate(d.rn)) / self.vfp.getD(@truncate(d.rm)));
                        } else {
                            self.executeVfp(bus, pc, inst, true);
                            priv = @intFromBool(self.isPrivileged());
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                        }
                    },
                    .vmla_f64_al => {
                        if (self.vfpReady(priv)) {
                            self.vfp.setD(@truncate(d.rd), self.vfp.getD(@truncate(d.rd)) + (self.vfp.getD(@truncate(d.rn)) * self.vfp.getD(@truncate(d.rm))));
                        } else {
                            self.executeVfp(bus, pc, inst, true);
                            priv = @intFromBool(self.isPrivileged());
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                        }
                    },
                    .vmls_f64_al => {
                        if (self.vfpReady(priv)) {
                            self.vfp.setD(@truncate(d.rd), self.vfp.getD(@truncate(d.rd)) - (self.vfp.getD(@truncate(d.rn)) * self.vfp.getD(@truncate(d.rm))));
                        } else {
                            self.executeVfp(bus, pc, inst, true);
                            priv = @intFromBool(self.isPrivileged());
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                        }
                    },
                    .vmov_f64_al => {
                        if (self.vfpReady(priv)) {
                            self.vfp.setDU64(@truncate(d.rd), self.vfp.getDU64(@truncate(d.rm)));
                        } else {
                            self.executeVfp(bus, pc, inst, true);
                            priv = @intFromBool(self.isPrivileged());
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                        }
                    },
                    .vcmp_f64_al => {
                        if (self.vfpReady(priv)) {
                            self.vfp.updateCmpFlags(f64, self.vfp.getD(@truncate(d.rd)), self.vfp.getD(@truncate(d.rm)));
                        } else {
                            self.executeVfp(bus, pc, inst, true);
                            priv = @intFromBool(self.isPrivileged());
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                        }
                    },
                    .vcmpz_f64_al => {
                        if (self.vfpReady(priv)) {
                            self.vfp.updateCmpFlags(f64, self.vfp.getD(@truncate(d.rd)), 0.0);
                        } else {
                            self.executeVfp(bus, pc, inst, true);
                            priv = @intFromBool(self.isPrivileged());
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                        }
                    },
                    .vadd_f32_al => {
                        if (self.vfpReady(priv)) {
                            self.vfp.setS(@truncate(d.rd), self.vfp.getS(@truncate(d.rn)) + self.vfp.getS(@truncate(d.rm)));
                        } else {
                            self.executeVfp(bus, pc, inst, false);
                            priv = @intFromBool(self.isPrivileged());
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                        }
                    },
                    .vsub_f32_al => {
                        if (self.vfpReady(priv)) {
                            self.vfp.setS(@truncate(d.rd), self.vfp.getS(@truncate(d.rn)) - self.vfp.getS(@truncate(d.rm)));
                        } else {
                            self.executeVfp(bus, pc, inst, false);
                            priv = @intFromBool(self.isPrivileged());
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                        }
                    },
                    .vmul_f32_al => {
                        if (self.vfpReady(priv)) {
                            self.vfp.setS(@truncate(d.rd), self.vfp.getS(@truncate(d.rn)) * self.vfp.getS(@truncate(d.rm)));
                        } else {
                            self.executeVfp(bus, pc, inst, false);
                            priv = @intFromBool(self.isPrivileged());
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                        }
                    },
                    .vdiv_f32_al => {
                        if (self.vfpReady(priv)) {
                            self.vfp.setS(@truncate(d.rd), self.vfp.getS(@truncate(d.rn)) / self.vfp.getS(@truncate(d.rm)));
                        } else {
                            self.executeVfp(bus, pc, inst, false);
                            priv = @intFromBool(self.isPrivileged());
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                        }
                    },
                    .vmla_f32_al => {
                        if (self.vfpReady(priv)) {
                            self.vfp.setS(@truncate(d.rd), self.vfp.getS(@truncate(d.rd)) + (self.vfp.getS(@truncate(d.rn)) * self.vfp.getS(@truncate(d.rm))));
                        } else {
                            self.executeVfp(bus, pc, inst, false);
                            priv = @intFromBool(self.isPrivileged());
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                        }
                    },
                    .vmls_f32_al => {
                        if (self.vfpReady(priv)) {
                            self.vfp.setS(@truncate(d.rd), self.vfp.getS(@truncate(d.rd)) - (self.vfp.getS(@truncate(d.rn)) * self.vfp.getS(@truncate(d.rm))));
                        } else {
                            self.executeVfp(bus, pc, inst, false);
                            priv = @intFromBool(self.isPrivileged());
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                        }
                    },
                    .vmov_f32_al => {
                        if (self.vfpReady(priv)) {
                            self.vfp.s[d.rd] = self.vfp.s[d.rm];
                        } else {
                            self.executeVfp(bus, pc, inst, false);
                            priv = @intFromBool(self.isPrivileged());
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                        }
                    },
                    .vfp_dp_al => {
                        if (self.vfpReady(priv)) {
                            self.vfp.executeDataProc(inst);
                        } else {
                            self.executeVfp(bus, pc, inst, ((inst >> 8) & 0xf) == 11);
                            priv = @intFromBool(self.isPrivileged());
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                        }
                    },
                    .vldm_al => {
                        if (self.vfpReady(priv)) {
                            const base_val = self.r[d.rn];
                            const start_off: i32 = @as(i16, @bitCast(@as(u16, @truncate(d.imm >> 32))));
                            const start_addr = base_val +% @as(u32, @bitCast(start_off));
                            const last_off: u32 = @as(u16, @truncate(d.imm >> 16));
                            const last_addr = start_addr +% last_off;
                            const hit_page: ?[*]u8 = if ((start_addr & ~@as(u32, 0xffc)) == data_r_vbase and
                                (last_addr & ~@as(u32, 0xffc)) == data_r_vbase)
                                data_page_ptr
                            else blk: {
                                const slot = self.mmu.soft_tlb32[priv][(start_addr >> 12) & Mmu.soft_tlb_mask];
                                if ((start_addr & ~@as(u32, 0xffc)) == slot.r_vbase and
                                    (last_addr & ~@as(u32, 0xffc)) == slot.r_vbase)
                                {
                                    data_r_vbase = slot.r_vbase;
                                    data_w_vbase = slot.w_vbase;
                                    data_page_ptr = bus.ram.ptr + slot.pbase;
                                    break :blk data_page_ptr;
                                }
                                break :blk null;
                            };
                            if (hit_page) |page_ptr| {
                                const off: usize = start_addr & 0xfff;
                                const nbytes: usize = @as(u16, @truncate(d.imm));
                                if (comptime @import("builtin").cpu.arch.endian() == .little) {
                                    const s_bytes: *[256]u8 = @ptrCast(&self.vfp.s);
                                    @memcpy(s_bytes[@as(usize, d.rd) * 4 ..][0..nbytes], page_ptr[off..][0..nbytes]);
                                } else {
                                    var p = off;
                                    for (self.vfp.s[d.rd..][0 .. nbytes / 4]) |*s_reg| {
                                        s_reg.* = std.mem.readInt(u32, page_ptr[p..][0..4], .little);
                                        p += 4;
                                    }
                                }
                                const wb_off: i32 = @as(i16, @bitCast(@as(u16, @truncate(d.imm >> 48))));
                                if (wb_off != 0) self.r[d.rn] = base_val +% @as(u32, @bitCast(wb_off));
                            } else {
                                self.executeVfp(bus, pc, inst, d.rm != 0);
                                priv = @intFromBool(self.isPrivileged());
                                data_r_vbase = 0xffff_ffff;
                                data_w_vbase = 0xffff_ffff;
                            }
                        } else {
                            self.executeVfp(bus, pc, inst, d.rm != 0);
                            priv = @intFromBool(self.isPrivileged());
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                        }
                    },
                    .vstm_al => {
                        if (self.vfpReady(priv)) {
                            const base_val = self.r[d.rn];
                            const start_off: i32 = @as(i16, @bitCast(@as(u16, @truncate(d.imm >> 32))));
                            const start_addr = base_val +% @as(u32, @bitCast(start_off));
                            const last_off: u32 = @as(u16, @truncate(d.imm >> 16));
                            const last_addr = start_addr +% last_off;
                            const hit_page: ?[*]u8 = if ((start_addr & ~@as(u32, 0xffc)) == data_w_vbase and
                                (last_addr & ~@as(u32, 0xffc)) == data_w_vbase)
                                data_page_ptr
                            else blk: {
                                const slot = self.mmu.soft_tlb32[priv][(start_addr >> 12) & Mmu.soft_tlb_mask];
                                if ((start_addr & ~@as(u32, 0xffc)) == slot.w_vbase and
                                    (last_addr & ~@as(u32, 0xffc)) == slot.w_vbase)
                                {
                                    data_r_vbase = slot.r_vbase;
                                    data_w_vbase = slot.w_vbase;
                                    data_page_ptr = bus.ram.ptr + slot.pbase;
                                    break :blk data_page_ptr;
                                }
                                break :blk null;
                            };
                            if (hit_page) |page_ptr| {
                                const off: usize = start_addr & 0xfff;
                                const nbytes: usize = @as(u16, @truncate(d.imm));
                                if (comptime @import("builtin").cpu.arch.endian() == .little) {
                                    const s_bytes: *const [256]u8 = @ptrCast(&self.vfp.s);
                                    @memcpy(page_ptr[off..][0..nbytes], s_bytes[@as(usize, d.rd) * 4 ..][0..nbytes]);
                                } else {
                                    var p = off;
                                    for (self.vfp.s[d.rd..][0 .. nbytes / 4]) |s_reg| {
                                        std.mem.writeInt(u32, page_ptr[p..][0..4], s_reg, .little);
                                        p += 4;
                                    }
                                }
                                const wb_off: i32 = @as(i16, @bitCast(@as(u16, @truncate(d.imm >> 48))));
                                if (wb_off != 0) self.r[d.rn] = base_val +% @as(u32, @bitCast(wb_off));
                            } else {
                                self.executeVfp(bus, pc, inst, d.rm != 0);
                                priv = @intFromBool(self.isPrivileged());
                                data_r_vbase = 0xffff_ffff;
                                data_w_vbase = 0xffff_ffff;
                            }
                        } else {
                            self.executeVfp(bus, pc, inst, d.rm != 0);
                            priv = @intFromBool(self.isPrivileged());
                            code_vbase = 0xffff_ffff;
                            data_r_vbase = 0xffff_ffff;
                            data_w_vbase = 0xffff_ffff;
                        }
                    },
                    .vfp_ls_multi_al => {
                        self.executeVfp(bus, pc, inst, d.rm != 0);
                        priv = @intFromBool(self.isPrivileged());
                        data_r_vbase = 0xffff_ffff;
                        data_w_vbase = 0xffff_ffff;
                    },
                    .unconditional => {
                        self.executeUnconditional(bus, pc, inst);
                        if (self.mmu.halted_wfi or self.yield_slice) break;
                        _ = self.checkInterrupts(bus);
                        priv = @intFromBool(self.isPrivileged());
                        code_vbase = 0xffff_ffff;
                        data_r_vbase = 0xffff_ffff;
                        data_w_vbase = 0xffff_ffff;
                    },
                }
            }
            return executed;
        }

        pub inline fn stepOne(self: *Self, bus: *Bus) void {
            if (self.is_aarch64) {
                aarch64_mod.Aarch64Exec(Self, Bus).step64(self, bus);
                return;
            }
            if (self.isThumb()) {
                const pc = self.r[15] & ~@as(u32, 1);
                const inst16 = self.fetch16(bus, pc) catch {
                    self.enterException(.abt, 0x0c, pc +% 4, false);
                    return;
                };
                self.r[15] = pc +% 2;
                var data_r_vbase: u32 = 0xffff_ffff;
                var data_w_vbase: u32 = 0xffff_ffff;
                var data_page_ptr: [*]u8 = bus.ram.ptr;
                _ = self.executeThumb(bus, pc, inst16, @intFromBool(self.isPrivileged()), 0xffff_ffff, 0, &data_r_vbase, &data_w_vbase, &data_page_ptr);
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
                    const shift_imm: i32 = @as(i32, imm24) << 2;
                    const offset: u32 = @bitCast(shift_imm);
                    const target_pc = (inst_pc +% 8) +% offset;
                    const priv: u1 = @intFromBool(self.isPrivileged());
                    if (link) {
                        self.r[14] = inst_pc +% 4;
                        if (self.last_dmb_pc == inst_pc) {
                            self.yield_slice = true;
                        } else {
                            const tslot = self.mmu.soft_tlb32[priv][(target_pc >> 12) & Mmu.soft_tlb_mask];
                            if ((target_pc & 0xffff_f000) == tslot.x_vbase) {
                                const target_paddr = tslot.pbase | (target_pc & 0xfff);
                                const target_inst = std.mem.readInt(u32, bus.ram[target_paddr..][0..4], .little);
                                if (target_inst == 0xe12fff1e) {
                                    self.last_dmb_pc = inst_pc;
                                }
                            }
                        }
                    } else if (shift_imm >= -28 and shift_imm < 0) {
                        if (self.last_dmb_pc == inst_pc) {
                            self.yield_slice = true;
                        } else {
                            const islot = self.mmu.soft_tlb32[priv][(inst_pc >> 12) & Mmu.soft_tlb_mask];
                            if ((inst_pc & 0xfff) < 0xffc and (inst_pc & 0xffff_f000) == islot.x_vbase) {
                                const next_paddr = islot.pbase | ((inst_pc +% 4) & 0xfff);
                                const next_inst = std.mem.readInt(u32, bus.ram[next_paddr..][0..4], .little);
                                if ((next_inst & 0x0fff_ffe0) == 0x057f_f040) {
                                    self.last_dmb_pc = inst_pc;
                                }
                            }
                        }
                    }
                    self.r[15] = target_pc;
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
                } else if ((inst & 0x0fff_ffe0) == 0x057f_f040) {
                    self.memoryBarrier(bus, (inst & 0x10) == 0);
                    // DSB / DMB: yield slice if repeated at the same PC within the current slice
                    if (self.last_dmb_pc == inst_pc) {
                        self.yield_slice = true;
                    } else {
                        self.last_dmb_pc = inst_pc;
                    }
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
                    const hint = inst & 0xff;
                    if (hint == 3) {
                        self.mmu.halted_wfi = true;
                    } else if (hint == 1 or hint == 2) {
                        self.yield_slice = true;
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
                            self.excl_val = val;
                            self.excl_paddr = self.mmu.translate(bus.ram, vaddr, .read, self.isPrivileged()) catch 0;
                        },
                        0b1000 => { // STREX Rd, Rm, [Rn]
                            self.r[rd] = self.storeExclusive(bus, u32, vaddr, self.r[rm], self.isPrivileged()) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return;
                            };
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
                            self.excl_val = @as(u64, lo) | (@as(u64, hi) << 32);
                        },
                        0b1010 => { // STREXD Rd, Rm, Rm+1, [Rn]
                            const val: u64 = @as(u64, self.r[rm]) | (@as(u64, self.r[rm +% 1]) << 32);
                            self.r[rd] = self.storeExclusive(bus, u64, vaddr, val, self.isPrivileged()) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return;
                            };
                        },
                        0b1101 => { // LDREXB Rd, [Rn]
                            const val = self.read8(bus, vaddr) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return;
                            };
                            self.r[rd] = val;
                            self.excl_valid = true;
                            self.excl_val = val;
                        },
                        0b1100 => { // STREXB Rd, Rm, [Rn]
                            self.r[rd] = self.storeExclusive(bus, u8, vaddr, @truncate(self.r[rm]), self.isPrivileged()) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return;
                            };
                        },
                        0b1111 => { // LDREXH Rd, [Rn]
                            const val = self.read16(bus, vaddr) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return;
                            };
                            self.r[rd] = val;
                            self.excl_valid = true;
                            self.excl_val = val;
                        },
                        0b1110 => { // STREXH Rd, Rm, [Rn]
                            self.r[rd] = self.storeExclusive(bus, u16, vaddr, @truncate(self.r[rm]), self.isPrivileged()) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return;
                            };
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
                    0b011 => { // MLS Rd, Rn, Rm, Ra
                        self.r[rd_hi] = self.r[rd_lo] -% (self.r[rm] *% self.r[rs]);
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
            const priv: u1 = @intFromBool(self.isPrivileged());

            if (l) {
                if (!user_bank and count > 0) {
                    const last_addr = start_addr +% total_bytes -% 4;
                    const slot = self.mmu.soft_tlb32[priv][(start_addr >> 12) & Mmu.soft_tlb_mask];
                    if ((start_addr & ~@as(u32, 0xffc)) == slot.r_vbase and
                        (last_addr & ~@as(u32, 0xffc)) == slot.r_vbase)
                    {
                        var paddr = slot.pbase | (start_addr & 0xfff);
                        var rem_fast = reg_list & 0x7fff;
                        while (rem_fast != 0) : (rem_fast &= rem_fast - 1) {
                            const i: u4 = @intCast(@ctz(rem_fast));
                            self.r[i] = std.mem.readInt(u32, bus.ram[paddr..][0..4], .little);
                            paddr += 4;
                        }
                        if (w and (reg_list & (@as(u16, 1) << rn)) == 0) {
                            self.r[rn] = final_base;
                        }
                        if ((reg_list & (1 << 15)) != 0) {
                            const pc_val = std.mem.readInt(u32, bus.ram[paddr..][0..4], .little);
                            if (s) {
                                self.exceptionReturn(pc_val);
                            } else {
                                self.setPcWithInterworking(pc_val);
                            }
                        }
                        return;
                    }
                }
                var loaded: [16]u32 = undefined;
                var addr = start_addr;
                var rem = reg_list;
                while (rem != 0) : (rem &= rem - 1) {
                    const i: u4 = @intCast(@ctz(rem));
                    loaded[i] = self.read32(bus, addr) catch {
                        // Base Restored Abort Model: Rn and previous registers untouched!
                        self.enterException(.abt, 0x10, inst_pc +% 8, false);
                        return;
                    };
                    addr +%= 4;
                }
                if (w and (reg_list & (@as(u16, 1) << rn)) == 0) {
                    self.r[rn] = final_base;
                }
                var rem_commit = reg_list & 0x7fff;
                if (user_bank) {
                    while (rem_commit != 0) : (rem_commit &= rem_commit - 1) {
                        const i: u4 = @intCast(@ctz(rem_commit));
                        self.writeUserReg(i, loaded[i]);
                    }
                } else {
                    while (rem_commit != 0) : (rem_commit &= rem_commit - 1) {
                        const i: u4 = @intCast(@ctz(rem_commit));
                        self.r[i] = loaded[i];
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
                if (!user_bank and count > 0) {
                    const last_addr = start_addr +% total_bytes -% 4;
                    const slot = self.mmu.soft_tlb32[priv][(start_addr >> 12) & Mmu.soft_tlb_mask];
                    if ((start_addr & ~@as(u32, 0xffc)) == slot.w_vbase and
                        (last_addr & ~@as(u32, 0xffc)) == slot.w_vbase)
                    {
                        var paddr = slot.pbase | (start_addr & 0xfff);
                        var rem_fast = reg_list;
                        while (rem_fast != 0) : (rem_fast &= rem_fast - 1) {
                            const i: u4 = @intCast(@ctz(rem_fast));
                            const val = if (i == 15) (inst_pc +% 8) else self.r[i];
                            std.mem.writeInt(u32, bus.ram[paddr..][0..4], val, .little);
                            paddr += 4;
                        }
                        if (w) {
                            self.r[rn] = final_base;
                        }
                        return;
                    }
                }
                // STM: Pre-validate write translation on first and last address before committing writes
                if (count > 0) {
                    const last_addr = start_addr +% total_bytes -% 4;
                    const slot = self.mmu.soft_tlb32[priv][(start_addr >> 12) & Mmu.soft_tlb_mask];
                    if ((start_addr & ~@as(u32, 0xffc)) != slot.w_vbase or
                        (last_addr & ~@as(u32, 0xffc)) != slot.w_vbase)
                    {
                        _ = self.mmu.translate(bus.ram, start_addr, .write, priv != 0) catch {
                            self.enterException(.abt, 0x10, inst_pc +% 8, false);
                            return;
                        };
                        if (total_bytes > 4) {
                            _ = self.mmu.translate(bus.ram, last_addr, .write, priv != 0) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return;
                            };
                        }
                    }
                }
                var addr = start_addr;
                var rem = reg_list;
                while (rem != 0) : (rem &= rem - 1) {
                    const i: u4 = @intCast(@ctz(rem));
                    const val = if (i == 15)
                        (inst_pc +% 8)
                    else if (user_bank)
                        self.readUserReg(i)
                    else
                        self.r[i];
                    self.write32(bus, addr, val) catch {
                        self.enterException(.abt, 0x10, inst_pc +% 8, false);
                        return;
                    };
                    addr +%= 4;
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
                    // - ARMv6/v7 memory/instruction barriers (c7, 0, c10, 4/5 = DSB/DMB; c7, 0, c5, 4/6 = ISB/BPIALL)
                    // - ARMv7 Generic Timer user reads (c14, 0, c0, 0 = CNTFRQ)
                    if (!self.isPrivileged()) {
                        const allowed_c13 = (crn == 13 and crm == 0 and (opc2 == 2 or (opc2 == 3 and l)));
                        const allowed_c7 = (crn == 7 and !l and ((crm == 10 and (opc2 == 4 or opc2 == 5)) or (crm == 5 and (opc2 == 4 or opc2 == 6))));
                        const allowed_c14 = (crn == 14 and l);
                        if (!allowed_c13 and !allowed_c7 and !allowed_c14) {
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
                        if (crn == 7 and crm == 10 and (opc2 == 4 or opc2 == 5)) {
                            self.memoryBarrier(bus, opc2 == 4);
                        }
                        if (crn == 14) self.syncCoreTimerLines(bus);
                    }
                    return;
                }
                // MCRR / MRRC p15 (64-bit TTBR0/TTBR1, PAR, CNTPCT/CNTVCT/CVAL, CPUECTLR)
                if ((inst & 0x0fe0_0000) == 0x0c40_0000) {
                    const l = (inst & (1 << 20)) != 0;
                    const rt2: u4 = @truncate((inst >> 16) & 0xf);
                    const rt: u4 = @truncate((inst >> 12) & 0xf);
                    const opc1_64: u4 = @truncate((inst >> 4) & 0xf);
                    const crm: u4 = @truncate(inst & 0xf);
                    if (!self.isPrivileged() and !(crm == 14 and l)) {
                        self.enterException(.und, 0x04, inst_pc +% 4, false);
                        return;
                    }
                    if (l) {
                        const val64 = self.mmu.readCp15_64(opc1_64, crm);
                        self.r[rt] = @truncate(val64);
                        self.r[rt2] = @truncate(val64 >> 32);
                    } else {
                        const val64: u64 = (@as(u64, self.r[rt2]) << 32) | self.r[rt];
                        self.mmu.writeCp15_64(opc1_64, crm, val64);
                        if (crm == 14) self.syncCoreTimerLines(bus);
                    }
                    return;
                }
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

        inline fn vfpReady(self: *const Self, priv: u1) bool {
            const cp10_acc: u2 = @truncate((self.mmu.cpacr >> 20) & 3);
            return self.vfp.isEnabled() and (cp10_acc >= 2 or (cp10_acc == 1 and priv != 0));
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
                    const dm: u5 = @truncate((((inst >> 5) & 1) << 4) | (inst & 0xf));
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
                        const dd: u5 = (d_bit << 4) | vd;
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
                const word_count: u32 = @min(@as(u32, 64), if (is_double) (imm8 & ~@as(u32, 1)) else imm8);
                const start_addr = if (u) base_val else (base_val -% offset_bytes);
                const final_base = if (u) (base_val +% offset_bytes) else (base_val -% offset_bytes);
                const first_s: usize = if (is_double) (@as(usize, (d_bit << 4) | vd) * 2) else ((@as(usize, vd) << 1) | d_bit);

                if (l) {
                    var loaded: [64]u32 = undefined;
                    for (0..word_count) |i| {
                        loaded[i] = self.read32(bus, start_addr +% @as(u32, @intCast(i * 4))) catch {
                            self.enterException(.abt, 0x10, inst_pc +% 8, false);
                            return;
                        };
                    }
                    for (0..word_count) |i| {
                        if (first_s + i < 64) self.vfp.s[first_s + i] = loaded[i];
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
                        const val = if (first_s + i < 64) self.vfp.s[first_s + i] else 0;
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
                    const d_idx: u5 = (n_bit << 4) | vn;
                    const s_idx: u6 = (@as(u6, d_idx) << 1) | @as(u6, opc1 & 1);
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

        /// Executes a 16-bit Thumb instruction. Returns `true` if privilege/mode changed,
        /// `WFI`/`YIELD` was executed, or an MMIO store occurred that may have raised an IRQ.
        fn executeThumb(
            self: *Self,
            bus: *Bus,
            inst_pc: u32,
            inst: u16,
            priv: u1,
            code_vbase: u32,
            code_pbase: u32,
            data_r_vbase: *u32,
            data_w_vbase: *u32,
            data_page_ptr: *[*]u8,
        ) bool {
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
                    return false;
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
                    return false;
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
                        return false;
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
                        return false;
                    } else if ((inst & 0xf800) == 0x4800) {
                        // LDR Rd, [PC, #imm8*4]
                        const rd: u4 = @truncate((inst >> 8) & 7);
                        const imm: u32 = (@as(u32, inst & 0xff)) * 4;
                        const addr = ((inst_pc +% 4) & ~@as(u32, 3)) +% imm;
                        if ((addr & 0xffff_f000) == code_vbase) {
                            self.r[rd] = std.mem.readInt(u32, bus.ram[(code_pbase | (addr & 0xffc))..][0..4], .little);
                            return false;
                        }
                        if ((addr & 0xffff_f000) == data_r_vbase.*) {
                            self.r[rd] = std.mem.readInt(u32, data_page_ptr.*[addr & 0xffc ..][0..4], .little);
                            return false;
                        }
                        const slot = self.mmu.soft_tlb32[priv][(addr >> 12) & Mmu.soft_tlb_mask];
                        if ((addr & 0xffff_f000) == slot.r_vbase) {
                            data_r_vbase.* = slot.r_vbase;
                            data_w_vbase.* = slot.w_vbase;
                            data_page_ptr.* = bus.ram.ptr + slot.pbase;
                            self.r[rd] = std.mem.readInt(u32, data_page_ptr.*[addr & 0xffc ..][0..4], .little);
                            return false;
                        }
                        const val = self.read32(bus, addr) catch {
                            self.enterException(.abt, 0x10, inst_pc +% 8, false);
                            return true;
                        };
                        self.r[rd] = val;
                        return false;
                    } else {
                        // Load/Store register offset
                        const op: u3 = @truncate((inst >> 9) & 7);
                        const rm: u4 = @truncate((inst >> 6) & 7);
                        const rn: u4 = @truncate((inst >> 3) & 7);
                        const rd: u4 = @truncate(inst & 7);
                        const addr = self.r[rn] +% self.r[rm];
                        switch (op) {
                            0b000 => {
                                if ((addr & ~@as(u32, 0xffc)) == data_w_vbase.*) {
                                    std.mem.writeInt(u32, data_page_ptr.*[addr & 0xffc ..][0..4], self.r[rd], .little);
                                    return false;
                                }
                                const slot = self.mmu.soft_tlb32[priv][(addr >> 12) & Mmu.soft_tlb_mask];
                                if ((addr & ~@as(u32, 0xffc)) == slot.w_vbase) {
                                    data_r_vbase.* = slot.r_vbase;
                                    data_w_vbase.* = slot.w_vbase;
                                    data_page_ptr.* = bus.ram.ptr + slot.pbase;
                                    std.mem.writeInt(u32, data_page_ptr.*[addr & 0xffc ..][0..4], self.r[rd], .little);
                                    return false;
                                }
                                self.write32(bus, addr, self.r[rd]) catch {
                                    self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                    return true;
                                };
                                return true;
                            },
                            0b001 => {
                                if ((addr & ~@as(u32, 0xffe)) == data_w_vbase.*) {
                                    std.mem.writeInt(u16, data_page_ptr.*[addr & 0xffe ..][0..2], @truncate(self.r[rd]), .little);
                                    return false;
                                }
                                const slot = self.mmu.soft_tlb32[priv][(addr >> 12) & Mmu.soft_tlb_mask];
                                if ((addr & ~@as(u32, 0xffe)) == slot.w_vbase) {
                                    data_r_vbase.* = slot.r_vbase;
                                    data_w_vbase.* = slot.w_vbase;
                                    data_page_ptr.* = bus.ram.ptr + slot.pbase;
                                    std.mem.writeInt(u16, data_page_ptr.*[addr & 0xffe ..][0..2], @truncate(self.r[rd]), .little);
                                    return false;
                                }
                                self.write16(bus, addr, @truncate(self.r[rd])) catch {
                                    self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                    return true;
                                };
                                return true;
                            },
                            0b010 => {
                                if ((addr & 0xffff_f000) == data_w_vbase.*) {
                                    data_page_ptr.*[addr & 0xfff] = @truncate(self.r[rd]);
                                    return false;
                                }
                                const slot = self.mmu.soft_tlb32[priv][(addr >> 12) & Mmu.soft_tlb_mask];
                                if ((addr & 0xffff_f000) == slot.w_vbase) {
                                    data_r_vbase.* = slot.r_vbase;
                                    data_w_vbase.* = slot.w_vbase;
                                    data_page_ptr.* = bus.ram.ptr + slot.pbase;
                                    data_page_ptr.*[addr & 0xfff] = @truncate(self.r[rd]);
                                    return false;
                                }
                                self.write8(bus, addr, @truncate(self.r[rd])) catch {
                                    self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                    return true;
                                };
                                return true;
                            },
                            0b011 => {
                                if ((addr & 0xffff_f000) == data_r_vbase.*) {
                                    const bval = data_page_ptr.*[addr & 0xfff];
                                    self.r[rd] = @bitCast(@as(i32, @as(i8, @bitCast(bval))));
                                    return false;
                                }
                                const slot = self.mmu.soft_tlb32[priv][(addr >> 12) & Mmu.soft_tlb_mask];
                                if ((addr & 0xffff_f000) == slot.r_vbase) {
                                    data_r_vbase.* = slot.r_vbase;
                                    data_w_vbase.* = slot.w_vbase;
                                    data_page_ptr.* = bus.ram.ptr + slot.pbase;
                                    const bval = data_page_ptr.*[addr & 0xfff];
                                    self.r[rd] = @bitCast(@as(i32, @as(i8, @bitCast(bval))));
                                    return false;
                                }
                                const bval = self.read8(bus, addr) catch {
                                    self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                    return true;
                                };
                                self.r[rd] = @bitCast(@as(i32, @as(i8, @bitCast(bval))));
                                return false;
                            },
                            0b100 => {
                                if ((addr & ~@as(u32, 0xffc)) == data_r_vbase.*) {
                                    self.r[rd] = std.mem.readInt(u32, data_page_ptr.*[addr & 0xffc ..][0..4], .little);
                                    return false;
                                }
                                const slot = self.mmu.soft_tlb32[priv][(addr >> 12) & Mmu.soft_tlb_mask];
                                if ((addr & ~@as(u32, 0xffc)) == slot.r_vbase) {
                                    data_r_vbase.* = slot.r_vbase;
                                    data_w_vbase.* = slot.w_vbase;
                                    data_page_ptr.* = bus.ram.ptr + slot.pbase;
                                    self.r[rd] = std.mem.readInt(u32, data_page_ptr.*[addr & 0xffc ..][0..4], .little);
                                    return false;
                                }
                                self.r[rd] = self.read32(bus, addr) catch {
                                    self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                    return true;
                                };
                                return false;
                            },
                            0b101 => {
                                if ((addr & ~@as(u32, 0xffe)) == data_r_vbase.*) {
                                    self.r[rd] = std.mem.readInt(u16, data_page_ptr.*[addr & 0xffe ..][0..2], .little);
                                    return false;
                                }
                                const slot = self.mmu.soft_tlb32[priv][(addr >> 12) & Mmu.soft_tlb_mask];
                                if ((addr & ~@as(u32, 0xffe)) == slot.r_vbase) {
                                    data_r_vbase.* = slot.r_vbase;
                                    data_w_vbase.* = slot.w_vbase;
                                    data_page_ptr.* = bus.ram.ptr + slot.pbase;
                                    self.r[rd] = std.mem.readInt(u16, data_page_ptr.*[addr & 0xffe ..][0..2], .little);
                                    return false;
                                }
                                self.r[rd] = self.read16(bus, addr) catch {
                                    self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                    return true;
                                };
                                return false;
                            },
                            0b110 => {
                                if ((addr & 0xffff_f000) == data_r_vbase.*) {
                                    self.r[rd] = data_page_ptr.*[addr & 0xfff];
                                    return false;
                                }
                                const slot = self.mmu.soft_tlb32[priv][(addr >> 12) & Mmu.soft_tlb_mask];
                                if ((addr & 0xffff_f000) == slot.r_vbase) {
                                    data_r_vbase.* = slot.r_vbase;
                                    data_w_vbase.* = slot.w_vbase;
                                    data_page_ptr.* = bus.ram.ptr + slot.pbase;
                                    self.r[rd] = data_page_ptr.*[addr & 0xfff];
                                    return false;
                                }
                                self.r[rd] = self.read8(bus, addr) catch {
                                    self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                    return true;
                                };
                                return false;
                            },
                            0b111 => {
                                if ((addr & ~@as(u32, 0xffe)) == data_r_vbase.*) {
                                    const hval = std.mem.readInt(u16, data_page_ptr.*[addr & 0xffe ..][0..2], .little);
                                    self.r[rd] = @bitCast(@as(i32, @as(i16, @bitCast(hval))));
                                    return false;
                                }
                                const slot = self.mmu.soft_tlb32[priv][(addr >> 12) & Mmu.soft_tlb_mask];
                                if ((addr & ~@as(u32, 0xffe)) == slot.r_vbase) {
                                    data_r_vbase.* = slot.r_vbase;
                                    data_w_vbase.* = slot.w_vbase;
                                    data_page_ptr.* = bus.ram.ptr + slot.pbase;
                                    const hval = std.mem.readInt(u16, data_page_ptr.*[addr & 0xffe ..][0..2], .little);
                                    self.r[rd] = @bitCast(@as(i32, @as(i16, @bitCast(hval))));
                                    return false;
                                }
                                const hval = self.read16(bus, addr) catch {
                                    self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                    return true;
                                };
                                self.r[rd] = @bitCast(@as(i32, @as(i16, @bitCast(hval))));
                                return false;
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
                            if ((addr & 0xffff_f000) == data_r_vbase.*) {
                                self.r[rd] = data_page_ptr.*[addr & 0xfff];
                                return false;
                            }
                            const slot = self.mmu.soft_tlb32[priv][(addr >> 12) & Mmu.soft_tlb_mask];
                            if ((addr & 0xffff_f000) == slot.r_vbase) {
                                data_r_vbase.* = slot.r_vbase;
                                data_w_vbase.* = slot.w_vbase;
                                data_page_ptr.* = bus.ram.ptr + slot.pbase;
                                self.r[rd] = data_page_ptr.*[addr & 0xfff];
                                return false;
                            }
                            self.r[rd] = self.read8(bus, addr) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return true;
                            };
                        } else {
                            if ((addr & ~@as(u32, 0xffc)) == data_r_vbase.*) {
                                self.r[rd] = std.mem.readInt(u32, data_page_ptr.*[addr & 0xffc ..][0..4], .little);
                                return false;
                            }
                            const slot = self.mmu.soft_tlb32[priv][(addr >> 12) & Mmu.soft_tlb_mask];
                            if ((addr & ~@as(u32, 0xffc)) == slot.r_vbase) {
                                data_r_vbase.* = slot.r_vbase;
                                data_w_vbase.* = slot.w_vbase;
                                data_page_ptr.* = bus.ram.ptr + slot.pbase;
                                self.r[rd] = std.mem.readInt(u32, data_page_ptr.*[addr & 0xffc ..][0..4], .little);
                                return false;
                            }
                            self.r[rd] = self.read32(bus, addr) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return true;
                            };
                        }
                        return false;
                    } else {
                        if (b) {
                            if ((addr & 0xffff_f000) == data_w_vbase.*) {
                                data_page_ptr.*[addr & 0xfff] = @truncate(self.r[rd]);
                                return false;
                            }
                            const slot = self.mmu.soft_tlb32[priv][(addr >> 12) & Mmu.soft_tlb_mask];
                            if ((addr & 0xffff_f000) == slot.w_vbase) {
                                data_r_vbase.* = slot.r_vbase;
                                data_w_vbase.* = slot.w_vbase;
                                data_page_ptr.* = bus.ram.ptr + slot.pbase;
                                data_page_ptr.*[addr & 0xfff] = @truncate(self.r[rd]);
                                return false;
                            }
                            self.write8(bus, addr, @truncate(self.r[rd])) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return true;
                            };
                            return true;
                        } else {
                            if ((addr & ~@as(u32, 0xffc)) == data_w_vbase.*) {
                                std.mem.writeInt(u32, data_page_ptr.*[addr & 0xffc ..][0..4], self.r[rd], .little);
                                return false;
                            }
                            const slot = self.mmu.soft_tlb32[priv][(addr >> 12) & Mmu.soft_tlb_mask];
                            if ((addr & ~@as(u32, 0xffc)) == slot.w_vbase) {
                                data_r_vbase.* = slot.r_vbase;
                                data_w_vbase.* = slot.w_vbase;
                                data_page_ptr.* = bus.ram.ptr + slot.pbase;
                                std.mem.writeInt(u32, data_page_ptr.*[addr & 0xffc ..][0..4], self.r[rd], .little);
                                return false;
                            }
                            self.write32(bus, addr, self.r[rd]) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return true;
                            };
                            return true;
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
                            if ((addr & ~@as(u32, 0xffe)) == data_r_vbase.*) {
                                self.r[rd] = std.mem.readInt(u16, data_page_ptr.*[addr & 0xffe ..][0..2], .little);
                                return false;
                            }
                            const slot = self.mmu.soft_tlb32[priv][(addr >> 12) & Mmu.soft_tlb_mask];
                            if ((addr & ~@as(u32, 0xffe)) == slot.r_vbase) {
                                data_r_vbase.* = slot.r_vbase;
                                data_w_vbase.* = slot.w_vbase;
                                data_page_ptr.* = bus.ram.ptr + slot.pbase;
                                self.r[rd] = std.mem.readInt(u16, data_page_ptr.*[addr & 0xffe ..][0..2], .little);
                                return false;
                            }
                            self.r[rd] = self.read16(bus, addr) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return true;
                            };
                            return false;
                        } else {
                            if ((addr & ~@as(u32, 0xffe)) == data_w_vbase.*) {
                                std.mem.writeInt(u16, data_page_ptr.*[addr & 0xffe ..][0..2], @truncate(self.r[rd]), .little);
                                return false;
                            }
                            const slot = self.mmu.soft_tlb32[priv][(addr >> 12) & Mmu.soft_tlb_mask];
                            if ((addr & ~@as(u32, 0xffe)) == slot.w_vbase) {
                                data_r_vbase.* = slot.r_vbase;
                                data_w_vbase.* = slot.w_vbase;
                                data_page_ptr.* = bus.ram.ptr + slot.pbase;
                                std.mem.writeInt(u16, data_page_ptr.*[addr & 0xffe ..][0..2], @truncate(self.r[rd]), .little);
                                return false;
                            }
                            self.write16(bus, addr, @truncate(self.r[rd])) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return true;
                            };
                            return true;
                        }
                    } else {
                        // LDR / STR [SP, #imm8*4]
                        const l = (inst & (1 << 11)) != 0;
                        const rd: u4 = @truncate((inst >> 8) & 7);
                        const imm: u32 = (@as(u32, inst & 0xff)) * 4;
                        const addr = self.r[13] +% imm;
                        if (l) {
                            if ((addr & ~@as(u32, 0xffc)) == data_r_vbase.*) {
                                self.r[rd] = std.mem.readInt(u32, data_page_ptr.*[addr & 0xffc ..][0..4], .little);
                                return false;
                            }
                            const slot = self.mmu.soft_tlb32[priv][(addr >> 12) & Mmu.soft_tlb_mask];
                            if ((addr & ~@as(u32, 0xffc)) == slot.r_vbase) {
                                data_r_vbase.* = slot.r_vbase;
                                data_w_vbase.* = slot.w_vbase;
                                data_page_ptr.* = bus.ram.ptr + slot.pbase;
                                self.r[rd] = std.mem.readInt(u32, data_page_ptr.*[addr & 0xffc ..][0..4], .little);
                                return false;
                            }
                            self.r[rd] = self.read32(bus, addr) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return true;
                            };
                            return false;
                        } else {
                            if ((addr & ~@as(u32, 0xffc)) == data_w_vbase.*) {
                                std.mem.writeInt(u32, data_page_ptr.*[addr & 0xffc ..][0..4], self.r[rd], .little);
                                return false;
                            }
                            const slot = self.mmu.soft_tlb32[priv][(addr >> 12) & Mmu.soft_tlb_mask];
                            if ((addr & ~@as(u32, 0xffc)) == slot.w_vbase) {
                                data_r_vbase.* = slot.r_vbase;
                                data_w_vbase.* = slot.w_vbase;
                                data_page_ptr.* = bus.ram.ptr + slot.pbase;
                                std.mem.writeInt(u32, data_page_ptr.*[addr & 0xffc ..][0..4], self.r[rd], .little);
                                return false;
                            }
                            self.write32(bus, addr, self.r[rd]) catch {
                                self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                return true;
                            };
                            return true;
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
                        return false;
                    } else {
                        // Misc 16-bit Thumb (ADD/SUB SP, SXTH/SXTB/UXTH/UXTB, PUSH/POP, REV, BKPT)
                        return self.executeThumbMisc(bus, inst_pc, inst, priv, data_r_vbase, data_w_vbase, data_page_ptr);
                    }
                },
                0b110 => {
                    if ((inst & (1 << 12)) == 0) {
                        // LDMIA / STMIA
                        const l = (inst & (1 << 11)) != 0;
                        const rn: u4 = @truncate((inst >> 8) & 7);
                        const rlist: u8 = @truncate(inst & 0xff);
                        const base_val = self.r[rn];
                        if (rlist != 0) {
                            const count: u32 = @popCount(rlist);
                            const total_bytes = count * 4;
                            const last_addr = base_val +% total_bytes -% 4;
                            if (l) {
                                const hit_page: ?[*]u8 = if ((base_val & ~@as(u32, 0xffc)) == data_r_vbase.* and
                                    (last_addr & ~@as(u32, 0xffc)) == data_r_vbase.*)
                                    data_page_ptr.*
                                else blk: {
                                    const slot = self.mmu.soft_tlb32[priv][(base_val >> 12) & Mmu.soft_tlb_mask];
                                    if ((base_val & ~@as(u32, 0xffc)) == slot.r_vbase and
                                        (last_addr & ~@as(u32, 0xffc)) == slot.r_vbase)
                                    {
                                        data_r_vbase.* = slot.r_vbase;
                                        data_w_vbase.* = slot.w_vbase;
                                        data_page_ptr.* = bus.ram.ptr + slot.pbase;
                                        break :blk data_page_ptr.*;
                                    }
                                    break :blk null;
                                };
                                if (hit_page) |page_ptr| {
                                    var off: usize = base_val & 0xfff;
                                    self.r[rn] = base_val +% total_bytes;
                                    var rem = rlist;
                                    while (rem != 0) : (rem &= rem - 1) {
                                        const i: u4 = @intCast(@ctz(rem));
                                        self.r[i] = std.mem.readInt(u32, page_ptr[off..][0..4], .little);
                                        off += 4;
                                    }
                                    return false;
                                }
                            } else {
                                const hit_page: ?[*]u8 = if ((base_val & ~@as(u32, 0xffc)) == data_w_vbase.* and
                                    (last_addr & ~@as(u32, 0xffc)) == data_w_vbase.*)
                                    data_page_ptr.*
                                else blk: {
                                    const slot = self.mmu.soft_tlb32[priv][(base_val >> 12) & Mmu.soft_tlb_mask];
                                    if ((base_val & ~@as(u32, 0xffc)) == slot.w_vbase and
                                        (last_addr & ~@as(u32, 0xffc)) == slot.w_vbase)
                                    {
                                        data_r_vbase.* = slot.r_vbase;
                                        data_w_vbase.* = slot.w_vbase;
                                        data_page_ptr.* = bus.ram.ptr + slot.pbase;
                                        break :blk data_page_ptr.*;
                                    }
                                    break :blk null;
                                };
                                if (hit_page) |page_ptr| {
                                    var off: usize = base_val & 0xfff;
                                    var rem = rlist;
                                    while (rem != 0) : (rem &= rem - 1) {
                                        const i: u4 = @intCast(@ctz(rem));
                                        std.mem.writeInt(u32, page_ptr[off..][0..4], self.r[i], .little);
                                        off += 4;
                                    }
                                    self.r[rn] = base_val +% total_bytes;
                                    return false;
                                }
                            }
                        }
                        var addr = base_val;
                        if (l) {
                            var loaded: [8]u32 = undefined;
                            var rem = rlist;
                            while (rem != 0) : (rem &= rem - 1) {
                                const i: u4 = @intCast(@ctz(rem));
                                loaded[i] = self.read32(bus, addr) catch {
                                    self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                    return true;
                                };
                                addr +%= 4;
                            }
                            self.r[rn] = addr;
                            var rem_c = rlist;
                            while (rem_c != 0) : (rem_c &= rem_c - 1) {
                                const i: u4 = @intCast(@ctz(rem_c));
                                self.r[i] = loaded[i];
                            }
                            return false;
                        } else {
                            var rem = rlist;
                            while (rem != 0) : (rem &= rem - 1) {
                                const i: u4 = @intCast(@ctz(rem));
                                self.write32(bus, addr, self.r[i]) catch {
                                    self.enterException(.abt, 0x10, inst_pc +% 8, false);
                                    return true;
                                };
                                addr +%= 4;
                            }
                            self.r[rn] = addr;
                            return true;
                        }
                    } else {
                        const cond: u4 = @truncate((inst >> 8) & 0xf);
                        if (cond == 0xf) {
                            // SVC (Thumb)
                            self.enterException(.svc, 0x08, inst_pc +% 2, false);
                            return true;
                        } else if (cond == 0xe) {
                            // Permanently undefined
                            self.enterException(.und, 0x04, inst_pc +% 2, false);
                            return true;
                        } else if (dec.checkCond(cond, self.cpsr)) {
                            const imm8: i8 = @bitCast(@as(u8, @truncate(inst)));
                            const offset: u32 = @bitCast(@as(i32, imm8) * 2);
                            self.r[15] = (inst_pc +% 4) +% offset;
                        }
                        return false;
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
                    return false;
                },
            }
        }

        fn executeThumbMisc(
            self: *Self,
            bus: *Bus,
            inst_pc: u32,
            inst: u16,
            priv: u1,
            data_r_vbase: *u32,
            data_w_vbase: *u32,
            data_page_ptr: *[*]u8,
        ) bool {
            const sub: u4 = @truncate((inst >> 8) & 0xf);
            switch (sub) {
                0b0000 => { // ADD/SUB SP, #imm7*4
                    const imm: u32 = (@as(u32, inst & 0x7f)) * 4;
                    if ((inst & 0x80) != 0) self.r[13] -%= imm else self.r[13] +%= imm;
                    return false;
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
                    return false;
                },
                0b0100, 0b0101 => { // PUSH
                    const push_lr = (sub & 1) != 0;
                    const rlist: u8 = @truncate(inst & 0xff);
                    const reg_list: u16 = @as(u16, rlist) | (if (push_lr) @as(u16, 1 << 14) else 0);
                    const count: u32 = @popCount(reg_list);
                    const start_sp = self.r[13] -% (count * 4);
                    if (count > 0) {
                        const last_addr = self.r[13] -% 4;
                        const hit_page: ?[*]u8 = if ((start_sp & ~@as(u32, 0xffc)) == data_w_vbase.* and
                            (last_addr & ~@as(u32, 0xffc)) == data_w_vbase.*)
                            data_page_ptr.*
                        else blk: {
                            const slot = self.mmu.soft_tlb32[priv][(start_sp >> 12) & Mmu.soft_tlb_mask];
                            if ((start_sp & ~@as(u32, 0xffc)) == slot.w_vbase and
                                (last_addr & ~@as(u32, 0xffc)) == slot.w_vbase)
                            {
                                data_r_vbase.* = slot.r_vbase;
                                data_w_vbase.* = slot.w_vbase;
                                data_page_ptr.* = bus.ram.ptr + slot.pbase;
                                break :blk data_page_ptr.*;
                            }
                            break :blk null;
                        };
                        if (hit_page) |page_ptr| {
                            var off: usize = start_sp & 0xfff;
                            var rem = reg_list;
                            while (rem != 0) : (rem &= rem - 1) {
                                const i: u4 = @intCast(@ctz(rem));
                                std.mem.writeInt(u32, page_ptr[off..][0..4], self.r[i], .little);
                                off += 4;
                            }
                            self.r[13] = start_sp;
                            return false;
                        }
                    }
                    var addr = start_sp;
                    var rem = reg_list;
                    while (rem != 0) : (rem &= rem - 1) {
                        const i: u4 = @intCast(@ctz(rem));
                        self.write32(bus, addr, self.r[i]) catch {
                            self.enterException(.abt, 0x10, inst_pc +% 8, false);
                            return true;
                        };
                        addr +%= 4;
                    }
                    self.r[13] = start_sp;
                    return true;
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
                    return false;
                },
                0b1100, 0b1101 => { // POP
                    const pop_pc = (sub & 1) != 0;
                    const rlist: u8 = @truncate(inst & 0xff);
                    const count: u32 = @as(u32, @popCount(rlist)) + @intFromBool(pop_pc);
                    const start_sp = self.r[13];
                    if (count > 0) {
                        const last_addr = start_sp +% (count * 4) -% 4;
                        const hit_page: ?[*]u8 = if ((start_sp & ~@as(u32, 0xffc)) == data_r_vbase.* and
                            (last_addr & ~@as(u32, 0xffc)) == data_r_vbase.*)
                            data_page_ptr.*
                        else blk: {
                            const slot = self.mmu.soft_tlb32[priv][(start_sp >> 12) & Mmu.soft_tlb_mask];
                            if ((start_sp & ~@as(u32, 0xffc)) == slot.r_vbase and
                                (last_addr & ~@as(u32, 0xffc)) == slot.r_vbase)
                            {
                                data_r_vbase.* = slot.r_vbase;
                                data_w_vbase.* = slot.w_vbase;
                                data_page_ptr.* = bus.ram.ptr + slot.pbase;
                                break :blk data_page_ptr.*;
                            }
                            break :blk null;
                        };
                        if (hit_page) |page_ptr| {
                            var off: usize = start_sp & 0xfff;
                            var rem = rlist;
                            while (rem != 0) : (rem &= rem - 1) {
                                const i: u4 = @intCast(@ctz(rem));
                                self.r[i] = std.mem.readInt(u32, page_ptr[off..][0..4], .little);
                                off += 4;
                            }
                            self.r[13] = start_sp +% (count * 4);
                            if (pop_pc) {
                                const new_pc = std.mem.readInt(u32, page_ptr[off..][0..4], .little);
                                self.setPcWithInterworking(new_pc);
                            }
                            return false;
                        }
                    }
                    var addr = start_sp;
                    var loaded: [8]u32 = undefined;
                    var rem = rlist;
                    while (rem != 0) : (rem &= rem - 1) {
                        const i: u4 = @intCast(@ctz(rem));
                        loaded[i] = self.read32(bus, addr) catch {
                            self.enterException(.abt, 0x10, inst_pc +% 8, false);
                            return true;
                        };
                        addr +%= 4;
                    }
                    var new_pc: u32 = 0;
                    if (pop_pc) {
                        new_pc = self.read32(bus, addr) catch {
                            self.enterException(.abt, 0x10, inst_pc +% 8, false);
                            return true;
                        };
                        addr +%= 4;
                    }
                    self.r[13] = addr;
                    var rem_c = rlist;
                    while (rem_c != 0) : (rem_c &= rem_c - 1) {
                        const i: u4 = @intCast(@ctz(rem_c));
                        self.r[i] = loaded[i];
                    }
                    if (pop_pc) self.setPcWithInterworking(new_pc);
                    return false;
                },
                0b1111 => { // 16-bit Thumb NOP / YIELD / WFE / WFI / SEV hints (0xbf00..0xbf40)
                    const hint: u4 = @truncate((inst >> 4) & 0xf);
                    if ((inst & 0xf) == 0) {
                        if (hint == 3) {
                            self.mmu.halted_wfi = true;
                            return true;
                        } else if (hint == 1 or hint == 2) {
                            self.yield_slice = true;
                            return true;
                        }
                    }
                    return false;
                },
                else => return false,
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
    // 0x1014: stmia r2, {r0, r1} (0xe8820003)
    // 0x1018: ldmia r2, {r2, r5} (0xe8920024) - base register r2 is in reg_list!
    const prog = [_]u32{
        0xe3a0002a,
        0xe280103a,
        0xe5821004,
        0xe5923004,
        0xe6bf4f33,
        0xe8820003,
        0xe8920024,
    };
    for (prog, 0..) |inst, i| {
        std.mem.writeInt(u32, ram[0x1000 + i * 4 ..][0..4], inst, .little);
    }

    _ = cpu.runSteps(&bus, 7);
    try std.testing.expectEqual(@as(u32, 42), cpu.r[0]);
    try std.testing.expectEqual(@as(u32, 100), cpu.r[1]);
    try std.testing.expectEqual(@as(u32, 42), cpu.r[2]);
    try std.testing.expectEqual(@as(u32, 100), cpu.r[3]);
    try std.testing.expectEqual(@as(u32, 0x64000000), cpu.r[4]);
    try std.testing.expectEqual(@as(u32, 100), cpu.r[5]);
    _ = aarch64_mod;
}

test "ARM1176 pre-decoded atomics, 64-bit multiplies, CLZ, and media fast-path" {
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
    std.mem.writeInt(u32, ram[0x2000..][0..4], 10, .little);

    // 0x1000: ldrex r0, [r2]        (0xe1920f9f) -> r0 = 10, excl_valid = true
    // 0x1004: add r1, r0, #5        (0xe2801005) -> r1 = 15
    // 0x1008: strex r3, r1, [r2]    (0xe1823f91) -> [0x2000] = 15, r3 = 0, excl_valid = false
    // 0x100c: strex r4, r0, [r2]    (0xe1824f90) -> fails (r4 = 1), [0x2000] remains 15
    // 0x1010: movw r5, #0x8000      (0xe3085000)
    // 0x1014: movt r5, #0x0001      (0xe3405001) -> r5 = 0x00018000
    // 0x1018: clz r6, r5            (0xe16f6f15) -> r6 = 15
    // 0x101c: umull r7, r8, r5, r5  (0xe0887595) -> 0x18000 * 0x18000 = 0x00000002_40000000 (r7=0x40000000, r8=2)
    // 0x1020: ubfx r9, r5, #12, #8  (0xe7e79655) -> (0x18000 >> 12) & 0xff = 0x18
    // 0x1024: sxtb r10, r9, ror #0  (0xe6afaa79) -> Wait: sxtb r10, r9 is 0xe6afa079
    const prog = [_]u32{
        0xe1920f9f,
        0xe2801005,
        0xe1823f91,
        0xe1824f90,
        0xe3085000,
        0xe3405001,
        0xe16f6f15,
        0xe0887595,
        0xe7e79655,
        0xe6afa079,
    };
    for (prog, 0..) |inst, i| {
        std.mem.writeInt(u32, ram[0x1000 + i * 4 ..][0..4], inst, .little);
    }

    try std.testing.expectEqual(ArmOp.ldrex_al, @as(ArmOp, @enumFromInt(decodeArm32(prog[0]).op)));
    try std.testing.expectEqual(ArmOp.strex_al, @as(ArmOp, @enumFromInt(decodeArm32(prog[2]).op)));
    try std.testing.expectEqual(ArmOp.clz_al, @as(ArmOp, @enumFromInt(decodeArm32(prog[6]).op)));
    try std.testing.expectEqual(ArmOp.umull_al, @as(ArmOp, @enumFromInt(decodeArm32(prog[7]).op)));
    try std.testing.expectEqual(ArmOp.ubfx_al, @as(ArmOp, @enumFromInt(decodeArm32(prog[8]).op)));
    try std.testing.expectEqual(ArmOp.sxtb_al, @as(ArmOp, @enumFromInt(decodeArm32(prog[9]).op)));

    _ = cpu.runSteps(&bus, prog.len);
    try std.testing.expectEqual(@as(u32, 10), cpu.r[0]);
    try std.testing.expectEqual(@as(u32, 15), cpu.r[1]);
    try std.testing.expectEqual(@as(u32, 0), cpu.r[3]);
    try std.testing.expectEqual(@as(u32, 1), cpu.r[4]);
    try std.testing.expectEqual(@as(u32, 15), std.mem.readInt(u32, ram[0x2000..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 15), cpu.r[6]);
    try std.testing.expectEqual(@as(u32, 0x4000_0000), cpu.r[7]);
    try std.testing.expectEqual(@as(u32, 2), cpu.r[8]);
    try std.testing.expectEqual(@as(u32, 0x18), cpu.r[9]);
    try std.testing.expectEqual(@as(u32, 0x18), cpu.r[10]);
}

test "ARM1176 pre-decoded VFP load/store and double-precision arithmetic" {
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
    cpu.initReset(0x1000, 0x2000, 0, 0);
    cpu.mmu.cpacr = 0x00f0_0000;
    cpu.vfp.fpexc = 1 << 30;

    std.mem.writeInt(u64, ram[0x2000..][0..8], @bitCast(@as(f64, 12.5)), .little);
    std.mem.writeInt(u64, ram[0x2008..][0..8], @bitCast(@as(f64, 3.5)), .little);

    // 0x1000: vldr d0, [r0, #0]     (0xed900b00) -> d0 = 12.5
    // 0x1004: vldr d1, [r0, #8]     (0xed901b02) -> d1 = 3.5
    // 0x1008: vadd.f64 d2, d0, d1   (0xee302b01) -> d2 = 16.0
    // 0x100c: vmul.f64 d3, d2, d1   (0xee223b01) -> d3 = 56.0
    // 0x1010: vstr d3, [r0, #16]    (0xed803b04) -> [0x2010] = 56.0
    // 0x1014: vcmp.f64 d3, d2       (0xeeb43b42) -> d3 > d2
    // 0x1018: vmrs APSR_nzcv, fpscr (0xeef1fa10) -> C=1, Z=0
    const prog = [_]u32{
        0xed900b00,
        0xed901b02,
        0xee302b01,
        0xee223b01,
        0xed803b04,
        0xeeb43b42,
        0xeef1fa10,
    };
    for (prog, 0..) |inst, i| {
        std.mem.writeInt(u32, ram[0x1000 + i * 4 ..][0..4], inst, .little);
    }

    try std.testing.expectEqual(ArmOp.vldr_f64_al, @as(ArmOp, @enumFromInt(decodeArm32(prog[0]).op)));
    try std.testing.expectEqual(ArmOp.vadd_f64_al, @as(ArmOp, @enumFromInt(decodeArm32(prog[2]).op)));
    try std.testing.expectEqual(ArmOp.vmul_f64_al, @as(ArmOp, @enumFromInt(decodeArm32(prog[3]).op)));
    try std.testing.expectEqual(ArmOp.vstr_f64_al, @as(ArmOp, @enumFromInt(decodeArm32(prog[4]).op)));
    try std.testing.expectEqual(ArmOp.vcmp_f64_al, @as(ArmOp, @enumFromInt(decodeArm32(prog[5]).op)));
    try std.testing.expectEqual(ArmOp.vmrs_apsr_al, @as(ArmOp, @enumFromInt(decodeArm32(prog[6]).op)));

    _ = cpu.runSteps(&bus, prog.len);
    try std.testing.expectEqual(@as(f64, 16.0), cpu.vfp.getD(2));
    try std.testing.expectEqual(@as(f64, 56.0), cpu.vfp.getD(3));
    try std.testing.expectEqual(@as(f64, 56.0), @as(f64, @bitCast(std.mem.readInt(u64, ram[0x2010..][0..8], .little))));
    try std.testing.expect((cpu.cpsr & PsrFlags.C) != 0);
    try std.testing.expect((cpu.cpsr & PsrFlags.Z) == 0);

    // Verify contiguous PUSH/POP (STMDB/LDMIA), VPUSH/VPOP (VSTMDB/VLDMIA), and LDRD/STRD fast-paths
    cpu.r[13] = 0x3000;
    cpu.r[4] = 0x1111_2222;
    cpu.r[5] = 0x3333_4444;
    cpu.r[6] = 0x5555_6666;
    cpu.r[7] = 0x7777_8888;
    cpu.r[14] = 0x1040;
    // 0x101c: push {r4-r7, lr}      (0xe92d40f0) -> contiguous r4..r7 + lr
    // 0x1020: vpush {d2-d3}         (0xed2d2b04) -> vstm_al
    // 0x1024: mov r4, #0            (0xe3a04000)
    // 0x1028: mov r5, #0            (0xe3a05000)
    // 0x102c: vmov.f64 d2, d0       (0xeeb02b40) -> overwrite d2 with 12.5
    // 0x1030: vpop {d2-d3}          (0xecbd2b04) -> vldm_al restores d2=16.0, d3=56.0
    // 0x1034: strd r4, r5, [r0, #24](0xe1c041f8) -> strd_imm_al writes 0, 0
    // 0x1038: pop {r4-r7, pc}       (0xe8bd80f0) -> contiguous r4..r7 + pc (jumps to 0x1040)
    // 0x1040: ldrd r8, r9, [r0, #0] (0xe1c080d0) -> ldrd_imm_al reads d0 raw words into r8, r9
    const block_prog = [_]u32{
        0xe92d40f0,
        0xed2d2b04,
        0xe3a04000,
        0xe3a05000,
        0xeeb02b40,
        0xecbd2b04,
        0xe1c041f8,
        0xe8bd80f0,
        0xe1a00000, // 0x103c: nop (skipped by pop pc)
        0xe1c080d0, // 0x1040: ldrd r8, r9, [r0, #0]
    };
    for (block_prog, 0..) |inst, i| {
        std.mem.writeInt(u32, ram[0x101c + i * 4 ..][0..4], inst, .little);
    }

    const push_dec = decodeArm32(block_prog[0]);
    try std.testing.expectEqual(ArmOp.stm_al, @as(ArmOp, @enumFromInt(push_dec.op)));
    try std.testing.expect((push_dec.rm & 0x80) != 0); // contiguous fast-path active
    try std.testing.expectEqual(ArmOp.vstm_al, @as(ArmOp, @enumFromInt(decodeArm32(block_prog[1]).op)));
    try std.testing.expectEqual(ArmOp.vldm_al, @as(ArmOp, @enumFromInt(decodeArm32(block_prog[5]).op)));
    try std.testing.expectEqual(ArmOp.strd_imm_al, @as(ArmOp, @enumFromInt(decodeArm32(block_prog[6]).op)));
    try std.testing.expectEqual(ArmOp.ldm_pc_al, @as(ArmOp, @enumFromInt(decodeArm32(block_prog[7]).op)));
    try std.testing.expectEqual(ArmOp.ldrd_imm_al, @as(ArmOp, @enumFromInt(decodeArm32(block_prog[9]).op)));

    _ = cpu.runSteps(&bus, 9);
    try std.testing.expectEqual(@as(u32, 0x3000), cpu.r[13]);
    try std.testing.expectEqual(@as(u32, 0x1111_2222), cpu.r[4]);
    try std.testing.expectEqual(@as(u32, 0x3333_4444), cpu.r[5]);
    try std.testing.expectEqual(@as(u32, 0x5555_6666), cpu.r[6]);
    try std.testing.expectEqual(@as(u32, 0x7777_8888), cpu.r[7]);
    try std.testing.expectEqual(@as(f64, 16.0), cpu.vfp.getD(2));
    try std.testing.expectEqual(@as(f64, 56.0), cpu.vfp.getD(3));
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 12.5))), (@as(u64, cpu.r[9]) << 32) | cpu.r[8]);

    // Verify Thumb-1 page-cached fetch, PC-relative literal load fast-path, and inline SoftTLB loads/stores
    cpu.r[15] = 0x1800;
    cpu.cpsr |= PsrFlags.T;
    cpu.r[0] = 0x2400;
    cpu.r[13] = 0x3400;
    std.mem.writeInt(u32, ram[0x1820..][0..4], 0xdead_beef, .little);
    // 0x1800: ldr r1, [pc, #28]     (0x4907) -> base = (0x1804 & ~3) + 28 = 0x1820 -> r1 = 0xdead_beef
    // 0x1802: str r1, [r0, #4]      (0x6041) -> [0x2404] = 0xdead_beef
    // 0x1804: ldrh r2, [r0, #6]     (0x88c2) -> r2 = 0xdead
    // 0x1806: ldrsh r3, [r0, r4]    (where r4=6 -> 0x5f03) -> r3 = 0xffff_dead
    // 0x1808: str r1, [sp, #8]      (0x9102) -> [0x3408] = 0xdead_beef
    // 0x180a: ldr r5, [sp, #8]      (0x9d02) -> r5 = 0xdead_beef
    cpu.r[4] = 6;
    const thumb_prog = [_]u16{
        0x4907,
        0x6041,
        0x88c2,
        0x5f03,
        0x9102,
        0x9d02,
    };
    for (thumb_prog, 0..) |inst, i| {
        std.mem.writeInt(u16, ram[0x1800 + i * 2 ..][0..2], inst, .little);
    }
    _ = cpu.runSteps(&bus, thumb_prog.len);
    try std.testing.expectEqual(@as(u32, 0xdead_beef), cpu.r[1]);
    try std.testing.expectEqual(@as(u32, 0xdead_beef), std.mem.readInt(u32, ram[0x2404..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 0x0000_dead), cpu.r[2]);
    try std.testing.expectEqual(@as(u32, 0xffff_dead), cpu.r[3]);
    try std.testing.expectEqual(@as(u32, 0xdead_beef), cpu.r[5]);

    // Verify ARM32 pre-decoded LDREXD/STREXD/LDREXH/STREXH and register-offset LDRH/STRH/LDRSB/LDRSH
    cpu.cpsr &= ~PsrFlags.T;
    cpu.r[15] = 0x1900;
    cpu.r[0] = 0x2500;
    cpu.r[1] = 8;
    std.mem.writeInt(u64, ram[0x2500..][0..8], 0x88776655_44332211, .little);
    // 0x1900: ldrexd r2, r3, [r0]       (0xe1b02f9f) -> r2=0x44332211, r3=0x88776655
    // 0x1904: add r2, r2, #1            (0xe2822001) -> r2=0x44332212
    // 0x1908: strexd r4, r2, r3, [r0]   (0xe1a04f92) -> [0x2500]=0x88776655_44332212, r4=0
    // 0x190c: strh r2, [r0, r1]         (0xe18020b1) -> [0x2508]=0x2212
    // 0x1910: ldrh r5, [r0, r1]         (0xe19050b1) -> r5=0x2212
    // 0x1914: ldrsh r6, [r0, r1]        (0xe19060f1) -> r6=0x0000_2212
    // 0x1918: ldrsb r7, [r0, r1]        (0xe19070d1) -> r7=0x0000_0012
    // 0x191c: ldr r8, [pc, #8]          (0xe59f8008) -> [0x192c] = 0xcafe_babe (hits code_vbase fast path)
    // 0x1920: str r8, [r0, #16]         (0xe5808010) -> [0x2510] = 0xcafe_babe (hits preserved data_w_vbase)
    // 0x1924: ldr r9, [r0, #16]         (0xe5909010) -> r9 = 0xcafe_babe (hits data_r_vbase)
    std.mem.writeInt(u32, ram[0x192c..][0..4], 0xcafe_babe, .little);
    const sync_reg_prog = [_]u32{
        0xe1b02f9f,
        0xe2822001,
        0xe1a04f92,
        0xe18020b1,
        0xe19050b1,
        0xe19060f1,
        0xe19070d1,
        0xe59f8008,
        0xe5808010,
        0xe5909010,
    };
    for (sync_reg_prog, 0..) |inst, i| {
        std.mem.writeInt(u32, ram[0x1900 + i * 4 ..][0..4], inst, .little);
    }
    try std.testing.expectEqual(ArmOp.ldrexd_al, @as(ArmOp, @enumFromInt(decodeArm32(sync_reg_prog[0]).op)));
    try std.testing.expectEqual(ArmOp.strexd_al, @as(ArmOp, @enumFromInt(decodeArm32(sync_reg_prog[2]).op)));
    try std.testing.expectEqual(ArmOp.strh_reg_al, @as(ArmOp, @enumFromInt(decodeArm32(sync_reg_prog[3]).op)));
    try std.testing.expectEqual(ArmOp.ldrh_reg_al, @as(ArmOp, @enumFromInt(decodeArm32(sync_reg_prog[4]).op)));
    try std.testing.expectEqual(ArmOp.ldrsh_reg_al, @as(ArmOp, @enumFromInt(decodeArm32(sync_reg_prog[5]).op)));
    try std.testing.expectEqual(ArmOp.ldrsb_reg_al, @as(ArmOp, @enumFromInt(decodeArm32(sync_reg_prog[6]).op)));
    try std.testing.expectEqual(ArmOp.ldr_lit_al, @as(ArmOp, @enumFromInt(decodeArm32(sync_reg_prog[7]).op)));

    _ = cpu.runSteps(&bus, sync_reg_prog.len);
    try std.testing.expectEqual(@as(u32, 0x4433_2212), cpu.r[2]);
    try std.testing.expectEqual(@as(u32, 0x8877_6655), cpu.r[3]);
    try std.testing.expectEqual(@as(u32, 0), cpu.r[4]);
    try std.testing.expectEqual(@as(u64, 0x88776655_44332212), std.mem.readInt(u64, ram[0x2500..][0..8], .little));
    try std.testing.expectEqual(@as(u32, 0x2212), cpu.r[5]);
    try std.testing.expectEqual(@as(u32, 0x2212), cpu.r[6]);
    try std.testing.expectEqual(@as(u32, 0x12), cpu.r[7]);
    try std.testing.expectEqual(@as(u32, 0xcafe_babe), cpu.r[8]);
    try std.testing.expectEqual(@as(u32, 0xcafe_babe), cpu.r[9]);

    // Verify newly pre-decoded ADC/SBC, shifted ALU, media (SBFX/BFI/BFC/RBIT/SXTAB), UDIV/SDIV, and subtracted-offset LSL loads/stores
    cpu.r[15] = 0x1a00;
    cpu.r[0] = 0x2600;
    cpu.r[1] = 2; // index for [r0, -r1, lsl #2] -> 0x2600 - 8 = 0x25f8
    cpu.r[2] = 100;
    cpu.r[3] = 25;
    cpu.cpsr |= PsrFlags.C;
    // 0x1a00: adc r4, r2, #10             (0xe2a2400a) -> 100 + 10 + 1 = 111
    // 0x1a04: sbc r5, r4, r3              (0xe0c45003) -> 111 - 25 - 0 = 86
    // 0x1a08: add r6, r5, r2, lsr #2      (0xe0856122) -> 86 + (100 >> 2) = 111
    // 0x1a0c: sbfx r7, r0, #8, #8         (0xe7a77450) -> signExtend8((0x2600 >> 8) & 0xff) = 0x26 = 38
    // 0x1a10: bfi r7, r3, #8, #8          (0xe7cf7413) -> r7 = (25 << 8) | 38 = 0x1926
    // 0x1a14: bfc r7, #8, #4              (0xe7cb741f) -> clear bits 8..11 of 0x1926 -> 0x1026
    // 0x1a18: rbit r8, r1                 (0xe6ff8f31) -> bitReverse(2) = 0x4000_0000
    // 0x1a1c: sxtab r9, r2, r0, ror #8    (0xe6a29470) -> 100 + signExtend8(0x26) = 138
    // 0x1a20: udiv r10, r2, r3            (0xe73a_f312) -> 100 / 25 = 4
    // 0x1a24: str r9, [r0, -r1, lsl #2]   (0xe7009101) -> [0x25f8] = 138
    // 0x1a28: ldr r11, [r0, -r1, lsl #2]  (0xe710b101) -> r11 = 138
    const ext_prog = [_]u32{
        0xe2a2400a,
        0xe0c45003,
        0xe0856122,
        0xe7a77450,
        0xe7cf7413,
        0xe7cb741f,
        0xe6ff8f31,
        0xe6a29470,
        0xe73af312,
        0xe7009101,
        0xe710b101,
    };
    for (ext_prog, 0..) |inst, i| {
        std.mem.writeInt(u32, ram[0x1a00 + i * 4 ..][0..4], inst, .little);
    }
    try std.testing.expectEqual(ArmOp.adc_imm_al, @as(ArmOp, @enumFromInt(decodeArm32(ext_prog[0]).op)));
    try std.testing.expectEqual(ArmOp.sbc_reg_al, @as(ArmOp, @enumFromInt(decodeArm32(ext_prog[1]).op)));
    try std.testing.expectEqual(ArmOp.add_lsr_reg_al, @as(ArmOp, @enumFromInt(decodeArm32(ext_prog[2]).op)));
    try std.testing.expectEqual(ArmOp.sbfx_al, @as(ArmOp, @enumFromInt(decodeArm32(ext_prog[3]).op)));
    try std.testing.expectEqual(ArmOp.bfi_al, @as(ArmOp, @enumFromInt(decodeArm32(ext_prog[4]).op)));
    try std.testing.expectEqual(ArmOp.bfc_al, @as(ArmOp, @enumFromInt(decodeArm32(ext_prog[5]).op)));
    try std.testing.expectEqual(ArmOp.rbit_al, @as(ArmOp, @enumFromInt(decodeArm32(ext_prog[6]).op)));
    try std.testing.expectEqual(ArmOp.sxtab_al, @as(ArmOp, @enumFromInt(decodeArm32(ext_prog[7]).op)));
    try std.testing.expectEqual(ArmOp.udiv_al, @as(ArmOp, @enumFromInt(decodeArm32(ext_prog[8]).op)));
    try std.testing.expectEqual(ArmOp.str_reg_sub_lsl_al, @as(ArmOp, @enumFromInt(decodeArm32(ext_prog[9]).op)));
    try std.testing.expectEqual(ArmOp.ldr_reg_sub_lsl_al, @as(ArmOp, @enumFromInt(decodeArm32(ext_prog[10]).op)));

    _ = cpu.runSteps(&bus, ext_prog.len);
    try std.testing.expectEqual(@as(u32, 111), cpu.r[4]);
    try std.testing.expectEqual(@as(u32, 86), cpu.r[5]);
    try std.testing.expectEqual(@as(u32, 111), cpu.r[6]);
    try std.testing.expectEqual(@as(u32, 0x1026), cpu.r[7]);
    try std.testing.expectEqual(@as(u32, 0x4000_0000), cpu.r[8]);
    try std.testing.expectEqual(@as(u32, 138), cpu.r[9]);
    try std.testing.expectEqual(@as(u32, 4), cpu.r[10]);
    try std.testing.expectEqual(@as(u32, 138), cpu.r[11]);
}
