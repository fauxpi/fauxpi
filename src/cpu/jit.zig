const std = @import("std");
const builtin = @import("builtin");
const mmu_mod = @import("mmu.zig");
const aarch64_mod = @import("aarch64.zig");
const arm1176_mod = @import("arm1176.zig");

pub const is_x86_64_linux = builtin.cpu.arch == .x86_64 and builtin.os.tag == .linux;

/// Native x86-64 JIT trace entry point using System V AMD64 ABI (`callconv(.c)`):
/// - `cpu` (%rdi -> %rbx): `*CpuType`
/// - `bus` (%rsi -> %r12): `*Bus`
/// - `ram_ptr` (%rdx -> %r13): `[*]u8`
/// - `soft_tlb_ptr` (%rcx -> %rbp): `*anyopaque` (`&cpu.mmu.soft_tlb64[priv][0]` or `&cpu.mmu.soft_tlb32[priv][0]`)
/// - `max_insts` (%r8 -> %r14): `usize`
/// - `sp_ptr` (%r9 -> pushed at `0(%rsp)`): `*u64` (`&cpu.sp_el[spIndex(cpu)]` for AArch64; unused for ARM32)
/// Returns executed guest instruction count (`>= 1`) in `%rax`.
pub const JitFn = *const fn (
    cpu: *anyopaque,
    bus: *anyopaque,
    ram_ptr: [*]u8,
    soft_tlb_ptr: *anyopaque,
    max_insts: usize,
    sp_ptr: *anyopaque,
) callconv(.c) usize;

var global_code_pools: [4]?[*]align(4096) u8 = @splat(null);
var global_pool_lock: std.atomic.Value(u32) = .init(0);

pub const JitCodeBuffer = struct {
    pub const capacity: usize = 8 * 1024 * 1024;

    used: usize = 0,
    loop_counts: [256]u8 = @splat(0),

    pub fn ensurePool(core_id: u2) ?[*]align(4096) u8 {
        if (!is_x86_64_linux) return null;
        if (@atomicLoad(?[*]align(4096) u8, &global_code_pools[core_id], .acquire)) |p| return p;
        while (global_pool_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
        defer global_pool_lock.store(0, .release);
        if (global_code_pools[core_id]) |p| return p;
        const slice = std.posix.mmap(
            null,
            capacity,
            .{ .READ = true, .WRITE = true, .EXEC = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        ) catch return null;
        @atomicStore(?[*]align(4096) u8, &global_code_pools[core_id], slice.ptr, .release);
        return slice.ptr;
    }

    pub fn reset(self: *JitCodeBuffer) void {
        self.used = 0;
        self.loop_counts = @splat(0);
    }

    pub fn allocCode(self: *JitCodeBuffer, core_id: u2, code: []const u8) ?JitFn {
        const base = ensurePool(core_id) orelse return null;
        const aligned_used = (self.used + 15) & ~@as(usize, 15);
        if (aligned_used + code.len > capacity) return null;
        @memcpy(base[aligned_used .. aligned_used + code.len], code);
        self.used = aligned_used + code.len;
        return @ptrCast(base + aligned_used);
    }
};

pub const Reg = enum(u4) {
    rax = 0,
    rcx = 1,
    rdx = 2,
    rbx = 3,
    rsp = 4,
    rbp = 5,
    rsi = 6,
    rdi = 7,
    r8 = 8,
    r9 = 9,
    r10 = 10,
    r11 = 11,
    r12 = 12,
    r13 = 13,
    r14 = 14,
    r15 = 15,

    pub inline fn low3(self: Reg) u8 {
        return @intCast(@intFromEnum(self) & 7);
    }

    pub inline fn isExt(self: Reg) bool {
        return (@intFromEnum(self) & 8) != 0;
    }
};

pub const Cond = enum(u4) {
    o = 0x0,
    no = 0x1,
    b = 0x2, // c / nae (unsigned <)
    ae = 0x3, // nc / nb (unsigned >=)
    e = 0x4, // z
    ne = 0x5, // nz
    be = 0x6, // na (unsigned <=)
    a = 0x7, // nbe (unsigned >)
    s = 0x8,
    ns = 0x9,
    l = 0xc, // signed <
    ge = 0xd, // signed >=
    le = 0xe, // signed <=
    g = 0xf, // signed >
};

const Fixup = struct {
    disp_offset: u32,
    label: u16,
};

pub const X64Emitter = struct {
    buf: [16384]u8 = undefined,
    len: usize = 0,
    labels: [512]i32 = @splat(-1),
    label_count: u16 = 0,
    fixups: [1024]Fixup = undefined,
    fixup_count: usize = 0,

    pub fn newLabel(self: *X64Emitter) u16 {
        const id = self.label_count;
        self.label_count += 1;
        self.labels[id] = -1;
        return id;
    }

    pub fn bindLabel(self: *X64Emitter, label: u16) void {
        self.labels[label] = @intCast(self.len);
    }

    pub fn resolveFixups(self: *X64Emitter) bool {
        for (self.fixups[0..self.fixup_count]) |f| {
            const target = self.labels[f.label];
            if (target < 0) return false;
            const next_ip: i32 = @intCast(f.disp_offset + 4);
            const rel: i32 = target - next_ip;
            std.mem.writeInt(i32, self.buf[f.disp_offset..][0..4], rel, .little);
        }
        return true;
    }

    pub inline fn emit8(self: *X64Emitter, b: u8) void {
        self.buf[self.len] = b;
        self.len += 1;
    }

    pub inline fn emit32(self: *X64Emitter, v: u32) void {
        std.mem.writeInt(u32, self.buf[self.len..][0..4], v, .little);
        self.len += 4;
    }

    pub inline fn emitI32(self: *X64Emitter, v: i32) void {
        std.mem.writeInt(i32, self.buf[self.len..][0..4], v, .little);
        self.len += 4;
    }

    pub inline fn emit64(self: *X64Emitter, v: u64) void {
        std.mem.writeInt(u64, self.buf[self.len..][0..8], v, .little);
        self.len += 8;
    }

    inline fn emitRex(self: *X64Emitter, w: bool, r: bool, x: bool, b: bool, force: bool) void {
        var rex: u8 = 0x40;
        if (w) rex |= 0x08;
        if (r) rex |= 0x04;
        if (x) rex |= 0x02;
        if (b) rex |= 0x01;
        if (rex != 0x40 or force) self.emit8(rex);
    }

    inline fn emitModRmReg(self: *X64Emitter, reg_field: u8, rm_field: u8) void {
        self.emit8(0xc0 | ((reg_field & 7) << 3) | (rm_field & 7));
    }

    fn emitModRmMem(self: *X64Emitter, reg_field: u8, base: Reg, disp: i32) void {
        const base_low = base.low3();
        if (disp == 0 and base_low != 5) {
            self.emit8(((reg_field & 7) << 3) | base_low);
            if (base_low == 4) self.emit8(0x24);
        } else if (disp >= -128 and disp <= 127) {
            self.emit8(0x40 | ((reg_field & 7) << 3) | base_low);
            if (base_low == 4) self.emit8(0x24);
            self.emit8(@bitCast(@as(i8, @intCast(disp))));
        } else {
            self.emit8(0x80 | ((reg_field & 7) << 3) | base_low);
            if (base_low == 4) self.emit8(0x24);
            self.emitI32(disp);
        }
    }

    fn emitModRmSib(self: *X64Emitter, reg_field: u8, base: Reg, index: Reg, scale_shift: u2, disp: i32) void {
        const base_low = base.low3();
        const index_low = index.low3();
        std.debug.assert(index != .rsp);
        const sib: u8 = (@as(u8, scale_shift) << 6) | (index_low << 3) | base_low;
        if (disp == 0 and base_low != 5) {
            self.emit8(((reg_field & 7) << 3) | 4);
            self.emit8(sib);
        } else if (disp >= -128 and disp <= 127) {
            self.emit8(0x40 | ((reg_field & 7) << 3) | 4);
            self.emit8(sib);
            self.emit8(@bitCast(@as(i8, @intCast(disp))));
        } else {
            self.emit8(0x80 | ((reg_field & 7) << 3) | 4);
            self.emit8(sib);
            self.emitI32(disp);
        }
    }

    pub fn pushReg(self: *X64Emitter, reg: Reg) void {
        if (reg.isExt()) self.emit8(0x41);
        self.emit8(0x50 + reg.low3());
    }

    pub fn popReg(self: *X64Emitter, reg: Reg) void {
        if (reg.isExt()) self.emit8(0x41);
        self.emit8(0x58 + reg.low3());
    }

    pub fn ret(self: *X64Emitter) void {
        self.emit8(0xc3);
    }

    pub fn emitPrologue(self: *X64Emitter) void {
        self.pushReg(.rbp);
        self.pushReg(.rbx);
        self.pushReg(.r12);
        self.pushReg(.r13);
        self.pushReg(.r14);
        self.pushReg(.r15);
        self.pushReg(.r9); // 0(%rsp) = sp_ptr; total 7 pushes + return addr = 64B (16B aligned)
        self.movRegReg(true, .rbx, .rdi); // cpu
        self.movRegReg(true, .r12, .rsi); // bus
        self.movRegReg(true, .r13, .rdx); // ram_ptr
        self.movRegReg(true, .rbp, .rcx); // soft_tlb_ptr
        self.movRegReg(true, .r14, .r8); // max_insts
        self.xorRegReg(false, .r15, .r15); // executed_insts = 0
    }

    pub fn emitEpilogue(self: *X64Emitter) void {
        self.movRegReg(true, .rax, .r15);
        self.popReg(.r9);
        self.popReg(.r15);
        self.popReg(.r14);
        self.popReg(.r13);
        self.popReg(.r12);
        self.popReg(.rbx);
        self.popReg(.rbp);
        self.ret();
    }

    pub fn movRegReg(self: *X64Emitter, is64: bool, dst: Reg, src: Reg) void {
        if (is64 and dst == src) return;
        self.emitRex(is64, src.isExt(), false, dst.isExt(), false);
        self.emit8(0x89);
        self.emitModRmReg(src.low3(), dst.low3());
    }

    pub fn movImm64(self: *X64Emitter, dst: Reg, imm: u64) void {
        if (imm == 0) {
            self.xorRegReg(false, dst, dst);
            return;
        }
        if (imm <= 0xffff_ffff) {
            if (dst.isExt()) self.emit8(0x41);
            self.emit8(0xb8 + dst.low3());
            self.emit32(@intCast(imm));
            return;
        }
        const simm: i64 = @bitCast(imm);
        if (simm >= -0x8000_0000 and simm <= 0x7fff_ffff) {
            self.emitRex(true, false, false, dst.isExt(), false);
            self.emit8(0xc7);
            self.emitModRmReg(0, dst.low3());
            self.emitI32(@intCast(simm));
            return;
        }
        self.emitRex(true, false, false, dst.isExt(), false);
        self.emit8(0xb8 + dst.low3());
        self.emit64(imm);
    }

    pub fn movImm32(self: *X64Emitter, dst: Reg, imm: u32) void {
        if (imm == 0) {
            self.xorRegReg(false, dst, dst);
            return;
        }
        if (dst.isExt()) self.emit8(0x41);
        self.emit8(0xb8 + dst.low3());
        self.emit32(imm);
    }

    pub fn movRegMem(self: *X64Emitter, is64: bool, dst: Reg, base: Reg, disp: i32) void {
        self.emitRex(is64, dst.isExt(), false, base.isExt(), false);
        self.emit8(0x8b);
        self.emitModRmMem(dst.low3(), base, disp);
    }

    pub fn movMemReg(self: *X64Emitter, is64: bool, base: Reg, disp: i32, src: Reg) void {
        self.emitRex(is64, src.isExt(), false, base.isExt(), false);
        self.emit8(0x89);
        self.emitModRmMem(src.low3(), base, disp);
    }

    pub fn addMemImm32(self: *X64Emitter, is64: bool, base: Reg, disp: i32, imm: i32) void {
        if (imm == 0) return;
        self.emitRex(is64, false, false, base.isExt(), false);
        if (imm >= -128 and imm <= 127) {
            self.emit8(0x83);
            self.emitModRmMem(0, base, disp);
            self.emit8(@bitCast(@as(i8, @intCast(imm))));
        } else {
            self.emit8(0x81);
            self.emitModRmMem(0, base, disp);
            self.emitI32(imm);
        }
    }

    pub fn testMemImm32(self: *X64Emitter, is64: bool, base: Reg, disp: i32, imm: u32) void {
        self.emitRex(is64, false, false, base.isExt(), false);
        self.emit8(0xf7);
        self.emitModRmMem(0, base, disp);
        self.emit32(imm);
    }

    pub fn movRegSib(self: *X64Emitter, is64: bool, dst: Reg, base: Reg, index: Reg, scale_shift: u2, disp: i32) void {
        self.emitRex(is64, dst.isExt(), index.isExt(), base.isExt(), false);
        self.emit8(0x8b);
        self.emitModRmSib(dst.low3(), base, index, scale_shift, disp);
    }

    pub fn movSibReg(self: *X64Emitter, is64: bool, base: Reg, index: Reg, scale_shift: u2, disp: i32, src: Reg) void {
        self.emitRex(is64, src.isExt(), index.isExt(), base.isExt(), false);
        self.emit8(0x89);
        self.emitModRmSib(src.low3(), base, index, scale_shift, disp);
    }

    pub fn cmpSibReg(self: *X64Emitter, is64: bool, base: Reg, index: Reg, scale_shift: u2, disp: i32, reg: Reg) void {
        self.emitRex(is64, reg.isExt(), index.isExt(), base.isExt(), false);
        self.emit8(0x39);
        self.emitModRmSib(reg.low3(), base, index, scale_shift, disp);
    }

    pub fn movzxSib8(self: *X64Emitter, dst: Reg, base: Reg, index: Reg, scale_shift: u2, disp: i32) void {
        self.emitRex(false, dst.isExt(), index.isExt(), base.isExt(), false);
        self.emit8(0x0f);
        self.emit8(0xb6);
        self.emitModRmSib(dst.low3(), base, index, scale_shift, disp);
    }

    pub fn movzxSib16(self: *X64Emitter, dst: Reg, base: Reg, index: Reg, scale_shift: u2, disp: i32) void {
        self.emitRex(false, dst.isExt(), index.isExt(), base.isExt(), false);
        self.emit8(0x0f);
        self.emit8(0xb7);
        self.emitModRmSib(dst.low3(), base, index, scale_shift, disp);
    }

    pub fn movsxSib8(self: *X64Emitter, is64: bool, dst: Reg, base: Reg, index: Reg, scale_shift: u2, disp: i32) void {
        self.emitRex(is64, dst.isExt(), index.isExt(), base.isExt(), false);
        self.emit8(0x0f);
        self.emit8(0xbe);
        self.emitModRmSib(dst.low3(), base, index, scale_shift, disp);
    }

    pub fn movsxSib16(self: *X64Emitter, is64: bool, dst: Reg, base: Reg, index: Reg, scale_shift: u2, disp: i32) void {
        self.emitRex(is64, dst.isExt(), index.isExt(), base.isExt(), false);
        self.emit8(0x0f);
        self.emit8(0xbf);
        self.emitModRmSib(dst.low3(), base, index, scale_shift, disp);
    }

    pub fn movsxdSib32(self: *X64Emitter, dst: Reg, base: Reg, index: Reg, scale_shift: u2, disp: i32) void {
        self.emitRex(true, dst.isExt(), index.isExt(), base.isExt(), false);
        self.emit8(0x63);
        self.emitModRmSib(dst.low3(), base, index, scale_shift, disp);
    }

    pub fn movSib8Reg(self: *X64Emitter, base: Reg, index: Reg, scale_shift: u2, disp: i32, src: Reg) void {
        const force_rex = (@intFromEnum(src) >= 4 and @intFromEnum(src) <= 7);
        self.emitRex(false, src.isExt(), index.isExt(), base.isExt(), force_rex);
        self.emit8(0x88);
        self.emitModRmSib(src.low3(), base, index, scale_shift, disp);
    }

    pub fn movSib16Reg(self: *X64Emitter, base: Reg, index: Reg, scale_shift: u2, disp: i32, src: Reg) void {
        self.emit8(0x66);
        self.emitRex(false, src.isExt(), index.isExt(), base.isExt(), false);
        self.emit8(0x89);
        self.emitModRmSib(src.low3(), base, index, scale_shift, disp);
    }

    pub fn leaRegMem(self: *X64Emitter, is64: bool, dst: Reg, base: Reg, disp: i32) void {
        self.emitRex(is64, dst.isExt(), false, base.isExt(), false);
        self.emit8(0x8d);
        self.emitModRmMem(dst.low3(), base, disp);
    }

    fn emitAluRegReg(self: *X64Emitter, opcode: u8, is64: bool, dst: Reg, src: Reg) void {
        self.emitRex(is64, src.isExt(), false, dst.isExt(), false);
        self.emit8(opcode);
        self.emitModRmReg(src.low3(), dst.low3());
    }

    fn emitAluRegImm(self: *X64Emitter, subop: u8, is64: bool, dst: Reg, imm: i32) void {
        self.emitRex(is64, false, false, dst.isExt(), false);
        if (imm >= -128 and imm <= 127) {
            self.emit8(0x83);
            self.emitModRmReg(subop, dst.low3());
            self.emit8(@bitCast(@as(i8, @intCast(imm))));
        } else {
            self.emit8(0x81);
            self.emitModRmReg(subop, dst.low3());
            self.emitI32(imm);
        }
    }

    pub fn addRegReg(self: *X64Emitter, is64: bool, dst: Reg, src: Reg) void {
        self.emitAluRegReg(0x01, is64, dst, src);
    }

    pub fn orRegReg(self: *X64Emitter, is64: bool, dst: Reg, src: Reg) void {
        self.emitAluRegReg(0x09, is64, dst, src);
    }

    pub fn andRegReg(self: *X64Emitter, is64: bool, dst: Reg, src: Reg) void {
        self.emitAluRegReg(0x21, is64, dst, src);
    }

    pub fn subRegReg(self: *X64Emitter, is64: bool, dst: Reg, src: Reg) void {
        self.emitAluRegReg(0x29, is64, dst, src);
    }

    pub fn xorRegReg(self: *X64Emitter, is64: bool, dst: Reg, src: Reg) void {
        self.emitAluRegReg(0x31, is64, dst, src);
    }

    pub fn cmpRegReg(self: *X64Emitter, is64: bool, lhs: Reg, rhs: Reg) void {
        self.emitAluRegReg(0x39, is64, lhs, rhs);
    }

    pub fn testRegReg(self: *X64Emitter, is64: bool, lhs: Reg, rhs: Reg) void {
        self.emitAluRegReg(0x85, is64, lhs, rhs);
    }

    pub fn addRegImm(self: *X64Emitter, is64: bool, dst: Reg, imm: i32) void {
        self.emitAluRegImm(0, is64, dst, imm);
    }

    pub fn orRegImm(self: *X64Emitter, is64: bool, dst: Reg, imm: i32) void {
        self.emitAluRegImm(1, is64, dst, imm);
    }

    pub fn andRegImm(self: *X64Emitter, is64: bool, dst: Reg, imm: i32) void {
        self.emitAluRegImm(4, is64, dst, imm);
    }

    pub fn subRegImm(self: *X64Emitter, is64: bool, dst: Reg, imm: i32) void {
        self.emitAluRegImm(5, is64, dst, imm);
    }

    pub fn xorRegImm(self: *X64Emitter, is64: bool, dst: Reg, imm: i32) void {
        self.emitAluRegImm(6, is64, dst, imm);
    }

    pub fn cmpRegImm(self: *X64Emitter, is64: bool, dst: Reg, imm: i32) void {
        self.emitAluRegImm(7, is64, dst, imm);
    }

    pub fn testRegImm32(self: *X64Emitter, is64: bool, reg: Reg, imm: u32) void {
        self.emitRex(is64, false, false, reg.isExt(), false);
        self.emit8(0xf7);
        self.emitModRmReg(0, reg.low3());
        self.emit32(imm);
    }

    pub fn notReg(self: *X64Emitter, is64: bool, dst: Reg) void {
        self.emitRex(is64, false, false, dst.isExt(), false);
        self.emit8(0xf7);
        self.emitModRmReg(2, dst.low3());
    }

    pub fn negReg(self: *X64Emitter, is64: bool, dst: Reg) void {
        self.emitRex(is64, false, false, dst.isExt(), false);
        self.emit8(0xf7);
        self.emitModRmReg(3, dst.low3());
    }

    pub fn imulRegReg(self: *X64Emitter, is64: bool, dst: Reg, src: Reg) void {
        self.emitRex(is64, dst.isExt(), false, src.isExt(), false);
        self.emit8(0x0f);
        self.emit8(0xaf);
        self.emitModRmReg(dst.low3(), src.low3());
    }

    fn emitShiftImm(self: *X64Emitter, subop: u8, is64: bool, dst: Reg, shift: u6) void {
        if (shift == 0) return;
        self.emitRex(is64, false, false, dst.isExt(), false);
        if (shift == 1) {
            self.emit8(0xd1);
            self.emitModRmReg(subop, dst.low3());
        } else {
            self.emit8(0xc1);
            self.emitModRmReg(subop, dst.low3());
            self.emit8(shift);
        }
    }

    fn emitShiftCl(self: *X64Emitter, subop: u8, is64: bool, dst: Reg) void {
        self.emitRex(is64, false, false, dst.isExt(), false);
        self.emit8(0xd3);
        self.emitModRmReg(subop, dst.low3());
    }

    pub fn shlImm(self: *X64Emitter, is64: bool, dst: Reg, shift: u6) void {
        self.emitShiftImm(4, is64, dst, shift);
    }

    pub fn shrImm(self: *X64Emitter, is64: bool, dst: Reg, shift: u6) void {
        self.emitShiftImm(5, is64, dst, shift);
    }

    pub fn sarImm(self: *X64Emitter, is64: bool, dst: Reg, shift: u6) void {
        self.emitShiftImm(7, is64, dst, shift);
    }

    pub fn rorImm(self: *X64Emitter, is64: bool, dst: Reg, shift: u6) void {
        self.emitShiftImm(1, is64, dst, shift);
    }

    pub fn shlCl(self: *X64Emitter, is64: bool, dst: Reg) void {
        self.emitShiftCl(4, is64, dst);
    }

    pub fn shrCl(self: *X64Emitter, is64: bool, dst: Reg) void {
        self.emitShiftCl(5, is64, dst);
    }

    pub fn sarCl(self: *X64Emitter, is64: bool, dst: Reg) void {
        self.emitShiftCl(7, is64, dst);
    }

    pub fn rorCl(self: *X64Emitter, is64: bool, dst: Reg) void {
        self.emitShiftCl(1, is64, dst);
    }

    pub fn movzx8(self: *X64Emitter, is64: bool, dst: Reg, src: Reg) void {
        const force_rex = (@intFromEnum(src) >= 4 and @intFromEnum(src) <= 7);
        self.emitRex(is64, dst.isExt(), false, src.isExt(), force_rex);
        self.emit8(0x0f);
        self.emit8(0xb6);
        self.emitModRmReg(dst.low3(), src.low3());
    }

    pub fn movzx16(self: *X64Emitter, is64: bool, dst: Reg, src: Reg) void {
        self.emitRex(is64, dst.isExt(), false, src.isExt(), false);
        self.emit8(0x0f);
        self.emit8(0xb7);
        self.emitModRmReg(dst.low3(), src.low3());
    }

    pub fn movsx8(self: *X64Emitter, is64: bool, dst: Reg, src: Reg) void {
        const force_rex = (@intFromEnum(src) >= 4 and @intFromEnum(src) <= 7);
        self.emitRex(is64, dst.isExt(), false, src.isExt(), force_rex);
        self.emit8(0x0f);
        self.emit8(0xbe);
        self.emitModRmReg(dst.low3(), src.low3());
    }

    pub fn movsx16(self: *X64Emitter, is64: bool, dst: Reg, src: Reg) void {
        self.emitRex(is64, dst.isExt(), false, src.isExt(), false);
        self.emit8(0x0f);
        self.emit8(0xbf);
        self.emitModRmReg(dst.low3(), src.low3());
    }

    pub fn movsxd32(self: *X64Emitter, dst: Reg, src: Reg) void {
        self.emitRex(true, dst.isExt(), false, src.isExt(), false);
        self.emit8(0x63);
        self.emitModRmReg(dst.low3(), src.low3());
    }

    pub fn setcc(self: *X64Emitter, cc: Cond, dst: Reg) void {
        const force_rex = (@intFromEnum(dst) >= 4 and @intFromEnum(dst) <= 7);
        self.emitRex(false, false, false, dst.isExt(), force_rex);
        self.emit8(0x0f);
        self.emit8(0x90 + @as(u8, @intFromEnum(cc)));
        self.emitModRmReg(0, dst.low3());
    }

    pub fn jmpLabel(self: *X64Emitter, label: u16) void {
        self.emit8(0xe9);
        self.fixups[self.fixup_count] = .{
            .disp_offset = @intCast(self.len),
            .label = label,
        };
        self.fixup_count += 1;
        self.emit32(0);
    }

    pub fn jccLabel(self: *X64Emitter, cc: Cond, label: u16) void {
        self.emit8(0x0f);
        self.emit8(0x80 + @as(u8, @intFromEnum(cc)));
        self.fixups[self.fixup_count] = .{
            .disp_offset = @intCast(self.len),
            .label = label,
        };
        self.fixup_count += 1;
        self.emit32(0);
    }

    pub fn callReg(self: *X64Emitter, reg: Reg) void {
        if (reg.isExt()) self.emit8(0x41);
        self.emit8(0xff);
        self.emitModRmReg(2, reg.low3());
    }

    pub fn bswap(self: *X64Emitter, is64: bool, dst: Reg) void {
        self.emitRex(is64, false, false, dst.isExt(), false);
        self.emit8(0x0f);
        self.emit8(0xc8 + dst.low3());
    }
};

// ============================================================================
// SoftTLB Offset Constants
// ============================================================================

const SoftTlb64 = mmu_mod.Mmu.SoftTlbSlot64;
const off_tlb64_read_vpage: i32 = @intCast(@offsetOf(SoftTlb64, "r_vbase"));
const off_tlb64_write_vpage: i32 = @intCast(@offsetOf(SoftTlb64, "w_vbase"));
const off_tlb64_pbase: i32 = @intCast(@offsetOf(SoftTlb64, "pbase"));

const SoftTlb32 = mmu_mod.Mmu.SoftTlbSlot32;
const off_tlb32_read_vpage: i32 = @intCast(@offsetOf(SoftTlb32, "r_vbase"));
const off_tlb32_write_vpage: i32 = @intCast(@offsetOf(SoftTlb32, "w_vbase"));
const off_tlb32_pbase: i32 = @intCast(@offsetOf(SoftTlb32, "pbase"));

pub const SlowLoadResult64 = extern struct {
    val: u64,
    abort: u64,
};

const ExitStub = struct {
    label: u16,
    pc_delta: i32,
};

// ============================================================================
// Flag & Condition Helpers
// ============================================================================

fn emitUpdateNZCV_AddSub(em: *X64Emitter, state_disp: i32, is_sub: bool) void {
    // Capture all 4 condition flags before any shift/or modifies EFLAGS!
    em.setcc(.s, .rax); // N
    em.setcc(.e, .rcx); // Z
    em.setcc(if (is_sub) .ae else .b, .rdx); // C: ARM C = !borrow (ae) for SUB, carry (b) for ADD
    em.setcc(.o, .r8); // V

    em.movzx8(false, .rax, .rax);
    em.movzx8(false, .rcx, .rcx);
    em.movzx8(false, .rdx, .rdx);
    em.movzx8(false, .r8, .r8);

    em.shlImm(false, .rax, 31);
    em.shlImm(false, .rcx, 30);
    em.shlImm(false, .rdx, 29);
    em.shlImm(false, .r8, 28);

    em.orRegReg(false, .rax, .rcx);
    em.orRegReg(false, .rax, .rdx);
    em.orRegReg(false, .rax, .r8);

    em.movRegMem(false, .rcx, .rbx, state_disp);
    em.andRegImm(false, .rcx, 0x0fff_ffff);
    em.orRegReg(false, .rcx, .rax);
    em.movMemReg(false, .rbx, state_disp, .rcx);
}

fn emitUpdateNZ_Logic(em: *X64Emitter, state_disp: i32, preserve_cv: bool) void {
    em.setcc(.s, .rax);
    em.setcc(.e, .rcx);
    em.movzx8(false, .rax, .rax);
    em.movzx8(false, .rcx, .rcx);
    em.shlImm(false, .rax, 31);
    em.shlImm(false, .rcx, 30);
    em.orRegReg(false, .rax, .rcx);

    em.movRegMem(false, .rcx, .rbx, state_disp);
    em.andRegImm(false, .rcx, if (preserve_cv) 0x3fff_ffff else 0x0fff_ffff);
    em.orRegReg(false, .rcx, .rax);
    em.movMemReg(false, .rbx, state_disp, .rcx);
}

fn emitArmCondBranch(em: *X64Emitter, state_disp: i32, cond: u4, jump_if_true: bool, target_label: u16) void {
    const base_cond: u3 = @intCast(cond >> 1);
    const invert = ((cond & 1) != 0) != (!jump_if_true);
    switch (base_cond) {
        0 => { // EQ / NE: Z == 1
            em.testMemImm32(false, .rbx, state_disp, 1 << 30);
            em.jccLabel(if (invert) .e else .ne, target_label);
        },
        1 => { // CS / CC: C == 1
            em.testMemImm32(false, .rbx, state_disp, 1 << 29);
            em.jccLabel(if (invert) .e else .ne, target_label);
        },
        2 => { // MI / PL: N == 1
            em.testMemImm32(false, .rbx, state_disp, 1 << 31);
            em.jccLabel(if (invert) .e else .ne, target_label);
        },
        3 => { // VS / VC: V == 1
            em.testMemImm32(false, .rbx, state_disp, 1 << 28);
            em.jccLabel(if (invert) .e else .ne, target_label);
        },
        4 => { // HI / LS: C == 1 and Z == 0 -> (state & 0x6000_0000) == 0x2000_0000
            em.movRegMem(false, .rax, .rbx, state_disp);
            em.andRegImm(false, .rax, 0x6000_0000);
            em.cmpRegImm(false, .rax, 0x2000_0000);
            em.jccLabel(if (invert) .ne else .e, target_label);
        },
        5 => { // GE / LT: N == V
            em.movRegMem(false, .rax, .rbx, state_disp);
            em.movRegReg(false, .rcx, .rax);
            em.shrImm(false, .rax, 3); // N at bit 28
            em.xorRegReg(false, .rax, .rcx);
            em.testRegImm32(false, .rax, 1 << 28); // ZF=1 iff N==V
            em.jccLabel(if (invert) .ne else .e, target_label);
        },
        6 => { // GT / LE: Z == 0 and N == V
            em.movRegMem(false, .rax, .rbx, state_disp);
            em.movRegReg(false, .rcx, .rax);
            em.shrImm(false, .rax, 3); // N at bit 28
            em.xorRegReg(false, .rax, .rcx); // bit 28 is N^V
            em.shrImm(false, .rcx, 2); // Z at bit 28
            em.orRegReg(false, .rax, .rcx); // bit 28 is Z | (N^V)
            em.testRegImm32(false, .rax, 1 << 28); // ZF=1 iff Z==0 and N==V
            em.jccLabel(if (invert) .ne else .e, target_label);
        },
        7 => { // AL
            if (!invert) em.jmpLabel(target_label);
        },
    }
}

// ============================================================================
// AArch64 Generic JIT Backend
// ============================================================================

pub fn A64Jit(comptime CpuType: type, comptime Bus: type) type {
    const A64 = aarch64_mod.Aarch64Exec(CpuType, Bus);
    const A64Op = A64.A64Op;
    const off_x: i32 = @intCast(@offsetOf(CpuType, "x"));
    const off_pc64: i32 = @intCast(@offsetOf(CpuType, "pc64"));
    const off_pstate: i32 = @intCast(@offsetOf(CpuType, "pstate"));
    const off_tpidr_el0: i32 = @intCast(@offsetOf(CpuType, "mmu") + @offsetOf(mmu_mod.Mmu, "tpidr_el0"));

    return struct {
        inline fn a64RegOff(reg: u5) i32 {
            return off_x + @as(i32, reg) * 8;
        }

        fn emitLoadA64Reg(em: *X64Emitter, is64: bool, dst: Reg, reg: u8, use_sp: bool) void {
            const r: u5 = @truncate(reg);
            if (r == 31) {
                if (use_sp) {
                    em.movRegMem(true, dst, .rsp, 0);
                    em.movRegMem(is64, dst, dst, 0);
                } else {
                    em.xorRegReg(false, dst, dst);
                }
            } else {
                em.movRegMem(is64, dst, .rbx, a64RegOff(r));
            }
        }

        fn emitStoreA64Reg(em: *X64Emitter, reg: u8, src: Reg, use_sp: bool, scratch: Reg) void {
            const r: u5 = @truncate(reg);
            if (r == 31) {
                if (use_sp) {
                    em.movRegMem(true, scratch, .rsp, 0);
                    em.movMemReg(true, scratch, 0, src);
                }
            } else {
                em.movMemReg(true, .rbx, a64RegOff(r), src);
            }
        }

        fn emitShiftA64Val(em: *X64Emitter, is64: bool, val_reg: Reg, shift_type: u2, shift_amt: u6) void {
            if (shift_amt == 0) return;
            switch (shift_type) {
                0 => em.shlImm(is64, val_reg, shift_amt),
                1 => em.shrImm(is64, val_reg, shift_amt),
                2 => em.sarImm(is64, val_reg, shift_amt),
                3 => em.rorImm(is64, val_reg, shift_amt),
            }
        }

        fn emitExtendA64Val(em: *X64Emitter, is64: bool, dst: Reg, src: Reg, option: u3, shift: u3) void {
            switch (option) {
                0 => em.movzx8(is64, dst, src), // UXTB
                1 => em.movzx16(is64, dst, src), // UXTH
                2 => em.movRegReg(false, dst, src), // UXTW (32-bit mov zero-extends to 64-bit)
                3 => em.movRegReg(is64, dst, src), // UXTX
                4 => em.movsx8(is64, dst, src), // SXTB
                5 => em.movsx16(is64, dst, src), // SXTH
                6 => { // SXTW
                    if (is64) em.movsxd32(dst, src) else em.movRegReg(false, dst, src);
                },
                7 => em.movRegReg(is64, dst, src), // SXTX
            }
            if (shift != 0) {
                em.shlImm(is64, dst, shift);
            }
        }

        pub fn jitSlowLoad64(
            cpu_opaque: *anyopaque,
            bus_opaque: *anyopaque,
            vaddr: u64,
            pc_and_wb: u64,
            size_and_sign: u32,
        ) callconv(.c) SlowLoadResult64 {
            const cpu: *CpuType = @ptrCast(@alignCast(cpu_opaque));
            const bus: *Bus = @ptrCast(@alignCast(bus_opaque));
            const pc_page_off: u32 = @truncate(pc_and_wb);
            const cur_pc = cpu.pc64 +% pc_page_off;
            const size: u4 = @intCast(size_and_sign & 0xf);
            const signed = (size_and_sign & 0x10) != 0;
            const is64 = (size_and_sign & 0x20) != 0;
            const do_wb = (size_and_sign & 0x40) != 0;
            const rn: u5 = @intCast((size_and_sign >> 8) & 0x1f);
            const wb_disp: i32 = @bitCast(@as(u32, @truncate(pc_and_wb >> 32)));

            const raw: u64 = switch (size) {
                1 => A64.readData8(cpu, bus, vaddr) catch {
                    A64.handleAbort64(cpu, cur_pc);
                    return .{ .val = 0, .abort = 1 };
                },
                2 => A64.readData16(cpu, bus, vaddr) catch {
                    A64.handleAbort64(cpu, cur_pc);
                    return .{ .val = 0, .abort = 1 };
                },
                4 => A64.readData32(cpu, bus, vaddr) catch {
                    A64.handleAbort64(cpu, cur_pc);
                    return .{ .val = 0, .abort = 1 };
                },
                8 => A64.readData64(cpu, bus, vaddr) catch {
                    A64.handleAbort64(cpu, cur_pc);
                    return .{ .val = 0, .abort = 1 };
                },
                else => unreachable,
            };

            if (do_wb) {
                A64.setXOrSp(cpu, rn, vaddr +% @as(u64, @bitCast(@as(i64, wb_disp))));
            }

            var val = raw;
            if (signed) {
                const sext64: u64 = switch (size) {
                    1 => @bitCast(@as(i64, @as(i8, @bitCast(@as(u8, @truncate(raw)))))),
                    2 => @bitCast(@as(i64, @as(i16, @bitCast(@as(u16, @truncate(raw)))))),
                    4 => @bitCast(@as(i64, @as(i32, @bitCast(@as(u32, @truncate(raw)))))),
                    else => raw,
                };
                val = if (is64) sext64 else @as(u32, @truncate(sext64));
            }
            return .{ .val = val, .abort = 0 };
        }

        pub fn jitSlowStore64(
            cpu_opaque: *anyopaque,
            bus_opaque: *anyopaque,
            vaddr: u64,
            val: u64,
            pc_and_wb: u64,
            size_and_rn: u32,
        ) callconv(.c) u64 {
            const cpu: *CpuType = @ptrCast(@alignCast(cpu_opaque));
            const bus: *Bus = @ptrCast(@alignCast(bus_opaque));
            const pc_page_off: u32 = @truncate(pc_and_wb);
            const cur_pc = cpu.pc64 +% pc_page_off;
            const size: u4 = @intCast(size_and_rn & 0xf);
            const do_wb = (size_and_rn & 0x10) != 0;
            const rn: u5 = @intCast((size_and_rn >> 8) & 0x1f);
            const wb_disp: i32 = @bitCast(@as(u32, @truncate(pc_and_wb >> 32)));
            switch (size) {
                1 => A64.writeData8(cpu, bus, vaddr, @truncate(val)) catch {
                    A64.handleAbort64(cpu, cur_pc);
                    return 1;
                },
                2 => A64.writeData16(cpu, bus, vaddr, @truncate(val)) catch {
                    A64.handleAbort64(cpu, cur_pc);
                    return 1;
                },
                4 => A64.writeData32(cpu, bus, vaddr, @truncate(val)) catch {
                    A64.handleAbort64(cpu, cur_pc);
                    return 1;
                },
                8 => A64.writeData64(cpu, bus, vaddr, val) catch {
                    A64.handleAbort64(cpu, cur_pc);
                    return 1;
                },
                else => unreachable,
            }
            if (do_wb) {
                A64.setXOrSp(cpu, rn, vaddr +% @as(u64, @bitCast(@as(i64, wb_disp))));
            }
            const priv: u1 = @intFromBool(A64.currentEl(cpu) != 0);
            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((vaddr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
            if ((vaddr & ~@as(u64, 0xfff)) != dslot.w_vbase) {
                cpu.pc64 = cur_pc +% 4;
                if (A64.checkInterrupts64(cpu, bus)) return 2;
                cpu.pc64 = cur_pc -% pc_page_off;
            }
            return 0;
        }

        pub fn jitSlowLoadPair64(
            cpu_opaque: *anyopaque,
            bus_opaque: *anyopaque,
            vaddr: u64,
            pc_page_off: u32,
            packed_info: u64,
        ) callconv(.c) u64 {
            const cpu: *CpuType = @ptrCast(@alignCast(cpu_opaque));
            const bus: *Bus = @ptrCast(@alignCast(bus_opaque));
            const cur_pc = cpu.pc64 +% pc_page_off;
            const rt: u5 = @intCast(packed_info & 0x1f);
            const rt2: u5 = @intCast((packed_info >> 5) & 0x1f);
            const rn: u5 = @intCast((packed_info >> 10) & 0x1f);
            const is64 = ((packed_info >> 15) & 1) != 0;
            const do_wb = ((packed_info >> 16) & 1) != 0;
            const wb_addr = vaddr +% @as(u64, @bitCast(@as(i64, @as(i32, @bitCast(@as(u32, @truncate(packed_info >> 32)))))));

            if (is64) {
                const pair = A64.readData128(cpu, bus, vaddr) catch {
                    A64.handleAbort64(cpu, cur_pc);
                    return 1;
                };
                if (rt != 31) cpu.x[rt] = @truncate(pair);
                if (rt2 != 31) cpu.x[rt2] = @truncate(pair >> 64);
            } else {
                const v1 = A64.readData32(cpu, bus, vaddr) catch {
                    A64.handleAbort64(cpu, cur_pc);
                    return 1;
                };
                const v2 = A64.readData32(cpu, bus, vaddr +% 4) catch {
                    A64.handleAbort64(cpu, cur_pc);
                    return 1;
                };
                if (rt != 31) cpu.x[rt] = v1;
                if (rt2 != 31) cpu.x[rt2] = v2;
            }
            if (do_wb) {
                A64.setXOrSp(cpu, rn, wb_addr);
            }
            return 0;
        }

        pub fn jitSlowStorePair64(
            cpu_opaque: *anyopaque,
            bus_opaque: *anyopaque,
            vaddr: u64,
            pc_page_off: u32,
            packed_info: u64,
        ) callconv(.c) u64 {
            const cpu: *CpuType = @ptrCast(@alignCast(cpu_opaque));
            const bus: *Bus = @ptrCast(@alignCast(bus_opaque));
            const cur_pc = cpu.pc64 +% pc_page_off;
            const rt: u5 = @intCast(packed_info & 0x1f);
            const rt2: u5 = @intCast((packed_info >> 5) & 0x1f);
            const rn: u5 = @intCast((packed_info >> 10) & 0x1f);
            const is64 = ((packed_info >> 15) & 1) != 0;
            const do_wb = ((packed_info >> 16) & 1) != 0;
            const wb_addr = vaddr +% @as(u64, @bitCast(@as(i64, @as(i32, @bitCast(@as(u32, @truncate(packed_info >> 32)))))));

            const v1: u64 = if (rt == 31) 0 else cpu.x[rt];
            const v2: u64 = if (rt2 == 31) 0 else cpu.x[rt2];
            if (is64) {
                A64.writeData128(cpu, bus, vaddr, @as(u128, v1) | (@as(u128, v2) << 64)) catch {
                    A64.handleAbort64(cpu, cur_pc);
                    return 1;
                };
            } else {
                A64.writeData32(cpu, bus, vaddr, @truncate(v1)) catch {
                    A64.handleAbort64(cpu, cur_pc);
                    return 1;
                };
                A64.writeData32(cpu, bus, vaddr +% 4, @truncate(v2)) catch {
                    A64.handleAbort64(cpu, cur_pc);
                    return 1;
                };
            }
            if (do_wb) {
                A64.setXOrSp(cpu, rn, wb_addr);
            }
            const priv: u1 = @intFromBool(A64.currentEl(cpu) != 0);
            const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((vaddr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
            if ((vaddr & ~@as(u64, 0xfff)) != dslot.w_vbase) {
                cpu.pc64 = cur_pc +% 4;
                if (A64.checkInterrupts64(cpu, bus)) return 2;
                cpu.pc64 = cur_pc -% pc_page_off;
            }
            return 0;
        }

        fn emitA64LoadAddr(
            em: *X64Emitter,
            rd: u8,
            rn: u8,
            size: u4,
            signed: bool,
            is64: bool,
            do_wb: bool,
            wb_disp: i32,
            pc_page_off: u32,
            epilogue_label: u16,
        ) void {
            const slow_label = em.newLabel();
            const done_label = em.newLabel();

            em.movRegReg(true, .rcx, .rdi);
            em.shrImm(true, .rcx, 7);
            em.andRegImm(false, .rcx, 0x1ffe0);

            const align_mask: i32 = switch (size) {
                1 => -4096,
                2 => -4095,
                4 => -4093,
                8 => -4089,
                else => unreachable,
            };
            em.movRegReg(true, .rax, .rdi);
            em.andRegImm(true, .rax, align_mask);
            em.cmpSibReg(true, .rbp, .rcx, 0, off_tlb64_read_vpage, .rax);
            em.jccLabel(.ne, slow_label);

            em.movRegSib(false, .rax, .rbp, .rcx, 0, off_tlb64_pbase);
            em.movRegReg(false, .rdx, .rdi);
            em.andRegImm(false, .rdx, 0xfff);
            em.orRegReg(true, .rax, .rdx);

            switch (size) {
                1 => {
                    if (signed) em.movsxSib8(is64, .rax, .r13, .rax, 0, 0) else em.movzxSib8(.rax, .r13, .rax, 0, 0);
                },
                2 => {
                    if (signed) em.movsxSib16(is64, .rax, .r13, .rax, 0, 0) else em.movzxSib16(.rax, .r13, .rax, 0, 0);
                },
                4 => {
                    if (signed and is64) em.movsxdSib32(.rax, .r13, .rax, 0, 0) else em.movRegSib(false, .rax, .r13, .rax, 0, 0);
                },
                8 => em.movRegSib(true, .rax, .r13, .rax, 0, 0),
                else => unreachable,
            }
            if (do_wb) {
                em.leaRegMem(true, .rcx, .rdi, wb_disp);
                emitStoreA64Reg(em, rn, .rcx, true, .rdx);
            }
            if ((rd & 0x1f) != 31) {
                emitStoreA64Reg(em, rd, .rax, false, .rdx);
            }
            em.jmpLabel(done_label);

            em.bindLabel(slow_label);
            const size_and_sign: u32 = @as(u32, size) |
                (if (signed) @as(u32, 0x10) else 0) |
                (if (is64) @as(u32, 0x20) else 0) |
                (if (do_wb) @as(u32, 0x40) | (@as(u32, rn & 0x1f) << 8) else 0);
            const pc_and_wb: u64 = @as(u64, pc_page_off) |
                (if (do_wb) (@as(u64, @as(u32, @bitCast(wb_disp))) << 32) else 0);
            em.movRegReg(true, .rdx, .rdi);
            em.movRegReg(true, .rdi, .rbx);
            em.movRegReg(true, .rsi, .r12);
            em.movImm64(.rcx, pc_and_wb);
            em.movImm32(.r8, size_and_sign);
            em.movImm64(.r11, @intFromPtr(&jitSlowLoad64));
            em.callReg(.r11);

            em.cmpRegImm(true, .rdx, 1);
            em.jccLabel(.e, epilogue_label);

            if ((rd & 0x1f) != 31) {
                emitStoreA64Reg(em, rd, .rax, false, .r8);
            }

            em.bindLabel(done_label);
        }

        fn emitA64StoreAddr(
            em: *X64Emitter,
            rd: u8,
            rn: u8,
            size: u4,
            do_wb: bool,
            wb_disp: i32,
            pc_page_off: u32,
            epilogue_label: u16,
        ) void {
            const slow_label = em.newLabel();
            const done_label = em.newLabel();

            em.movRegReg(true, .rcx, .rdi);
            em.shrImm(true, .rcx, 7);
            em.andRegImm(false, .rcx, 0x1ffe0);

            const align_mask: i32 = switch (size) {
                1 => -4096,
                2 => -4095,
                4 => -4093,
                8 => -4089,
                else => unreachable,
            };
            em.movRegReg(true, .rax, .rdi);
            em.andRegImm(true, .rax, align_mask);
            em.cmpSibReg(true, .rbp, .rcx, 0, off_tlb64_write_vpage, .rax);
            em.jccLabel(.ne, slow_label);

            em.movRegSib(false, .rax, .rbp, .rcx, 0, off_tlb64_pbase);
            em.movRegReg(false, .rdx, .rdi);
            em.andRegImm(false, .rdx, 0xfff);
            em.orRegReg(true, .rax, .rdx);

            emitLoadA64Reg(em, size == 8, .rcx, rd, false);
            switch (size) {
                1 => em.movSib8Reg(.r13, .rax, 0, 0, .rcx),
                2 => em.movSib16Reg(.r13, .rax, 0, 0, .rcx),
                4 => em.movSibReg(false, .r13, .rax, 0, 0, .rcx),
                8 => em.movSibReg(true, .r13, .rax, 0, 0, .rcx),
                else => unreachable,
            }
            if (do_wb) {
                em.leaRegMem(true, .rcx, .rdi, wb_disp);
                emitStoreA64Reg(em, rn, .rcx, true, .rdx);
            }
            em.jmpLabel(done_label);

            em.bindLabel(slow_label);
            const size_and_rn: u32 = @as(u32, size) |
                (if (do_wb) @as(u32, 0x10) | (@as(u32, rn & 0x1f) << 8) else 0);
            const pc_and_wb: u64 = @as(u64, pc_page_off) |
                (if (do_wb) (@as(u64, @as(u32, @bitCast(wb_disp))) << 32) else 0);
            em.movRegReg(true, .rdx, .rdi);
            emitLoadA64Reg(em, size == 8, .rcx, rd, false);
            em.movRegReg(true, .rdi, .rbx);
            em.movRegReg(true, .rsi, .r12);
            em.movImm64(.r8, pc_and_wb);
            em.movImm32(.r9, size_and_rn);
            em.movImm64(.r11, @intFromPtr(&jitSlowStore64));
            em.callReg(.r11);

            em.testRegReg(true, .rax, .rax);
            em.jccLabel(.ne, epilogue_label);

            em.bindLabel(done_label);
        }

        fn emitA64PairMem(
            em: *X64Emitter,
            rd: u8,
            rm: u8,
            rn: u8,
            is_load: bool,
            is64: bool,
            pre_disp: i32,
            do_wb: bool,
            wb_disp: i32,
            pc_page_off: u32,
            epilogue_label: u16,
        ) void {
            emitLoadA64Reg(em, true, .rdi, rn & 0x1f, true);
            if (pre_disp != 0) em.addRegImm(true, .rdi, pre_disp);

            const slow_label = em.newLabel();
            const done_label = em.newLabel();

            em.movRegReg(true, .rcx, .rdi);
            em.shrImm(true, .rcx, 7);
            em.andRegImm(false, .rcx, 0x1ffe0);

            const align_mask: i32 = if (is64) -4089 else -4093;
            em.movRegReg(true, .rax, .rdi);
            em.andRegImm(true, .rax, align_mask);
            em.cmpSibReg(true, .rbp, .rcx, 0, if (is_load) off_tlb64_read_vpage else off_tlb64_write_vpage, .rax);
            em.jccLabel(.ne, slow_label);

            em.movRegReg(false, .rdx, .rdi);
            em.andRegImm(false, .rdx, 0xfff);
            em.cmpRegImm(false, .rdx, if (is64) 4096 - 16 else 4096 - 8);
            em.jccLabel(.a, slow_label);

            em.movRegSib(false, .rax, .rbp, .rcx, 0, off_tlb64_pbase);
            em.orRegReg(true, .rax, .rdx);

            if (is_load) {
                em.movRegSib(is64, .rcx, .r13, .rax, 0, 0);
                em.movRegSib(is64, .rdx, .r13, .rax, 0, if (is64) 8 else 4);
                if (do_wb) {
                    em.leaRegMem(true, .r8, .rdi, wb_disp);
                    emitStoreA64Reg(em, rn & 0x1f, .r8, true, .r9);
                }
                if ((rd & 0x1f) != 31) emitStoreA64Reg(em, rd & 0x1f, .rcx, false, .r9);
                if ((rm & 0x1f) != 31) emitStoreA64Reg(em, rm & 0x1f, .rdx, false, .r9);
            } else {
                emitLoadA64Reg(em, is64, .rcx, rd & 0x1f, false);
                emitLoadA64Reg(em, is64, .rdx, rm & 0x1f, false);
                em.movSibReg(is64, .r13, .rax, 0, 0, .rcx);
                em.movSibReg(is64, .r13, .rax, 0, if (is64) 8 else 4, .rdx);
                if (do_wb) {
                    em.leaRegMem(true, .r8, .rdi, wb_disp);
                    emitStoreA64Reg(em, rn & 0x1f, .r8, true, .r9);
                }
            }
            em.jmpLabel(done_label);

            em.bindLabel(slow_label);
            const packed_low: u64 = @as(u64, rd & 0x1f) |
                (@as(u64, rm & 0x1f) << 5) |
                (@as(u64, rn & 0x1f) << 10) |
                (if (is64) @as(u64, 1) << 15 else 0) |
                (if (do_wb) @as(u64, 1) << 16 else 0);
            const packed_info: u64 = packed_low | (@as(u64, @as(u32, @bitCast(wb_disp))) << 32);

            em.movRegReg(true, .rdx, .rdi);
            em.movRegReg(true, .rdi, .rbx);
            em.movRegReg(true, .rsi, .r12);
            em.movImm32(.rcx, pc_page_off);
            em.movImm64(.r8, packed_info);
            em.movImm64(.r11, if (is_load) @intFromPtr(&jitSlowLoadPair64) else @intFromPtr(&jitSlowStorePair64));
            em.callReg(.r11);

            em.testRegReg(true, .rax, .rax);
            em.jccLabel(.ne, epilogue_label);

            em.bindLabel(done_label);
        }

        pub fn canCompileOp(op: A64Op) bool {
            return switch (op) {
                .nop,
                .adr,
                .adrp,
                .add_imm64,
                .sub_imm64,
                .adds_imm64,
                .subs_imm64,
                .add_imm32,
                .sub_imm32,
                .adds_imm32,
                .subs_imm32,
                .and_imm64,
                .orr_imm64,
                .eor_imm64,
                .ands_imm64,
                .and_imm32,
                .orr_imm32,
                .eor_imm32,
                .ands_imm32,
                .mov_wide,
                .movk64,
                .movk32,
                .ubfm_r,
                .ubfm_l,
                .bfm_r,
                .bfm_l,
                .sbfm64_r,
                .sbfm32_r,
                .extr64,
                .extr32,
                .orr_reg64,
                .orr_reg32,
                .orn_reg64,
                .orn_reg32,
                .add_reg64,
                .add_reg32,
                .adds_reg64,
                .adds_reg32,
                .sub_reg64,
                .sub_reg32,
                .subs_reg64,
                .subs_reg32,
                .and_reg64,
                .and_reg32,
                .bic_reg64,
                .bic_reg32,
                .eor_reg64,
                .eor_reg32,
                .ands_reg64,
                .ands_reg32,
                .add_lsl64,
                .add_lsl32,
                .sub_lsl64,
                .sub_lsl32,
                .orr_lsl64,
                .orr_lsr64,
                .add_ext64,
                .sub_ext64,
                .add_sub_ext,
                .dp_shift_reg,
                .lslv64,
                .lsrv64,
                .asrv64,
                .lslv32,
                .lsrv32,
                .asrv32,
                .clz64,
                .clz32,
                .rev64,
                .rev32,
                .csel,
                .ccmp,
                .madd_msub,
                .mrs_tpidr_el0,
                .ldr64_uimm,
                .str64_uimm,
                .ldr32_uimm,
                .str32_uimm,
                .ldrsw_uimm,
                .ldr16_uimm,
                .str16_uimm,
                .ldr8_uimm,
                .str8_uimm,
                .ldrsb64_uimm,
                .ldrsb32_uimm,
                .ldrsh64_uimm,
                .ldrsh32_uimm,
                .ldr_lit32,
                .ldr_lit64,
                .ldrsw_lit,
                .ldr64_pre,
                .ldr64_post,
                .str64_pre,
                .str64_post,
                .ldr32_pre,
                .ldr32_post,
                .str32_pre,
                .str32_post,
                .ldr64_reg_lsl,
                .str64_reg_lsl,
                .ldr32_reg_lsl,
                .str32_reg_lsl,
                .ldr8_reg_lsl,
                .str8_reg_lsl,
                .ldp64_off,
                .stp64_off,
                .ldp64_pre,
                .stp64_pre,
                .ldp64_post,
                .stp64_post,
                .ldp32_off,
                .stp32_off,
                .ldp32_pre,
                .stp32_pre,
                .ldp32_post,
                .stp32_post,
                .b_imm,
                .b_cond,
                .cbz64,
                .cbnz64,
                .cbz32,
                .cbnz32,
                .tbz,
                .tbnz,
                => true,
                else => false,
            };
        }

        inline fn isTerminator(op: A64Op) bool {
            return switch (op) {
                .b_imm, .bl_imm, .br_reg, .blr_reg, .ret => true,
                else => false,
            };
        }

        pub fn compileTrace(
            comptime SlotType: type,
            buf: *JitCodeBuffer,
            core_id: u2,
            code_page_ptr: [*]const u8,
            start_word: u10,
            requested_end_word: u16,
            out_end_word: *u16,
        ) ?JitFn {
            if (!is_x86_64_linux) return null;

            const max_window: u16 = 64;
            var decoded: [64]SlotType = undefined;
            var trace_len: u16 = 0;

            if (requested_end_word != 0) {
                if (requested_end_word <= start_word + 1 or requested_end_word - start_word > max_window or requested_end_word > 1024) return null;
                trace_len = requested_end_word - start_word;
                for (0..trace_len) |i| {
                    const w = start_word + @as(u16, @intCast(i));
                    const raw_inst = std.mem.readInt(u32, code_page_ptr[@as(usize, w) * 4 ..][0..4], .little);
                    const d = A64.decodeA64(SlotType, raw_inst);
                    const op: A64Op = @enumFromInt(d.op);
                    if (!canCompileOp(op)) return null;
                    decoded[i] = d;
                }
            } else {
                const limit_word: u16 = @min(@as(u16, 1024), @as(u16, start_word) + max_window);
                while (start_word + trace_len < limit_word) {
                    const w = start_word + trace_len;
                    const raw_inst = std.mem.readInt(u32, code_page_ptr[@as(usize, w) * 4 ..][0..4], .little);
                    const d = A64.decodeA64(SlotType, raw_inst);
                    const op: A64Op = @enumFromInt(d.op);
                    if (!canCompileOp(op)) break;
                    decoded[trace_len] = d;
                    trace_len += 1;
                    if (isTerminator(op)) {
                        if (op == .b_imm) {
                            const target_byte: i32 = @as(i32, @intCast(w)) * 4 + @as(i32, @bitCast(@as(u32, @truncate(d.imm))));
                            if (target_byte >= @as(i32, @intCast(w + 1)) * 4 and target_byte < @as(i32, @intCast(limit_word)) * 4 and (target_byte & 3) == 0) {
                                continue;
                            }
                        }
                        break;
                    }
                }
                if (trace_len < 2) return null;
            }

            const end_word: u16 = start_word + trace_len;
            out_end_word.* = end_word;

            var em = X64Emitter{};
            em.emitPrologue();

            const epilogue_label = em.newLabel();
            var inst_labels: [64]u16 = undefined;
            for (0..trace_len) |i| {
                inst_labels[i] = em.newLabel();
            }

            var exit_stubs: [128]ExitStub = undefined;
            var exit_stub_count: usize = 0;

            for (0..trace_len) |idx| {
                const w: u16 = start_word + @as(u16, @intCast(idx));
                const pc_page_off: u32 = @as(u32, w) * 4;
                const d = decoded[idx];
                const op: A64Op = @enumFromInt(d.op);

                em.bindLabel(inst_labels[idx]);
                em.addRegImm(true, .r15, 1);

                switch (op) {
                    .nop => {},

                    .adr => {
                        const disp: i64 = @as(i64, pc_page_off) +% @as(i64, @bitCast(d.imm));
                        em.movRegMem(true, .rax, .rbx, off_pc64);
                        if (disp >= -0x8000_0000 and disp <= 0x7fff_ffff) {
                            em.addRegImm(true, .rax, @intCast(disp));
                        } else {
                            em.movImm64(.rcx, @bitCast(disp));
                            em.addRegReg(true, .rax, .rcx);
                        }
                        emitStoreA64Reg(&em, d.rd, .rax, false, .rcx);
                    },
                    .adrp => {
                        const disp: i64 = @bitCast(d.imm);
                        em.movRegMem(true, .rax, .rbx, off_pc64);
                        if (disp >= -0x8000_0000 and disp <= 0x7fff_ffff) {
                            em.addRegImm(true, .rax, @intCast(disp));
                        } else {
                            em.movImm64(.rcx, d.imm);
                            em.addRegReg(true, .rax, .rcx);
                        }
                        emitStoreA64Reg(&em, d.rd, .rax, false, .rcx);
                    },

                    .add_imm64, .add_imm32, .sub_imm64, .sub_imm32 => {
                        const is64 = op == .add_imm64 or op == .sub_imm64;
                        const is_sub = op == .sub_imm64 or op == .sub_imm32;
                        emitLoadA64Reg(&em, is64, .rax, d.rn, true);
                        if (is_sub) {
                            em.subRegImm(is64, .rax, @intCast(@as(i64, @bitCast(d.imm))));
                        } else {
                            em.addRegImm(is64, .rax, @intCast(@as(i64, @bitCast(d.imm))));
                        }
                        emitStoreA64Reg(&em, d.rd, .rax, true, .rcx);
                    },

                    .adds_imm64, .adds_imm32, .subs_imm64, .subs_imm32 => {
                        const is64 = op == .adds_imm64 or op == .subs_imm64;
                        const is_sub = op == .subs_imm64 or op == .subs_imm32;
                        emitLoadA64Reg(&em, is64, .rax, d.rn, true);
                        if (is_sub) {
                            em.subRegImm(is64, .rax, @intCast(@as(i64, @bitCast(d.imm))));
                        } else {
                            em.addRegImm(is64, .rax, @intCast(@as(i64, @bitCast(d.imm))));
                        }
                        if (d.rd != 31) {
                            emitStoreA64Reg(&em, d.rd, .rax, false, .rcx);
                        }
                        emitUpdateNZCV_AddSub(&em, off_pstate, is_sub);
                    },

                    .and_imm64, .orr_imm64, .eor_imm64, .ands_imm64, .and_imm32, .orr_imm32, .eor_imm32, .ands_imm32 => {
                        const is64 = switch (op) {
                            .and_imm64, .orr_imm64, .eor_imm64, .ands_imm64 => true,
                            else => false,
                        };
                        emitLoadA64Reg(&em, is64, .rax, d.rn, false);
                        em.movImm64(.rcx, if (is64) d.imm else (d.imm & 0xffff_ffff));
                        switch (op) {
                            .and_imm64, .and_imm32 => {
                                em.andRegReg(is64, .rax, .rcx);
                                emitStoreA64Reg(&em, d.rd, .rax, true, .rdx);
                            },
                            .orr_imm64, .orr_imm32 => {
                                em.orRegReg(is64, .rax, .rcx);
                                emitStoreA64Reg(&em, d.rd, .rax, true, .rdx);
                            },
                            .eor_imm64, .eor_imm32 => {
                                em.xorRegReg(is64, .rax, .rcx);
                                emitStoreA64Reg(&em, d.rd, .rax, true, .rdx);
                            },
                            .ands_imm64, .ands_imm32 => {
                                em.andRegReg(is64, .rax, .rcx);
                                if (d.rd != 31) emitStoreA64Reg(&em, d.rd, .rax, false, .rdx);
                                emitUpdateNZ_Logic(&em, off_pstate, false);
                            },
                            else => unreachable,
                        }
                    },

                    .mov_wide => {
                        em.movImm64(.rax, d.imm);
                        emitStoreA64Reg(&em, d.rd, .rax, false, .rcx);
                    },
                    .movk64, .movk32 => {
                        const is64 = op == .movk64;
                        const sh: u6 = @truncate(d.rm);
                        const mask: u64 = ~(@as(u64, 0xffff) << sh);
                        emitLoadA64Reg(&em, is64, .rax, d.rd, false);
                        em.movImm64(.rcx, if (is64) mask else (mask & 0xffff_ffff));
                        em.andRegReg(is64, .rax, .rcx);
                        em.movImm64(.rcx, d.imm);
                        em.orRegReg(is64, .rax, .rcx);
                        emitStoreA64Reg(&em, d.rd, .rax, false, .rcx);
                    },

                    .ubfm_r => {
                        emitLoadA64Reg(&em, true, .rax, d.rn, false);
                        em.shrImm(true, .rax, @truncate(d.rm));
                        em.movImm64(.rcx, d.imm);
                        em.andRegReg(true, .rax, .rcx);
                        emitStoreA64Reg(&em, d.rd, .rax, false, .rcx);
                    },
                    .ubfm_l => {
                        emitLoadA64Reg(&em, true, .rax, d.rn, false);
                        em.shlImm(true, .rax, @truncate(d.rm));
                        em.movImm64(.rcx, d.imm);
                        em.andRegReg(true, .rax, .rcx);
                        emitStoreA64Reg(&em, d.rd, .rax, false, .rcx);
                    },
                    .bfm_r, .bfm_l => {
                        const is64 = (d.rm & 64) != 0;
                        const sh: u6 = @truncate(d.rm & 63);
                        emitLoadA64Reg(&em, is64, .rax, d.rn, false);
                        if (op == .bfm_r) em.shrImm(is64, .rax, sh) else em.shlImm(is64, .rax, sh);
                        em.movImm64(.rcx, d.imm);
                        em.andRegReg(is64, .rax, .rcx);
                        emitLoadA64Reg(&em, is64, .rdx, d.rd, false);
                        em.notReg(is64, .rcx);
                        em.andRegReg(is64, .rdx, .rcx);
                        em.orRegReg(is64, .rax, .rdx);
                        emitStoreA64Reg(&em, d.rd, .rax, false, .rcx);
                    },
                    .sbfm64_r, .sbfm32_r => {
                        const is64 = op == .sbfm64_r;
                        emitLoadA64Reg(&em, is64, .rax, d.rn, false);
                        em.shlImm(is64, .rax, @truncate(d.rm));
                        em.sarImm(is64, .rax, @truncate(d.imm));
                        emitStoreA64Reg(&em, d.rd, .rax, false, .rcx);
                    },
                    .extr64, .extr32 => {
                        const is64 = op == .extr64;
                        const sh: u6 = @truncate(d.imm);
                        emitLoadA64Reg(&em, is64, .rax, d.rm, false);
                        if (sh != 0) {
                            emitLoadA64Reg(&em, is64, .rcx, d.rn, false);
                            em.shrImm(is64, .rax, sh);
                            const lsh: u6 = @intCast((if (is64) @as(u7, 64) else @as(u7, 32)) - @as(u7, sh));
                            em.shlImm(is64, .rcx, lsh);
                            em.orRegReg(is64, .rax, .rcx);
                        }
                        emitStoreA64Reg(&em, d.rd, .rax, false, .rcx);
                    },

                    .orr_reg64, .orr_reg32, .orn_reg64, .orn_reg32, .and_reg64, .and_reg32, .bic_reg64, .bic_reg32, .eor_reg64, .eor_reg32, .ands_reg64, .ands_reg32 => {
                        const is64 = switch (op) {
                            .orr_reg64, .orn_reg64, .and_reg64, .bic_reg64, .eor_reg64, .ands_reg64 => true,
                            else => false,
                        };
                        const inv = op == .orn_reg64 or op == .orn_reg32 or op == .bic_reg64 or op == .bic_reg32;
                        const set_flags = op == .ands_reg64 or op == .ands_reg32;
                        emitLoadA64Reg(&em, is64, .rcx, d.rm, false);
                        if (inv) em.notReg(is64, .rcx);
                        if (d.rn == 31 and (op == .orr_reg64 or op == .orr_reg32 or op == .orn_reg64 or op == .orn_reg32)) {
                            emitStoreA64Reg(&em, d.rd, .rcx, false, .rdx);
                        } else {
                            emitLoadA64Reg(&em, is64, .rax, d.rn, false);
                            switch (op) {
                                .orr_reg64, .orr_reg32, .orn_reg64, .orn_reg32 => em.orRegReg(is64, .rax, .rcx),
                                .and_reg64, .and_reg32, .bic_reg64, .bic_reg32, .ands_reg64, .ands_reg32 => em.andRegReg(is64, .rax, .rcx),
                                .eor_reg64, .eor_reg32 => em.xorRegReg(is64, .rax, .rcx),
                                else => unreachable,
                            }
                            if (!set_flags or d.rd != 31) emitStoreA64Reg(&em, d.rd, .rax, false, .rdx);
                            if (set_flags) emitUpdateNZ_Logic(&em, off_pstate, false);
                        }
                    },

                    .add_reg64, .add_reg32, .adds_reg64, .adds_reg32, .sub_reg64, .sub_reg32, .subs_reg64, .subs_reg32 => {
                        const is64 = switch (op) {
                            .add_reg64, .adds_reg64, .sub_reg64, .subs_reg64 => true,
                            else => false,
                        };
                        const is_sub = switch (op) {
                            .sub_reg64, .sub_reg32, .subs_reg64, .subs_reg32 => true,
                            else => false,
                        };
                        const set_flags = switch (op) {
                            .adds_reg64, .adds_reg32, .subs_reg64, .subs_reg32 => true,
                            else => false,
                        };
                        emitLoadA64Reg(&em, is64, .rax, d.rn, false);
                        emitLoadA64Reg(&em, is64, .rcx, d.rm, false);
                        if (is_sub) em.subRegReg(is64, .rax, .rcx) else em.addRegReg(is64, .rax, .rcx);
                        if (!set_flags or d.rd != 31) emitStoreA64Reg(&em, d.rd, .rax, false, .rdx);
                        if (set_flags) emitUpdateNZCV_AddSub(&em, off_pstate, is_sub);
                    },

                    .add_lsl64, .add_lsl32, .sub_lsl64, .sub_lsl32, .orr_lsl64, .orr_lsr64 => {
                        const is64 = op != .add_lsl32 and op != .sub_lsl32;
                        emitLoadA64Reg(&em, is64, .rax, d.rn, false);
                        emitLoadA64Reg(&em, is64, .rcx, d.rm, false);
                        if (op == .orr_lsr64) {
                            em.shrImm(is64, .rcx, @truncate(d.imm));
                        } else {
                            em.shlImm(is64, .rcx, @truncate(d.imm));
                        }
                        switch (op) {
                            .add_lsl64, .add_lsl32 => em.addRegReg(is64, .rax, .rcx),
                            .sub_lsl64, .sub_lsl32 => em.subRegReg(is64, .rax, .rcx),
                            .orr_lsl64, .orr_lsr64 => em.orRegReg(is64, .rax, .rcx),
                            else => unreachable,
                        }
                        emitStoreA64Reg(&em, d.rd, .rax, false, .rdx);
                    },

                    .add_ext64, .sub_ext64 => {
                        const option: u3 = @truncate(d.imm >> 3);
                        const imm3: u3 = @truncate(d.imm);
                        emitLoadA64Reg(&em, true, .rax, d.rn, true);
                        emitLoadA64Reg(&em, true, .rcx, d.rm, false);
                        emitExtendA64Val(&em, true, .rcx, .rcx, option, imm3);
                        if (op == .sub_ext64) em.subRegReg(true, .rax, .rcx) else em.addRegReg(true, .rax, .rcx);
                        emitStoreA64Reg(&em, d.rd, .rax, true, .rdx);
                    },

                    .add_sub_ext => {
                        const imm3: u3 = @truncate(d.imm);
                        const option: u3 = @truncate(d.imm >> 3);
                        const s = ((d.imm >> 6) & 1) != 0;
                        const is_sub = ((d.imm >> 7) & 1) != 0;
                        const is64 = ((d.imm >> 8) & 1) != 0;
                        emitLoadA64Reg(&em, is64, .rax, d.rn, true);
                        emitLoadA64Reg(&em, is64, .rcx, d.rm, false);
                        emitExtendA64Val(&em, is64, .rcx, .rcx, option, imm3);
                        if (is_sub) em.subRegReg(is64, .rax, .rcx) else em.addRegReg(is64, .rax, .rcx);
                        if (!s or d.rd != 31) emitStoreA64Reg(&em, d.rd, .rax, !s, .rdx);
                        if (s) emitUpdateNZCV_AddSub(&em, off_pstate, is_sub);
                    },

                    .dp_shift_reg => {
                        const imm6: u6 = @truncate(d.imm);
                        const shift_type: u2 = @truncate(d.imm >> 6);
                        const op2: u4 = @truncate(d.imm >> 8);
                        const s: u1 = @truncate(d.imm >> 12);
                        const op0: u1 = @truncate(d.imm >> 13);
                        const is64 = ((d.imm >> 14) & 1) != 0;

                        emitLoadA64Reg(&em, is64, .rax, d.rn, false);
                        emitLoadA64Reg(&em, is64, .rcx, d.rm, false);
                        emitShiftA64Val(&em, is64, .rcx, shift_type, imm6);
                        if ((op2 & 0b1000) == 0) {
                            if ((op2 & 1) != 0) em.notReg(is64, .rcx);
                            const opc: u2 = (@as(u2, op0) << 1) | s;
                            switch (opc) {
                                0b00, 0b11 => em.andRegReg(is64, .rax, .rcx),
                                0b01 => em.orRegReg(is64, .rax, .rcx),
                                0b10 => em.xorRegReg(is64, .rax, .rcx),
                            }
                            if (opc != 0b11 or d.rd != 31) emitStoreA64Reg(&em, d.rd, .rax, false, .rdx);
                            if (opc == 0b11) emitUpdateNZ_Logic(&em, off_pstate, false);
                        } else {
                            const is_sub = op0 == 1;
                            const set_flags = s == 1;
                            if (is_sub) em.subRegReg(is64, .rax, .rcx) else em.addRegReg(is64, .rax, .rcx);
                            if (!set_flags or d.rd != 31) emitStoreA64Reg(&em, d.rd, .rax, false, .rdx);
                            if (set_flags) emitUpdateNZCV_AddSub(&em, off_pstate, is_sub);
                        }
                    },

                    .lslv64, .lsrv64, .asrv64, .lslv32, .lsrv32, .asrv32 => {
                        const is64 = op == .lslv64 or op == .lsrv64 or op == .asrv64;
                        emitLoadA64Reg(&em, is64, .rax, d.rn, false);
                        emitLoadA64Reg(&em, false, .rcx, d.rm, false);
                        switch (op) {
                            .lslv64, .lslv32 => em.shlCl(is64, .rax),
                            .lsrv64, .lsrv32 => em.shrCl(is64, .rax),
                            .asrv64, .asrv32 => em.sarCl(is64, .rax),
                            else => unreachable,
                        }
                        emitStoreA64Reg(&em, d.rd, .rax, false, .rdx);
                    },

                    .clz64, .clz32 => {
                        const is64 = op == .clz64;
                        const zero_label = em.newLabel();
                        const done_clz = em.newLabel();
                        emitLoadA64Reg(&em, is64, .rcx, d.rn, false);
                        em.testRegReg(is64, .rcx, .rcx);
                        em.jccLabel(.e, zero_label);
                        if (is64) em.emit8(0x48);
                        em.emit8(0x0f);
                        em.emit8(0xbd);
                        em.emitModRmReg(Reg.rax.low3(), Reg.rcx.low3());
                        em.xorRegImm(false, .rax, if (is64) 63 else 31);
                        em.jmpLabel(done_clz);
                        em.bindLabel(zero_label);
                        em.movImm32(.rax, if (is64) 64 else 32);
                        em.bindLabel(done_clz);
                        emitStoreA64Reg(&em, d.rd, .rax, false, .rdx);
                    },

                    .rev64, .rev32 => {
                        const is64 = op == .rev64;
                        emitLoadA64Reg(&em, is64, .rax, d.rn, false);
                        em.bswap(is64, .rax);
                        emitStoreA64Reg(&em, d.rd, .rax, false, .rcx);
                    },

                    .csel => {
                        const cond: u4 = @truncate(d.imm);
                        const op0 = ((d.imm >> 4) & 1) != 0;
                        const o2 = ((d.imm >> 5) & 1) != 0;
                        const is64 = ((d.imm >> 6) & 1) != 0;
                        const true_label = em.newLabel();
                        const done_label = em.newLabel();
                        emitArmCondBranch(&em, off_pstate, cond, true, true_label);
                        emitLoadA64Reg(&em, is64, .rax, d.rm, false);
                        if (op0) em.notReg(is64, .rax);
                        if (o2) em.addRegImm(is64, .rax, 1);
                        em.jmpLabel(done_label);
                        em.bindLabel(true_label);
                        emitLoadA64Reg(&em, is64, .rax, d.rn, false);
                        em.bindLabel(done_label);
                        emitStoreA64Reg(&em, d.rd, .rax, false, .rcx);
                    },

                    .ccmp => {
                        const cond: u4 = @truncate(d.imm);
                        const nzcv_imm: u32 = @as(u32, @truncate((d.imm >> 4) & 0xf)) << 28;
                        const is_imm = ((d.imm >> 8) & 1) != 0;
                        const is_sub = ((d.imm >> 9) & 1) != 0;
                        const is64 = ((d.imm >> 10) & 1) != 0;
                        const false_label = em.newLabel();
                        const done_ccmp = em.newLabel();
                        emitArmCondBranch(&em, off_pstate, cond, false, false_label);
                        emitLoadA64Reg(&em, is64, .rax, d.rn, false);
                        if (is_imm) {
                            if (is_sub) em.subRegImm(is64, .rax, @intCast(d.rm)) else em.addRegImm(is64, .rax, @intCast(d.rm));
                        } else {
                            emitLoadA64Reg(&em, is64, .rcx, d.rm, false);
                            if (is_sub) em.subRegReg(is64, .rax, .rcx) else em.addRegReg(is64, .rax, .rcx);
                        }
                        emitUpdateNZCV_AddSub(&em, off_pstate, is_sub);
                        em.jmpLabel(done_ccmp);
                        em.bindLabel(false_label);
                        em.movRegMem(false, .rax, .rbx, off_pstate);
                        em.andRegImm(false, .rax, 0x0fff_ffff);
                        if (nzcv_imm != 0) em.orRegImm(false, .rax, @bitCast(nzcv_imm));
                        em.movMemReg(false, .rbx, off_pstate, .rax);
                        em.bindLabel(done_ccmp);
                    },

                    .mrs_tpidr_el0 => {
                        em.movRegMem(true, .rax, .rbx, off_tpidr_el0);
                        emitStoreA64Reg(&em, d.rd, .rax, false, .rcx);
                    },

                    .ldr_lit32, .ldr_lit64, .ldrsw_lit => {
                        em.movRegMem(true, .rdi, .rbx, off_pc64);
                        const off: i32 = @as(i32, @intCast(pc_page_off)) +% @as(i32, @bitCast(@as(u32, @truncate(d.imm))));
                        if (off != 0) em.addRegImm(true, .rdi, off);
                        emitA64LoadAddr(
                            &em,
                            d.rd,
                            31,
                            if (op == .ldr_lit64) 8 else 4,
                            op == .ldrsw_lit,
                            op != .ldr_lit32,
                            false,
                            0,
                            pc_page_off,
                            epilogue_label,
                        );
                    },

                    .madd_msub => {
                        const ra: u8 = @truncate(d.imm & 0x1f);
                        const is_sub = ((d.imm >> 5) & 1) != 0;
                        const is64 = ((d.imm >> 6) & 1) != 0;
                        emitLoadA64Reg(&em, is64, .rax, d.rn, false);
                        emitLoadA64Reg(&em, is64, .rcx, d.rm, false);
                        em.imulRegReg(is64, .rax, .rcx);
                        if (ra != 31 or is_sub) {
                            emitLoadA64Reg(&em, is64, .rcx, ra, false);
                            if (is_sub) {
                                em.subRegReg(is64, .rcx, .rax);
                                em.movRegReg(is64, .rax, .rcx);
                            } else {
                                em.addRegReg(is64, .rax, .rcx);
                            }
                        }
                        emitStoreA64Reg(&em, d.rd, .rax, false, .rcx);
                    },

                    .ldr64_uimm, .ldr32_uimm, .ldrsw_uimm, .ldr16_uimm, .ldr8_uimm, .ldrsb64_uimm, .ldrsb32_uimm, .ldrsh64_uimm, .ldrsh32_uimm => {
                        const size: u4 = switch (op) {
                            .ldr64_uimm => 8,
                            .ldr32_uimm, .ldrsw_uimm => 4,
                            .ldr16_uimm, .ldrsh64_uimm, .ldrsh32_uimm => 2,
                            .ldr8_uimm, .ldrsb64_uimm, .ldrsb32_uimm => 1,
                            else => unreachable,
                        };
                        const signed = switch (op) {
                            .ldrsw_uimm, .ldrsb64_uimm, .ldrsb32_uimm, .ldrsh64_uimm, .ldrsh32_uimm => true,
                            else => false,
                        };
                        const is64 = switch (op) {
                            .ldr64_uimm, .ldrsw_uimm, .ldrsb64_uimm, .ldrsh64_uimm => true,
                            else => false,
                        };
                        emitLoadA64Reg(&em, true, .rdi, d.rn, true);
                        const disp: i32 = @bitCast(@as(u32, @truncate(d.imm)));
                        if (disp != 0) em.addRegImm(true, .rdi, disp);
                        emitA64LoadAddr(&em, d.rd, d.rn, size, signed, is64, false, 0, pc_page_off, epilogue_label);
                    },

                    .str64_uimm, .str32_uimm, .str16_uimm, .str8_uimm => {
                        const size: u4 = switch (op) {
                            .str64_uimm => 8,
                            .str32_uimm => 4,
                            .str16_uimm => 2,
                            .str8_uimm => 1,
                            else => unreachable,
                        };
                        emitLoadA64Reg(&em, true, .rdi, d.rn, true);
                        const disp: i32 = @bitCast(@as(u32, @truncate(d.imm)));
                        if (disp != 0) em.addRegImm(true, .rdi, disp);
                        emitA64StoreAddr(&em, d.rd, d.rn, size, false, 0, pc_page_off, epilogue_label);
                    },

                    .ldr64_pre, .ldr64_post, .ldr32_pre, .ldr32_post => {
                        const is_pre = op == .ldr64_pre or op == .ldr32_pre;
                        const size: u4 = if (op == .ldr64_pre or op == .ldr64_post) 8 else 4;
                        const disp: i32 = @bitCast(@as(u32, @truncate(d.imm)));
                        emitLoadA64Reg(&em, true, .rdi, d.rn, true);
                        if (is_pre and disp != 0) em.addRegImm(true, .rdi, disp);
                        emitA64LoadAddr(&em, d.rd, d.rn, size, false, size == 8, true, if (is_pre) 0 else disp, pc_page_off, epilogue_label);
                    },

                    .str64_pre, .str64_post, .str32_pre, .str32_post => {
                        const is_pre = op == .str64_pre or op == .str32_pre;
                        const size: u4 = if (op == .str64_pre or op == .str64_post) 8 else 4;
                        const disp: i32 = @bitCast(@as(u32, @truncate(d.imm)));
                        emitLoadA64Reg(&em, true, .rdi, d.rn, true);
                        if (is_pre and disp != 0) em.addRegImm(true, .rdi, disp);
                        emitA64StoreAddr(&em, d.rd, d.rn, size, true, if (is_pre) 0 else disp, pc_page_off, epilogue_label);
                    },

                    .ldr64_reg_lsl, .ldr32_reg_lsl, .ldr8_reg_lsl => {
                        const size: u4 = switch (op) {
                            .ldr64_reg_lsl => 8,
                            .ldr32_reg_lsl => 4,
                            .ldr8_reg_lsl => 1,
                            else => unreachable,
                        };
                        emitLoadA64Reg(&em, true, .rdi, d.rn, true);
                        emitLoadA64Reg(&em, true, .rax, d.rm, false);
                        const sh: u6 = @truncate(d.imm);
                        if (sh != 0) em.shlImm(true, .rax, sh);
                        em.addRegReg(true, .rdi, .rax);
                        emitA64LoadAddr(&em, d.rd, d.rn, size, false, size == 8, false, 0, pc_page_off, epilogue_label);
                    },

                    .str64_reg_lsl, .str32_reg_lsl, .str8_reg_lsl => {
                        const size: u4 = switch (op) {
                            .str64_reg_lsl => 8,
                            .str32_reg_lsl => 4,
                            .str8_reg_lsl => 1,
                            else => unreachable,
                        };
                        emitLoadA64Reg(&em, true, .rdi, d.rn, true);
                        emitLoadA64Reg(&em, true, .rax, d.rm, false);
                        const sh: u6 = @truncate(d.imm);
                        if (sh != 0) em.shlImm(true, .rax, sh);
                        em.addRegReg(true, .rdi, .rax);
                        emitA64StoreAddr(&em, d.rd, d.rn, size, false, 0, pc_page_off, epilogue_label);
                    },

                    .ldp64_off, .ldp64_pre, .ldp64_post, .ldp32_off, .ldp32_pre, .ldp32_post, .stp64_off, .stp64_pre, .stp64_post, .stp32_off, .stp32_pre, .stp32_post => {
                        const is_load = switch (op) {
                            .ldp64_off, .ldp64_pre, .ldp64_post, .ldp32_off, .ldp32_pre, .ldp32_post => true,
                            else => false,
                        };
                        const is64 = switch (op) {
                            .ldp64_off, .ldp64_pre, .ldp64_post, .stp64_off, .stp64_pre, .stp64_post => true,
                            else => false,
                        };
                        const is_pre = op == .ldp64_pre or op == .ldp32_pre or op == .stp64_pre or op == .stp32_pre;
                        const is_post = op == .ldp64_post or op == .ldp32_post or op == .stp64_post or op == .stp32_post;
                        const disp: i32 = @bitCast(@as(u32, @truncate(d.imm)));
                        emitA64PairMem(
                            &em,
                            d.rd,
                            d.rm,
                            d.rn,
                            is_load,
                            is64,
                            if (is_post) 0 else disp,
                            is_pre or is_post,
                            if (is_post) disp else 0,
                            pc_page_off,
                            epilogue_label,
                        );
                    },

                    .b_imm, .bl_imm => {
                        if (op == .bl_imm) {
                            em.movRegMem(true, .rax, .rbx, off_pc64);
                            em.addRegImm(true, .rax, @intCast(pc_page_off + 4));
                            emitStoreA64Reg(&em, 30, .rax, false, .rcx);
                        }
                        const target_delta: i32 = @as(i32, @intCast(pc_page_off)) + @as(i32, @bitCast(@as(u32, @truncate(d.imm))));
                        const target_word_i32 = @divExact(target_delta, 4);
                        if (op == .b_imm and target_word_i32 >= @as(i32, start_word) and target_word_i32 < @as(i32, end_word)) {
                            const target_w: u16 = @intCast(target_word_i32);
                            const target_idx = target_w - start_word;
                            if (target_w > w) {
                                em.jmpLabel(inst_labels[target_idx]);
                            } else {
                                const rem: i32 = @intCast(end_word - target_w);
                                const exit_label = em.newLabel();
                                exit_stubs[exit_stub_count] = .{ .label = exit_label, .pc_delta = target_delta };
                                exit_stub_count += 1;
                                em.leaRegMem(true, .rax, .r15, rem);
                                em.cmpRegReg(true, .rax, .r14);
                                em.jccLabel(.a, exit_label);
                                em.jmpLabel(inst_labels[target_idx]);
                            }
                        } else {
                            em.addMemImm32(true, .rbx, off_pc64, target_delta);
                            em.jmpLabel(epilogue_label);
                        }
                    },

                    .b_cond, .cbz64, .cbnz64, .cbz32, .cbnz32, .tbz, .tbnz => {
                        const target_delta: i32 = @as(i32, @intCast(pc_page_off)) + @as(i32, @bitCast(@as(u32, @truncate(d.imm))));
                        const target_word_i32 = @divExact(target_delta, 4);
                        const in_trace = target_word_i32 >= @as(i32, start_word) and target_word_i32 < @as(i32, end_word);

                        var taken_label: u16 = undefined;
                        if (in_trace) {
                            const target_w: u16 = @intCast(target_word_i32);
                            const target_idx = target_w - start_word;
                            if (target_w > w) {
                                taken_label = inst_labels[target_idx];
                            } else {
                                const check_label = em.newLabel();
                                const exit_label = em.newLabel();
                                exit_stubs[exit_stub_count] = .{ .label = exit_label, .pc_delta = target_delta };
                                exit_stub_count += 1;
                                taken_label = check_label;

                                const not_taken_label = em.newLabel();
                                switch (op) {
                                    .b_cond => emitArmCondBranch(&em, off_pstate, @intCast(d.rd & 0xf), false, not_taken_label),
                                    .cbz64, .cbz32 => {
                                        emitLoadA64Reg(&em, op == .cbz64, .rax, d.rd, false);
                                        em.testRegReg(op == .cbz64, .rax, .rax);
                                        em.jccLabel(.ne, not_taken_label);
                                    },
                                    .cbnz64, .cbnz32 => {
                                        emitLoadA64Reg(&em, op == .cbnz64, .rax, d.rd, false);
                                        em.testRegReg(op == .cbnz64, .rax, .rax);
                                        em.jccLabel(.e, not_taken_label);
                                    },
                                    .tbz, .tbnz => {
                                        const bit: u6 = @intCast(d.rm & 0x3f);
                                        emitLoadA64Reg(&em, bit >= 32, .rax, d.rd, false);
                                        if (bit > 0) em.shrImm(bit >= 32, .rax, bit);
                                        em.testRegImm32(false, .rax, 1);
                                        em.jccLabel(if (op == .tbz) .ne else .e, not_taken_label);
                                    },
                                    else => unreachable,
                                }
                                em.bindLabel(check_label);
                                const rem: i32 = @intCast(end_word - target_w);
                                em.leaRegMem(true, .rax, .r15, rem);
                                em.cmpRegReg(true, .rax, .r14);
                                em.jccLabel(.a, exit_label);
                                em.jmpLabel(inst_labels[target_idx]);
                                em.bindLabel(not_taken_label);
                                continue;
                            }
                        } else {
                            const exit_label = em.newLabel();
                            exit_stubs[exit_stub_count] = .{ .label = exit_label, .pc_delta = target_delta };
                            exit_stub_count += 1;
                            taken_label = exit_label;
                        }

                        switch (op) {
                            .b_cond => emitArmCondBranch(&em, off_pstate, @intCast(d.rd & 0xf), true, taken_label),
                            .cbz64, .cbz32 => {
                                emitLoadA64Reg(&em, op == .cbz64, .rax, d.rd, false);
                                em.testRegReg(op == .cbz64, .rax, .rax);
                                em.jccLabel(.e, taken_label);
                            },
                            .cbnz64, .cbnz32 => {
                                emitLoadA64Reg(&em, op == .cbnz64, .rax, d.rd, false);
                                em.testRegReg(op == .cbnz64, .rax, .rax);
                                em.jccLabel(.ne, taken_label);
                            },
                            .tbz, .tbnz => {
                                const bit: u6 = @intCast(d.rm & 0x3f);
                                emitLoadA64Reg(&em, bit >= 32, .rax, d.rd, false);
                                if (bit > 0) em.shrImm(bit >= 32, .rax, bit);
                                em.testRegImm32(false, .rax, 1);
                                em.jccLabel(if (op == .tbz) .e else .ne, taken_label);
                            },
                            else => unreachable,
                        }
                    },

                    .br_reg, .blr_reg, .ret => {
                        emitLoadA64Reg(&em, true, .rax, d.rn, false);
                        if (op == .blr_reg) {
                            em.movRegMem(true, .rcx, .rbx, off_pc64);
                            em.addRegImm(true, .rcx, @intCast(pc_page_off + 4));
                            emitStoreA64Reg(&em, 30, .rcx, false, .rdx);
                        }
                        em.movMemReg(true, .rbx, off_pc64, .rax);
                        em.jmpLabel(epilogue_label);
                    },

                    else => unreachable,
                }
            }

            const last_op: A64Op = @enumFromInt(decoded[trace_len - 1].op);
            if (!isTerminator(last_op)) {
                em.addMemImm32(true, .rbx, off_pc64, @intCast(@as(u32, end_word) * 4));
                em.jmpLabel(epilogue_label);
            }

            for (exit_stubs[0..exit_stub_count]) |stub| {
                em.bindLabel(stub.label);
                em.addMemImm32(true, .rbx, off_pc64, stub.pc_delta);
                em.jmpLabel(epilogue_label);
            }

            em.bindLabel(epilogue_label);
            em.emitEpilogue();

            if (!em.resolveFixups()) return null;
            return buf.allocCode(core_id, em.buf[0..em.len]);
        }
    };
}

// ============================================================================
// ARM32 Generic JIT Backend
// ============================================================================

pub fn Arm32Jit(comptime CpuType: type, comptime Bus: type) type {
    const ArmOp = arm1176_mod.ArmOp;
    const DecodedSlot = arm1176_mod.DecodedSlot;
    const off_r: i32 = @intCast(@offsetOf(CpuType, "r"));
    const off_r15: i32 = off_r + 15 * 4;
    const off_cpsr: i32 = @intCast(@offsetOf(CpuType, "cpsr"));

    return struct {
        inline fn arm32RegOff(reg: u8) i32 {
            return off_r + @as(i32, reg & 0xf) * 4;
        }

        fn emitLoadArm32Reg(em: *X64Emitter, dst: Reg, reg: u8, pc_page_off: u32) void {
            const r = reg & 0xf;
            em.movRegMem(false, dst, .rbx, arm32RegOff(r));
            if (r == 15) {
                em.addRegImm(false, dst, @intCast(pc_page_off + 8));
            }
        }

        fn emitStoreArm32Reg(em: *X64Emitter, reg: u8, src: Reg) void {
            em.movMemReg(false, .rbx, arm32RegOff(reg & 0xf), src);
        }

        pub fn jitSlowLoad32(
            cpu_opaque: *anyopaque,
            bus_opaque: *anyopaque,
            vaddr: u32,
            pc_and_wb: u64,
            size_and_rn: u32,
        ) callconv(.c) SlowLoadResult64 {
            const cpu: *CpuType = @ptrCast(@alignCast(cpu_opaque));
            const bus: *Bus = @ptrCast(@alignCast(bus_opaque));
            const pc_page_off: u32 = @truncate(pc_and_wb);
            const cur_pc = cpu.r[15] +% pc_page_off;
            const size: u4 = @intCast(size_and_rn & 0xf);
            const do_wb = (size_and_rn & 0x10) != 0;
            const rn: u4 = @intCast((size_and_rn >> 8) & 0xf);
            const wb_disp: i32 = @bitCast(@as(u32, @truncate(pc_and_wb >> 32)));
            const val: u64 = switch (size) {
                1 => cpu.read8(bus, vaddr) catch {
                    cpu.enterException(.abt, 0x10, cur_pc +% 8, false);
                    return .{ .val = 0, .abort = 1 };
                },
                2 => cpu.read16(bus, vaddr) catch {
                    cpu.enterException(.abt, 0x10, cur_pc +% 8, false);
                    return .{ .val = 0, .abort = 1 };
                },
                4 => cpu.read32(bus, vaddr) catch {
                    cpu.enterException(.abt, 0x10, cur_pc +% 8, false);
                    return .{ .val = 0, .abort = 1 };
                },
                8 => cpu.read64(bus, vaddr) catch {
                    cpu.enterException(.abt, 0x10, cur_pc +% 8, false);
                    return .{ .val = 0, .abort = 1 };
                },
                else => unreachable,
            };
            if (do_wb) {
                cpu.r[rn] = vaddr +% @as(u32, @bitCast(wb_disp));
            }
            return .{ .val = val, .abort = 0 };
        }

        pub fn jitSlowStore32(
            cpu_opaque: *anyopaque,
            bus_opaque: *anyopaque,
            vaddr: u32,
            val: u64,
            pc_and_wb: u64,
            size_and_rn: u32,
        ) callconv(.c) u64 {
            const cpu: *CpuType = @ptrCast(@alignCast(cpu_opaque));
            const bus: *Bus = @ptrCast(@alignCast(bus_opaque));
            const pc_page_off: u32 = @truncate(pc_and_wb);
            const cur_pc = cpu.r[15] +% pc_page_off;
            const size: u4 = @intCast(size_and_rn & 0xf);
            const do_wb = (size_and_rn & 0x10) != 0;
            const rn: u4 = @intCast((size_and_rn >> 8) & 0xf);
            const wb_disp: i32 = @bitCast(@as(u32, @truncate(pc_and_wb >> 32)));
            switch (size) {
                1 => cpu.write8(bus, vaddr, @truncate(val)) catch {
                    cpu.enterException(.abt, 0x10, cur_pc +% 8, false);
                    return 1;
                },
                2 => cpu.write16(bus, vaddr, @truncate(val)) catch {
                    cpu.enterException(.abt, 0x10, cur_pc +% 8, false);
                    return 1;
                },
                4 => cpu.write32(bus, vaddr, @truncate(val)) catch {
                    cpu.enterException(.abt, 0x10, cur_pc +% 8, false);
                    return 1;
                },
                8 => cpu.write64(bus, vaddr, val) catch {
                    cpu.enterException(.abt, 0x10, cur_pc +% 8, false);
                    return 1;
                },
                else => unreachable,
            }
            if (do_wb) {
                cpu.r[rn] = vaddr +% @as(u32, @bitCast(wb_disp));
            }
            const priv: u1 = @intFromBool(cpu.isPrivileged());
            const slot = cpu.mmu.soft_tlb32[priv][(vaddr >> 12) & mmu_mod.Mmu.soft_tlb_mask];
            if ((vaddr & 0xffff_f000) != slot.w_vbase) {
                cpu.r[15] = cur_pc +% 4;
                if (cpu.checkInterrupts(bus)) return 2;
                cpu.r[15] = cur_pc -% pc_page_off;
            }
            return 0;
        }

        pub fn jitSlowLdmStm32(
            cpu_opaque: *anyopaque,
            bus_opaque: *anyopaque,
            pc_page_off: u32,
            raw_inst: u32,
        ) callconv(.c) u64 {
            const cpu: *CpuType = @ptrCast(@alignCast(cpu_opaque));
            const bus: *Bus = @ptrCast(@alignCast(bus_opaque));
            const trace_pc = cpu.r[15];
            const cur_pc = trace_pc +% pc_page_off;
            cpu.r[15] = cur_pc +% 4;
            cpu.executeLoadStoreMultiple(bus, cur_pc, raw_inst);
            if (cpu.r[15] != cur_pc +% 4) return 1;
            if ((raw_inst & (1 << 20)) == 0) {
                if (cpu.checkInterrupts(bus)) return 1;
            }
            cpu.r[15] = trace_pc;
            return 0;
        }

        pub fn canCompileSlot(d: DecodedSlot) bool {
            const raw = d.raw;
            if ((raw >> 28) == 0xf) return false;
            const op: ArmOp = @enumFromInt(d.op);
            return switch (op) {
                .nop_al,
                .add_imm_al,
                .sub_imm_al,
                .rsb_imm_al,
                .and_imm_al,
                .orr_imm_al,
                .eor_imm_al,
                .bic_imm_al,
                .mov_imm_al,
                .mvn_imm_al,
                .cmp_imm_al,
                .cmn_imm_al,
                .tst_imm_al,
                .teq_imm_al,
                .adds_imm_al,
                .subs_imm_al,
                .movw_al,
                .movt_al,
                .add_reg_al,
                .sub_reg_al,
                .rsb_reg_al,
                .and_reg_al,
                .orr_reg_al,
                .eor_reg_al,
                .bic_reg_al,
                .mov_reg_al,
                .mvn_reg_al,
                .adds_reg_al,
                .subs_reg_al,
                .cmp_reg_al,
                .cmn_reg_al,
                .tst_reg_al,
                .teq_reg_al,
                .lsl_imm_al,
                .lsr_imm_al,
                .asr_imm_al,
                .mvn_lsl_imm_al,
                .mvn_lsr_imm_al,
                .add_lsl_reg_al,
                .sub_lsl_reg_al,
                .rsb_lsl_reg_al,
                .orr_lsl_reg_al,
                .eor_lsl_reg_al,
                .and_lsl_reg_al,
                .bic_lsl_reg_al,
                .add_lsr_reg_al,
                .sub_lsr_reg_al,
                .rsb_lsr_reg_al,
                .orr_lsr_reg_al,
                .eor_lsr_reg_al,
                .and_lsr_reg_al,
                .bic_lsr_reg_al,
                .add_asr_reg_al,
                .sub_asr_reg_al,
                .orr_asr_reg_al,
                .and_asr_reg_al,
                .bic_asr_reg_al,
                .cmp_lsl_reg_al,
                .cmp_lsr_reg_al,
                .ldr_imm_al,
                .str_imm_al,
                .ldrb_imm_al,
                .strb_imm_al,
                .ldr_lit_al,
                .ldrh_imm_al,
                .strh_imm_al,
                .ldrsb_imm_al,
                .ldrsh_imm_al,
                .ldrh_reg_al,
                .strh_reg_al,
                .ldrsb_reg_al,
                .ldrsh_reg_al,
                .ldrd_imm_al,
                .strd_imm_al,
                .ldr_wb_al => d.rd != 15,
                .str_wb_al,
                .ldrb_wb_al,
                .strb_wb_al,
                .ldr_reg_lsl_al,
                .str_reg_lsl_al,
                .ldrb_reg_lsl_al,
                .strb_reg_lsl_al,
                .ldr_reg_sub_lsl_al,
                .str_reg_sub_lsl_al,
                .ldrb_reg_sub_lsl_al,
                .strb_reg_sub_lsl_al,
                .ldr_reg_lsr_al,
                .str_reg_lsr_al,
                .ldm_al,
                .stm_al,
                .mul_al,
                .mla_al,
                .mls_al,
                .umull_al,
                .umlal_al,
                .smull_al,
                .smlal_al,
                .clz_al,
                .uxtb_al,
                .uxth_al,
                .sxtb_al,
                .sxth_al,
                .uxtab_al,
                .uxtah_al,
                .sxtab_al,
                .sxtah_al,
                .rev_al,
                .ubfx_al,
                .sbfx_al,
                .bfi_al,
                .bfc_al,
                .b_al,
                => true,
                else => false,
            };
        }

        inline fn isTerminator(op: ArmOp, raw: u32) bool {
            if ((raw >> 28) != 0xe) return false;
            return switch (op) {
                .b_al, .bx_lr_al, .bx_reg_al, .blx_reg_al => true,
                else => false,
            };
        }

        pub fn compileTrace(
            buf: *JitCodeBuffer,
            core_id: u2,
            code_page_ptr: [*]const u8,
            start_word: u10,
            requested_end_word: u16,
            out_end_word: *u16,
        ) ?JitFn {
            if (!is_x86_64_linux) return null;

            const max_window: u16 = 64;
            var decoded: [64]DecodedSlot = undefined;
            var trace_len: u16 = 0;

            if (requested_end_word != 0) {
                if (requested_end_word <= start_word + 1 or requested_end_word - start_word > max_window or requested_end_word > 1024) return null;
                trace_len = requested_end_word - start_word;
                for (0..trace_len) |i| {
                    const w = start_word + @as(u16, @intCast(i));
                    const raw_inst = std.mem.readInt(u32, code_page_ptr[@as(usize, w) * 4 ..][0..4], .little);
                    const d = arm1176_mod.decodeArm32(raw_inst);
                    if (!canCompileSlot(d)) return null;
                    const op: ArmOp = @enumFromInt(d.op);
                    if (op == .b_al or op == .bl_al) {
                        if (w + 1 < 1024) {
                            const next_raw = std.mem.readInt(u32, code_page_ptr[@as(usize, w + 1) * 4 ..][0..4], .little);
                            if ((next_raw & 0x0fff_ffe0) == 0x057f_f040) return null;
                        }
                    }
                    decoded[i] = d;
                }
            } else {
                const limit_word: u16 = @min(@as(u16, 1024), @as(u16, start_word) + max_window);
                while (start_word + trace_len < limit_word) {
                    const w = start_word + trace_len;
                    const raw_inst = std.mem.readInt(u32, code_page_ptr[@as(usize, w) * 4 ..][0..4], .little);
                    const d = arm1176_mod.decodeArm32(raw_inst);
                    if (!canCompileSlot(d)) break;
                    const op: ArmOp = @enumFromInt(d.op);
                    if (op == .b_al or op == .bl_al) {
                        if (w + 1 < 1024) {
                            const next_raw = std.mem.readInt(u32, code_page_ptr[@as(usize, w + 1) * 4 ..][0..4], .little);
                            if ((next_raw & 0x0fff_ffe0) == 0x057f_f040) break;
                        }
                    }
                    decoded[trace_len] = d;
                    trace_len += 1;
                    if (isTerminator(op, raw_inst)) {
                        break;
                    }
                }
                if (trace_len < 2) return null;
            }

            const end_word: u16 = start_word + trace_len;
            out_end_word.* = end_word;

            var em = X64Emitter{};
            em.emitPrologue();

            const epilogue_label = em.newLabel();
            var inst_labels: [64]u16 = undefined;
            for (0..trace_len) |i| {
                inst_labels[i] = em.newLabel();
            }

            var exit_stubs: [128]ExitStub = undefined;
            var exit_stub_count: usize = 0;

            for (0..trace_len) |idx| {
                const w: u16 = start_word + @as(u16, @intCast(idx));
                const pc_page_off: u32 = @as(u32, w) * 4;
                const d = decoded[idx];
                const raw = d.raw;
                const cond: u4 = @intCast(raw >> 28);
                const op: ArmOp = @enumFromInt(d.op);
                const imm32: u32 = @truncate(d.imm);

                em.bindLabel(inst_labels[idx]);
                em.addRegImm(true, .r15, 1);

                if (op == .b_al or op == .bl_al) {
                    const target_delta: i32 = @as(i32, @intCast(pc_page_off + 8)) + @as(i32, @bitCast(imm32));
                    const target_word_i32 = @divExact(target_delta, 4);
                    const in_trace = op == .b_al and target_word_i32 >= @as(i32, start_word) and target_word_i32 < @as(i32, end_word);

                    if (cond == 0xe) {
                        if (op == .bl_al) {
                            em.movRegMem(false, .rax, .rbx, off_r15);
                            em.addRegImm(false, .rax, @intCast(pc_page_off + 4));
                            emitStoreArm32Reg(&em, 14, .rax);
                        }
                        if (in_trace) {
                            const target_w: u16 = @intCast(target_word_i32);
                            const target_idx = target_w - start_word;
                            if (target_w > w) {
                                em.jmpLabel(inst_labels[target_idx]);
                            } else {
                                const rem: i32 = @intCast(end_word - target_w);
                                const exit_label = em.newLabel();
                                exit_stubs[exit_stub_count] = .{ .label = exit_label, .pc_delta = target_delta };
                                exit_stub_count += 1;
                                em.leaRegMem(true, .rax, .r15, rem);
                                em.cmpRegReg(true, .rax, .r14);
                                em.jccLabel(.a, exit_label);
                                em.jmpLabel(inst_labels[target_idx]);
                            }
                        } else {
                            em.addMemImm32(false, .rbx, off_r15, target_delta);
                            em.jmpLabel(epilogue_label);
                        }
                    } else {
                        const not_taken = em.newLabel();
                        emitArmCondBranch(&em, off_cpsr, cond, false, not_taken);
                        if (op == .bl_al) {
                            em.movRegMem(false, .rax, .rbx, off_r15);
                            em.addRegImm(false, .rax, @intCast(pc_page_off + 4));
                            emitStoreArm32Reg(&em, 14, .rax);
                        }
                        if (in_trace) {
                            const target_w: u16 = @intCast(target_word_i32);
                            const target_idx = target_w - start_word;
                            if (target_w > w) {
                                em.jmpLabel(inst_labels[target_idx]);
                            } else {
                                const rem: i32 = @intCast(end_word - target_w);
                                const exit_label = em.newLabel();
                                exit_stubs[exit_stub_count] = .{ .label = exit_label, .pc_delta = target_delta };
                                exit_stub_count += 1;
                                em.leaRegMem(true, .rax, .r15, rem);
                                em.cmpRegReg(true, .rax, .r14);
                                em.jccLabel(.a, exit_label);
                                em.jmpLabel(inst_labels[target_idx]);
                            }
                        } else {
                            const exit_label = em.newLabel();
                            exit_stubs[exit_stub_count] = .{ .label = exit_label, .pc_delta = target_delta };
                            exit_stub_count += 1;
                            em.jmpLabel(exit_label);
                        }
                        em.bindLabel(not_taken);
                    }
                    continue;
                }

                const skip_label = if (cond < 0xe) em.newLabel() else 0;
                if (cond < 0xe) {
                    emitArmCondBranch(&em, off_cpsr, cond, false, skip_label);
                }

                switch (op) {
                    .nop_al => {},
                    .mov_imm_al, .movw_al => {
                        em.movImm32(.rax, imm32);
                        emitStoreArm32Reg(&em, d.rd, .rax);
                    },
                    .mvn_imm_al => {
                        em.movImm32(.rax, ~imm32);
                        emitStoreArm32Reg(&em, d.rd, .rax);
                    },
                    .movt_al => {
                        emitLoadArm32Reg(&em, .rax, d.rd, pc_page_off);
                        em.andRegImm(false, .rax, 0xffff);
                        em.orRegImm(false, .rax, @bitCast(imm32 << 16));
                        emitStoreArm32Reg(&em, d.rd, .rax);
                    },

                    .add_imm_al, .sub_imm_al, .rsb_imm_al, .and_imm_al, .orr_imm_al, .eor_imm_al, .bic_imm_al => {
                        emitLoadArm32Reg(&em, .rax, d.rn, pc_page_off);
                        switch (op) {
                            .add_imm_al => em.addRegImm(false, .rax, @bitCast(imm32)),
                            .sub_imm_al => em.subRegImm(false, .rax, @bitCast(imm32)),
                            .rsb_imm_al => {
                                em.movImm32(.rcx, imm32);
                                em.subRegReg(false, .rcx, .rax);
                                em.movRegReg(false, .rax, .rcx);
                            },
                            .and_imm_al => em.andRegImm(false, .rax, @bitCast(imm32)),
                            .orr_imm_al => em.orRegImm(false, .rax, @bitCast(imm32)),
                            .eor_imm_al => em.xorRegImm(false, .rax, @bitCast(imm32)),
                            .bic_imm_al => em.andRegImm(false, .rax, @bitCast(~imm32)),
                            else => unreachable,
                        }
                        emitStoreArm32Reg(&em, d.rd, .rax);
                    },

                    .adds_imm_al, .subs_imm_al, .cmp_imm_al, .cmn_imm_al => {
                        const is_sub = op == .subs_imm_al or op == .cmp_imm_al;
                        const write_rd = op == .adds_imm_al or op == .subs_imm_al;
                        emitLoadArm32Reg(&em, .rax, d.rn, pc_page_off);
                        if (is_sub) em.subRegImm(false, .rax, @bitCast(imm32)) else em.addRegImm(false, .rax, @bitCast(imm32));
                        if (write_rd) emitStoreArm32Reg(&em, d.rd, .rax);
                        emitUpdateNZCV_AddSub(&em, off_cpsr, is_sub);
                    },

                    .tst_imm_al, .teq_imm_al => {
                        emitLoadArm32Reg(&em, .rax, d.rn, pc_page_off);
                        if (op == .tst_imm_al) em.andRegImm(false, .rax, @bitCast(imm32)) else em.xorRegImm(false, .rax, @bitCast(imm32));
                        emitUpdateNZ_Logic(&em, off_cpsr, true);
                    },

                    .mov_reg_al, .mvn_reg_al => {
                        emitLoadArm32Reg(&em, .rax, d.rm, pc_page_off);
                        if (op == .mvn_reg_al) em.notReg(false, .rax);
                        emitStoreArm32Reg(&em, d.rd, .rax);
                    },

                    .add_reg_al, .sub_reg_al, .rsb_reg_al, .and_reg_al, .orr_reg_al, .eor_reg_al, .bic_reg_al => {
                        emitLoadArm32Reg(&em, .rax, d.rn, pc_page_off);
                        emitLoadArm32Reg(&em, .rcx, d.rm, pc_page_off);
                        switch (op) {
                            .add_reg_al => em.addRegReg(false, .rax, .rcx),
                            .sub_reg_al => em.subRegReg(false, .rax, .rcx),
                            .rsb_reg_al => {
                                em.subRegReg(false, .rcx, .rax);
                                em.movRegReg(false, .rax, .rcx);
                            },
                            .and_reg_al => em.andRegReg(false, .rax, .rcx),
                            .orr_reg_al => em.orRegReg(false, .rax, .rcx),
                            .eor_reg_al => em.xorRegReg(false, .rax, .rcx),
                            .bic_reg_al => {
                                em.notReg(false, .rcx);
                                em.andRegReg(false, .rax, .rcx);
                            },
                            else => unreachable,
                        }
                        emitStoreArm32Reg(&em, d.rd, .rax);
                    },

                    .adds_reg_al, .subs_reg_al, .cmp_reg_al, .cmn_reg_al => {
                        const is_sub = op == .subs_reg_al or op == .cmp_reg_al;
                        const write_rd = op == .adds_reg_al or op == .subs_reg_al;
                        emitLoadArm32Reg(&em, .rax, d.rn, pc_page_off);
                        emitLoadArm32Reg(&em, .rcx, d.rm, pc_page_off);
                        if (is_sub) em.subRegReg(false, .rax, .rcx) else em.addRegReg(false, .rax, .rcx);
                        if (write_rd) emitStoreArm32Reg(&em, d.rd, .rax);
                        emitUpdateNZCV_AddSub(&em, off_cpsr, is_sub);
                    },

                    .tst_reg_al, .teq_reg_al => {
                        emitLoadArm32Reg(&em, .rax, d.rn, pc_page_off);
                        emitLoadArm32Reg(&em, .rcx, d.rm, pc_page_off);
                        if (op == .tst_reg_al) em.andRegReg(false, .rax, .rcx) else em.xorRegReg(false, .rax, .rcx);
                        emitUpdateNZ_Logic(&em, off_cpsr, true);
                    },

                    .lsl_imm_al, .lsr_imm_al, .asr_imm_al, .mvn_lsl_imm_al, .mvn_lsr_imm_al => {
                        emitLoadArm32Reg(&em, .rax, d.rm, pc_page_off);
                        const sh: u6 = @truncate(imm32);
                        switch (op) {
                            .lsl_imm_al => em.shlImm(false, .rax, sh),
                            .lsr_imm_al => em.shrImm(false, .rax, sh),
                            .asr_imm_al => em.sarImm(false, .rax, sh),
                            .mvn_lsl_imm_al => {
                                em.shlImm(false, .rax, sh);
                                em.notReg(false, .rax);
                            },
                            .mvn_lsr_imm_al => {
                                em.shrImm(false, .rax, sh);
                                em.notReg(false, .rax);
                            },
                            else => unreachable,
                        }
                        emitStoreArm32Reg(&em, d.rd, .rax);
                    },

                    .add_lsl_reg_al, .sub_lsl_reg_al, .rsb_lsl_reg_al, .orr_lsl_reg_al, .eor_lsl_reg_al, .and_lsl_reg_al, .bic_lsl_reg_al, .add_lsr_reg_al, .sub_lsr_reg_al, .rsb_lsr_reg_al, .orr_lsr_reg_al, .eor_lsr_reg_al, .and_lsr_reg_al, .bic_lsr_reg_al, .add_asr_reg_al, .sub_asr_reg_al, .orr_asr_reg_al, .and_asr_reg_al, .bic_asr_reg_al => {
                        emitLoadArm32Reg(&em, .rax, d.rn, pc_page_off);
                        emitLoadArm32Reg(&em, .rcx, d.rm, pc_page_off);
                        const sh: u6 = @truncate(imm32);
                        switch (op) {
                            .add_lsl_reg_al, .sub_lsl_reg_al, .rsb_lsl_reg_al, .orr_lsl_reg_al, .eor_lsl_reg_al, .and_lsl_reg_al, .bic_lsl_reg_al => em.shlImm(false, .rcx, sh),
                            .add_lsr_reg_al, .sub_lsr_reg_al, .rsb_lsr_reg_al, .orr_lsr_reg_al, .eor_lsr_reg_al, .and_lsr_reg_al, .bic_lsr_reg_al => em.shrImm(false, .rcx, sh),
                            .add_asr_reg_al, .sub_asr_reg_al, .orr_asr_reg_al, .and_asr_reg_al, .bic_asr_reg_al => em.sarImm(false, .rcx, sh),
                            else => unreachable,
                        }
                        switch (op) {
                            .add_lsl_reg_al, .add_lsr_reg_al, .add_asr_reg_al => em.addRegReg(false, .rax, .rcx),
                            .sub_lsl_reg_al, .sub_lsr_reg_al, .sub_asr_reg_al => em.subRegReg(false, .rax, .rcx),
                            .rsb_lsl_reg_al, .rsb_lsr_reg_al => {
                                em.subRegReg(false, .rcx, .rax);
                                em.movRegReg(false, .rax, .rcx);
                            },
                            .orr_lsl_reg_al, .orr_lsr_reg_al, .orr_asr_reg_al => em.orRegReg(false, .rax, .rcx),
                            .eor_lsl_reg_al, .eor_lsr_reg_al => em.xorRegReg(false, .rax, .rcx),
                            .and_lsl_reg_al, .and_lsr_reg_al, .and_asr_reg_al => em.andRegReg(false, .rax, .rcx),
                            .bic_lsl_reg_al, .bic_lsr_reg_al, .bic_asr_reg_al => {
                                em.notReg(false, .rcx);
                                em.andRegReg(false, .rax, .rcx);
                            },
                            else => unreachable,
                        }
                        emitStoreArm32Reg(&em, d.rd, .rax);
                    },

                    .cmp_lsl_reg_al, .cmp_lsr_reg_al => {
                        emitLoadArm32Reg(&em, .rax, d.rn, pc_page_off);
                        emitLoadArm32Reg(&em, .rcx, d.rm, pc_page_off);
                        const sh: u6 = @truncate(imm32);
                        if (op == .cmp_lsl_reg_al) em.shlImm(false, .rcx, sh) else em.shrImm(false, .rcx, sh);
                        em.subRegReg(false, .rax, .rcx);
                        emitUpdateNZCV_AddSub(&em, off_cpsr, true);
                    },

                    .mul_al => {
                        emitLoadArm32Reg(&em, .rax, d.rm, pc_page_off);
                        emitLoadArm32Reg(&em, .rcx, d.rn, pc_page_off);
                        em.imulRegReg(false, .rax, .rcx);
                        emitStoreArm32Reg(&em, d.rd, .rax);
                    },
                    .mla_al => {
                        emitLoadArm32Reg(&em, .rax, d.rm, pc_page_off);
                        emitLoadArm32Reg(&em, .rcx, d.rn, pc_page_off);
                        em.imulRegReg(false, .rax, .rcx);
                        emitLoadArm32Reg(&em, .rcx, @truncate(imm32), pc_page_off);
                        em.addRegReg(false, .rax, .rcx);
                        emitStoreArm32Reg(&em, d.rd, .rax);
                    },
                    .mls_al => {
                        emitLoadArm32Reg(&em, .rcx, d.rm, pc_page_off);
                        emitLoadArm32Reg(&em, .rdx, d.rn, pc_page_off);
                        em.imulRegReg(false, .rcx, .rdx);
                        emitLoadArm32Reg(&em, .rax, @truncate(imm32), pc_page_off);
                        em.subRegReg(false, .rax, .rcx);
                        emitStoreArm32Reg(&em, d.rd, .rax);
                    },
                    .umull_al, .umlal_al, .smull_al, .smlal_al => {
                        const rd_lo: u8 = @truncate(imm32);
                        emitLoadArm32Reg(&em, .rax, d.rm, pc_page_off);
                        emitLoadArm32Reg(&em, .rcx, d.rn, pc_page_off);
                        if (op == .smull_al or op == .smlal_al) {
                            em.movsxd32(.rax, .rax);
                            em.movsxd32(.rcx, .rcx);
                        }
                        em.imulRegReg(true, .rax, .rcx);
                        if (op == .umlal_al or op == .smlal_al) {
                            emitLoadArm32Reg(&em, .rcx, rd_lo, pc_page_off);
                            emitLoadArm32Reg(&em, .rdx, d.rd, pc_page_off);
                            em.shlImm(true, .rdx, 32);
                            em.orRegReg(true, .rcx, .rdx);
                            em.addRegReg(true, .rax, .rcx);
                        }
                        emitStoreArm32Reg(&em, rd_lo, .rax);
                        em.shrImm(true, .rax, 32);
                        emitStoreArm32Reg(&em, d.rd, .rax);
                    },

                    .uxtb_al, .uxth_al, .sxtb_al, .sxth_al => {
                        emitLoadArm32Reg(&em, .rax, d.rm, pc_page_off);
                        const rot: u6 = @truncate(imm32);
                        if (rot != 0) em.rorImm(false, .rax, rot);
                        switch (op) {
                            .uxtb_al => em.movzx8(false, .rax, .rax),
                            .uxth_al => em.movzx16(false, .rax, .rax),
                            .sxtb_al => em.movsx8(false, .rax, .rax),
                            .sxth_al => em.movsx16(false, .rax, .rax),
                            else => unreachable,
                        }
                        emitStoreArm32Reg(&em, d.rd, .rax);
                    },

                    .uxtab_al, .uxtah_al, .sxtab_al, .sxtah_al => {
                        emitLoadArm32Reg(&em, .rax, d.rm, pc_page_off);
                        const rot: u6 = @truncate(imm32);
                        if (rot != 0) em.rorImm(false, .rax, rot);
                        switch (op) {
                            .uxtab_al => em.movzx8(false, .rax, .rax),
                            .uxtah_al => em.movzx16(false, .rax, .rax),
                            .sxtab_al => em.movsx8(false, .rax, .rax),
                            .sxtah_al => em.movsx16(false, .rax, .rax),
                            else => unreachable,
                        }
                        emitLoadArm32Reg(&em, .rcx, d.rn, pc_page_off);
                        em.addRegReg(false, .rax, .rcx);
                        emitStoreArm32Reg(&em, d.rd, .rax);
                    },

                    .rev_al => {
                        emitLoadArm32Reg(&em, .rax, d.rm, pc_page_off);
                        em.bswap(false, .rax);
                        emitStoreArm32Reg(&em, d.rd, .rax);
                    },

                    .ubfx_al => {
                        emitLoadArm32Reg(&em, .rax, d.rm, pc_page_off);
                        const lsb: u6 = @truncate(d.rn & 0x1f);
                        if (lsb != 0) em.shrImm(false, .rax, lsb);
                        em.andRegImm(false, .rax, @bitCast(imm32));
                        emitStoreArm32Reg(&em, d.rd, .rax);
                    },
                    .sbfx_al => {
                        emitLoadArm32Reg(&em, .rax, d.rm, pc_page_off);
                        const sh_left: u6 = @truncate(d.rn & 0x1f);
                        const sh_right: u6 = @truncate(imm32 & 0x1f);
                        if (sh_left != 0) em.shlImm(false, .rax, sh_left);
                        if (sh_right != 0) em.sarImm(false, .rax, sh_right);
                        emitStoreArm32Reg(&em, d.rd, .rax);
                    },
                    .bfi_al => {
                        emitLoadArm32Reg(&em, .rax, d.rd, pc_page_off);
                        em.andRegImm(false, .rax, @bitCast(~imm32));
                        emitLoadArm32Reg(&em, .rcx, d.rm, pc_page_off);
                        const lsb: u6 = @truncate(d.rn & 0x1f);
                        if (lsb != 0) em.shlImm(false, .rcx, lsb);
                        em.andRegImm(false, .rcx, @bitCast(imm32));
                        em.orRegReg(false, .rax, .rcx);
                        emitStoreArm32Reg(&em, d.rd, .rax);
                    },
                    .bfc_al => {
                        emitLoadArm32Reg(&em, .rax, d.rd, pc_page_off);
                        em.andRegImm(false, .rax, @bitCast(~imm32));
                        emitStoreArm32Reg(&em, d.rd, .rax);
                    },

                    .clz_al => {
                        const zero_label = em.newLabel();
                        const done_clz = em.newLabel();
                        emitLoadArm32Reg(&em, .rcx, d.rm, pc_page_off);
                        em.testRegReg(false, .rcx, .rcx);
                        em.jccLabel(.e, zero_label);
                        em.emit8(0x0f);
                        em.emit8(0xbd);
                        em.emitModRmReg(Reg.rax.low3(), Reg.rcx.low3());
                        em.xorRegImm(false, .rax, 31);
                        em.jmpLabel(done_clz);
                        em.bindLabel(zero_label);
                        em.movImm32(.rax, 32);
                        em.bindLabel(done_clz);
                        emitStoreArm32Reg(&em, d.rd, .rax);
                    },

                    .ldr_imm_al, .str_imm_al, .ldrb_imm_al, .strb_imm_al, .ldrh_imm_al, .strh_imm_al, .ldrsb_imm_al, .ldrsh_imm_al, .ldrh_reg_al, .strh_reg_al, .ldrsb_reg_al, .ldrsh_reg_al, .ldr_wb_al, .str_wb_al, .ldrb_wb_al, .strb_wb_al, .ldr_lit_al, .ldr_reg_lsl_al, .str_reg_lsl_al, .ldrb_reg_lsl_al, .strb_reg_lsl_al, .ldr_reg_sub_lsl_al, .str_reg_sub_lsl_al, .ldrb_reg_sub_lsl_al, .strb_reg_sub_lsl_al, .ldr_reg_lsr_al, .str_reg_lsr_al => {
                        const is_load = switch (op) {
                            .ldr_imm_al, .ldrb_imm_al, .ldrh_imm_al, .ldrsb_imm_al, .ldrsh_imm_al, .ldrh_reg_al, .ldrsb_reg_al, .ldrsh_reg_al, .ldr_wb_al, .ldrb_wb_al, .ldr_lit_al, .ldr_reg_lsl_al, .ldrb_reg_lsl_al, .ldr_reg_sub_lsl_al, .ldrb_reg_sub_lsl_al, .ldr_reg_lsr_al => true,
                            else => false,
                        };
                        const size: u32 = switch (op) {
                            .ldr_imm_al, .str_imm_al, .ldr_wb_al, .str_wb_al, .ldr_lit_al, .ldr_reg_lsl_al, .str_reg_lsl_al, .ldr_reg_sub_lsl_al, .str_reg_sub_lsl_al, .ldr_reg_lsr_al, .str_reg_lsr_al => 4,
                            .ldrh_imm_al, .strh_imm_al, .ldrsh_imm_al, .ldrh_reg_al, .strh_reg_al, .ldrsh_reg_al => 2,
                            .ldrb_imm_al, .strb_imm_al, .ldrsb_imm_al, .ldrsb_reg_al, .ldrb_wb_al, .strb_wb_al, .ldrb_reg_lsl_al, .strb_reg_lsl_al, .ldrb_reg_sub_lsl_al, .strb_reg_sub_lsl_al => 1,
                            else => unreachable,
                        };
                        const is_signed = switch (op) {
                            .ldrsb_imm_al, .ldrsh_imm_al, .ldrsb_reg_al, .ldrsh_reg_al => true,
                            else => false,
                        };
                        const do_wb = switch (op) {
                            .ldr_wb_al, .str_wb_al, .ldrb_wb_al, .strb_wb_al => true,
                            else => false,
                        };
                        const is_reg_off = switch (op) {
                            .ldrh_reg_al, .strh_reg_al, .ldrsb_reg_al, .ldrsh_reg_al, .ldr_reg_lsl_al, .str_reg_lsl_al, .ldrb_reg_lsl_al, .strb_reg_lsl_al, .ldr_reg_sub_lsl_al, .str_reg_sub_lsl_al, .ldrb_reg_sub_lsl_al, .strb_reg_sub_lsl_al, .ldr_reg_lsr_al, .str_reg_lsr_al => true,
                            else => false,
                        };
                        const addr_off: i32 = @bitCast(imm32);
                        const wb_total_off: i32 = if (do_wb) @bitCast(@as(u32, @truncate(d.imm >> 32))) else 0;
                        const wb_from_vaddr: i32 = wb_total_off -% addr_off;

                        if (op == .ldr_lit_al) {
                            emitLoadArm32Reg(&em, .rdi, 15, pc_page_off);
                            if (addr_off != 0) em.addRegImm(false, .rdi, addr_off);
                        } else if (is_reg_off) {
                            emitLoadArm32Reg(&em, .rdi, d.rn, pc_page_off);
                            emitLoadArm32Reg(&em, .rcx, d.rm, pc_page_off);
                            const sh: u6 = if (op == .ldrh_reg_al or op == .strh_reg_al or op == .ldrsb_reg_al or op == .ldrsh_reg_al) 0 else @truncate(imm32 & 0x1f);
                            if (op == .ldr_reg_lsr_al or op == .str_reg_lsr_al) {
                                if (sh != 0) em.shrImm(false, .rcx, sh);
                            } else {
                                if (sh != 0) em.shlImm(false, .rcx, sh);
                            }
                            if (op == .ldr_reg_sub_lsl_al or op == .str_reg_sub_lsl_al or op == .ldrb_reg_sub_lsl_al or op == .strb_reg_sub_lsl_al) {
                                em.subRegReg(false, .rdi, .rcx);
                            } else {
                                em.addRegReg(false, .rdi, .rcx);
                            }
                        } else {
                            emitLoadArm32Reg(&em, .rdi, d.rn, pc_page_off);
                            if (addr_off != 0) em.addRegImm(false, .rdi, addr_off);
                        }

                        const slow_label = em.newLabel();
                        const done_label = em.newLabel();

                        em.movRegReg(false, .rcx, .rdi);
                        em.shrImm(false, .rcx, 8);
                        em.andRegImm(false, .rcx, 0xfff0);

                        const align_mask: i32 = switch (size) {
                            4 => -4093,
                            2 => -4095,
                            1 => -4096,
                            else => unreachable,
                        };
                        em.movRegReg(false, .rax, .rdi);
                        em.andRegImm(false, .rax, align_mask);
                        em.cmpSibReg(false, .rbp, .rcx, 0, if (is_load) off_tlb32_read_vpage else off_tlb32_write_vpage, .rax);
                        em.jccLabel(.ne, slow_label);

                        em.movRegSib(false, .rax, .rbp, .rcx, 0, off_tlb32_pbase);
                        em.movRegReg(false, .rdx, .rdi);
                        em.andRegImm(false, .rdx, 0xfff);
                        em.orRegReg(false, .rax, .rdx);

                        if (is_load) {
                            switch (size) {
                                4 => em.movRegSib(false, .rax, .r13, .rax, 0, 0),
                                2 => {
                                    em.movzxSib16(.rax, .r13, .rax, 0, 0);
                                    if (is_signed) em.movsx16(false, .rax, .rax);
                                },
                                1 => {
                                    em.movzxSib8(.rax, .r13, .rax, 0, 0);
                                    if (is_signed) em.movsx8(false, .rax, .rax);
                                },
                                else => unreachable,
                            }
                            if (do_wb) {
                                em.leaRegMem(false, .rcx, .rdi, wb_from_vaddr);
                                emitStoreArm32Reg(&em, d.rn, .rcx);
                            }
                            emitStoreArm32Reg(&em, d.rd, .rax);
                        } else {
                            emitLoadArm32Reg(&em, .rcx, d.rd, pc_page_off);
                            switch (size) {
                                4 => em.movSibReg(false, .r13, .rax, 0, 0, .rcx),
                                2 => em.movSib16Reg(.r13, .rax, 0, 0, .rcx),
                                1 => em.movSib8Reg(.r13, .rax, 0, 0, .rcx),
                                else => unreachable,
                            }
                            if (do_wb) {
                                em.leaRegMem(false, .rcx, .rdi, wb_from_vaddr);
                                emitStoreArm32Reg(&em, d.rn, .rcx);
                            }
                        }
                        em.jmpLabel(done_label);

                        em.bindLabel(slow_label);
                        const size_and_rn: u32 = size | (if (do_wb) @as(u32, 0x10) else 0) | (@as(u32, d.rn) << 8);
                        const pc_and_wb: u64 = @as(u64, pc_page_off) | (@as(u64, @as(u32, @bitCast(wb_from_vaddr))) << 32);
                        if (is_load) {
                            em.movRegReg(false, .rdx, .rdi);
                            em.movRegReg(true, .rdi, .rbx);
                            em.movRegReg(true, .rsi, .r12);
                            if (pc_and_wb <= 0xffff_ffff) {
                                em.movImm32(.rcx, @truncate(pc_and_wb));
                            } else {
                                em.movImm64(.rcx, pc_and_wb);
                            }
                            em.movImm32(.r8, size_and_rn);
                            em.movImm64(.r11, @intFromPtr(&jitSlowLoad32));
                            em.callReg(.r11);

                            em.cmpRegImm(true, .rdx, 1);
                            em.jccLabel(.e, epilogue_label);
                            if (is_signed) {
                                if (size == 2) em.movsx16(false, .rax, .rax) else em.movsx8(false, .rax, .rax);
                            }
                            emitStoreArm32Reg(&em, d.rd, .rax);
                        } else {
                            em.movRegReg(false, .rdx, .rdi);
                            emitLoadArm32Reg(&em, .rcx, d.rd, pc_page_off);
                            em.movRegReg(true, .rdi, .rbx);
                            em.movRegReg(true, .rsi, .r12);
                            if (pc_and_wb <= 0xffff_ffff) {
                                em.movImm32(.r8, @truncate(pc_and_wb));
                            } else {
                                em.movImm64(.r8, pc_and_wb);
                            }
                            em.movImm32(.r9, size_and_rn);
                            em.movImm64(.r11, @intFromPtr(&jitSlowStore32));
                            em.callReg(.r11);

                            em.testRegReg(true, .rax, .rax);
                            em.jccLabel(.ne, epilogue_label);
                        }

                        em.bindLabel(done_label);
                    },

                    .ldrd_imm_al, .strd_imm_al => {
                        const is_load = op == .ldrd_imm_al;
                        const addr_off: i32 = @bitCast(imm32);
                        emitLoadArm32Reg(&em, .rdi, d.rn, pc_page_off);
                        if (addr_off != 0) em.addRegImm(false, .rdi, addr_off);

                        const slow_label = em.newLabel();
                        const done_label = em.newLabel();

                        em.movRegReg(false, .rcx, .rdi);
                        em.shrImm(false, .rcx, 8);
                        em.andRegImm(false, .rcx, 0xfff0);

                        em.movRegReg(false, .rax, .rdi);
                        em.andRegImm(false, .rax, -4093); // ~0xffc
                        em.cmpSibReg(false, .rbp, .rcx, 0, if (is_load) off_tlb32_read_vpage else off_tlb32_write_vpage, .rax);
                        em.jccLabel(.ne, slow_label);
                        em.leaRegMem(false, .rdx, .rdi, 4);
                        em.andRegImm(false, .rdx, -4093);
                        em.cmpRegReg(false, .rax, .rdx);
                        em.jccLabel(.ne, slow_label);

                        em.movRegSib(false, .rax, .rbp, .rcx, 0, off_tlb32_pbase);
                        em.movRegReg(false, .rdx, .rdi);
                        em.andRegImm(false, .rdx, 0xfff);
                        em.orRegReg(false, .rax, .rdx);

                        if (is_load) {
                            em.movRegSib(true, .rax, .r13, .rax, 0, 0);
                            emitStoreArm32Reg(&em, d.rd, .rax);
                            em.shrImm(true, .rax, 32);
                            emitStoreArm32Reg(&em, d.rd + 1, .rax);
                        } else {
                            emitLoadArm32Reg(&em, .rcx, d.rd, pc_page_off);
                            em.movSibReg(false, .r13, .rax, 0, 0, .rcx);
                            emitLoadArm32Reg(&em, .rcx, d.rd + 1, pc_page_off);
                            em.movSibReg(false, .r13, .rax, 0, 4, .rcx);
                        }
                        em.jmpLabel(done_label);

                        em.bindLabel(slow_label);
                        if (is_load) {
                            em.movRegReg(false, .rdx, .rdi);
                            em.movRegReg(true, .rdi, .rbx);
                            em.movRegReg(true, .rsi, .r12);
                            em.movImm32(.rcx, pc_page_off);
                            em.movImm32(.r8, 8);
                            em.movImm64(.r11, @intFromPtr(&jitSlowLoad32));
                            em.callReg(.r11);

                            em.testRegReg(true, .rdx, .rdx);
                            em.jccLabel(.ne, epilogue_label);
                            emitStoreArm32Reg(&em, d.rd, .rax);
                            em.shrImm(true, .rax, 32);
                            emitStoreArm32Reg(&em, d.rd + 1, .rax);
                        } else {
                            em.movRegReg(false, .rdx, .rdi);
                            emitLoadArm32Reg(&em, .rcx, d.rd, pc_page_off);
                            emitLoadArm32Reg(&em, .rax, d.rd + 1, pc_page_off);
                            em.shlImm(true, .rax, 32);
                            em.orRegReg(true, .rcx, .rax);
                            em.movRegReg(true, .rdi, .rbx);
                            em.movRegReg(true, .rsi, .r12);
                            em.movImm32(.r8, pc_page_off);
                            em.movImm32(.r9, 8);
                            em.movImm64(.r11, @intFromPtr(&jitSlowStore32));
                            em.callReg(.r11);

                            em.testRegReg(true, .rax, .rax);
                            em.jccLabel(.ne, epilogue_label);
                        }

                        em.bindLabel(done_label);
                    },

                    .ldm_al, .stm_al => {
                        const is_load = op == .ldm_al;
                        const reg_list: u16 = @truncate(d.imm);
                        const last_off: u16 = @truncate(d.imm >> 16);
                        const start_off: i32 = @as(i16, @bitCast(@as(u16, @truncate(d.imm >> 32))));
                        const wb_off: i32 = @as(i16, @bitCast(@as(u16, @truncate(d.imm >> 48))));

                        emitLoadArm32Reg(&em, .rdi, d.rn, pc_page_off);
                        if (start_off != 0) em.addRegImm(false, .rdi, start_off);

                        const slow_label = em.newLabel();
                        const done_label = em.newLabel();

                        em.movRegReg(false, .rcx, .rdi);
                        em.shrImm(false, .rcx, 8);
                        em.andRegImm(false, .rcx, 0xfff0);

                        em.movRegReg(false, .rax, .rdi);
                        em.andRegImm(false, .rax, -4093); // ~0xffc
                        em.cmpSibReg(false, .rbp, .rcx, 0, if (is_load) off_tlb32_read_vpage else off_tlb32_write_vpage, .rax);
                        em.jccLabel(.ne, slow_label);
                        if (last_off != 0) {
                            em.leaRegMem(false, .rdx, .rdi, @intCast(last_off));
                            em.andRegImm(false, .rdx, -4093);
                            em.cmpRegReg(false, .rax, .rdx);
                            em.jccLabel(.ne, slow_label);
                        }

                        em.movRegSib(false, .rax, .rbp, .rcx, 0, off_tlb32_pbase);
                        em.movRegReg(false, .rdx, .rdi);
                        em.andRegImm(false, .rdx, 0xfff);
                        em.orRegReg(false, .rax, .rdx);

                        var cur_disp: i32 = 0;
                        var rem: u16 = reg_list;
                        while (rem != 0) {
                            const r_idx: u4 = @intCast(@ctz(rem));
                            const pair_mask: u16 = @as(u16, 3) << r_idx;
                            if (r_idx < 14 and (rem & pair_mask) == pair_mask) {
                                if (is_load) {
                                    em.movRegSib(true, .rcx, .r13, .rax, 0, cur_disp);
                                    em.movMemReg(true, .rbx, arm32RegOff(r_idx), .rcx);
                                } else {
                                    em.movRegMem(true, .rcx, .rbx, arm32RegOff(r_idx));
                                    em.movSibReg(true, .r13, .rax, 0, cur_disp, .rcx);
                                }
                                cur_disp += 8;
                                rem &= ~pair_mask;
                            } else {
                                if (is_load) {
                                    em.movRegSib(false, .rcx, .r13, .rax, 0, cur_disp);
                                    emitStoreArm32Reg(&em, r_idx, .rcx);
                                } else {
                                    emitLoadArm32Reg(&em, .rcx, r_idx, pc_page_off);
                                    em.movSibReg(false, .r13, .rax, 0, cur_disp, .rcx);
                                }
                                cur_disp += 4;
                                rem &= rem - 1;
                            }
                        }
                        if (wb_off != 0) {
                            em.leaRegMem(false, .rcx, .rdi, wb_off -% start_off);
                            emitStoreArm32Reg(&em, d.rn, .rcx);
                        }
                        em.jmpLabel(done_label);

                        em.bindLabel(slow_label);
                        em.movRegReg(true, .rdi, .rbx);
                        em.movRegReg(true, .rsi, .r12);
                        em.movImm32(.rdx, pc_page_off);
                        em.movImm32(.rcx, raw);
                        em.movImm64(.r11, @intFromPtr(&jitSlowLdmStm32));
                        em.callReg(.r11);
                        em.testRegReg(true, .rax, .rax);
                        em.jccLabel(.ne, epilogue_label);

                        em.bindLabel(done_label);
                    },

                    .bx_lr_al, .bx_reg_al, .blx_reg_al => {
                        const rm: u8 = if (op == .bx_lr_al) 14 else d.rm;
                        emitLoadArm32Reg(&em, .rax, rm, pc_page_off);
                        if (op == .blx_reg_al) {
                            em.movRegMem(false, .rcx, .rbx, off_r15);
                            em.addRegImm(false, .rcx, @intCast(pc_page_off + 4));
                            emitStoreArm32Reg(&em, 14, .rcx);
                        }
                        const thumb_label = em.newLabel();
                        em.testRegImm32(false, .rax, 1);
                        em.jccLabel(.ne, thumb_label);
                        em.andRegImm(false, .rax, -4);
                        em.movMemReg(false, .rbx, off_r15, .rax);
                        if (cond < 0xe) {
                            const skip_after = em.newLabel();
                            em.jmpLabel(epilogue_label);
                            em.bindLabel(thumb_label);
                            em.andRegImm(false, .rax, -2);
                            em.movMemReg(false, .rbx, off_r15, .rax);
                            em.movRegMem(false, .rcx, .rbx, off_cpsr);
                            em.orRegImm(false, .rcx, 1 << 5);
                            em.movMemReg(false, .rbx, off_cpsr, .rcx);
                            em.jmpLabel(epilogue_label);
                            _ = skip_after;
                        } else {
                            em.jmpLabel(epilogue_label);
                            em.bindLabel(thumb_label);
                            em.andRegImm(false, .rax, -2);
                            em.movMemReg(false, .rbx, off_r15, .rax);
                            em.movRegMem(false, .rcx, .rbx, off_cpsr);
                            em.orRegImm(false, .rcx, 1 << 5);
                            em.movMemReg(false, .rbx, off_cpsr, .rcx);
                            em.jmpLabel(epilogue_label);
                        }
                    },

                    else => unreachable,
                }

                if (cond < 0xe) {
                    em.bindLabel(skip_label);
                }
            }

            const last_d = decoded[trace_len - 1];
            const last_op: ArmOp = @enumFromInt(last_d.op);
            if (!isTerminator(last_op, last_d.raw)) {
                em.addMemImm32(false, .rbx, off_r15, @intCast(@as(u32, end_word) * 4));
                em.jmpLabel(epilogue_label);
            }

            for (exit_stubs[0..exit_stub_count]) |stub| {
                em.bindLabel(stub.label);
                em.addMemImm32(false, .rbx, off_r15, stub.pc_delta);
                em.jmpLabel(epilogue_label);
            }

            em.bindLabel(epilogue_label);
            em.emitEpilogue();

            if (!em.resolveFixups()) return null;
            return buf.allocCode(core_id, em.buf[0..em.len]);
        }
    };
}

test "X64Emitter encodes basic arithmetic and branches" {
    var em = X64Emitter{};
    em.emitPrologue();
    const done_label = em.newLabel();
    em.addRegImm(true, .r15, 5);
    em.jmpLabel(done_label);
    em.addRegImm(true, .r15, 100);
    em.bindLabel(done_label);
    em.emitEpilogue();
    try std.testing.expect(em.resolveFixups());
    try std.testing.expect(em.len > 16);

    if (is_x86_64_linux) {
        var jbuf: JitCodeBuffer = .{};
        const fn_ptr = jbuf.allocCode(0, em.buf[0..em.len]).?;
        var dummy: u64 = 0;
        const ran = fn_ptr(&dummy, &dummy, @ptrCast(&dummy), &dummy, 10, @ptrCast(&dummy));
        try std.testing.expectEqual(@as(usize, 5), ran);
    }
}


