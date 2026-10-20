const std = @import("std");
const builtin = @import("builtin");
const mmu_mod = @import("mmu.zig");
const vfp_mod = @import("vfp.zig");
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

pub const TraceCacheEntry = struct {
    page_ptr: usize = 0,
    start_word: u16 = 0xffff,
    end_word_req: u16 = 0,
    trace_len: u8 = 0,
    failed: bool = false,
    is_spin: bool = false,
    code_hash: u64 = 0,
    fn_ptr: ?JitFn = null,
};

pub const JitCodeBuffer = struct {
    pub const capacity: usize = 16 * 1024 * 1024;
    pub const trace_cache_size: usize = 512;

    used: usize = 0,
    loop_counts: [256]u8 = @splat(0),
    call_counts: [256]u8 = @splat(0),
    spin_hashes: [4]u64 = @splat(0),
    trace_cache: [trace_cache_size]TraceCacheEntry = @splat(.{}),

    pub inline fn isSpinHash(self: *const JitCodeBuffer, h: u8) bool {
        return ((self.spin_hashes[h >> 6] >> @intCast(h & 63)) & 1) != 0;
    }

    pub inline fn setSpinHash(self: *JitCodeBuffer, h: u8) void {
        self.spin_hashes[h >> 6] |= (@as(u64, 1) << @intCast(h & 63));
    }

    /// Hashes on the decoded-icache page slot (derived from the guest physical address) rather than the
    /// host pointer, so trace placement - and with it `--clock instructions` timing - doesn't vary with ASLR.
    pub inline fn traceCacheIdx(code_page_idx: usize, start_word: u10, end_word_req: u16) usize {
        const p = code_page_idx *% 0x9E3779B1;
        return (p ^ (p >> 8) ^ @as(usize, start_word) ^ (@as(usize, end_word_req) << 4)) & (trace_cache_size - 1);
    }

    pub inline fn hashLoopWords(code_page_ptr: [*]const u8, start_word: u10, end_word_req: u16) u64 {
        var h: u64 = 0xcbf29ce484222325;
        var w: usize = start_word;
        const limit: usize = if (end_word_req != 0) end_word_req else @min(@as(usize, 1024), @as(usize, start_word) + 64);
        while (w < limit) : (w += 1) {
            const inst = std.mem.readInt(u32, code_page_ptr[w * 4 ..][0..4], .little);
            h = (h ^ inst) *% 0x100000001b3;
        }
        return h;
    }

    pub inline fn traceCacheIdxThumb(thumb_page_idx: usize, start_hw: u11, end_hw_req: u16) usize {
        const p = thumb_page_idx *% 0x9E3779B1;
        return (p ^ (p >> 8) ^ @as(usize, start_hw) ^ (@as(usize, end_hw_req) << 4) ^ 0x155) & (trace_cache_size - 1);
    }

    pub inline fn hashThumbHalfwords(code_page_ptr: [*]const u8, start_hw: u11, end_hw_req: u16) u64 {
        var h: u64 = 0xcbf29ce484222325;
        var hw: usize = start_hw;
        const limit: usize = if (end_hw_req != 0) end_hw_req else @min(@as(usize, 2048), @as(usize, start_hw) + 64);
        while (hw < limit) : (hw += 1) {
            const inst = std.mem.readInt(u16, code_page_ptr[hw * 2 ..][0..2], .little);
            h = (h ^ inst) *% 0x100000001b3;
        }
        return h;
    }

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
        self.call_counts = @splat(0);
        self.spin_hashes = @splat(0);
        self.trace_cache = @splat(.{});
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

pub const Xmm = enum(u4) {
    xmm0 = 0,
    xmm1 = 1,
    xmm2 = 2,
    xmm3 = 3,

    pub inline fn low3(self: Xmm) u8 {
        return @intCast(@intFromEnum(self) & 7);
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
    p = 0xa, // parity / unordered NaN
    np = 0xb,
    l = 0xc, // signed <
    ge = 0xd, // signed >=
    le = 0xe, // signed <=
    g = 0xf, // signed >
};

const Fixup = struct {
    disp_offset: u32,
    label: u16,
};

pub const host_pin_regs = [5]Reg{ .r8, .r9, .r10, .r11, .rsi };

pub const RegPinSet = struct {
    guest_regs: [5]u8 = @splat(0xff),
    count: u8 = 0,

    pub inline fn getHost(self: RegPinSet, guest_reg: u8) ?Reg {
        inline for (0..5) |i| {
            if (i < self.count and self.guest_regs[i] == guest_reg) return host_pin_regs[i];
        }
        return null;
    }

    pub inline fn isPinned(self: RegPinSet, guest_reg: u8) bool {
        return self.getHost(guest_reg) != null;
    }
};

pub const X64Emitter = struct {
    buf: [32768]u8 = undefined,
    len: usize = 0,
    labels: [1024]i32 = @splat(-1),
    label_count: u16 = 0,
    fixups: [2048]Fixup = undefined,
    fixup_count: usize = 0,
    pins: RegPinSet = .{},

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

    pub fn adcRegReg(self: *X64Emitter, is64: bool, dst: Reg, src: Reg) void {
        self.emitAluRegReg(0x11, is64, dst, src);
    }

    pub fn mulReg1(self: *X64Emitter, is64: bool, src: Reg) void {
        self.emitRex(is64, false, false, src.isExt(), false);
        self.emit8(0xf7);
        self.emitModRmReg(4, src.low3());
    }

    pub fn imulReg1(self: *X64Emitter, is64: bool, src: Reg) void {
        self.emitRex(is64, false, false, src.isExt(), false);
        self.emit8(0xf7);
        self.emitModRmReg(5, src.low3());
    }

    pub fn divReg1(self: *X64Emitter, is64: bool, src: Reg) void {
        self.emitRex(is64, false, false, src.isExt(), false);
        self.emit8(0xf7);
        self.emitModRmReg(6, src.low3());
    }

    pub fn idivReg1(self: *X64Emitter, is64: bool, src: Reg) void {
        self.emitRex(is64, false, false, src.isExt(), false);
        self.emit8(0xf7);
        self.emitModRmReg(7, src.low3());
    }

    pub fn cdqCqo(self: *X64Emitter, is64: bool) void {
        if (is64) self.emit8(0x48);
        self.emit8(0x99);
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

    pub fn movupsLoad(self: *X64Emitter, dst: Xmm, base: Reg, disp: i32) void {
        self.emitRex(false, false, false, base.isExt(), false);
        self.emit8(0x0f);
        self.emit8(0x10);
        self.emitModRmMem(dst.low3(), base, disp);
    }

    pub fn movupsStore(self: *X64Emitter, base: Reg, disp: i32, src: Xmm) void {
        self.emitRex(false, false, false, base.isExt(), false);
        self.emit8(0x0f);
        self.emit8(0x11);
        self.emitModRmMem(src.low3(), base, disp);
    }

    pub fn movupsLoadSib(self: *X64Emitter, dst: Xmm, base: Reg, index: Reg, scale_log2: u2, disp: i32) void {
        self.emitRex(false, false, index.isExt(), base.isExt(), false);
        self.emit8(0x0f);
        self.emit8(0x10);
        self.emitModRmSib(dst.low3(), base, index, scale_log2, disp);
    }

    pub fn movupsStoreSib(self: *X64Emitter, base: Reg, index: Reg, scale_log2: u2, disp: i32, src: Xmm) void {
        self.emitRex(false, false, index.isExt(), base.isExt(), false);
        self.emit8(0x0f);
        self.emit8(0x11);
        self.emitModRmSib(src.low3(), base, index, scale_log2, disp);
    }

    pub fn movsdLoad(self: *X64Emitter, dst: Xmm, base: Reg, disp: i32) void {
        self.emit8(0xf2);
        self.emitRex(false, false, false, base.isExt(), false);
        self.emit8(0x0f);
        self.emit8(0x10);
        self.emitModRmMem(dst.low3(), base, disp);
    }

    pub fn movsdStore(self: *X64Emitter, base: Reg, disp: i32, src: Xmm) void {
        self.emit8(0xf2);
        self.emitRex(false, false, false, base.isExt(), false);
        self.emit8(0x0f);
        self.emit8(0x11);
        self.emitModRmMem(src.low3(), base, disp);
    }

    pub fn movssLoad(self: *X64Emitter, dst: Xmm, base: Reg, disp: i32) void {
        self.emit8(0xf3);
        self.emitRex(false, false, false, base.isExt(), false);
        self.emit8(0x0f);
        self.emit8(0x10);
        self.emitModRmMem(dst.low3(), base, disp);
    }

    pub fn movssStore(self: *X64Emitter, base: Reg, disp: i32, src: Xmm) void {
        self.emit8(0xf3);
        self.emitRex(false, false, false, base.isExt(), false);
        self.emit8(0x0f);
        self.emit8(0x11);
        self.emitModRmMem(src.low3(), base, disp);
    }

    inline fn emitSseOp(self: *X64Emitter, prefix: u8, op: u8, dst: Xmm, src: Xmm) void {
        self.emit8(prefix);
        self.emit8(0x0f);
        self.emit8(op);
        self.emitModRmReg(dst.low3(), src.low3());
    }

    pub fn addsd(self: *X64Emitter, dst: Xmm, src: Xmm) void {
        self.emitSseOp(0xf2, 0x58, dst, src);
    }

    pub fn subsd(self: *X64Emitter, dst: Xmm, src: Xmm) void {
        self.emitSseOp(0xf2, 0x5c, dst, src);
    }

    pub fn mulsd(self: *X64Emitter, dst: Xmm, src: Xmm) void {
        self.emitSseOp(0xf2, 0x59, dst, src);
    }

    pub fn divsd(self: *X64Emitter, dst: Xmm, src: Xmm) void {
        self.emitSseOp(0xf2, 0x5e, dst, src);
    }

    pub fn addss(self: *X64Emitter, dst: Xmm, src: Xmm) void {
        self.emitSseOp(0xf3, 0x58, dst, src);
    }

    pub fn subss(self: *X64Emitter, dst: Xmm, src: Xmm) void {
        self.emitSseOp(0xf3, 0x5c, dst, src);
    }

    pub fn mulss(self: *X64Emitter, dst: Xmm, src: Xmm) void {
        self.emitSseOp(0xf3, 0x59, dst, src);
    }

    pub fn divss(self: *X64Emitter, dst: Xmm, src: Xmm) void {
        self.emitSseOp(0xf3, 0x5e, dst, src);
    }

    pub fn pand(self: *X64Emitter, dst: Xmm, src: Xmm) void {
        self.emitSseOp(0x66, 0xdb, dst, src);
    }

    pub fn pandn(self: *X64Emitter, dst: Xmm, src: Xmm) void {
        self.emitSseOp(0x66, 0xdf, dst, src);
    }

    pub fn por(self: *X64Emitter, dst: Xmm, src: Xmm) void {
        self.emitSseOp(0x66, 0xeb, dst, src);
    }

    pub fn pxor(self: *X64Emitter, dst: Xmm, src: Xmm) void {
        self.emitSseOp(0x66, 0xef, dst, src);
    }

    pub fn paddb(self: *X64Emitter, dst: Xmm, src: Xmm) void {
        self.emitSseOp(0x66, 0xfc, dst, src);
    }

    pub fn paddw(self: *X64Emitter, dst: Xmm, src: Xmm) void {
        self.emitSseOp(0x66, 0xfd, dst, src);
    }

    pub fn paddd(self: *X64Emitter, dst: Xmm, src: Xmm) void {
        self.emitSseOp(0x66, 0xfe, dst, src);
    }

    pub fn paddq(self: *X64Emitter, dst: Xmm, src: Xmm) void {
        self.emitSseOp(0x66, 0xd4, dst, src);
    }

    pub fn psubb(self: *X64Emitter, dst: Xmm, src: Xmm) void {
        self.emitSseOp(0x66, 0xf8, dst, src);
    }

    pub fn psubw(self: *X64Emitter, dst: Xmm, src: Xmm) void {
        self.emitSseOp(0x66, 0xf9, dst, src);
    }

    pub fn psubd(self: *X64Emitter, dst: Xmm, src: Xmm) void {
        self.emitSseOp(0x66, 0xfa, dst, src);
    }

    pub fn psubq(self: *X64Emitter, dst: Xmm, src: Xmm) void {
        self.emitSseOp(0x66, 0xfb, dst, src);
    }

    pub fn pcmpeqb(self: *X64Emitter, dst: Xmm, src: Xmm) void {
        self.emitSseOp(0x66, 0x74, dst, src);
    }

    pub fn ucomisd(self: *X64Emitter, a: Xmm, b: Xmm) void {
        self.emitSseOp(0x66, 0x2e, a, b);
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

const FlagSetKind = enum {
    none,
    add,
    sub,
    logic_clear_cv,
    logic_keep_cv,
};

fn armCondToX86Cond(cond: u4, kind: FlagSetKind, jump_if_true: bool) ?Cond {
    const base_cond: u3 = @intCast(cond >> 1);
    const invert = ((cond & 1) != 0) != (!jump_if_true);
    return switch (base_cond) {
        0 => if (invert) .ne else .e, // EQ / NE: Z == 1
        1 => switch (kind) { // CS / CC: C == 1
            .sub => if (invert) .b else .ae, // ARM C = !CF on x86 SUB
            .add => if (invert) .ae else .b, // ARM C = CF on x86 ADD
            else => null,
        },
        2 => if (invert) .ns else .s, // MI / PL: N == 1
        3 => switch (kind) { // VS / VC: V == 1
            .sub, .add => if (invert) .no else .o,
            else => null,
        },
        4 => switch (kind) { // HI / LS: C == 1 and Z == 0
            .sub => if (invert) .be else .a, // !CF and !ZF -> JA
            else => null,
        },
        5 => switch (kind) { // GE / LT: N == V
            .sub, .add => if (invert) .l else .ge,
            else => null,
        },
        6 => switch (kind) { // GT / LE: Z == 0 and N == V
            .sub, .add => if (invert) .le else .g,
            else => null,
        },
        else => null,
    };
}

fn emitUpdateNZCV_AddSub(em: *X64Emitter, state_disp: i32, is_sub: bool) void {
    // Capture all 4 condition flags before any shift/or modifies EFLAGS!
    // Use .rdi (fast-path scratch) instead of .r8 so .r8..r11 and .rsi stay reserved for pinned guest regs.
    em.setcc(.s, .rax); // N
    em.setcc(.e, .rcx); // Z
    em.setcc(if (is_sub) .ae else .b, .rdx); // C: ARM C = !borrow (ae) for SUB, carry (b) for ADD
    em.setcc(.o, .rdi); // V

    em.movzx8(false, .rax, .rax);
    em.movzx8(false, .rcx, .rcx);
    em.movzx8(false, .rdx, .rdx);
    em.movzx8(false, .rdi, .rdi);

    em.shlImm(false, .rax, 31);
    em.shlImm(false, .rcx, 30);
    em.shlImm(false, .rdx, 29);
    em.shlImm(false, .rdi, 28);

    em.orRegReg(false, .rax, .rcx);
    em.orRegReg(false, .rax, .rdx);
    em.orRegReg(false, .rax, .rdi);

    em.movRegMem(false, .rcx, .rbx, state_disp);
    em.andRegImm(false, .rcx, 0x0fff_ffff);
    em.orRegReg(false, .rcx, .rax);
    em.movMemReg(false, .rbx, state_disp, .rcx);
}

fn emitDeferredFlagUpdate(em: *X64Emitter, state_disp: i32, kind: FlagSetKind) void {
    switch (kind) {
        .none => {},
        .add => emitUpdateNZCV_AddSub(em, state_disp, false),
        .sub => emitUpdateNZCV_AddSub(em, state_disp, true),
        .logic_clear_cv => emitUpdateNZ_Logic(em, state_disp, false),
        .logic_keep_cv => emitUpdateNZ_Logic(em, state_disp, true),
    }
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
    const off_sp_el0: i32 = @intCast(@offsetOf(CpuType, "sp_el"));
    const off_excl_valid: i32 = @intCast(@offsetOf(CpuType, "excl_valid"));
    const off_tpidr_el0: i32 = @intCast(@offsetOf(CpuType, "mmu") + @offsetOf(mmu_mod.Mmu, "tpidr_el0"));
    const off_tpidrro_el0: i32 = @intCast(@offsetOf(CpuType, "mmu") + @offsetOf(mmu_mod.Mmu, "tpidrro_el0"));
    const off_tpidr_el1: i32 = @intCast(@offsetOf(CpuType, "mmu") + @offsetOf(mmu_mod.Mmu, "tpidr_el1"));
    const off_tpidr_el2: i32 = @intCast(@offsetOf(CpuType, "mmu") + @offsetOf(mmu_mod.Mmu, "tpidr_el2"));
    const off_vfp_v: i32 = @intCast(@offsetOf(CpuType, "vfp") + @offsetOf(vfp_mod.Vfp, "v"));

    return struct {
        inline fn a64RegOff(reg: u5) i32 {
            return off_x + @as(i32, reg) * 8;
        }

        inline fn a64VfpOff(reg: u8) i32 {
            return off_vfp_v + @as(i32, reg & 0x1f) * 16;
        }

        inline fn sysRegId(op0: u2, op1: u3, crn: u4, crm: u4, op2: u3) u16 {
            return (@as(u16, op0) << 14) | (@as(u16, op1) << 11) | (@as(u16, crn) << 7) | (@as(u16, crm) << 3) | @as(u16, op2);
        }

        inline fn slotSysRegId(comptime SlotType: type, d: SlotType) u16 {
            return sysRegId(@truncate(d.rn >> 3), @truncate(d.rn), @truncate(d.rm >> 4), @truncate(d.rm), @truncate(d.imm));
        }

        fn canCompileLoadStoreOther64(raw: u32) bool {
            const size: u2 = @truncate(raw >> 30);
            const opc: u2 = @truncate(raw >> 22);
            const rn: u8 = @truncate((raw >> 5) & 0x1f);
            const rt: u8 = @truncate(raw & 0x1f);
            if (opc == 0b10 and size == 3) return false;
            if (opc == 0b11 and size >= 2) return false;
            if ((raw & 0x3f20_0400) == 0x3800_0400) {
                return rn != rt;
            }
            if ((raw & 0x3f20_0c00) == 0x3820_0800) {
                const option: u3 = @truncate(raw >> 13);
                return option == 0b010 or option == 0b011 or option == 0b110 or option == 0b111;
            }
            return false;
        }

        fn emitReloadPinned64(em: *X64Emitter) void {
            for (0..em.pins.count) |i| {
                const r: u5 = @intCast(em.pins.guest_regs[i]);
                em.movRegMem(true, host_pin_regs[i], .rbx, a64RegOff(r));
            }
        }

        fn emitSpillPinned64(em: *X64Emitter) void {
            for (0..em.pins.count) |i| {
                const r: u5 = @intCast(em.pins.guest_regs[i]);
                em.movMemReg(true, .rbx, a64RegOff(r), host_pin_regs[i]);
            }
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
            } else if (em.pins.getHost(r)) |hreg| {
                if (!is64 or dst != hreg) {
                    em.movRegReg(is64, dst, hreg);
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
            } else if (em.pins.getHost(r)) |hreg| {
                if (hreg != src) {
                    em.movRegReg(true, hreg, src);
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
            abort_epilogue_label: u16,
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
            emitSpillPinned64(em);
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
            em.jccLabel(.e, abort_epilogue_label);
            emitReloadPinned64(em);

            if ((rd & 0x1f) != 31) {
                emitStoreA64Reg(em, rd, .rax, false, .rcx);
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
            abort_epilogue_label: u16,
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
            emitSpillPinned64(em);
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
            em.jccLabel(.ne, abort_epilogue_label);
            emitReloadPinned64(em);

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
            abort_epilogue_label: u16,
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
                    em.leaRegMem(true, .rdi, .rdi, wb_disp);
                    emitStoreA64Reg(em, rn & 0x1f, .rdi, true, .rax);
                }
                if ((rd & 0x1f) != 31) emitStoreA64Reg(em, rd & 0x1f, .rcx, false, .rax);
                if ((rm & 0x1f) != 31) emitStoreA64Reg(em, rm & 0x1f, .rdx, false, .rax);
            } else {
                emitLoadA64Reg(em, is64, .rcx, rd & 0x1f, false);
                emitLoadA64Reg(em, is64, .rdx, rm & 0x1f, false);
                em.movSibReg(is64, .r13, .rax, 0, 0, .rcx);
                em.movSibReg(is64, .r13, .rax, 0, if (is64) 8 else 4, .rdx);
                if (do_wb) {
                    em.leaRegMem(true, .rdi, .rdi, wb_disp);
                    emitStoreA64Reg(em, rn & 0x1f, .rdi, true, .rax);
                }
            }
            em.jmpLabel(done_label);

            em.bindLabel(slow_label);
            emitSpillPinned64(em);
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
            em.jccLabel(.ne, abort_epilogue_label);
            emitReloadPinned64(em);

            em.bindLabel(done_label);
        }

        pub fn jitSlowLoadFp64(
            cpu_opaque: *anyopaque,
            bus_opaque: *anyopaque,
            vaddr: u64,
            pc_and_wb: u64,
            info: u32,
        ) callconv(.c) u64 {
            const cpu: *CpuType = @ptrCast(@alignCast(cpu_opaque));
            const bus: *Bus = @ptrCast(@alignCast(bus_opaque));
            const pc_page_off: u32 = @truncate(pc_and_wb);
            const cur_pc = cpu.pc64 +% pc_page_off;
            const size: u5 = @intCast(info & 0x1f);
            const do_wb = (info & 0x20) != 0;
            const rd: u5 = @intCast((info >> 8) & 0x1f);
            const rn: u5 = @intCast((info >> 16) & 0x1f);
            const wb_disp: i32 = @bitCast(@as(u32, @truncate(pc_and_wb >> 32)));

            const val: u128 = switch (size) {
                4 => A64.readData32(cpu, bus, vaddr) catch {
                    A64.handleAbort64(cpu, cur_pc);
                    return 1;
                },
                8 => A64.readData64(cpu, bus, vaddr) catch {
                    A64.handleAbort64(cpu, cur_pc);
                    return 1;
                },
                16 => A64.readData128(cpu, bus, vaddr) catch {
                    A64.handleAbort64(cpu, cur_pc);
                    return 1;
                },
                else => unreachable,
            };
            cpu.vfp.v[rd] = val;
            if (do_wb) {
                A64.setXOrSp(cpu, rn, vaddr +% @as(u64, @bitCast(@as(i64, wb_disp))));
            }
            return 0;
        }

        pub fn jitSlowStoreFp64(
            cpu_opaque: *anyopaque,
            bus_opaque: *anyopaque,
            vaddr: u64,
            pc_and_wb: u64,
            info: u32,
        ) callconv(.c) u64 {
            const cpu: *CpuType = @ptrCast(@alignCast(cpu_opaque));
            const bus: *Bus = @ptrCast(@alignCast(bus_opaque));
            const pc_page_off: u32 = @truncate(pc_and_wb);
            const cur_pc = cpu.pc64 +% pc_page_off;
            const size: u5 = @intCast(info & 0x1f);
            const do_wb = (info & 0x20) != 0;
            const rd: u5 = @intCast((info >> 8) & 0x1f);
            const rn: u5 = @intCast((info >> 16) & 0x1f);
            const wb_disp: i32 = @bitCast(@as(u32, @truncate(pc_and_wb >> 32)));
            const val = cpu.vfp.v[rd];

            switch (size) {
                4 => A64.writeData32(cpu, bus, vaddr, @truncate(val)) catch {
                    A64.handleAbort64(cpu, cur_pc);
                    return 1;
                },
                8 => A64.writeData64(cpu, bus, vaddr, @truncate(val)) catch {
                    A64.handleAbort64(cpu, cur_pc);
                    return 1;
                },
                16 => A64.writeData128(cpu, bus, vaddr, val) catch {
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

        pub fn jitSlowPairFp64(
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
            const is128 = ((packed_info >> 15) & 1) != 0;
            const do_wb = ((packed_info >> 16) & 1) != 0;
            const is_load = ((packed_info >> 17) & 1) != 0;
            const wb_addr = vaddr +% @as(u64, @bitCast(@as(i64, @as(i32, @bitCast(@as(u32, @truncate(packed_info >> 32)))))));

            if (is_load) {
                if (is128) {
                    const v1 = A64.readData128(cpu, bus, vaddr) catch {
                        A64.handleAbort64(cpu, cur_pc);
                        return 1;
                    };
                    const v2 = A64.readData128(cpu, bus, vaddr +% 16) catch {
                        A64.handleAbort64(cpu, cur_pc);
                        return 1;
                    };
                    cpu.vfp.v[rt] = v1;
                    cpu.vfp.v[rt2] = v2;
                } else {
                    const pair = A64.readData128(cpu, bus, vaddr) catch {
                        A64.handleAbort64(cpu, cur_pc);
                        return 1;
                    };
                    cpu.vfp.v[rt] = @as(u64, @truncate(pair));
                    cpu.vfp.v[rt2] = @as(u64, @truncate(pair >> 64));
                }
                if (do_wb) A64.setXOrSp(cpu, rn, wb_addr);
                return 0;
            } else {
                if (is128) {
                    A64.writeData128(cpu, bus, vaddr, cpu.vfp.v[rt]) catch {
                        A64.handleAbort64(cpu, cur_pc);
                        return 1;
                    };
                    A64.writeData128(cpu, bus, vaddr +% 16, cpu.vfp.v[rt2]) catch {
                        A64.handleAbort64(cpu, cur_pc);
                        return 1;
                    };
                } else {
                    const v1: u64 = @truncate(cpu.vfp.v[rt]);
                    const v2: u64 = @truncate(cpu.vfp.v[rt2]);
                    A64.writeData128(cpu, bus, vaddr, @as(u128, v1) | (@as(u128, v2) << 64)) catch {
                        A64.handleAbort64(cpu, cur_pc);
                        return 1;
                    };
                }
                if (do_wb) A64.setXOrSp(cpu, rn, wb_addr);
                const priv: u1 = @intFromBool(A64.currentEl(cpu) != 0);
                const dslot = &cpu.mmu.soft_tlb64[priv][@as(usize, @truncate((vaddr >> 12) & mmu_mod.Mmu.soft_tlb_mask))];
                if ((vaddr & ~@as(u64, 0xfff)) != dslot.w_vbase) {
                    cpu.pc64 = cur_pc +% 4;
                    if (A64.checkInterrupts64(cpu, bus)) return 2;
                    cpu.pc64 = cur_pc -% pc_page_off;
                }
                return 0;
            }
        }

        pub fn jitSlowDcZva64(
            cpu_opaque: *anyopaque,
            bus_opaque: *anyopaque,
            base_va: u64,
            pc_page_off: u32,
        ) callconv(.c) u64 {
            const cpu: *CpuType = @ptrCast(@alignCast(cpu_opaque));
            const bus: *Bus = @ptrCast(@alignCast(bus_opaque));
            const cur_pc = cpu.pc64 +% pc_page_off;
            var off: u64 = 0;
            while (off < 64) : (off += 8) {
                A64.writeData64(cpu, bus, base_va +% off, 0) catch {
                    A64.handleAbort64(cpu, cur_pc);
                    return 1;
                };
            }
            return 0;
        }

        fn emitA64LoadFpAddr(
            em: *X64Emitter,
            rd: u8,
            rn: u8,
            size: u5,
            do_wb: bool,
            wb_disp: i32,
            pc_page_off: u32,
            abort_epilogue_label: u16,
        ) void {
            const slow_label = em.newLabel();
            const done_label = em.newLabel();

            em.movRegReg(true, .rcx, .rdi);
            em.shrImm(true, .rcx, 7);
            em.andRegImm(false, .rcx, 0x1ffe0);

            if (size == 16) {
                em.movRegReg(true, .rax, .rdi);
                em.andRegImm(true, .rax, -4096);
                em.cmpSibReg(true, .rbp, .rcx, 0, off_tlb64_read_vpage, .rax);
                em.jccLabel(.ne, slow_label);
                em.movRegReg(false, .rdx, .rdi);
                em.andRegImm(false, .rdx, 0xfff);
                em.cmpRegImm(false, .rdx, 4096 - 16);
                em.jccLabel(.a, slow_label);
                em.movRegSib(false, .rax, .rbp, .rcx, 0, off_tlb64_pbase);
                em.orRegReg(true, .rax, .rdx);
                em.movupsLoadSib(.xmm0, .r13, .rax, 0, 0);
                if (do_wb) {
                    em.leaRegMem(true, .rcx, .rdi, wb_disp);
                    emitStoreA64Reg(em, rn, .rcx, true, .rdx);
                }
                em.movupsStore(.rbx, a64VfpOff(rd), .xmm0);
            } else {
                const align_mask: i32 = if (size == 8) -4089 else -4093;
                em.movRegReg(true, .rax, .rdi);
                em.andRegImm(true, .rax, align_mask);
                em.cmpSibReg(true, .rbp, .rcx, 0, off_tlb64_read_vpage, .rax);
                em.jccLabel(.ne, slow_label);
                em.movRegSib(false, .rax, .rbp, .rcx, 0, off_tlb64_pbase);
                em.movRegReg(false, .rdx, .rdi);
                em.andRegImm(false, .rdx, 0xfff);
                em.orRegReg(true, .rax, .rdx);
                em.movRegSib(size == 8, .rax, .r13, .rax, 0, 0);
                if (do_wb) {
                    em.leaRegMem(true, .rcx, .rdi, wb_disp);
                    emitStoreA64Reg(em, rn, .rcx, true, .rdx);
                }
                em.movMemReg(true, .rbx, a64VfpOff(rd), .rax);
                em.xorRegReg(false, .rax, .rax);
                em.movMemReg(true, .rbx, a64VfpOff(rd) + 8, .rax);
            }
            em.jmpLabel(done_label);

            em.bindLabel(slow_label);
            emitSpillPinned64(em);
            const info: u32 = @as(u32, size) |
                (if (do_wb) @as(u32, 0x20) else 0) |
                (@as(u32, rd & 0x1f) << 8) |
                (@as(u32, rn & 0x1f) << 16);
            const pc_and_wb: u64 = @as(u64, pc_page_off) |
                (if (do_wb) (@as(u64, @as(u32, @bitCast(wb_disp))) << 32) else 0);
            em.movRegReg(true, .rdx, .rdi);
            em.movRegReg(true, .rdi, .rbx);
            em.movRegReg(true, .rsi, .r12);
            em.movImm64(.rcx, pc_and_wb);
            em.movImm32(.r8, info);
            em.movImm64(.r11, @intFromPtr(&jitSlowLoadFp64));
            em.callReg(.r11);

            em.testRegReg(true, .rax, .rax);
            em.jccLabel(.ne, abort_epilogue_label);
            emitReloadPinned64(em);

            em.bindLabel(done_label);
        }

        fn emitA64StoreFpAddr(
            em: *X64Emitter,
            rd: u8,
            rn: u8,
            size: u5,
            do_wb: bool,
            wb_disp: i32,
            pc_page_off: u32,
            abort_epilogue_label: u16,
        ) void {
            const slow_label = em.newLabel();
            const done_label = em.newLabel();

            em.movRegReg(true, .rcx, .rdi);
            em.shrImm(true, .rcx, 7);
            em.andRegImm(false, .rcx, 0x1ffe0);

            if (size == 16) {
                em.movRegReg(true, .rax, .rdi);
                em.andRegImm(true, .rax, -4096);
                em.cmpSibReg(true, .rbp, .rcx, 0, off_tlb64_write_vpage, .rax);
                em.jccLabel(.ne, slow_label);
                em.movRegReg(false, .rdx, .rdi);
                em.andRegImm(false, .rdx, 0xfff);
                em.cmpRegImm(false, .rdx, 4096 - 16);
                em.jccLabel(.a, slow_label);
                em.movRegSib(false, .rax, .rbp, .rcx, 0, off_tlb64_pbase);
                em.orRegReg(true, .rax, .rdx);
                em.movupsLoad(.xmm0, .rbx, a64VfpOff(rd));
                em.movupsStoreSib(.r13, .rax, 0, 0, .xmm0);
            } else {
                const align_mask: i32 = if (size == 8) -4089 else -4093;
                em.movRegReg(true, .rax, .rdi);
                em.andRegImm(true, .rax, align_mask);
                em.cmpSibReg(true, .rbp, .rcx, 0, off_tlb64_write_vpage, .rax);
                em.jccLabel(.ne, slow_label);
                em.movRegSib(false, .rax, .rbp, .rcx, 0, off_tlb64_pbase);
                em.movRegReg(false, .rdx, .rdi);
                em.andRegImm(false, .rdx, 0xfff);
                em.orRegReg(true, .rax, .rdx);
                em.movRegMem(size == 8, .rcx, .rbx, a64VfpOff(rd));
                em.movSibReg(size == 8, .r13, .rax, 0, 0, .rcx);
            }
            if (do_wb) {
                em.leaRegMem(true, .rcx, .rdi, wb_disp);
                emitStoreA64Reg(em, rn, .rcx, true, .rdx);
            }
            em.jmpLabel(done_label);

            em.bindLabel(slow_label);
            emitSpillPinned64(em);
            const info: u32 = @as(u32, size) |
                (if (do_wb) @as(u32, 0x20) else 0) |
                (@as(u32, rd & 0x1f) << 8) |
                (@as(u32, rn & 0x1f) << 16);
            const pc_and_wb: u64 = @as(u64, pc_page_off) |
                (if (do_wb) (@as(u64, @as(u32, @bitCast(wb_disp))) << 32) else 0);
            em.movRegReg(true, .rdx, .rdi);
            em.movRegReg(true, .rdi, .rbx);
            em.movRegReg(true, .rsi, .r12);
            em.movImm64(.rcx, pc_and_wb);
            em.movImm32(.r8, info);
            em.movImm64(.r11, @intFromPtr(&jitSlowStoreFp64));
            em.callReg(.r11);

            em.testRegReg(true, .rax, .rax);
            em.jccLabel(.ne, abort_epilogue_label);
            emitReloadPinned64(em);

            em.bindLabel(done_label);
        }

        fn emitA64PairFpMem(
            em: *X64Emitter,
            rd: u8,
            rm: u8,
            rn: u8,
            is_load: bool,
            is128: bool,
            pre_disp: i32,
            do_wb: bool,
            wb_disp: i32,
            pc_page_off: u32,
            abort_epilogue_label: u16,
        ) void {
            emitLoadA64Reg(em, true, .rdi, rn & 0x1f, true);
            if (pre_disp != 0) em.addRegImm(true, .rdi, pre_disp);

            const slow_label = em.newLabel();
            const done_label = em.newLabel();

            em.movRegReg(true, .rcx, .rdi);
            em.shrImm(true, .rcx, 7);
            em.andRegImm(false, .rcx, 0x1ffe0);

            em.movRegReg(true, .rax, .rdi);
            em.andRegImm(true, .rax, -4096);
            em.cmpSibReg(true, .rbp, .rcx, 0, if (is_load) off_tlb64_read_vpage else off_tlb64_write_vpage, .rax);
            em.jccLabel(.ne, slow_label);

            em.movRegReg(false, .rdx, .rdi);
            em.andRegImm(false, .rdx, 0xfff);
            em.cmpRegImm(false, .rdx, if (is128) 4096 - 32 else 4096 - 16);
            em.jccLabel(.a, slow_label);

            em.movRegSib(false, .rax, .rbp, .rcx, 0, off_tlb64_pbase);
            em.orRegReg(true, .rax, .rdx);

            if (is_load) {
                if (is128) {
                    em.movupsLoadSib(.xmm0, .r13, .rax, 0, 0);
                    em.movupsLoadSib(.xmm1, .r13, .rax, 0, 16);
                    if (do_wb) {
                        em.leaRegMem(true, .rdi, .rdi, wb_disp);
                        emitStoreA64Reg(em, rn & 0x1f, .rdi, true, .rax);
                    }
                    em.movupsStore(.rbx, a64VfpOff(rd), .xmm0);
                    em.movupsStore(.rbx, a64VfpOff(rm), .xmm1);
                } else {
                    em.movRegSib(true, .rcx, .r13, .rax, 0, 0);
                    em.movRegSib(true, .rdx, .r13, .rax, 0, 8);
                    if (do_wb) {
                        em.leaRegMem(true, .rdi, .rdi, wb_disp);
                        emitStoreA64Reg(em, rn & 0x1f, .rdi, true, .rax);
                    }
                    em.xorRegReg(false, .rax, .rax);
                    em.movMemReg(true, .rbx, a64VfpOff(rd), .rcx);
                    em.movMemReg(true, .rbx, a64VfpOff(rd) + 8, .rax);
                    em.movMemReg(true, .rbx, a64VfpOff(rm), .rdx);
                    em.movMemReg(true, .rbx, a64VfpOff(rm) + 8, .rax);
                }
            } else {
                if (is128) {
                    em.movupsLoad(.xmm0, .rbx, a64VfpOff(rd));
                    em.movupsLoad(.xmm1, .rbx, a64VfpOff(rm));
                    em.movupsStoreSib(.r13, .rax, 0, 0, .xmm0);
                    em.movupsStoreSib(.r13, .rax, 0, 16, .xmm1);
                } else {
                    em.movRegMem(true, .rcx, .rbx, a64VfpOff(rd));
                    em.movRegMem(true, .rdx, .rbx, a64VfpOff(rm));
                    em.movSibReg(true, .r13, .rax, 0, 0, .rcx);
                    em.movSibReg(true, .r13, .rax, 0, 8, .rdx);
                }
                if (do_wb) {
                    em.leaRegMem(true, .rdi, .rdi, wb_disp);
                    emitStoreA64Reg(em, rn & 0x1f, .rdi, true, .rax);
                }
            }
            em.jmpLabel(done_label);

            em.bindLabel(slow_label);
            emitSpillPinned64(em);
            const packed_low: u64 = @as(u64, rd & 0x1f) |
                (@as(u64, rm & 0x1f) << 5) |
                (@as(u64, rn & 0x1f) << 10) |
                (if (is128) @as(u64, 1) << 15 else 0) |
                (if (do_wb) @as(u64, 1) << 16 else 0) |
                (if (is_load) @as(u64, 1) << 17 else 0);
            const packed_info: u64 = packed_low | (@as(u64, @as(u32, @bitCast(wb_disp))) << 32);

            em.movRegReg(true, .rdx, .rdi);
            em.movRegReg(true, .rdi, .rbx);
            em.movRegReg(true, .rsi, .r12);
            em.movImm32(.rcx, pc_page_off);
            em.movImm64(.r8, packed_info);
            em.movImm64(.r11, @intFromPtr(&jitSlowPairFp64));
            em.callReg(.r11);

            em.testRegReg(true, .rax, .rax);
            em.jccLabel(.ne, abort_epilogue_label);
            emitReloadPinned64(em);

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
                .udiv64,
                .sdiv64,
                .udiv32,
                .sdiv32,
                .clz64,
                .clz32,
                .rev64,
                .rev32,
                .csel,
                .ccmp,
                .madd_msub,
                .maddl_mulh,
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
                .ldr_fp32_uimm,
                .str_fp32_uimm,
                .ldr_fp64_uimm,
                .str_fp64_uimm,
                .ldr_fp128_uimm,
                .str_fp128_uimm,
                .ldr_fp64_pre,
                .ldr_fp64_post,
                .str_fp64_pre,
                .str_fp64_post,
                .ldr_fp128_pre,
                .ldr_fp128_post,
                .str_fp128_pre,
                .str_fp128_post,
                .ldr_fp64_reg_lsl,
                .str_fp64_reg_lsl,
                .ldr_fp128_reg_lsl,
                .str_fp128_reg_lsl,
                .ldp_fp64_off,
                .stp_fp64_off,
                .ldp_fp64_pre,
                .stp_fp64_pre,
                .ldp_fp64_post,
                .stp_fp64_post,
                .ldp_fp128_off,
                .stp_fp128_off,
                .ldp_fp128_pre,
                .stp_fp128_pre,
                .ldp_fp128_post,
                .stp_fp128_post,
                .dc_zva,
                .fmov_d_x,
                .fmov_x_d,
                .fmov_s_w,
                .fmov_w_s,
                .fmov_d_hi_x,
                .fmov_x_d_hi,
                .fmov_f64,
                .fmov_f32,
                .fabs_f64,
                .fneg_f64,
                .fabs_f32,
                .fneg_f32,
                .fadd_f64,
                .fsub_f64,
                .fmul_f64,
                .fdiv_f64,
                .fadd_f32,
                .fsub_f32,
                .fmul_f32,
                .fdiv_f32,
                .fmadd_f64,
                .fmsub_f64,
                .fmadd_f32,
                .fmsub_f32,
                .simd_movi,
                .simd_and,
                .simd_bic,
                .simd_orr,
                .simd_orn,
                .simd_eor,
                .simd_bsl,
                .simd_not,
                .simd_dup_gpr,
                .simd_dup_elem,
                .simd_umov32,
                .simd_umov64,
                .simd_add_8,
                .simd_sub_8,
                .simd_add_16,
                .simd_sub_16,
                .simd_add_32,
                .simd_sub_32,
                .simd_add_64,
                .simd_sub_64,
                .simd_cmeq_8,
                .simd_cmeqz_8,
                .simd_cmtst_8,
                .b_imm,
                .bl_imm,
                .b_cond,
                .cbz64,
                .cbnz64,
                .cbz32,
                .cbnz32,
                .tbz,
                .tbnz,
                .br_reg,
                .blr_reg,
                .ret,
                => true,
                else => false,
            };
        }

        pub fn canCompileSlot(comptime SlotType: type, d: SlotType) bool {
            const op: A64Op = @enumFromInt(d.op);
            if (canCompileOp(op)) return true;
            return switch (op) {
                .mrs_sys => switch (slotSysRegId(SlotType, d)) {
                    sysRegId(3, 0, 4, 1, 0), // SP_EL0
                    sysRegId(3, 3, 13, 0, 2), // TPIDR_EL0
                    sysRegId(3, 3, 13, 0, 3), // TPIDRRO_EL0
                    sysRegId(3, 0, 13, 0, 4), // TPIDR_EL1
                    sysRegId(3, 4, 13, 0, 2), // TPIDR_EL2
                    sysRegId(3, 3, 4, 2, 0), // NZCV
                    sysRegId(3, 3, 4, 2, 1), // DAIF
                    sysRegId(3, 0, 0, 0, 0), // MIDR_EL1
                    sysRegId(3, 3, 0, 0, 1), // CTR_EL0
                    sysRegId(3, 3, 0, 0, 7), // DCZID_EL0
                    => true,
                    else => false,
                },
                .msr_safe => switch (d.rn) {
                    0, 6, 7, 8, 9 => true,
                    else => false,
                },
                .load_store_other => canCompileLoadStoreOther64(d.raw),
                else => false,
            };
        }

        inline fn isTerminator(op: A64Op) bool {
            return switch (op) {
                .b_imm, .bl_imm, .br_reg, .blr_reg, .ret => true,
                else => false,
            };
        }

        fn selectPinnedRegsA64(comptime SlotType: type, decoded: []const SlotType) RegPinSet {
            var counts: [31]u16 = @splat(0);
            const bump = struct {
                inline fn add(c: *[31]u16, r: u8) void {
                    const idx = r & 0x1f;
                    if (idx < 31) c[idx] +|= 1;
                }
            }.add;
            for (decoded) |d| {
                const op: A64Op = @enumFromInt(d.op);
                switch (op) {
                    .nop => {},
                    .adr, .adrp, .mov_wide, .mrs_tpidr_el0, .ldr_lit32, .ldr_lit64, .ldrsw_lit, .cbz64, .cbnz64, .cbz32, .cbnz32, .tbz, .tbnz => bump(&counts, d.rd),
                    .movk64, .movk32 => {
                        bump(&counts, d.rd);
                        bump(&counts, d.rd);
                    },
                    .add_imm64, .sub_imm64, .adds_imm64, .subs_imm64, .add_imm32, .sub_imm32, .adds_imm32, .subs_imm32, .and_imm64, .orr_imm64, .eor_imm64, .ands_imm64, .and_imm32, .orr_imm32, .eor_imm32, .ands_imm32, .ubfm_r, .ubfm_l, .sbfm64_r, .sbfm32_r, .clz64, .clz32, .rev64, .rev32, .ldr64_uimm, .str64_uimm, .ldr32_uimm, .str32_uimm, .ldrsw_uimm, .ldr16_uimm, .str16_uimm, .ldr8_uimm, .str8_uimm, .ldrsb64_uimm, .ldrsb32_uimm, .ldrsh64_uimm, .ldrsh32_uimm => {
                        bump(&counts, d.rd);
                        bump(&counts, d.rn);
                    },
                    .bfm_r, .bfm_l, .ldr64_pre, .ldr64_post, .str64_pre, .str64_post, .ldr32_pre, .ldr32_post, .str32_pre, .str32_post => {
                        bump(&counts, d.rd);
                        bump(&counts, d.rn);
                        bump(&counts, d.rn);
                    },
                    .extr64, .extr32, .orr_reg64, .orr_reg32, .orn_reg64, .orn_reg32, .add_reg64, .add_reg32, .adds_reg64, .adds_reg32, .sub_reg64, .sub_reg32, .subs_reg64, .subs_reg32, .and_reg64, .and_reg32, .bic_reg64, .bic_reg32, .eor_reg64, .eor_reg32, .ands_reg64, .ands_reg32, .add_lsl64, .add_lsl32, .sub_lsl64, .sub_lsl32, .orr_lsl64, .orr_lsr64, .add_ext64, .sub_ext64, .add_sub_ext, .dp_shift_reg, .lslv64, .lsrv64, .asrv64, .lslv32, .lsrv32, .asrv32, .csel, .ldr64_reg_lsl, .str64_reg_lsl, .ldr32_reg_lsl, .str32_reg_lsl, .ldr8_reg_lsl, .str8_reg_lsl, .ldp64_off, .stp64_off, .ldp64_pre, .stp64_pre, .ldp64_post, .stp64_post, .ldp32_off, .stp32_off, .ldp32_pre, .stp32_pre, .ldp32_post, .stp32_post => {
                        bump(&counts, d.rd);
                        bump(&counts, d.rn);
                        bump(&counts, d.rm);
                    },
                    .ccmp => {
                        bump(&counts, d.rn);
                        if (((d.imm >> 8) & 1) == 0) bump(&counts, d.rm);
                    },
                    .udiv64, .sdiv64, .udiv32, .sdiv32 => {
                        bump(&counts, d.rd);
                        bump(&counts, d.rn);
                        bump(&counts, d.rm);
                    },
                    .madd_msub, .maddl_mulh => {
                        bump(&counts, d.rd);
                        bump(&counts, d.rn);
                        bump(&counts, d.rm);
                        bump(&counts, @truncate(d.imm & 0x1f));
                    },
                    .load_store_other => {
                        bump(&counts, @truncate(d.raw & 0x1f));
                        bump(&counts, @truncate((d.raw >> 5) & 0x1f));
                        if ((d.raw & 0x3f20_0c00) == 0x3820_0800) {
                            bump(&counts, @truncate((d.raw >> 16) & 0x1f));
                        } else {
                            bump(&counts, @truncate((d.raw >> 5) & 0x1f));
                        }
                    },
                    .mrs_sys, .dc_zva, .fmov_x_d, .fmov_w_s, .fmov_x_d_hi, .simd_umov32, .simd_umov64 => bump(&counts, d.rd),
                    .fmov_d_x, .fmov_s_w, .fmov_d_hi_x, .simd_dup_gpr, .ldr_fp32_uimm, .str_fp32_uimm, .ldr_fp64_uimm, .str_fp64_uimm, .ldr_fp128_uimm, .str_fp128_uimm, .ldp_fp64_off, .stp_fp64_off, .ldp_fp128_off, .stp_fp128_off => bump(&counts, d.rn),
                    .ldr_fp64_pre, .ldr_fp64_post, .str_fp64_pre, .str_fp64_post, .ldr_fp128_pre, .ldr_fp128_post, .str_fp128_pre, .str_fp128_post, .ldp_fp64_pre, .stp_fp64_pre, .ldp_fp64_post, .stp_fp64_post, .ldp_fp128_pre, .stp_fp128_pre, .ldp_fp128_post, .stp_fp128_post => {
                        bump(&counts, d.rn);
                        bump(&counts, d.rn);
                    },
                    .ldr_fp64_reg_lsl, .str_fp64_reg_lsl, .ldr_fp128_reg_lsl, .str_fp128_reg_lsl => {
                        bump(&counts, d.rn);
                        bump(&counts, d.rm);
                    },
                    .bl_imm => bump(&counts, 30),
                    .br_reg, .ret => bump(&counts, d.rn),
                    .blr_reg => {
                        bump(&counts, d.rn);
                        bump(&counts, 30);
                    },
                    .msr_safe => if (d.rn >= 5 and d.rn <= 9) bump(&counts, d.rd),
                    else => {},
                }
            }
            var pins = RegPinSet{};
            while (pins.count < 5) {
                var best_r: u8 = 0xff;
                var best_c: u16 = 1; // Only pin registers used at least twice
                for (0..31) |r| {
                    if (counts[r] > best_c) {
                        best_c = counts[r];
                        best_r = @intCast(r);
                    }
                }
                if (best_r == 0xff) break;
                pins.guest_regs[pins.count] = best_r;
                pins.count += 1;
                counts[best_r] = 0;
            }
            return pins;
        }

        fn a64FlagSetKind(comptime SlotType: type, d: SlotType) FlagSetKind {
            const op: A64Op = @enumFromInt(d.op);
            return switch (op) {
                .adds_imm64, .adds_imm32, .adds_reg64, .adds_reg32 => .add,
                .subs_imm64, .subs_imm32, .subs_reg64, .subs_reg32 => .sub,
                .ands_imm64, .ands_imm32, .ands_reg64, .ands_reg32 => .logic_clear_cv,
                .add_sub_ext => if (((d.imm >> 6) & 1) != 0) (if (((d.imm >> 7) & 1) != 0) FlagSetKind.sub else .add) else .none,
                .dp_shift_reg => blk: {
                    const op2: u4 = @truncate(d.imm >> 8);
                    const s: u1 = @truncate(d.imm >> 12);
                    const op0: u1 = @truncate(d.imm >> 13);
                    if (s == 0) break :blk FlagSetKind.none;
                    if ((op2 & 0b1000) == 0) {
                        break :blk if (op0 == 1) FlagSetKind.logic_clear_cv else .none;
                    } else {
                        break :blk if (op0 == 1) FlagSetKind.sub else .add;
                    }
                },
                else => .none,
            };
        }

        fn a64ReadsFlagsOrBranches(op: A64Op) bool {
            return switch (op) {
                .b_imm, .bl_imm, .b_cond, .cbz64, .cbnz64, .cbz32, .cbnz32, .tbz, .tbnz, .br_reg, .blr_reg, .ret, .csel, .ccmp, .mrs_sys, .msr_safe => true,
                else => false,
            };
        }

        fn canFuseA64BackwardBranch(
            comptime SlotType: type,
            decoded: []const SlotType,
            start_word: u10,
            end_word: u16,
            idx: usize,
            kind: FlagSetKind,
        ) bool {
            if (kind == .none or idx + 1 >= decoded.len) return false;
            const next_d = decoded[idx + 1];
            const next_op: A64Op = @enumFromInt(next_d.op);
            if (next_op != .b_cond) return false;
            const cond: u4 = @intCast(next_d.rd & 0xf);
            if (armCondToX86Cond(cond, kind, false) == null) return false;

            const next_w: u16 = start_word + @as(u16, @intCast(idx + 1));
            const next_pc_off: i32 = @as(i32, next_w) * 4;
            const target_delta: i32 = next_pc_off + @as(i32, @bitCast(@as(u32, @truncate(next_d.imm))));
            const target_word_i32 = @divExact(target_delta, 4);
            if (target_word_i32 < @as(i32, start_word) or target_word_i32 >= @as(i32, end_word)) return false;
            const target_w: u16 = @intCast(target_word_i32);
            if (target_w > next_w) return false; // Only fuse backward loop branches
            const target_idx: usize = target_w - start_word;
            if (target_idx > idx) return false;

            // Ensure no instruction in the loop body before `idx` reads NZCV or branches,
            // and no branch in the trace targets `idx + 1` directly.
            for (0..decoded.len) |j| {
                const jd = decoded[j];
                const jop: A64Op = @enumFromInt(jd.op);
                switch (jop) {
                    .b_imm, .bl_imm, .b_cond, .cbz64, .cbnz64, .cbz32, .cbnz32, .tbz, .tbnz => {
                        const jw: u16 = start_word + @as(u16, @intCast(j));
                        const jdelta: i32 = @as(i32, jw) * 4 + @as(i32, @bitCast(@as(u32, @truncate(jd.imm))));
                        if (@divExact(jdelta, 4) == @as(i32, next_w)) return false;
                    },
                    else => {},
                }
                if (j >= target_idx and j < idx) {
                    if (a64ReadsFlagsOrBranches(jop) or a64FlagSetKind(SlotType, jd) != .none) return false;
                }
            }
            return true;
        }

        pub fn isSpinLoop(
            comptime SlotType: type,
            code_page_ptr: [*]const u8,
            start_word: u10,
            end_word_req: u16,
        ) bool {
            if (end_word_req <= start_word + 1 or end_word_req - start_word > 64 or end_word_req > 1024) return false;
            const trace_len: u16 = end_word_req - start_word;
            var read_before_write: u32 = 0;
            var written: u32 = 0;
            var has_side_effect = false;
            var has_load = false;

            const useReg = struct {
                inline fn r(rbw: *u32, wr: u32, reg: u8) void {
                    const idx = reg & 0x1f;
                    if (idx < 31 and (wr & (@as(u32, 1) << @intCast(idx))) == 0) {
                        rbw.* |= (@as(u32, 1) << @intCast(idx));
                    }
                }
            }.r;
            const defReg = struct {
                inline fn w(wr: *u32, reg: u8) void {
                    const idx = reg & 0x1f;
                    if (idx < 31) wr.* |= (@as(u32, 1) << @intCast(idx));
                }
            }.w;

            for (0..trace_len) |i| {
                const w = start_word + @as(u16, @intCast(i));
                const raw = std.mem.readInt(u32, code_page_ptr[@as(usize, w) * 4 ..][0..4], .little);
                if ((raw & 0x3f00_0000) == 0x0800_0000) return true;
                const d = A64.decodeA64(SlotType, raw);
                const op: A64Op = @enumFromInt(d.op);
                switch (op) {
                    .msr_safe => if (d.rn == 1 or d.rn == 2) return true else {
                        has_side_effect = true;
                    },
                    .ldxr64, .stxr64, .ldxr32, .stxr32 => return true,
                    .nop, .b_imm, .b_cond, .ret, .br_reg => {},
                    .cbz64, .cbnz64, .cbz32, .cbnz32, .tbz, .tbnz => useReg(&read_before_write, written, d.rd),
                    .ldr64_uimm, .ldr32_uimm, .ldrsw_uimm, .ldr16_uimm, .ldr8_uimm, .ldrsb64_uimm, .ldrsb32_uimm, .ldrsh64_uimm, .ldrsh32_uimm => {
                        has_load = true;
                        useReg(&read_before_write, written, d.rn);
                        defReg(&written, d.rd);
                    },
                    .ldr64_reg_lsl, .ldr32_reg_lsl, .ldr8_reg_lsl => {
                        has_load = true;
                        useReg(&read_before_write, written, d.rn);
                        useReg(&read_before_write, written, d.rm);
                        defReg(&written, d.rd);
                    },
                    .ldr_lit32, .ldr_lit64, .ldrsw_lit => {
                        has_load = true;
                        defReg(&written, d.rd);
                    },
                    .adr, .adrp, .mov_wide, .mrs_tpidr_el0, .mrs_sys => defReg(&written, d.rd),
                    .movk64, .movk32 => {
                        useReg(&read_before_write, written, d.rd);
                        defReg(&written, d.rd);
                    },
                    .add_imm64, .sub_imm64, .adds_imm64, .subs_imm64, .add_imm32, .sub_imm32, .adds_imm32, .subs_imm32, .and_imm64, .orr_imm64, .eor_imm64, .ands_imm64, .and_imm32, .orr_imm32, .eor_imm32, .ands_imm32, .ubfm_r, .ubfm_l, .sbfm64_r, .sbfm32_r, .clz64, .clz32, .rev64, .rev32 => {
                        useReg(&read_before_write, written, d.rn);
                        defReg(&written, d.rd);
                    },
                    .bfm_r, .bfm_l => {
                        useReg(&read_before_write, written, d.rn);
                        useReg(&read_before_write, written, d.rd);
                        defReg(&written, d.rd);
                    },
                    .ccmp => {
                        useReg(&read_before_write, written, d.rn);
                        if (((d.imm >> 8) & 1) == 0) useReg(&read_before_write, written, d.rm);
                    },
                    .orr_reg64, .orr_reg32, .orn_reg64, .orn_reg32, .add_reg64, .add_reg32, .adds_reg64, .adds_reg32, .sub_reg64, .sub_reg32, .subs_reg64, .subs_reg32, .and_reg64, .and_reg32, .bic_reg64, .bic_reg32, .eor_reg64, .eor_reg32, .ands_reg64, .ands_reg32, .add_lsl64, .add_lsl32, .sub_lsl64, .sub_lsl32, .orr_lsl64, .orr_lsr64, .extr64, .extr32, .add_ext64, .sub_ext64, .add_sub_ext, .dp_shift_reg, .lslv64, .lsrv64, .asrv64, .lslv32, .lsrv32, .asrv32, .csel, .udiv64, .sdiv64, .udiv32, .sdiv32 => {
                        useReg(&read_before_write, written, d.rn);
                        useReg(&read_before_write, written, d.rm);
                        defReg(&written, d.rd);
                    },
                    else => has_side_effect = true,
                }
            }
            if (end_word_req < 1024) {
                const next_raw = std.mem.readInt(u32, code_page_ptr[@as(usize, end_word_req) * 4 ..][0..4], .little);
                if ((next_raw & 0xffff_f09f) == 0xd503_309f) return true;
            }
            return !has_side_effect and has_load and (written & read_before_write) == 0;
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
            var decoded: [128]SlotType = undefined;
            var trace_len: u16 = 0;

            if (requested_end_word != 0) {
                if (requested_end_word <= start_word + 1 or requested_end_word - start_word > max_window or requested_end_word > 1024) return null;
                if (isSpinLoop(SlotType, code_page_ptr, start_word, requested_end_word)) return null;
                trace_len = requested_end_word - start_word;
                var can_bypass = false;
                for (0..trace_len) |i| {
                    const w = start_word + @as(u16, @intCast(i));
                    const raw_inst = std.mem.readInt(u32, code_page_ptr[@as(usize, w) * 4 ..][0..4], .little);
                    const d = A64.decodeA64(SlotType, raw_inst);
                    const op: A64Op = @enumFromInt(d.op);
                    if (!canCompileSlot(SlotType, d)) return null;
                    if (trace_len <= 8 and op == .load_store_other and (raw_inst & 0x3f40_7c00) == 0x0840_7c00) return null;
                    if ((op == .bl_imm or op == .blr_reg or op == .ret or op == .br_reg) and !can_bypass) return null;
                    switch (op) {
                        .b_imm, .b_cond, .cbz64, .cbnz64, .cbz32, .cbnz32, .tbz, .tbnz => {
                            const jdelta: i32 = @as(i32, w) * 4 + @as(i32, @bitCast(@as(u32, @truncate(d.imm))));
                            const tw = @divExact(jdelta, 4);
                            if (tw > @as(i32, w) + 1 or tw <= @as(i32, w)) can_bypass = true;
                        },
                        else => {},
                    }
                    decoded[i] = d;
                }
            } else {
                const limit_word: u16 = @min(@as(u16, 1024), @as(u16, start_word) + 64);
                var target_mask: u64 = 0;
                var has_backward_branch = false;
                while (start_word + trace_len < limit_word) {
                    const w = start_word + trace_len;
                    const raw_inst = std.mem.readInt(u32, code_page_ptr[@as(usize, w) * 4 ..][0..4], .little);
                    const d = A64.decodeA64(SlotType, raw_inst);
                    const op: A64Op = @enumFromInt(d.op);
                    if (!canCompileSlot(SlotType, d)) break;
                    switch (op) {
                        .b_imm, .b_cond, .cbz64, .cbnz64, .cbz32, .cbnz32, .tbz, .tbnz => {
                            const jdelta: i32 = @as(i32, w) * 4 + @as(i32, @bitCast(@as(u32, @truncate(d.imm))));
                            if ((jdelta & 3) == 0) {
                                const tw = @divExact(jdelta, 4);
                                if (tw > @as(i32, w) and tw < @as(i32, limit_word)) {
                                    const tidx: u6 = @intCast(tw - @as(i32, start_word));
                                    target_mask |= (@as(u64, 1) << tidx);
                                } else if (tw >= @as(i32, start_word) and tw <= @as(i32, w)) {
                                    const loop_start: u10 = @intCast(tw);
                                    if (isSpinLoop(SlotType, code_page_ptr, loop_start, w + 1)) return null;
                                    if (w + 1 - @as(u16, loop_start) <= 8) {
                                        for (loop_start - start_word..trace_len) |li| {
                                            if (decoded[li].op == @intFromEnum(A64Op.load_store_other) and (decoded[li].raw & 0x3f40_7c00) == 0x0840_7c00) return null;
                                        }
                                    }
                                    has_backward_branch = true;
                                }
                            }
                        },
                        else => {},
                    }
                    decoded[trace_len] = d;
                    trace_len += 1;
                    if (isTerminator(op)) {
                        if (trace_len < 64 and (target_mask >> @intCast(trace_len)) != 0) {
                            continue;
                        }
                        if (op == .b_imm) {
                            const target_byte: i32 = @as(i32, @intCast(w)) * 4 + @as(i32, @bitCast(@as(u32, @truncate(d.imm))));
                            if (target_byte >= @as(i32, @intCast(w + 1)) * 4 and target_byte < @as(i32, @intCast(limit_word)) * 4 and (target_byte & 3) == 0) {
                                continue;
                            }
                        }
                        break;
                    }
                }
                if (trace_len < 4 and (!has_backward_branch or trace_len < 2)) return null;
            }

            const end_word: u16 = start_word + trace_len;
            out_end_word.* = end_word;

            var em = X64Emitter{
                .pins = selectPinnedRegsA64(SlotType, decoded[0..trace_len]),
            };
            em.emitPrologue();
            emitReloadPinned64(&em);

            const epilogue_label = em.newLabel();
            const abort_epilogue_label = em.newLabel();
            var inst_labels: [128]u16 = undefined;
            for (0..trace_len) |i| {
                inst_labels[i] = em.newLabel();
            }

            var exit_stubs: [256]ExitStub = undefined;
            var exit_stub_count: usize = 0;
            var fused_flag_kind: FlagSetKind = .none;

            for (0..trace_len) |idx| {
                const w: u16 = start_word + @as(u16, @intCast(idx));
                const pc_page_off: u32 = @as(u32, w) * 4;
                const d = decoded[idx];
                const op: A64Op = @enumFromInt(d.op);
                const flag_kind = a64FlagSetKind(SlotType, d);
                const fuse_flags = canFuseA64BackwardBranch(SlotType, decoded[0..trace_len], start_word, end_word, idx, flag_kind);

                em.bindLabel(inst_labels[idx]);
                if (fused_flag_kind != .none) {
                    em.leaRegMem(true, .r15, .r15, 1);
                } else {
                    em.addRegImm(true, .r15, 1);
                }

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
                        const imm_i32: i32 = @intCast(@as(i64, @bitCast(d.imm)));
                        if (d.rd == d.rn and em.pins.getHost(d.rd & 0x1f) != null) {
                            const hreg = em.pins.getHost(d.rd & 0x1f).?;
                            if (is_sub) em.subRegImm(is64, hreg, imm_i32) else em.addRegImm(is64, hreg, imm_i32);
                        } else {
                            emitLoadA64Reg(&em, is64, .rax, d.rn, true);
                            if (is_sub) em.subRegImm(is64, .rax, imm_i32) else em.addRegImm(is64, .rax, imm_i32);
                            emitStoreA64Reg(&em, d.rd, .rax, true, .rcx);
                        }
                    },

                    .adds_imm64, .adds_imm32, .subs_imm64, .subs_imm32 => {
                        const is64 = op == .adds_imm64 or op == .subs_imm64;
                        const is_sub = op == .subs_imm64 or op == .subs_imm32;
                        const imm_i32: i32 = @intCast(@as(i64, @bitCast(d.imm)));
                        if (d.rd == d.rn and d.rd != 31 and em.pins.getHost(d.rd & 0x1f) != null) {
                            const hreg = em.pins.getHost(d.rd & 0x1f).?;
                            if (is_sub) em.subRegImm(is64, hreg, imm_i32) else em.addRegImm(is64, hreg, imm_i32);
                        } else {
                            emitLoadA64Reg(&em, is64, .rax, d.rn, true);
                            if (is_sub) em.subRegImm(is64, .rax, imm_i32) else em.addRegImm(is64, .rax, imm_i32);
                            if (d.rd != 31) {
                                emitStoreA64Reg(&em, d.rd, .rax, false, .rcx);
                            }
                        }
                        if (fuse_flags) {
                            fused_flag_kind = flag_kind;
                        } else {
                            emitUpdateNZCV_AddSub(&em, off_pstate, is_sub);
                        }
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
                                if (fuse_flags) {
                                    fused_flag_kind = flag_kind;
                                } else {
                                    emitUpdateNZ_Logic(&em, off_pstate, false);
                                }
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
                            if (set_flags) {
                                if (fuse_flags) {
                                    fused_flag_kind = flag_kind;
                                } else {
                                    emitUpdateNZ_Logic(&em, off_pstate, false);
                                }
                            }
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
                        if (set_flags) {
                            if (fuse_flags) {
                                fused_flag_kind = flag_kind;
                            } else {
                                emitUpdateNZCV_AddSub(&em, off_pstate, is_sub);
                            }
                        }
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
                        if (s) {
                            if (fuse_flags) {
                                fused_flag_kind = flag_kind;
                            } else {
                                emitUpdateNZCV_AddSub(&em, off_pstate, is_sub);
                            }
                        }
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
                            if (opc == 0b11) {
                                if (fuse_flags) {
                                    fused_flag_kind = flag_kind;
                                } else {
                                    emitUpdateNZ_Logic(&em, off_pstate, false);
                                }
                            }
                        } else {
                            const is_sub = op0 == 1;
                            const set_flags = s == 1;
                            if (is_sub) em.subRegReg(is64, .rax, .rcx) else em.addRegReg(is64, .rax, .rcx);
                            if (!set_flags or d.rd != 31) emitStoreA64Reg(&em, d.rd, .rax, false, .rdx);
                            if (set_flags) {
                                if (fuse_flags) {
                                    fused_flag_kind = flag_kind;
                                } else {
                                    emitUpdateNZCV_AddSub(&em, off_pstate, is_sub);
                                }
                            }
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

                    .mrs_sys => {
                        switch (slotSysRegId(SlotType, d)) {
                            sysRegId(3, 0, 4, 1, 0) => em.movRegMem(true, .rax, .rbx, off_sp_el0),
                            sysRegId(3, 3, 13, 0, 2) => em.movRegMem(true, .rax, .rbx, off_tpidr_el0),
                            sysRegId(3, 3, 13, 0, 3) => em.movRegMem(true, .rax, .rbx, off_tpidrro_el0),
                            sysRegId(3, 0, 13, 0, 4) => em.movRegMem(true, .rax, .rbx, off_tpidr_el1),
                            sysRegId(3, 4, 13, 0, 2) => em.movRegMem(true, .rax, .rbx, off_tpidr_el2),
                            sysRegId(3, 3, 4, 2, 0) => {
                                em.movRegMem(false, .rax, .rbx, off_pstate);
                                em.andRegImm(false, .rax, @bitCast(@as(u32, 0xf000_0000)));
                            },
                            sysRegId(3, 3, 4, 2, 1) => {
                                em.movRegMem(false, .rax, .rbx, off_pstate);
                                em.andRegImm(false, .rax, 0x3c0);
                            },
                            sysRegId(3, 0, 0, 0, 0) => em.movImm32(.rax, 0x410fd034),
                            sysRegId(3, 3, 0, 0, 1) => em.movImm32(.rax, 0x8444_8004),
                            sysRegId(3, 3, 0, 0, 7) => em.movImm32(.rax, 4),
                            else => unreachable,
                        }
                        emitStoreA64Reg(&em, d.rd, .rax, false, .rcx);
                    },

                    .msr_safe => {
                        switch (d.rn) {
                            0 => {
                                em.xorRegReg(false, .rax, .rax);
                                em.movSib8Reg(.rbx, .rax, 0, off_excl_valid, .rax);
                            },
                            3 => {
                                em.movRegMem(false, .rax, .rbx, off_pstate);
                                em.orRegImm(false, .rax, @bitCast(@as(u32, @truncate(d.imm))));
                                em.movMemReg(false, .rbx, off_pstate, .rax);
                            },
                            4 => {
                                em.movRegMem(false, .rax, .rbx, off_pstate);
                                em.andRegImm(false, .rax, @bitCast(@as(u32, @truncate(d.imm))));
                                em.movMemReg(false, .rbx, off_pstate, .rax);
                            },
                            5 => {
                                emitLoadA64Reg(&em, false, .rax, d.rd, false);
                                em.andRegImm(false, .rax, 0x3c0);
                                em.movRegMem(false, .rcx, .rbx, off_pstate);
                                em.andRegImm(false, .rcx, @bitCast(~@as(u32, 0x3c0)));
                                em.orRegReg(false, .rcx, .rax);
                                em.movMemReg(false, .rbx, off_pstate, .rcx);
                            },
                            6 => {
                                emitLoadA64Reg(&em, false, .rax, d.rd, false);
                                em.andRegImm(false, .rax, @bitCast(@as(u32, 0xf000_0000)));
                                em.movRegMem(false, .rcx, .rbx, off_pstate);
                                em.andRegImm(false, .rcx, 0x0fff_ffff);
                                em.orRegReg(false, .rcx, .rax);
                                em.movMemReg(false, .rbx, off_pstate, .rcx);
                            },
                            7 => {
                                emitLoadA64Reg(&em, true, .rax, d.rd, false);
                                em.movMemReg(true, .rbx, off_tpidr_el0, .rax);
                            },
                            8 => {
                                emitLoadA64Reg(&em, true, .rax, d.rd, false);
                                em.movMemReg(true, .rbx, off_tpidr_el1, .rax);
                            },
                            9 => {
                                emitLoadA64Reg(&em, true, .rax, d.rd, false);
                                em.movMemReg(true, .rbx, off_sp_el0, .rax);
                            },
                            11 => {},
                            else => unreachable,
                        }
                    },

                    .udiv64, .udiv32 => {
                        const is64 = op == .udiv64;
                        const zero_label = em.newLabel();
                        const done_div = em.newLabel();
                        emitLoadA64Reg(&em, is64, .rcx, d.rm, false);
                        em.testRegReg(is64, .rcx, .rcx);
                        em.jccLabel(.e, zero_label);
                        emitLoadA64Reg(&em, is64, .rax, d.rn, false);
                        em.xorRegReg(false, .rdx, .rdx);
                        em.divReg1(is64, .rcx);
                        em.jmpLabel(done_div);
                        em.bindLabel(zero_label);
                        em.xorRegReg(false, .rax, .rax);
                        em.bindLabel(done_div);
                        emitStoreA64Reg(&em, d.rd, .rax, false, .rcx);
                    },

                    .sdiv64, .sdiv32 => {
                        const is64 = op == .sdiv64;
                        const zero_label = em.newLabel();
                        const neg1_label = em.newLabel();
                        const done_div = em.newLabel();
                        emitLoadA64Reg(&em, is64, .rcx, d.rm, false);
                        em.testRegReg(is64, .rcx, .rcx);
                        em.jccLabel(.e, zero_label);
                        emitLoadA64Reg(&em, is64, .rax, d.rn, false);
                        em.cmpRegImm(is64, .rcx, -1);
                        em.jccLabel(.e, neg1_label);
                        em.cdqCqo(is64);
                        em.idivReg1(is64, .rcx);
                        em.jmpLabel(done_div);
                        em.bindLabel(neg1_label);
                        em.negReg(is64, .rax);
                        em.jmpLabel(done_div);
                        em.bindLabel(zero_label);
                        em.xorRegReg(false, .rax, .rax);
                        em.bindLabel(done_div);
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
                            abort_epilogue_label,
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

                    .maddl_mulh => {
                        const ra: u8 = @truncate(d.imm & 0x1f);
                        const o0 = ((d.imm >> 5) & 1) != 0;
                        const op31: u3 = @truncate(d.imm >> 6);
                        switch (op31) {
                            0b001 => { // SMADDL / SMSUBL
                                emitLoadA64Reg(&em, false, .rax, d.rn, false);
                                em.movsxd32(.rax, .rax);
                                emitLoadA64Reg(&em, false, .rcx, d.rm, false);
                                em.movsxd32(.rcx, .rcx);
                                em.imulRegReg(true, .rax, .rcx);
                                if (ra != 31 or o0) {
                                    emitLoadA64Reg(&em, true, .rcx, ra, false);
                                    if (o0) {
                                        em.subRegReg(true, .rcx, .rax);
                                        em.movRegReg(true, .rax, .rcx);
                                    } else {
                                        em.addRegReg(true, .rax, .rcx);
                                    }
                                }
                                emitStoreA64Reg(&em, d.rd, .rax, false, .rcx);
                            },
                            0b101 => { // UMADDL / UMSUBL
                                emitLoadA64Reg(&em, false, .rax, d.rn, false);
                                emitLoadA64Reg(&em, false, .rcx, d.rm, false);
                                em.imulRegReg(true, .rax, .rcx);
                                if (ra != 31 or o0) {
                                    emitLoadA64Reg(&em, true, .rcx, ra, false);
                                    if (o0) {
                                        em.subRegReg(true, .rcx, .rax);
                                        em.movRegReg(true, .rax, .rcx);
                                    } else {
                                        em.addRegReg(true, .rax, .rcx);
                                    }
                                }
                                emitStoreA64Reg(&em, d.rd, .rax, false, .rcx);
                            },
                            0b010 => { // SMULH
                                emitLoadA64Reg(&em, true, .rax, d.rn, false);
                                emitLoadA64Reg(&em, true, .rcx, d.rm, false);
                                em.imulReg1(true, .rcx);
                                emitStoreA64Reg(&em, d.rd, .rdx, false, .rcx);
                            },
                            else => { // UMULH
                                emitLoadA64Reg(&em, true, .rax, d.rn, false);
                                emitLoadA64Reg(&em, true, .rcx, d.rm, false);
                                em.mulReg1(true, .rcx);
                                emitStoreA64Reg(&em, d.rd, .rdx, false, .rcx);
                            },
                        }
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
                        emitA64LoadAddr(&em, d.rd, d.rn, size, signed, is64, false, 0, pc_page_off, abort_epilogue_label);
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
                        emitA64StoreAddr(&em, d.rd, d.rn, size, false, 0, pc_page_off, abort_epilogue_label);
                    },

                    .ldr64_pre, .ldr64_post, .ldr32_pre, .ldr32_post => {
                        const is_pre = op == .ldr64_pre or op == .ldr32_pre;
                        const size: u4 = if (op == .ldr64_pre or op == .ldr64_post) 8 else 4;
                        const disp: i32 = @bitCast(@as(u32, @truncate(d.imm)));
                        emitLoadA64Reg(&em, true, .rdi, d.rn, true);
                        if (is_pre and disp != 0) em.addRegImm(true, .rdi, disp);
                        emitA64LoadAddr(&em, d.rd, d.rn, size, false, size == 8, true, if (is_pre) 0 else disp, pc_page_off, abort_epilogue_label);
                    },

                    .str64_pre, .str64_post, .str32_pre, .str32_post => {
                        const is_pre = op == .str64_pre or op == .str32_pre;
                        const size: u4 = if (op == .str64_pre or op == .str64_post) 8 else 4;
                        const disp: i32 = @bitCast(@as(u32, @truncate(d.imm)));
                        emitLoadA64Reg(&em, true, .rdi, d.rn, true);
                        if (is_pre and disp != 0) em.addRegImm(true, .rdi, disp);
                        emitA64StoreAddr(&em, d.rd, d.rn, size, true, if (is_pre) 0 else disp, pc_page_off, abort_epilogue_label);
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
                        emitA64LoadAddr(&em, d.rd, d.rn, size, false, size == 8, false, 0, pc_page_off, abort_epilogue_label);
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
                        emitA64StoreAddr(&em, d.rd, d.rn, size, false, 0, pc_page_off, abort_epilogue_label);
                    },

                    .load_store_other => {
                        const raw = d.raw;
                        const size_shift: u2 = @truncate(raw >> 30);
                        const size: u4 = @as(u4, 1) << size_shift;
                        const opc: u2 = @truncate(raw >> 22);
                        const rn: u8 = @truncate((raw >> 5) & 0x1f);
                        const rt: u8 = @truncate(raw & 0x1f);
                        const is_load = opc != 0;
                        const signed = (opc & 2) != 0;
                        const is64 = (size_shift == 3) or (opc == 0b10);
                        if ((raw & 0x3f20_0400) == 0x3800_0400) {
                            const is_pre = ((raw >> 11) & 1) != 0;
                            const imm9: i32 = @as(i9, @bitCast(@as(u9, @truncate(raw >> 12))));
                            emitLoadA64Reg(&em, true, .rdi, rn, true);
                            if (is_pre and imm9 != 0) em.addRegImm(true, .rdi, imm9);
                            if (is_load) {
                                emitA64LoadAddr(&em, rt, rn, size, signed, is64, true, if (is_pre) 0 else imm9, pc_page_off, abort_epilogue_label);
                            } else {
                                emitA64StoreAddr(&em, rt, rn, size, true, if (is_pre) 0 else imm9, pc_page_off, abort_epilogue_label);
                            }
                        } else {
                            const option: u3 = @truncate(raw >> 13);
                            const s_bit = ((raw >> 12) & 1) != 0;
                            const shift: u6 = if (s_bit) size_shift else 0;
                            const rm: u8 = @truncate((raw >> 16) & 0x1f);
                            emitLoadA64Reg(&em, true, .rdi, rn, true);
                            switch (option) {
                                0b010 => emitLoadA64Reg(&em, false, .rax, rm, false), // UXTW
                                0b110 => { // SXTW
                                    emitLoadA64Reg(&em, false, .rax, rm, false);
                                    em.movsxd32(.rax, .rax);
                                },
                                else => emitLoadA64Reg(&em, true, .rax, rm, false), // LSL / SXTX
                            }
                            if (shift != 0) em.shlImm(true, .rax, shift);
                            em.addRegReg(true, .rdi, .rax);
                            if (is_load) {
                                emitA64LoadAddr(&em, rt, rn, size, signed, is64, false, 0, pc_page_off, abort_epilogue_label);
                            } else {
                                emitA64StoreAddr(&em, rt, rn, size, false, 0, pc_page_off, abort_epilogue_label);
                            }
                        }
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
                            abort_epilogue_label,
                        );
                    },

                    .ldr_fp32_uimm, .ldr_fp64_uimm, .ldr_fp128_uimm => {
                        const size: u5 = switch (op) {
                            .ldr_fp32_uimm => 4,
                            .ldr_fp64_uimm => 8,
                            .ldr_fp128_uimm => 16,
                            else => unreachable,
                        };
                        emitLoadA64Reg(&em, true, .rdi, d.rn, true);
                        const disp: i32 = @bitCast(@as(u32, @truncate(d.imm)));
                        if (disp != 0) em.addRegImm(true, .rdi, disp);
                        emitA64LoadFpAddr(&em, d.rd, d.rn, size, false, 0, pc_page_off, abort_epilogue_label);
                    },

                    .str_fp32_uimm, .str_fp64_uimm, .str_fp128_uimm => {
                        const size: u5 = switch (op) {
                            .str_fp32_uimm => 4,
                            .str_fp64_uimm => 8,
                            .str_fp128_uimm => 16,
                            else => unreachable,
                        };
                        emitLoadA64Reg(&em, true, .rdi, d.rn, true);
                        const disp: i32 = @bitCast(@as(u32, @truncate(d.imm)));
                        if (disp != 0) em.addRegImm(true, .rdi, disp);
                        emitA64StoreFpAddr(&em, d.rd, d.rn, size, false, 0, pc_page_off, abort_epilogue_label);
                    },

                    .ldr_fp64_pre, .ldr_fp64_post, .ldr_fp128_pre, .ldr_fp128_post => {
                        const is_pre = op == .ldr_fp64_pre or op == .ldr_fp128_pre;
                        const size: u5 = if (op == .ldr_fp128_pre or op == .ldr_fp128_post) 16 else 8;
                        const disp: i32 = @bitCast(@as(u32, @truncate(d.imm)));
                        emitLoadA64Reg(&em, true, .rdi, d.rn, true);
                        if (is_pre and disp != 0) em.addRegImm(true, .rdi, disp);
                        emitA64LoadFpAddr(&em, d.rd, d.rn, size, true, if (is_pre) 0 else disp, pc_page_off, abort_epilogue_label);
                    },

                    .str_fp64_pre, .str_fp64_post, .str_fp128_pre, .str_fp128_post => {
                        const is_pre = op == .str_fp64_pre or op == .str_fp128_pre;
                        const size: u5 = if (op == .str_fp128_pre or op == .str_fp128_post) 16 else 8;
                        const disp: i32 = @bitCast(@as(u32, @truncate(d.imm)));
                        emitLoadA64Reg(&em, true, .rdi, d.rn, true);
                        if (is_pre and disp != 0) em.addRegImm(true, .rdi, disp);
                        emitA64StoreFpAddr(&em, d.rd, d.rn, size, true, if (is_pre) 0 else disp, pc_page_off, abort_epilogue_label);
                    },

                    .ldr_fp64_reg_lsl, .ldr_fp128_reg_lsl => {
                        const size: u5 = if (op == .ldr_fp128_reg_lsl) 16 else 8;
                        emitLoadA64Reg(&em, true, .rdi, d.rn, true);
                        emitLoadA64Reg(&em, true, .rax, d.rm, false);
                        const sh: u6 = @truncate(d.imm);
                        if (sh != 0) em.shlImm(true, .rax, sh);
                        em.addRegReg(true, .rdi, .rax);
                        emitA64LoadFpAddr(&em, d.rd, d.rn, size, false, 0, pc_page_off, abort_epilogue_label);
                    },

                    .str_fp64_reg_lsl, .str_fp128_reg_lsl => {
                        const size: u5 = if (op == .str_fp128_reg_lsl) 16 else 8;
                        emitLoadA64Reg(&em, true, .rdi, d.rn, true);
                        emitLoadA64Reg(&em, true, .rax, d.rm, false);
                        const sh: u6 = @truncate(d.imm);
                        if (sh != 0) em.shlImm(true, .rax, sh);
                        em.addRegReg(true, .rdi, .rax);
                        emitA64StoreFpAddr(&em, d.rd, d.rn, size, false, 0, pc_page_off, abort_epilogue_label);
                    },

                    .ldp_fp64_off, .ldp_fp64_pre, .ldp_fp64_post, .stp_fp64_off, .stp_fp64_pre, .stp_fp64_post, .ldp_fp128_off, .ldp_fp128_pre, .ldp_fp128_post, .stp_fp128_off, .stp_fp128_pre, .stp_fp128_post => {
                        const is_load = switch (op) {
                            .ldp_fp64_off, .ldp_fp64_pre, .ldp_fp64_post, .ldp_fp128_off, .ldp_fp128_pre, .ldp_fp128_post => true,
                            else => false,
                        };
                        const is128 = switch (op) {
                            .ldp_fp128_off, .ldp_fp128_pre, .ldp_fp128_post, .stp_fp128_off, .stp_fp128_pre, .stp_fp128_post => true,
                            else => false,
                        };
                        const is_pre = op == .ldp_fp64_pre or op == .stp_fp64_pre or op == .ldp_fp128_pre or op == .stp_fp128_pre;
                        const is_post = op == .ldp_fp64_post or op == .stp_fp64_post or op == .ldp_fp128_post or op == .stp_fp128_post;
                        const disp: i32 = @bitCast(@as(u32, @truncate(d.imm)));
                        emitA64PairFpMem(
                            &em,
                            d.rd,
                            d.rm,
                            d.rn,
                            is_load,
                            is128,
                            if (is_post) 0 else disp,
                            is_pre or is_post,
                            if (is_post) disp else 0,
                            pc_page_off,
                            abort_epilogue_label,
                        );
                    },

                    .dc_zva => {
                        const slow_zva = em.newLabel();
                        const done_zva = em.newLabel();
                        emitLoadA64Reg(&em, true, .rdi, d.rd, false);
                        em.andRegImm(true, .rdi, -64);

                        em.movRegReg(true, .rcx, .rdi);
                        em.shrImm(true, .rcx, 7);
                        em.andRegImm(false, .rcx, 0x1ffe0);

                        em.movRegReg(true, .rax, .rdi);
                        em.andRegImm(true, .rax, -4096);
                        em.cmpSibReg(true, .rbp, .rcx, 0, off_tlb64_write_vpage, .rax);
                        em.jccLabel(.ne, slow_zva);

                        em.movRegSib(false, .rax, .rbp, .rcx, 0, off_tlb64_pbase);
                        em.movRegReg(false, .rdx, .rdi);
                        em.andRegImm(false, .rdx, 0xfc0);
                        em.orRegReg(true, .rax, .rdx);

                        em.pxor(.xmm0, .xmm0);
                        em.movupsStoreSib(.r13, .rax, 0, 0, .xmm0);
                        em.movupsStoreSib(.r13, .rax, 0, 16, .xmm0);
                        em.movupsStoreSib(.r13, .rax, 0, 32, .xmm0);
                        em.movupsStoreSib(.r13, .rax, 0, 48, .xmm0);
                        em.jmpLabel(done_zva);

                        em.bindLabel(slow_zva);
                        emitSpillPinned64(&em);
                        em.movRegReg(true, .rdx, .rdi);
                        em.movRegReg(true, .rdi, .rbx);
                        em.movRegReg(true, .rsi, .r12);
                        em.movImm32(.rcx, pc_page_off);
                        em.movImm64(.r11, @intFromPtr(&jitSlowDcZva64));
                        em.callReg(.r11);
                        em.testRegReg(true, .rax, .rax);
                        em.jccLabel(.ne, abort_epilogue_label);
                        emitReloadPinned64(&em);

                        em.bindLabel(done_zva);
                    },

                    .fmov_d_x, .fmov_s_w => {
                        emitLoadA64Reg(&em, op == .fmov_d_x, .rax, d.rn, false);
                        em.movMemReg(true, .rbx, a64VfpOff(d.rd), .rax);
                        em.xorRegReg(false, .rcx, .rcx);
                        em.movMemReg(true, .rbx, a64VfpOff(d.rd) + 8, .rcx);
                    },
                    .fmov_x_d, .fmov_w_s => {
                        em.movRegMem(op == .fmov_x_d, .rax, .rbx, a64VfpOff(d.rn));
                        emitStoreA64Reg(&em, d.rd, .rax, false, .rcx);
                    },
                    .fmov_d_hi_x => {
                        emitLoadA64Reg(&em, true, .rax, d.rn, false);
                        em.movMemReg(true, .rbx, a64VfpOff(d.rd) + 8, .rax);
                    },
                    .fmov_x_d_hi => {
                        em.movRegMem(true, .rax, .rbx, a64VfpOff(d.rn) + 8);
                        emitStoreA64Reg(&em, d.rd, .rax, false, .rcx);
                    },
                    .fmov_f64, .fmov_f32 => {
                        em.movRegMem(op == .fmov_f64, .rax, .rbx, a64VfpOff(d.rn));
                        em.movMemReg(true, .rbx, a64VfpOff(d.rd), .rax);
                        em.xorRegReg(false, .rcx, .rcx);
                        em.movMemReg(true, .rbx, a64VfpOff(d.rd) + 8, .rcx);
                    },
                    .fabs_f64, .fneg_f64 => {
                        em.movRegMem(true, .rax, .rbx, a64VfpOff(d.rn));
                        em.movImm64(.rcx, if (op == .fabs_f64) 0x7fff_ffff_ffff_ffff else 0x8000_0000_0000_0000);
                        if (op == .fabs_f64) em.andRegReg(true, .rax, .rcx) else em.xorRegReg(true, .rax, .rcx);
                        em.movMemReg(true, .rbx, a64VfpOff(d.rd), .rax);
                        em.xorRegReg(false, .rcx, .rcx);
                        em.movMemReg(true, .rbx, a64VfpOff(d.rd) + 8, .rcx);
                    },
                    .fabs_f32, .fneg_f32 => {
                        em.movRegMem(false, .rax, .rbx, a64VfpOff(d.rn));
                        if (op == .fabs_f32) {
                            em.andRegImm(false, .rax, 0x7fff_ffff);
                        } else {
                            em.xorRegImm(false, .rax, @bitCast(@as(u32, 0x8000_0000)));
                        }
                        em.movMemReg(true, .rbx, a64VfpOff(d.rd), .rax);
                        em.xorRegReg(false, .rcx, .rcx);
                        em.movMemReg(true, .rbx, a64VfpOff(d.rd) + 8, .rcx);
                    },
                    .fadd_f64, .fsub_f64, .fmul_f64, .fdiv_f64 => {
                        em.movsdLoad(.xmm0, .rbx, a64VfpOff(d.rn));
                        em.movsdLoad(.xmm1, .rbx, a64VfpOff(d.rm));
                        switch (op) {
                            .fadd_f64 => em.addsd(.xmm0, .xmm1),
                            .fsub_f64 => em.subsd(.xmm0, .xmm1),
                            .fmul_f64 => em.mulsd(.xmm0, .xmm1),
                            .fdiv_f64 => em.divsd(.xmm0, .xmm1),
                            else => unreachable,
                        }
                        em.movupsStore(.rbx, a64VfpOff(d.rd), .xmm0);
                    },
                    .fadd_f32, .fsub_f32, .fmul_f32, .fdiv_f32 => {
                        em.movssLoad(.xmm0, .rbx, a64VfpOff(d.rn));
                        em.movssLoad(.xmm1, .rbx, a64VfpOff(d.rm));
                        switch (op) {
                            .fadd_f32 => em.addss(.xmm0, .xmm1),
                            .fsub_f32 => em.subss(.xmm0, .xmm1),
                            .fmul_f32 => em.mulss(.xmm0, .xmm1),
                            .fdiv_f32 => em.divss(.xmm0, .xmm1),
                            else => unreachable,
                        }
                        em.movupsStore(.rbx, a64VfpOff(d.rd), .xmm0);
                    },
                    .fmadd_f64, .fmsub_f64 => {
                        em.movsdLoad(.xmm0, .rbx, a64VfpOff(d.rn));
                        em.movsdLoad(.xmm1, .rbx, a64VfpOff(d.rm));
                        em.mulsd(.xmm0, .xmm1);
                        em.movsdLoad(.xmm1, .rbx, a64VfpOff(@truncate(d.imm)));
                        if (op == .fmadd_f64) em.addsd(.xmm1, .xmm0) else em.subsd(.xmm1, .xmm0);
                        em.movupsStore(.rbx, a64VfpOff(d.rd), .xmm1);
                    },
                    .fmadd_f32, .fmsub_f32 => {
                        em.movssLoad(.xmm0, .rbx, a64VfpOff(d.rn));
                        em.movssLoad(.xmm1, .rbx, a64VfpOff(d.rm));
                        em.mulss(.xmm0, .xmm1);
                        em.movssLoad(.xmm1, .rbx, a64VfpOff(@truncate(d.imm)));
                        if (op == .fmadd_f32) em.addss(.xmm1, .xmm0) else em.subss(.xmm1, .xmm0);
                        em.movupsStore(.rbx, a64VfpOff(d.rd), .xmm1);
                    },

                    .simd_movi => {
                        if (d.imm == 0) {
                            em.pxor(.xmm0, .xmm0);
                            em.movupsStore(.rbx, a64VfpOff(d.rd), .xmm0);
                        } else {
                            em.movImm64(.rax, d.imm);
                            em.movMemReg(true, .rbx, a64VfpOff(d.rd), .rax);
                            if (d.rn == 0) em.xorRegReg(false, .rax, .rax);
                            em.movMemReg(true, .rbx, a64VfpOff(d.rd) + 8, .rax);
                        }
                    },
                    .simd_dup_gpr => {
                        emitLoadA64Reg(&em, true, .rax, d.rn, false);
                        switch (d.rm) {
                            1 => {
                                em.movzx8(true, .rax, .rax);
                                em.movImm64(.rcx, 0x0101_0101_0101_0101);
                                em.imulRegReg(true, .rax, .rcx);
                            },
                            2 => {
                                em.movzx16(true, .rax, .rax);
                                em.movImm64(.rcx, 0x0001_0001_0001_0001);
                                em.imulRegReg(true, .rax, .rcx);
                            },
                            4 => {
                                em.movRegReg(false, .rax, .rax);
                                em.movImm64(.rcx, 0x0000_0001_0000_0001);
                                em.imulRegReg(true, .rax, .rcx);
                            },
                            else => {},
                        }
                        em.movMemReg(true, .rbx, a64VfpOff(d.rd), .rax);
                        if (d.imm == 0) em.xorRegReg(false, .rax, .rax);
                        em.movMemReg(true, .rbx, a64VfpOff(d.rd) + 8, .rax);
                    },
                    .simd_dup_elem => {
                        const sh: u7 = @truncate(d.rm);
                        em.movRegMem(true, .rax, .rbx, a64VfpOff(d.rn) + (if (sh >= 64) @as(i32, 8) else 0));
                        const bit_sh: u6 = @intCast(sh & 63);
                        if (bit_sh != 0) em.shrImm(true, .rax, bit_sh);
                        const esize_bytes: u8 = @truncate(d.imm >> 1);
                        switch (esize_bytes) {
                            1 => {
                                em.movzx8(true, .rax, .rax);
                                em.movImm64(.rcx, 0x0101_0101_0101_0101);
                                em.imulRegReg(true, .rax, .rcx);
                            },
                            2 => {
                                em.movzx16(true, .rax, .rax);
                                em.movImm64(.rcx, 0x0001_0001_0001_0001);
                                em.imulRegReg(true, .rax, .rcx);
                            },
                            4 => {
                                em.movRegReg(false, .rax, .rax);
                                em.movImm64(.rcx, 0x0000_0001_0000_0001);
                                em.imulRegReg(true, .rax, .rcx);
                            },
                            else => {},
                        }
                        em.movMemReg(true, .rbx, a64VfpOff(d.rd), .rax);
                        if ((d.imm & 1) == 0) em.xorRegReg(false, .rax, .rax);
                        em.movMemReg(true, .rbx, a64VfpOff(d.rd) + 8, .rax);
                    },
                    .simd_umov32, .simd_umov64 => {
                        const is64 = op == .simd_umov64;
                        const sh: u7 = @truncate(d.rm);
                        em.movRegMem(true, .rax, .rbx, a64VfpOff(d.rn) + (if (sh >= 64) @as(i32, 8) else 0));
                        const bit_sh: u6 = @intCast(sh & 63);
                        if (bit_sh != 0) em.shrImm(true, .rax, bit_sh);
                        if (!is64) em.movRegReg(false, .rax, .rax);
                        emitStoreA64Reg(&em, d.rd, .rax, false, .rcx);
                    },
                    .simd_and, .simd_bic, .simd_orr, .simd_orn, .simd_eor, .simd_bsl, .simd_not, .simd_add_8, .simd_sub_8, .simd_add_16, .simd_sub_16, .simd_add_32, .simd_sub_32, .simd_add_64, .simd_sub_64, .simd_cmeq_8, .simd_cmeqz_8, .simd_cmtst_8 => {
                        em.movupsLoad(.xmm0, .rbx, a64VfpOff(d.rn));
                        switch (op) {
                            .simd_and => {
                                em.movupsLoad(.xmm1, .rbx, a64VfpOff(d.rm));
                                em.pand(.xmm0, .xmm1);
                            },
                            .simd_bic => {
                                em.movupsLoad(.xmm0, .rbx, a64VfpOff(d.rm));
                                em.movupsLoad(.xmm1, .rbx, a64VfpOff(d.rn));
                                em.pandn(.xmm0, .xmm1);
                            },
                            .simd_orr => {
                                em.movupsLoad(.xmm1, .rbx, a64VfpOff(d.rm));
                                em.por(.xmm0, .xmm1);
                            },
                            .simd_orn => {
                                em.movupsLoad(.xmm1, .rbx, a64VfpOff(d.rm));
                                em.pcmpeqb(.xmm2, .xmm2);
                                em.pxor(.xmm1, .xmm2);
                                em.por(.xmm0, .xmm1);
                            },
                            .simd_eor => {
                                em.movupsLoad(.xmm1, .rbx, a64VfpOff(d.rm));
                                em.pxor(.xmm0, .xmm1);
                            },
                            .simd_bsl => {
                                em.movupsLoad(.xmm1, .rbx, a64VfpOff(d.rm));
                                em.movupsLoad(.xmm2, .rbx, a64VfpOff(d.rd));
                                em.pand(.xmm0, .xmm2);
                                em.pandn(.xmm2, .xmm1);
                                em.por(.xmm0, .xmm2);
                            },
                            .simd_not => {
                                em.pcmpeqb(.xmm1, .xmm1);
                                em.pxor(.xmm0, .xmm1);
                            },
                            .simd_add_8 => {
                                em.movupsLoad(.xmm1, .rbx, a64VfpOff(d.rm));
                                em.paddb(.xmm0, .xmm1);
                            },
                            .simd_sub_8 => {
                                em.movupsLoad(.xmm1, .rbx, a64VfpOff(d.rm));
                                em.psubb(.xmm0, .xmm1);
                            },
                            .simd_add_16 => {
                                em.movupsLoad(.xmm1, .rbx, a64VfpOff(d.rm));
                                em.paddw(.xmm0, .xmm1);
                            },
                            .simd_sub_16 => {
                                em.movupsLoad(.xmm1, .rbx, a64VfpOff(d.rm));
                                em.psubw(.xmm0, .xmm1);
                            },
                            .simd_add_32 => {
                                em.movupsLoad(.xmm1, .rbx, a64VfpOff(d.rm));
                                em.paddd(.xmm0, .xmm1);
                            },
                            .simd_sub_32 => {
                                em.movupsLoad(.xmm1, .rbx, a64VfpOff(d.rm));
                                em.psubd(.xmm0, .xmm1);
                            },
                            .simd_add_64 => {
                                em.movupsLoad(.xmm1, .rbx, a64VfpOff(d.rm));
                                em.paddq(.xmm0, .xmm1);
                            },
                            .simd_sub_64 => {
                                em.movupsLoad(.xmm1, .rbx, a64VfpOff(d.rm));
                                em.psubq(.xmm0, .xmm1);
                            },
                            .simd_cmeq_8 => {
                                em.movupsLoad(.xmm1, .rbx, a64VfpOff(d.rm));
                                em.pcmpeqb(.xmm0, .xmm1);
                            },
                            .simd_cmeqz_8 => {
                                em.pxor(.xmm1, .xmm1);
                                em.pcmpeqb(.xmm0, .xmm1);
                            },
                            .simd_cmtst_8 => {
                                em.movupsLoad(.xmm1, .rbx, a64VfpOff(d.rm));
                                em.pand(.xmm0, .xmm1);
                                em.pxor(.xmm1, .xmm1);
                                em.pcmpeqb(.xmm0, .xmm1);
                                em.pcmpeqb(.xmm2, .xmm2);
                                em.pxor(.xmm0, .xmm2);
                            },
                            else => unreachable,
                        }
                        if (d.imm != 0) {
                            em.movupsStore(.rbx, a64VfpOff(d.rd), .xmm0);
                        } else {
                            em.movsdStore(.rbx, a64VfpOff(d.rd), .xmm0);
                            em.xorRegReg(false, .rax, .rax);
                            em.movMemReg(true, .rbx, a64VfpOff(d.rd) + 8, .rax);
                        }
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
                                if (op == .b_cond and fused_flag_kind != .none) {
                                    const x86_cc = armCondToX86Cond(@intCast(d.rd & 0xf), fused_flag_kind, false).?;
                                    em.jccLabel(x86_cc, not_taken_label);
                                    em.bindLabel(check_label);
                                    const rem: i32 = @intCast(end_word - target_w);
                                    em.leaRegMem(true, .rax, .r15, rem);
                                    em.cmpRegReg(true, .rax, .r14);
                                    em.jccLabel(.a, exit_label);
                                    em.jmpLabel(inst_labels[target_idx]);
                                    em.bindLabel(not_taken_label);
                                    emitDeferredFlagUpdate(&em, off_pstate, fused_flag_kind);
                                    fused_flag_kind = .none;
                                    continue;
                                }
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
            emitSpillPinned64(&em);
            em.bindLabel(abort_epilogue_label);
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
    const off_excl_valid: i32 = @intCast(@offsetOf(CpuType, "excl_valid"));
    const off_mmu: i32 = @intCast(@offsetOf(CpuType, "mmu"));
    const off_tpidruro: i32 = off_mmu + @as(i32, @intCast(@offsetOf(mmu_mod.Mmu, "tpidruro")));
    const off_tpidrurw: i32 = off_mmu + @as(i32, @intCast(@offsetOf(mmu_mod.Mmu, "tpidrurw")));
    const off_tpidrprw: i32 = off_mmu + @as(i32, @intCast(@offsetOf(mmu_mod.Mmu, "tpidrprw")));
    const off_cpacr: i32 = off_mmu + @as(i32, @intCast(@offsetOf(mmu_mod.Mmu, "cpacr")));
    const off_vfp: i32 = @intCast(@offsetOf(CpuType, "vfp"));
    const off_vfp_s: i32 = off_vfp + @as(i32, @intCast(@offsetOf(vfp_mod.Vfp, "s")));
    const off_vfp_fpscr: i32 = off_vfp + @as(i32, @intCast(@offsetOf(vfp_mod.Vfp, "fpscr")));
    const off_vfp_fpexc: i32 = off_vfp + @as(i32, @intCast(@offsetOf(vfp_mod.Vfp, "fpexc")));

    return struct {
        inline fn arm32RegOff(reg: u8) i32 {
            return off_r + @as(i32, reg & 0xf) * 4;
        }

        inline fn arm32VfpSOff(s_reg: u8) i32 {
            return off_vfp_s + @as(i32, s_reg & 0x3f) * 4;
        }

        inline fn arm32VfpDOff(d_reg: u8) i32 {
            return off_vfp_s + @as(i32, d_reg & 0x1f) * 8;
        }

        fn emitReloadPinned32(em: *X64Emitter) void {
            for (0..em.pins.count) |i| {
                const r = em.pins.guest_regs[i] & 0xf;
                em.movRegMem(false, host_pin_regs[i], .rbx, arm32RegOff(r));
            }
        }

        fn emitSpillPinned32(em: *X64Emitter) void {
            for (0..em.pins.count) |i| {
                const r = em.pins.guest_regs[i] & 0xf;
                em.movMemReg(false, .rbx, arm32RegOff(r), host_pin_regs[i]);
            }
        }

        fn emitLoadArm32Reg(em: *X64Emitter, dst: Reg, reg: u8, pc_page_off: u32) void {
            const r = reg & 0xf;
            if (em.pins.getHost(r)) |hreg| {
                if (dst != hreg) em.movRegReg(false, dst, hreg);
                return;
            }
            em.movRegMem(false, dst, .rbx, arm32RegOff(r));
            if (r == 15) {
                em.addRegImm(false, dst, @intCast(pc_page_off + 8));
            }
        }

        fn emitStoreArm32Reg(em: *X64Emitter, reg: u8, src: Reg) void {
            const r = reg & 0xf;
            if (em.pins.getHost(r)) |hreg| {
                if (hreg != src) em.movRegReg(false, hreg, src);
                return;
            }
            em.movMemReg(false, .rbx, arm32RegOff(r), src);
        }

        fn emitSetPcInterworkingAndExit(em: *X64Emitter, epilogue_label: u16) void {
            const thumb_label = em.newLabel();
            em.testRegImm32(false, .rax, 1);
            em.jccLabel(.ne, thumb_label);
            em.andRegImm(false, .rax, -4);
            em.movMemReg(false, .rbx, off_r15, .rax);
            em.jmpLabel(epilogue_label);
            em.bindLabel(thumb_label);
            em.andRegImm(false, .rax, -2);
            em.movMemReg(false, .rbx, off_r15, .rax);
            em.movRegMem(false, .rcx, .rbx, off_cpsr);
            em.orRegImm(false, .rcx, 1 << 5);
            em.movMemReg(false, .rbx, off_cpsr, .rcx);
            em.jmpLabel(epilogue_label);
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
            if ((raw_inst & (1 << 15)) != 0 or cpu.r[15] != cur_pc +% 4) return 1;
            if ((raw_inst & (1 << 20)) == 0) {
                if (cpu.checkInterrupts(bus)) return 1;
            }
            cpu.r[15] = trace_pc;
            return 0;
        }

        pub fn jitSlowMsrCpsrC32(
            cpu_opaque: *anyopaque,
            bus_opaque: *anyopaque,
            pc_page_off: u32,
            val: u32,
        ) callconv(.c) void {
            const cpu: *CpuType = @ptrCast(@alignCast(cpu_opaque));
            const bus: *Bus = @ptrCast(@alignCast(bus_opaque));
            const cur_pc = cpu.r[15] +% pc_page_off;
            cpu.r[15] = cur_pc +% 4;
            if (cpu.isPrivileged()) {
                cpu.setCpsr((cpu.cpsr & 0xffff_ff00) | (val & 0xff));
                _ = cpu.checkInterrupts(bus);
            }
        }

        pub fn jitSlowVfp32(
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
            cpu.executeVfp(bus, cur_pc, raw_inst, ((raw_inst >> 8) & 0xf) == 11);
            if (cpu.r[15] != cur_pc +% 4) return 1;
            if ((raw_inst & 0x0e10_0000) == 0x0c00_0000) {
                if (cpu.checkInterrupts(bus)) return 1;
            }
            cpu.r[15] = trace_pc;
            return 0;
        }

        fn emitVfpReadyCheck(em: *X64Emitter, slow_label: u16) void {
            em.movRegMem(false, .rax, .rbx, off_vfp_fpexc);
            em.testRegImm32(false, .rax, 1 << 30);
            em.jccLabel(.e, slow_label);
            em.movRegMem(false, .rax, .rbx, off_cpacr);
            em.testRegImm32(false, .rax, 2 << 20);
            em.jccLabel(.e, slow_label);
        }

        fn emitSlowVfpCall(
            em: *X64Emitter,
            slow_label: u16,
            done_label: u16,
            pc_page_off: u32,
            raw: u32,
            abort_epilogue_label: u16,
        ) void {
            em.bindLabel(slow_label);
            emitSpillPinned32(em);
            em.movRegReg(true, .rdi, .rbx);
            em.movRegReg(true, .rsi, .r12);
            em.movImm32(.rdx, pc_page_off);
            em.movImm32(.rcx, raw);
            em.movImm64(.r11, @intFromPtr(&jitSlowVfp32));
            em.callReg(.r11);
            em.testRegReg(true, .rax, .rax);
            em.jccLabel(.ne, abort_epilogue_label);
            emitReloadPinned32(em);
            em.bindLabel(done_label);
        }

        pub fn canCompileSlot(d: DecodedSlot) bool {
            const raw = d.raw;
            const op: ArmOp = @enumFromInt(d.op);
            if ((raw >> 28) == 0xf) return op == .nop_al or op == .clrex_al;
            return switch (op) {
                .nop_al,
                .clrex_al,
                .add_imm_al,
                .sub_imm_al,
                .rsb_imm_al,
                .adc_imm_al,
                .sbc_imm_al,
                .rsc_imm_al,
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
                .adcs_imm_al,
                .sbcs_imm_al,
                .movw_al,
                .movt_al,
                .add_reg_al,
                .sub_reg_al,
                .rsb_reg_al,
                .adc_reg_al,
                .sbc_reg_al,
                .rsc_reg_al,
                .and_reg_al,
                .orr_reg_al,
                .eor_reg_al,
                .bic_reg_al,
                .mov_reg_al,
                .mvn_reg_al,
                .adds_reg_al,
                .subs_reg_al,
                .adcs_reg_al,
                .sbcs_reg_al,
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
                .tst_lsl_reg_al,
                .tst_lsr_reg_al,
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
                .rev16_al,
                .ubfx_al,
                .sbfx_al,
                .bfi_al,
                .bfc_al,
                .udiv_al,
                .sdiv_al,
                .b_al,
                .bx_lr_al,
                .bx_reg_al,
                .ldm_pc_al,
                .ldr_wb_al,
                .mrs_cpsr_al,
                .mrc_tpidruro_al,
                .mrc_tpidrurw_al,
                .mrc_tpidrprw_al,
                .vldr_f64_al,
                .vstr_f64_al,
                .vldr_f32_al,
                .vstr_f32_al,
                .vldm_al,
                .vstm_al,
                .vmov_r_f64_al,
                .vmov_f64_r_al,
                .vmov_r_f32_al,
                .vmov_f32_r_al,
                .vmrs_apsr_al,
                .vadd_f64_al,
                .vsub_f64_al,
                .vmul_f64_al,
                .vdiv_f64_al,
                .vmla_f64_al,
                .vmls_f64_al,
                .vmov_f64_al,
                .vcmp_f64_al,
                .vcmpz_f64_al,
                .vadd_f32_al,
                .vsub_f32_al,
                .vmul_f32_al,
                .vdiv_f32_al,
                .vmla_f32_al,
                .vmls_f32_al,
                .vmov_f32_al,
                => true,
                else => false,
            };
        }

        inline fn isTerminator(op: ArmOp, raw: u32) bool {
            if ((raw >> 28) != 0xe) return false;
            return switch (op) {
                .b_al, .bl_al, .bx_lr_al, .bx_reg_al, .blx_reg_al, .ldm_pc_al => true,
                .ldr_wb_al => ((raw >> 12) & 0xf) == 15,
                else => false,
            };
        }

        fn selectPinnedRegsArm32(decoded: []const DecodedSlot) RegPinSet {
            var counts: [15]u16 = @splat(0);
            const bump = struct {
                inline fn add(c: *[15]u16, r: u8) void {
                    const idx = r & 0xf;
                    if (idx < 15) c[idx] +|= 1;
                }
            }.add;
            for (decoded) |d| {
                const op: ArmOp = @enumFromInt(d.op);
                switch (op) {
                    .nop_al, .b_al => {},
                    .bl_al, .bx_lr_al => bump(&counts, 14),
                    .bx_reg_al, .msr_cpsr_c_al => bump(&counts, d.rm),
                    .blx_reg_al => {
                        bump(&counts, d.rm);
                        bump(&counts, 14);
                    },
                    .mov_imm_al, .movw_al, .mvn_imm_al, .ldr_lit_al, .mrs_cpsr_al, .mrc_tpidruro_al, .mrc_tpidrurw_al, .mrc_tpidrprw_al => bump(&counts, d.rd),
                    .movt_al, .bfc_al => {
                        bump(&counts, d.rd);
                        bump(&counts, d.rd);
                    },
                    .cmp_imm_al, .cmn_imm_al, .tst_imm_al, .teq_imm_al => bump(&counts, d.rn),
                    .add_imm_al, .sub_imm_al, .rsb_imm_al, .adc_imm_al, .sbc_imm_al, .rsc_imm_al, .and_imm_al, .orr_imm_al, .eor_imm_al, .bic_imm_al, .adds_imm_al, .subs_imm_al, .adcs_imm_al, .sbcs_imm_al, .ldr_imm_al, .str_imm_al, .ldrb_imm_al, .strb_imm_al, .ldrh_imm_al, .strh_imm_al, .ldrsb_imm_al, .ldrsh_imm_al => {
                        bump(&counts, d.rd);
                        bump(&counts, d.rn);
                    },
                    .ldr_wb_al, .str_wb_al, .ldrb_wb_al, .strb_wb_al => {
                        bump(&counts, d.rd);
                        bump(&counts, d.rn);
                        bump(&counts, d.rn);
                    },
                    .ldrd_imm_al, .strd_imm_al => {
                        bump(&counts, d.rd);
                        bump(&counts, d.rd + 1);
                        bump(&counts, d.rn);
                    },
                    .mov_reg_al, .mvn_reg_al, .lsl_imm_al, .lsr_imm_al, .asr_imm_al, .mvn_lsl_imm_al, .mvn_lsr_imm_al, .uxtb_al, .uxth_al, .sxtb_al, .sxth_al, .rev_al, .rev16_al, .ubfx_al, .sbfx_al, .clz_al => {
                        bump(&counts, d.rd);
                        bump(&counts, d.rm);
                    },
                    .bfi_al => {
                        bump(&counts, d.rd);
                        bump(&counts, d.rd);
                        bump(&counts, d.rm);
                    },
                    .cmp_reg_al, .cmn_reg_al, .tst_reg_al, .teq_reg_al, .cmp_lsl_reg_al, .cmp_lsr_reg_al, .tst_lsl_reg_al, .tst_lsr_reg_al => {
                        bump(&counts, d.rn);
                        bump(&counts, d.rm);
                    },
                    .add_reg_al, .sub_reg_al, .rsb_reg_al, .adc_reg_al, .sbc_reg_al, .rsc_reg_al, .and_reg_al, .orr_reg_al, .eor_reg_al, .bic_reg_al, .adds_reg_al, .subs_reg_al, .adcs_reg_al, .sbcs_reg_al, .add_lsl_reg_al, .sub_lsl_reg_al, .rsb_lsl_reg_al, .orr_lsl_reg_al, .eor_lsl_reg_al, .and_lsl_reg_al, .bic_lsl_reg_al, .add_lsr_reg_al, .sub_lsr_reg_al, .rsb_lsr_reg_al, .orr_lsr_reg_al, .eor_lsr_reg_al, .and_lsr_reg_al, .bic_lsr_reg_al, .add_asr_reg_al, .sub_asr_reg_al, .orr_asr_reg_al, .and_asr_reg_al, .bic_asr_reg_al, .mul_al, .udiv_al, .sdiv_al, .uxtab_al, .uxtah_al, .sxtab_al, .sxtah_al, .ldrh_reg_al, .strh_reg_al, .ldrsb_reg_al, .ldrsh_reg_al, .ldr_reg_lsl_al, .str_reg_lsl_al, .ldrb_reg_lsl_al, .strb_reg_lsl_al, .ldr_reg_sub_lsl_al, .str_reg_sub_lsl_al, .ldrb_reg_sub_lsl_al, .strb_reg_sub_lsl_al, .ldr_reg_lsr_al, .str_reg_lsr_al => {
                        bump(&counts, d.rd);
                        bump(&counts, d.rn);
                        bump(&counts, d.rm);
                    },
                    .mla_al, .mls_al, .umull_al, .umlal_al, .smull_al, .smlal_al => {
                        bump(&counts, d.rd);
                        bump(&counts, d.rn);
                        bump(&counts, d.rm);
                        bump(&counts, @truncate(d.imm));
                    },
                    .ldm_al, .ldm_pc_al, .stm_al => {
                        bump(&counts, d.rn);
                        var rem: u16 = @truncate(d.imm & 0x7fff);
                        while (rem != 0) : (rem &= rem - 1) {
                            bump(&counts, @intCast(@ctz(rem)));
                        }
                    },
                    .dp_imm_general => {
                        bump(&counts, @truncate((d.raw >> 12) & 0xf));
                        bump(&counts, @truncate((d.raw >> 16) & 0xf));
                    },
                    .dp_reg_general => {
                        bump(&counts, @truncate((d.raw >> 12) & 0xf));
                        bump(&counts, @truncate((d.raw >> 16) & 0xf));
                        bump(&counts, @truncate(d.raw & 0xf));
                        if ((d.raw & (1 << 4)) != 0) bump(&counts, @truncate((d.raw >> 8) & 0xf));
                    },
                    .vldr_f64_al, .vstr_f64_al, .vldr_f32_al, .vstr_f32_al, .vldm_al, .vstm_al => {
                        bump(&counts, d.rn);
                    },
                    .vmov_r_f64_al, .vmov_f64_r_al => {
                        bump(&counts, d.rd);
                        bump(&counts, d.rn);
                    },
                    .vmov_r_f32_al, .vmov_f32_r_al => {
                        bump(&counts, d.rd);
                    },
                    else => {},
                }
            }
            var pins = RegPinSet{};
            while (pins.count < 5) {
                var best_r: u8 = 0xff;
                var best_c: u16 = 1;
                for (0..15) |r| {
                    if (counts[r] > best_c) {
                        best_c = counts[r];
                        best_r = @intCast(r);
                    }
                }
                if (best_r == 0xff) break;
                pins.guest_regs[pins.count] = best_r;
                pins.count += 1;
                counts[best_r] = 0;
            }
            return pins;
        }

        fn arm32FlagSetKind(d: DecodedSlot) FlagSetKind {
            if ((d.raw >> 28) != 0xe) return .none;
            const op: ArmOp = @enumFromInt(d.op);
            return switch (op) {
                .adds_imm_al, .cmn_imm_al, .adds_reg_al, .cmn_reg_al => .add,
                .subs_imm_al, .cmp_imm_al, .subs_reg_al, .cmp_reg_al, .cmp_lsl_reg_al, .cmp_lsr_reg_al => .sub,
                .tst_imm_al, .teq_imm_al, .tst_reg_al, .teq_reg_al => .logic_keep_cv,
                else => .none,
            };
        }

        fn canFuseArm32BackwardBranch(
            decoded: []const DecodedSlot,
            start_word: u10,
            end_word: u16,
            idx: usize,
            kind: FlagSetKind,
        ) bool {
            if (kind == .none or idx + 1 >= decoded.len) return false;
            const next_d = decoded[idx + 1];
            const next_op: ArmOp = @enumFromInt(next_d.op);
            const next_cond: u4 = @intCast(next_d.raw >> 28);
            if (next_op != .b_al or next_cond >= 0xe) return false;
            if (armCondToX86Cond(next_cond, kind, false) == null) return false;

            const next_w: u16 = start_word + @as(u16, @intCast(idx + 1));
            const next_pc_off: u32 = @as(u32, next_w) * 4;
            const target_delta: i32 = @as(i32, @intCast(next_pc_off + 8)) + @as(i32, @bitCast(@as(u32, @truncate(next_d.imm))));
            const target_word_i32 = @divExact(target_delta, 4);
            if (target_word_i32 < @as(i32, start_word) or target_word_i32 >= @as(i32, end_word)) return false;
            const target_w: u16 = @intCast(target_word_i32);
            if (target_w > next_w) return false;
            const target_idx: usize = target_w - start_word;
            if (target_idx > idx) return false;

            for (0..decoded.len) |j| {
                const jd = decoded[j];
                const jop: ArmOp = @enumFromInt(jd.op);
                if (jop == .b_al or jop == .bl_al) {
                    const jw: u16 = start_word + @as(u16, @intCast(j));
                    const jdelta: i32 = @as(i32, @intCast(@as(u32, jw) * 4 + 8)) + @as(i32, @bitCast(@as(u32, @truncate(jd.imm))));
                    if (@divExact(jdelta, 4) == @as(i32, next_w)) return false;
                }
                if (j >= target_idx and j < idx) {
                    if ((jd.raw >> 28) != 0xe and jop != .nop_al and jop != .clrex_al and jop != .cpsid_al and jop != .cpsie_al) return false;
                    if (arm32FlagSetKind(jd) != .none) return false;
                    switch (jop) {
                        .b_al, .bl_al, .bx_lr_al, .bx_reg_al, .blx_reg_al, .ldm_pc_al,
                        .adc_imm_al, .sbc_imm_al, .rsc_imm_al, .adcs_imm_al, .sbcs_imm_al,
                        .adc_reg_al, .sbc_reg_al, .rsc_reg_al, .adcs_reg_al, .sbcs_reg_al,
                        .tst_lsl_reg_al, .tst_lsr_reg_al,
                        .mrs_cpsr_al, .msr_cpsr_c_al, .cpsid_al, .cpsie_al, .vmrs_apsr_al,
                        .dp_imm_general, .dp_reg_general,
                        => return false,
                        .ldr_wb_al => if (jd.rd == 15) return false,
                        else => {},
                    }
                }
            }
            return true;
        }

        pub fn isSpinLoop(
            code_page_ptr: [*]const u8,
            start_word: u10,
            end_word_req: u16,
        ) bool {
            if (end_word_req <= start_word + 1 or end_word_req - start_word > 64 or end_word_req > 1024) return false;
            const trace_len: u16 = end_word_req - start_word;
            var read_before_write: u32 = 0;
            var written: u32 = 0;
            var has_side_effect = false;
            var has_load = false;

            const useReg = struct {
                inline fn r(rbw: *u32, wr: u32, reg: u8) void {
                    const idx = reg & 0xf;
                    if (idx < 15 and (wr & (@as(u32, 1) << @intCast(idx))) == 0) {
                        rbw.* |= (@as(u32, 1) << @intCast(idx));
                    }
                }
            }.r;
            const defReg = struct {
                inline fn w(wr: *u32, reg: u8) void {
                    const idx = reg & 0xf;
                    if (idx < 15) wr.* |= (@as(u32, 1) << @intCast(idx));
                }
            }.w;

            for (0..trace_len) |i| {
                const w = start_word + @as(u16, @intCast(i));
                const raw = std.mem.readInt(u32, code_page_ptr[@as(usize, w) * 4 ..][0..4], .little);
                const d = arm1176_mod.decodeArm32(raw);
                const op: ArmOp = @enumFromInt(d.op);
                const cond: u4 = @truncate(raw >> 28);
                switch (op) {
                    .mcr_barrier_al, .yield_wfe_al, .dmb_dsb_v7_al,
                    .ldrex_al, .strex_al, .ldrexd_al, .strexd_al, .ldrexb_al, .strexb_al, .ldrexh_al, .strexh_al,
                    => return true,
                    .nop_al, .b_al, .bx_lr_al, .bx_reg_al, .ldm_pc_al => {},
                    .ldr_wb_al => if (d.rd != 15) {
                        has_side_effect = true;
                    },
                    .ldr_imm_al, .ldrb_imm_al, .ldrh_imm_al, .ldrsb_imm_al, .ldrsh_imm_al => {
                        has_load = true;
                        useReg(&read_before_write, written, d.rn);
                        if (cond == 0xe) defReg(&written, d.rd) else useReg(&read_before_write, written, d.rd);
                    },
                    .ldr_reg_lsl_al, .ldrb_reg_lsl_al, .ldr_reg_sub_lsl_al, .ldrb_reg_sub_lsl_al, .ldr_reg_lsr_al, .ldrh_reg_al, .ldrsb_reg_al, .ldrsh_reg_al => {
                        has_load = true;
                        useReg(&read_before_write, written, d.rn);
                        useReg(&read_before_write, written, d.rm);
                        if (cond == 0xe) defReg(&written, d.rd) else useReg(&read_before_write, written, d.rd);
                    },
                    .ldr_lit_al => {
                        has_load = true;
                        if (cond == 0xe) defReg(&written, d.rd) else useReg(&read_before_write, written, d.rd);
                    },
                    .mov_imm_al, .mvn_imm_al, .movw_al, .mrs_cpsr_al, .mrc_tpidruro_al, .mrc_tpidrurw_al, .mrc_tpidrprw_al => {
                        if (cond == 0xe) defReg(&written, d.rd) else useReg(&read_before_write, written, d.rd);
                    },
                    .movt_al, .bfc_al => {
                        useReg(&read_before_write, written, d.rd);
                        defReg(&written, d.rd);
                    },
                    .bfi_al => {
                        useReg(&read_before_write, written, d.rd);
                        useReg(&read_before_write, written, d.rm);
                        defReg(&written, d.rd);
                    },
                    .cmp_imm_al, .cmn_imm_al, .tst_imm_al, .teq_imm_al => {
                        useReg(&read_before_write, written, d.rn);
                    },
                    .cmp_reg_al, .cmn_reg_al, .tst_reg_al, .teq_reg_al, .cmp_lsl_reg_al, .cmp_lsr_reg_al, .tst_lsl_reg_al, .tst_lsr_reg_al => {
                        useReg(&read_before_write, written, d.rn);
                        useReg(&read_before_write, written, d.rm);
                    },
                    .add_imm_al, .sub_imm_al, .rsb_imm_al, .adc_imm_al, .sbc_imm_al, .rsc_imm_al, .and_imm_al, .orr_imm_al, .eor_imm_al, .bic_imm_al, .adds_imm_al, .subs_imm_al, .adcs_imm_al, .sbcs_imm_al, .ubfx_al, .sbfx_al => {
                        useReg(&read_before_write, written, d.rn);
                        if (cond == 0xe) defReg(&written, d.rd) else useReg(&read_before_write, written, d.rd);
                    },
                    .mov_reg_al, .mvn_reg_al, .lsl_imm_al, .lsr_imm_al, .asr_imm_al, .mvn_lsl_imm_al, .mvn_lsr_imm_al, .uxtb_al, .uxth_al, .sxtb_al, .sxth_al, .rev_al, .rev16_al, .clz_al => {
                        useReg(&read_before_write, written, d.rm);
                        if (cond == 0xe) defReg(&written, d.rd) else useReg(&read_before_write, written, d.rd);
                    },
                    .add_reg_al, .sub_reg_al, .rsb_reg_al, .adc_reg_al, .sbc_reg_al, .rsc_reg_al, .and_reg_al, .orr_reg_al, .eor_reg_al, .bic_reg_al, .adds_reg_al, .subs_reg_al, .adcs_reg_al, .sbcs_reg_al, .add_lsl_reg_al, .sub_lsl_reg_al, .rsb_lsl_reg_al, .orr_lsl_reg_al, .eor_lsl_reg_al, .and_lsl_reg_al, .bic_lsl_reg_al, .add_lsr_reg_al, .sub_lsr_reg_al, .rsb_lsr_reg_al, .orr_lsr_reg_al, .eor_lsr_reg_al, .and_lsr_reg_al, .bic_lsr_reg_al, .add_asr_reg_al, .sub_asr_reg_al, .orr_asr_reg_al, .and_asr_reg_al, .bic_asr_reg_al, .uxtab_al, .uxtah_al, .sxtab_al, .sxtah_al, .mul_al, .udiv_al, .sdiv_al => {
                        useReg(&read_before_write, written, d.rn);
                        useReg(&read_before_write, written, d.rm);
                        if (cond == 0xe) defReg(&written, d.rd) else useReg(&read_before_write, written, d.rd);
                    },
                    .dp_imm_general => {
                        const op4: u4 = @truncate((raw >> 21) & 0xf);
                        const rn: u8 = @truncate((raw >> 16) & 0xf);
                        const rd: u8 = @truncate((raw >> 12) & 0xf);
                        if (op4 != 0xd and op4 != 0xf) useReg(&read_before_write, written, rn);
                        if (op4 < 0x8 or op4 > 0xb) {
                            if (cond == 0xe) defReg(&written, rd) else useReg(&read_before_write, written, rd);
                        }
                    },
                    .dp_reg_general => {
                        const bit4 = (raw & (1 << 4)) != 0;
                        const op4: u4 = @truncate((raw >> 21) & 0xf);
                        const rn: u8 = @truncate((raw >> 16) & 0xf);
                        const rd: u8 = @truncate((raw >> 12) & 0xf);
                        const rm: u8 = @truncate(raw & 0xf);
                        if (op4 != 0xd and op4 != 0xf) useReg(&read_before_write, written, rn);
                        useReg(&read_before_write, written, rm);
                        if (bit4) useReg(&read_before_write, written, @truncate((raw >> 8) & 0xf));
                        if (op4 < 0x8 or op4 > 0xb) {
                            if (cond == 0xe) defReg(&written, rd) else useReg(&read_before_write, written, rd);
                        }
                    },
                    else => has_side_effect = true,
                }
            }
            if (end_word_req < 1024) {
                const next_raw = std.mem.readInt(u32, code_page_ptr[@as(usize, end_word_req) * 4 ..][0..4], .little);
                if ((next_raw & 0x0fff_ffe0) == 0x057f_f040) return true;
            }
            return !has_side_effect and has_load and (written & read_before_write) == 0;
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
            var decoded: [128]DecodedSlot = undefined;
            var trace_len: u16 = 0;

            if (requested_end_word != 0) {
                if (requested_end_word <= start_word + 1 or requested_end_word - start_word > max_window or requested_end_word > 1024) return null;
                if (isSpinLoop(code_page_ptr, start_word, requested_end_word)) return null;
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
                    const is_uncond_exit = (raw_inst >> 28) == 0xe and switch (op) {
                        .bl_al, .blx_reg_al, .bx_lr_al, .bx_reg_al, .ldm_pc_al => true,
                        .ldr_wb_al => d.rd == 15,
                        else => false,
                    };
                    if (is_uncond_exit) {
                        var can_bypass = false;
                        for (0..i) |j| {
                            const jd = decoded[j];
                            const jop: ArmOp = @enumFromInt(jd.op);
                            if (jop == .b_al) {
                                const jw: i32 = @intCast(start_word + @as(u16, @intCast(j)));
                                const jdelta: i32 = @bitCast(@as(u32, @truncate(jd.imm)));
                                const jtarget = jw + 2 + @divExact(jdelta, 4);
                                if (jtarget > @as(i32, w) or jtarget <= jw) {
                                    can_bypass = true;
                                    break;
                                }
                            }
                        }
                        if (!can_bypass) return null;
                    }
                    decoded[i] = d;
                }
            } else {
                const limit_word: u16 = @min(@as(u16, 1024), @as(u16, start_word) + 64);
                var target_mask: u64 = 0;
                var has_backward_branch = false;
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
                        const jdelta: i32 = @bitCast(@as(u32, @truncate(d.imm)));
                        const tw = @as(i32, w) + 2 + @divExact(jdelta, 4);
                        if (tw > @as(i32, w) and tw < @as(i32, limit_word)) {
                            const tidx: u6 = @intCast(tw - @as(i32, start_word));
                            target_mask |= (@as(u64, 1) << tidx);
                        } else if (op == .b_al and tw >= @as(i32, start_word) and tw <= @as(i32, w)) {
                            const loop_start: u10 = @intCast(tw);
                            if (isSpinLoop(code_page_ptr, loop_start, w + 1)) return null;
                            has_backward_branch = true;
                        }
                    }
                    decoded[trace_len] = d;
                    trace_len += 1;
                    if (isTerminator(op, raw_inst)) {
                        if (trace_len < 64 and (target_mask >> @intCast(trace_len)) != 0) {
                            continue;
                        }
                        break;
                    }
                }
                if (trace_len < 4 and (!has_backward_branch or trace_len < 2)) return null;
            }

            const end_word: u16 = start_word + trace_len;
            out_end_word.* = end_word;

            var em = X64Emitter{
                .pins = selectPinnedRegsArm32(decoded[0..trace_len]),
            };
            em.emitPrologue();
            emitReloadPinned32(&em);

            const epilogue_label = em.newLabel();
            const abort_epilogue_label = em.newLabel();
            var inst_labels: [128]u16 = undefined;
            for (0..trace_len) |i| {
                inst_labels[i] = em.newLabel();
            }

            var exit_stubs: [256]ExitStub = undefined;
            var exit_stub_count: usize = 0;
            var fused_flag_kind: FlagSetKind = .none;

            for (0..trace_len) |idx| {
                const w: u16 = start_word + @as(u16, @intCast(idx));
                const pc_page_off: u32 = @as(u32, w) * 4;
                const d = decoded[idx];
                const raw = d.raw;
                const cond: u4 = @intCast(raw >> 28);
                const op: ArmOp = @enumFromInt(d.op);
                const imm32: u32 = @truncate(d.imm);
                const flag_kind = arm32FlagSetKind(d);
                const fuse_flags = canFuseArm32BackwardBranch(decoded[0..trace_len], start_word, end_word, idx, flag_kind);

                em.bindLabel(inst_labels[idx]);
                if (fused_flag_kind != .none) {
                    em.leaRegMem(true, .r15, .r15, 1);
                } else {
                    em.addRegImm(true, .r15, 1);
                }

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
                        if (op == .b_al and in_trace and fused_flag_kind != .none) {
                            const target_w: u16 = @intCast(target_word_i32);
                            if (target_w <= w) {
                                const target_idx = target_w - start_word;
                                const x86_cc = armCondToX86Cond(cond, fused_flag_kind, false).?;
                                em.jccLabel(x86_cc, not_taken);
                                const rem: i32 = @intCast(end_word - target_w);
                                const exit_label = em.newLabel();
                                exit_stubs[exit_stub_count] = .{ .label = exit_label, .pc_delta = target_delta };
                                exit_stub_count += 1;
                                em.leaRegMem(true, .rax, .r15, rem);
                                em.cmpRegReg(true, .rax, .r14);
                                em.jccLabel(.a, exit_label);
                                em.jmpLabel(inst_labels[target_idx]);
                                em.bindLabel(not_taken);
                                emitDeferredFlagUpdate(&em, off_cpsr, fused_flag_kind);
                                fused_flag_kind = .none;
                                continue;
                            }
                        }
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
                        if ((op == .add_imm_al or op == .sub_imm_al) and d.rd == d.rn and em.pins.getHost(d.rd & 0xf) != null) {
                            const hreg = em.pins.getHost(d.rd & 0xf).?;
                            if (op == .add_imm_al) em.addRegImm(false, hreg, @bitCast(imm32)) else em.subRegImm(false, hreg, @bitCast(imm32));
                        } else {
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
                        }
                    },

                    .adc_imm_al, .sbc_imm_al, .rsc_imm_al => {
                        emitLoadArm32Reg(&em, .rax, d.rn, pc_page_off);
                        em.movRegMem(false, .rdx, .rbx, off_cpsr);
                        em.shrImm(false, .rdx, 29);
                        em.andRegImm(false, .rdx, 1);
                        if (op == .rsc_imm_al) {
                            em.notReg(false, .rax);
                            em.addRegImm(false, .rax, @bitCast(imm32));
                        } else if (op == .sbc_imm_al) {
                            em.addRegImm(false, .rax, @bitCast(~imm32));
                        } else {
                            em.addRegImm(false, .rax, @bitCast(imm32));
                        }
                        em.addRegReg(false, .rax, .rdx);
                        emitStoreArm32Reg(&em, d.rd, .rax);
                    },

                    .adds_imm_al, .subs_imm_al, .cmp_imm_al, .cmn_imm_al => {
                        const is_sub = op == .subs_imm_al or op == .cmp_imm_al;
                        const write_rd = op == .adds_imm_al or op == .subs_imm_al;
                        if (write_rd and d.rd == d.rn and em.pins.getHost(d.rd & 0xf) != null) {
                            const hreg = em.pins.getHost(d.rd & 0xf).?;
                            if (is_sub) em.subRegImm(false, hreg, @bitCast(imm32)) else em.addRegImm(false, hreg, @bitCast(imm32));
                        } else {
                            emitLoadArm32Reg(&em, .rax, d.rn, pc_page_off);
                            if (is_sub) em.subRegImm(false, .rax, @bitCast(imm32)) else em.addRegImm(false, .rax, @bitCast(imm32));
                            if (write_rd) emitStoreArm32Reg(&em, d.rd, .rax);
                        }
                        if (fuse_flags) {
                            fused_flag_kind = flag_kind;
                        } else {
                            emitUpdateNZCV_AddSub(&em, off_cpsr, is_sub);
                        }
                    },

                    .adcs_imm_al, .sbcs_imm_al => {
                        emitLoadArm32Reg(&em, .rax, d.rn, pc_page_off);
                        em.movImm32(.rcx, if (op == .sbcs_imm_al) ~imm32 else imm32);
                        em.movRegMem(false, .rdx, .rbx, off_cpsr);
                        em.shrImm(false, .rdx, 30);
                        em.adcRegReg(false, .rax, .rcx);
                        emitStoreArm32Reg(&em, d.rd, .rax);
                        emitUpdateNZCV_AddSub(&em, off_cpsr, false);
                    },

                    .tst_imm_al, .teq_imm_al => {
                        emitLoadArm32Reg(&em, .rax, d.rn, pc_page_off);
                        if (op == .tst_imm_al) em.andRegImm(false, .rax, @bitCast(imm32)) else em.xorRegImm(false, .rax, @bitCast(imm32));
                        if (fuse_flags) {
                            fused_flag_kind = flag_kind;
                        } else {
                            emitUpdateNZ_Logic(&em, off_cpsr, true);
                        }
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

                    .adc_reg_al, .sbc_reg_al, .rsc_reg_al => {
                        emitLoadArm32Reg(&em, .rax, d.rn, pc_page_off);
                        emitLoadArm32Reg(&em, .rcx, d.rm, pc_page_off);
                        if (op == .sbc_reg_al) {
                            em.notReg(false, .rcx);
                        } else if (op == .rsc_reg_al) {
                            em.notReg(false, .rax);
                        }
                        em.movRegMem(false, .rdx, .rbx, off_cpsr);
                        em.shrImm(false, .rdx, 29);
                        em.andRegImm(false, .rdx, 1);
                        em.addRegReg(false, .rax, .rcx);
                        em.addRegReg(false, .rax, .rdx);
                        emitStoreArm32Reg(&em, d.rd, .rax);
                    },

                    .adds_reg_al, .subs_reg_al, .cmp_reg_al, .cmn_reg_al => {
                        const is_sub = op == .subs_reg_al or op == .cmp_reg_al;
                        const write_rd = op == .adds_reg_al or op == .subs_reg_al;
                        emitLoadArm32Reg(&em, .rax, d.rn, pc_page_off);
                        emitLoadArm32Reg(&em, .rcx, d.rm, pc_page_off);
                        if (is_sub) em.subRegReg(false, .rax, .rcx) else em.addRegReg(false, .rax, .rcx);
                        if (write_rd) emitStoreArm32Reg(&em, d.rd, .rax);
                        if (fuse_flags) {
                            fused_flag_kind = flag_kind;
                        } else {
                            emitUpdateNZCV_AddSub(&em, off_cpsr, is_sub);
                        }
                    },

                    .adcs_reg_al, .sbcs_reg_al => {
                        emitLoadArm32Reg(&em, .rax, d.rn, pc_page_off);
                        emitLoadArm32Reg(&em, .rcx, d.rm, pc_page_off);
                        if (op == .sbcs_reg_al) em.notReg(false, .rcx);
                        em.movRegMem(false, .rdx, .rbx, off_cpsr);
                        em.shrImm(false, .rdx, 30);
                        em.adcRegReg(false, .rax, .rcx);
                        emitStoreArm32Reg(&em, d.rd, .rax);
                        emitUpdateNZCV_AddSub(&em, off_cpsr, false);
                    },

                    .tst_reg_al, .teq_reg_al => {
                        emitLoadArm32Reg(&em, .rax, d.rn, pc_page_off);
                        emitLoadArm32Reg(&em, .rcx, d.rm, pc_page_off);
                        if (op == .tst_reg_al) em.andRegReg(false, .rax, .rcx) else em.xorRegReg(false, .rax, .rcx);
                        if (fuse_flags) {
                            fused_flag_kind = flag_kind;
                        } else {
                            emitUpdateNZ_Logic(&em, off_cpsr, true);
                        }
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
                        if (fuse_flags) {
                            fused_flag_kind = flag_kind;
                        } else {
                            emitUpdateNZCV_AddSub(&em, off_cpsr, true);
                        }
                    },

                    .tst_lsl_reg_al, .tst_lsr_reg_al => {
                        emitLoadArm32Reg(&em, .rax, d.rn, pc_page_off);
                        emitLoadArm32Reg(&em, .rcx, d.rm, pc_page_off);
                        em.movRegReg(false, .rdx, .rcx);
                        const sh: u6 = @truncate(imm32);
                        if (op == .tst_lsl_reg_al) {
                            em.shrImm(false, .rdx, @intCast(32 - sh));
                            em.shlImm(false, .rcx, sh);
                        } else {
                            if (sh > 1) em.shrImm(false, .rdx, @intCast(sh - 1));
                            em.shrImm(false, .rcx, sh);
                        }
                        em.andRegImm(false, .rdx, 1);
                        em.shlImm(false, .rdx, 29);
                        em.andRegReg(false, .rax, .rcx);
                        em.setcc(.e, .rcx);
                        em.movzx8(false, .rcx, .rcx);
                        em.shlImm(false, .rcx, 30);
                        em.andRegImm(false, .rax, @bitCast(@as(u32, 0x8000_0000)));
                        em.orRegReg(false, .rax, .rcx);
                        em.orRegReg(false, .rax, .rdx);
                        em.movRegMem(false, .rcx, .rbx, off_cpsr);
                        em.andRegImm(false, .rcx, 0x1fff_ffff);
                        em.orRegReg(false, .rcx, .rax);
                        em.movMemReg(false, .rbx, off_cpsr, .rcx);
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

                    .rev_al, .rev16_al => {
                        emitLoadArm32Reg(&em, .rax, d.rm, pc_page_off);
                        em.bswap(false, .rax);
                        if (op == .rev16_al) em.rorImm(false, .rax, 16);
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

                    .udiv_al, .sdiv_al => {
                        const zero_label = em.newLabel();
                        const done_div = em.newLabel();
                        emitLoadArm32Reg(&em, .rax, d.rn, pc_page_off);
                        emitLoadArm32Reg(&em, .rcx, d.rm, pc_page_off);
                        em.testRegReg(false, .rcx, .rcx);
                        em.jccLabel(.e, zero_label);
                        if (op == .udiv_al) {
                            em.xorRegReg(false, .rdx, .rdx);
                            em.divReg1(false, .rcx);
                        } else {
                            const ovf_label = em.newLabel();
                            em.cmpRegImm(false, .rcx, -1);
                            em.jccLabel(.ne, ovf_label);
                            em.movImm32(.rdx, 0x8000_0000);
                            em.cmpRegReg(false, .rax, .rdx);
                            em.jccLabel(.e, done_div);
                            em.bindLabel(ovf_label);
                            em.cdqCqo(false);
                            em.idivReg1(false, .rcx);
                        }
                        em.jmpLabel(done_div);
                        em.bindLabel(zero_label);
                        em.xorRegReg(false, .rax, .rax);
                        em.bindLabel(done_div);
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
                            if (d.rd == 15) {
                                emitSetPcInterworkingAndExit(&em, epilogue_label);
                            } else {
                                emitStoreArm32Reg(&em, d.rd, .rax);
                            }
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
                        if (!(is_load and d.rd == 15)) {
                            em.jmpLabel(done_label);
                        }

                        em.bindLabel(slow_label);
                        emitSpillPinned32(&em);
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
                            em.jccLabel(.e, abort_epilogue_label);
                            emitReloadPinned32(&em);
                            if (is_signed) {
                                if (size == 2) em.movsx16(false, .rax, .rax) else em.movsx8(false, .rax, .rax);
                            }
                            if (d.rd == 15) {
                                emitSetPcInterworkingAndExit(&em, epilogue_label);
                            } else {
                                emitStoreArm32Reg(&em, d.rd, .rax);
                            }
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
                            em.jccLabel(.ne, abort_epilogue_label);
                            emitReloadPinned32(&em);
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
                        emitSpillPinned32(&em);
                        if (is_load) {
                            em.movRegReg(false, .rdx, .rdi);
                            em.movRegReg(true, .rdi, .rbx);
                            em.movRegReg(true, .rsi, .r12);
                            em.movImm32(.rcx, pc_page_off);
                            em.movImm32(.r8, 8);
                            em.movImm64(.r11, @intFromPtr(&jitSlowLoad32));
                            em.callReg(.r11);

                            em.testRegReg(true, .rdx, .rdx);
                            em.jccLabel(.ne, abort_epilogue_label);
                            emitReloadPinned32(&em);
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
                            em.jccLabel(.ne, abort_epilogue_label);
                            emitReloadPinned32(&em);
                        }

                        em.bindLabel(done_label);
                    },

                    .ldm_al, .ldm_pc_al, .stm_al => {
                        const is_load = op != .stm_al;
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
                        var rem: u16 = if (op == .ldm_pc_al) (reg_list & 0x7fff) else reg_list;
                        while (rem != 0) {
                            const r_idx: u4 = @intCast(@ctz(rem));
                            const pair_mask: u16 = @as(u16, 3) << r_idx;
                            if (r_idx < 14 and (rem & pair_mask) == pair_mask and !em.pins.isPinned(r_idx) and !em.pins.isPinned(r_idx + 1)) {
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
                        if (op == .ldm_pc_al) {
                            em.movRegSib(false, .rax, .r13, .rax, 0, cur_disp);
                            emitSetPcInterworkingAndExit(&em, epilogue_label);
                        } else {
                            em.jmpLabel(done_label);
                        }

                        em.bindLabel(slow_label);
                        emitSpillPinned32(&em);
                        em.movRegReg(true, .rdi, .rbx);
                        em.movRegReg(true, .rsi, .r12);
                        em.movImm32(.rdx, pc_page_off);
                        em.movImm32(.rcx, raw);
                        em.movImm64(.r11, @intFromPtr(&jitSlowLdmStm32));
                        em.callReg(.r11);
                        em.testRegReg(true, .rax, .rax);
                        em.jccLabel(.ne, abort_epilogue_label);
                        emitReloadPinned32(&em);

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
                        emitSetPcInterworkingAndExit(&em, epilogue_label);
                    },

                    .mrs_cpsr_al => {
                        em.movRegMem(false, .rax, .rbx, off_cpsr);
                        emitStoreArm32Reg(&em, d.rd, .rax);
                    },
                    .msr_cpsr_c_al => {
                        const slow_msr = em.newLabel();
                        const done_msr = em.newLabel();
                        emitLoadArm32Reg(&em, .rcx, d.rm, pc_page_off);
                        em.movRegMem(false, .rax, .rbx, off_cpsr);
                        em.movRegReg(false, .rdx, .rax);
                        em.andRegImm(false, .rdx, 0x1f);
                        em.cmpRegImm(false, .rdx, 0x10);
                        em.jccLabel(.e, done_msr);
                        em.movRegReg(false, .rdx, .rax);
                        em.xorRegReg(false, .rdx, .rcx);
                        em.testRegImm32(false, .rdx, 0x3f);
                        em.jccLabel(.ne, slow_msr);
                        em.andRegImm(false, .rax, -256);
                        em.movzx8(false, .rcx, .rcx);
                        em.orRegReg(false, .rax, .rcx);
                        em.movMemReg(false, .rbx, off_cpsr, .rax);
                        em.jmpLabel(done_msr);

                        em.bindLabel(slow_msr);
                        emitSpillPinned32(&em);
                        em.movRegReg(true, .rdi, .rbx);
                        em.movRegReg(true, .rsi, .r12);
                        em.movImm32(.rdx, pc_page_off);
                        em.movImm64(.r11, @intFromPtr(&jitSlowMsrCpsrC32));
                        em.callReg(.r11);
                        em.jmpLabel(abort_epilogue_label);

                        em.bindLabel(done_msr);
                    },
                    .cpsid_al, .cpsie_al => {
                        const done_cps = em.newLabel();
                        em.movRegMem(false, .rax, .rbx, off_cpsr);
                        em.movRegReg(false, .rdx, .rax);
                        em.andRegImm(false, .rdx, 0x1f);
                        em.cmpRegImm(false, .rdx, 0x10);
                        em.jccLabel(.e, done_cps);
                        if (op == .cpsid_al) {
                            em.orRegImm(false, .rax, @bitCast(imm32));
                        } else {
                            em.andRegImm(false, .rax, @bitCast(imm32));
                        }
                        em.movMemReg(false, .rbx, off_cpsr, .rax);
                        em.bindLabel(done_cps);
                    },
                    .clrex_al => {
                        em.xorRegReg(false, .rax, .rax);
                        em.movSib8Reg(.rbx, .rax, 0, off_excl_valid, .rax);
                    },
                    .mrc_tpidruro_al => {
                        em.movRegMem(false, .rax, .rbx, off_tpidruro);
                        emitStoreArm32Reg(&em, d.rd, .rax);
                    },
                    .mrc_tpidrurw_al => {
                        em.movRegMem(false, .rax, .rbx, off_tpidrurw);
                        emitStoreArm32Reg(&em, d.rd, .rax);
                    },
                    .mrc_tpidrprw_al => {
                        em.movRegMem(false, .rax, .rbx, off_tpidrprw);
                        emitStoreArm32Reg(&em, d.rd, .rax);
                    },

                    .dp_imm_general => {
                        const op4: u4 = @truncate((raw >> 21) & 0xf);
                        const rn: u8 = @truncate((raw >> 16) & 0xf);
                        const rd: u8 = @truncate((raw >> 12) & 0xf);
                        const rot: u5 = @as(u5, @truncate((raw >> 8) & 0xf)) * 2;
                        const dp_imm: u32 = std.math.rotr(u32, raw & 0xff, rot);
                        switch (op4) {
                            0xd => {
                                em.movImm32(.rax, dp_imm);
                                em.testRegReg(false, .rax, .rax);
                            },
                            0xf => {
                                em.movImm32(.rax, ~dp_imm);
                                em.testRegReg(false, .rax, .rax);
                            },
                            else => {
                                emitLoadArm32Reg(&em, .rax, rn, pc_page_off);
                                switch (op4) {
                                    0x0, 0x8 => em.andRegImm(false, .rax, @bitCast(dp_imm)),
                                    0x1, 0x9 => em.xorRegImm(false, .rax, @bitCast(dp_imm)),
                                    0xc => em.orRegImm(false, .rax, @bitCast(dp_imm)),
                                    0xe => em.andRegImm(false, .rax, @bitCast(~dp_imm)),
                                    else => unreachable,
                                }
                            },
                        }
                        if (op4 != 0x8 and op4 != 0x9) emitStoreArm32Reg(&em, rd, .rax);
                        if (rot == 0) {
                            emitUpdateNZ_Logic(&em, off_cpsr, true);
                        } else {
                            em.setcc(.e, .rcx);
                            em.movzx8(false, .rcx, .rcx);
                            em.shlImm(false, .rcx, 30);
                            em.andRegImm(false, .rax, @bitCast(@as(u32, 0x8000_0000)));
                            em.orRegReg(false, .rax, .rcx);
                            if ((dp_imm >> 31) != 0) em.orRegImm(false, .rax, 1 << 29);
                            em.movRegMem(false, .rcx, .rbx, off_cpsr);
                            em.andRegImm(false, .rcx, 0x1fff_ffff);
                            em.orRegReg(false, .rcx, .rax);
                            em.movMemReg(false, .rbx, off_cpsr, .rcx);
                        }
                    },

                    .dp_reg_general => {
                        const bit4 = (raw & (1 << 4)) != 0;
                        const op4: u4 = @truncate((raw >> 21) & 0xf);
                        const s = (raw & (1 << 20)) != 0;
                        const rn: u8 = @truncate((raw >> 16) & 0xf);
                        const rd: u8 = @truncate((raw >> 12) & 0xf);
                        const rm: u8 = @truncate(raw & 0xf);
                        const shift_imm: u6 = @truncate((raw >> 7) & 0x1f);
                        const shift_type: u2 = @truncate((raw >> 5) & 3);
                        const is_logic = !(op4 == 0x2 or op4 == 0x3 or op4 == 0x4 or op4 == 0x5 or op4 == 0x6 or op4 == 0x7 or op4 == 0xa or op4 == 0xb);
                        const has_shift = !bit4 and (shift_imm != 0 or shift_type != 0);

                        if (bit4) {
                            const rs: u8 = @truncate((raw >> 8) & 0xf);
                            const ok_shift = em.newLabel();
                            emitLoadArm32Reg(&em, .rcx, rs, pc_page_off);
                            em.movzx8(false, .rcx, .rcx);
                            em.cmpRegImm(false, .rcx, 32);
                            em.jccLabel(.be, ok_shift);
                            em.movImm32(.rcx, 32);
                            em.bindLabel(ok_shift);
                            emitLoadArm32Reg(&em, .rdx, rm, pc_page_off);
                            switch (shift_type) {
                                0 => em.shlCl(true, .rdx),
                                1 => em.shrCl(true, .rdx),
                                2 => {
                                    em.movsxd32(.rdx, .rdx);
                                    em.sarCl(true, .rdx);
                                },
                                else => unreachable,
                            }
                            em.movRegReg(false, .rcx, .rdx);
                        } else {
                            emitLoadArm32Reg(&em, .rcx, rm, pc_page_off);
                            if (has_shift) {
                                switch (shift_type) {
                                    0 => em.shlImm(false, .rcx, shift_imm),
                                    1 => if (shift_imm == 0) {
                                        if (s and is_logic) {
                                            em.shrImm(false, .rcx, 31);
                                            em.movRegReg(false, .rdx, .rcx);
                                            em.shlImm(false, .rdx, 29);
                                        }
                                        em.xorRegReg(false, .rcx, .rcx);
                                    } else {
                                        em.shrImm(false, .rcx, shift_imm);
                                    },
                                    2 => {
                                        em.sarImm(false, .rcx, if (shift_imm == 0) 31 else shift_imm);
                                        if (shift_imm == 0 and s and is_logic) {
                                            em.movRegReg(false, .rdx, .rcx);
                                            em.andRegImm(false, .rdx, 1 << 29);
                                        }
                                    },
                                    3 => em.rorImm(false, .rcx, shift_imm),
                                }
                                if (s and is_logic and shift_imm != 0) {
                                    em.setcc(.b, .rdx);
                                    em.movzx8(false, .rdx, .rdx);
                                    em.shlImm(false, .rdx, 29);
                                }
                            }
                        }

                        switch (op4) {
                            0xd => {
                                em.movRegReg(false, .rax, .rcx);
                                if (s) em.testRegReg(false, .rax, .rax);
                            },
                            0xf => {
                                em.movRegReg(false, .rax, .rcx);
                                em.notReg(false, .rax);
                                if (s) em.testRegReg(false, .rax, .rax);
                            },
                            0x0, 0x8 => {
                                emitLoadArm32Reg(&em, .rax, rn, pc_page_off);
                                em.andRegReg(false, .rax, .rcx);
                            },
                            0x1, 0x9 => {
                                emitLoadArm32Reg(&em, .rax, rn, pc_page_off);
                                em.xorRegReg(false, .rax, .rcx);
                            },
                            0xc => {
                                emitLoadArm32Reg(&em, .rax, rn, pc_page_off);
                                em.orRegReg(false, .rax, .rcx);
                            },
                            0xe => {
                                emitLoadArm32Reg(&em, .rax, rn, pc_page_off);
                                em.notReg(false, .rcx);
                                em.andRegReg(false, .rax, .rcx);
                            },
                            0x4, 0xb => {
                                emitLoadArm32Reg(&em, .rax, rn, pc_page_off);
                                em.addRegReg(false, .rax, .rcx);
                            },
                            0x2, 0xa => {
                                emitLoadArm32Reg(&em, .rax, rn, pc_page_off);
                                em.subRegReg(false, .rax, .rcx);
                            },
                            0x3 => {
                                emitLoadArm32Reg(&em, .rax, rn, pc_page_off);
                                em.subRegReg(false, .rcx, .rax);
                                em.movRegReg(false, .rax, .rcx);
                            },
                            0x5, 0x6, 0x7 => {
                                emitLoadArm32Reg(&em, .rax, rn, pc_page_off);
                                if (op4 == 0x6) em.notReg(false, .rcx) else if (op4 == 0x7) em.notReg(false, .rax);
                                em.movRegMem(false, .rdx, .rbx, off_cpsr);
                                em.shrImm(false, .rdx, 29);
                                em.andRegImm(false, .rdx, 1);
                                em.addRegReg(false, .rax, .rcx);
                                em.addRegReg(false, .rax, .rdx);
                            },
                        }
                        if (op4 < 0x8 or op4 > 0xb) emitStoreArm32Reg(&em, rd, .rax);
                        if (s) {
                            if (op4 == 0x2 or op4 == 0xa) {
                                emitUpdateNZCV_AddSub(&em, off_cpsr, true);
                            } else if (op4 == 0x4 or op4 == 0xb) {
                                emitUpdateNZCV_AddSub(&em, off_cpsr, false);
                            } else if (!has_shift) {
                                emitUpdateNZ_Logic(&em, off_cpsr, true);
                            } else {
                                em.setcc(.e, .rcx);
                                em.movzx8(false, .rcx, .rcx);
                                em.shlImm(false, .rcx, 30);
                                em.andRegImm(false, .rax, @bitCast(@as(u32, 0x8000_0000)));
                                em.orRegReg(false, .rax, .rcx);
                                em.orRegReg(false, .rax, .rdx);
                                em.movRegMem(false, .rcx, .rbx, off_cpsr);
                                em.andRegImm(false, .rcx, 0x1fff_ffff);
                                em.orRegReg(false, .rcx, .rax);
                                em.movMemReg(false, .rbx, off_cpsr, .rcx);
                            }
                        }
                    },

                    .vldr_f64_al, .vstr_f64_al, .vldr_f32_al, .vstr_f32_al => {
                        const is_load = op == .vldr_f64_al or op == .vldr_f32_al;
                        const is64 = op == .vldr_f64_al or op == .vstr_f64_al;
                        const addr_off: i32 = @bitCast(imm32);
                        const slow_vfp = em.newLabel();
                        const done_vfp = em.newLabel();
                        emitVfpReadyCheck(&em, slow_vfp);

                        emitLoadArm32Reg(&em, .rdi, d.rn, pc_page_off);
                        if (addr_off != 0) em.addRegImm(false, .rdi, addr_off);

                        em.movRegReg(false, .rcx, .rdi);
                        em.shrImm(false, .rcx, 8);
                        em.andRegImm(false, .rcx, 0xfff0);

                        em.movRegReg(false, .rax, .rdi);
                        em.andRegImm(false, .rax, -4093);
                        em.cmpSibReg(false, .rbp, .rcx, 0, if (is_load) off_tlb32_read_vpage else off_tlb32_write_vpage, .rax);
                        em.jccLabel(.ne, slow_vfp);
                        if (is64) {
                            em.leaRegMem(false, .rdx, .rdi, 4);
                            em.andRegImm(false, .rdx, -4093);
                            em.cmpRegReg(false, .rax, .rdx);
                            em.jccLabel(.ne, slow_vfp);
                        }

                        em.movRegSib(false, .rax, .rbp, .rcx, 0, off_tlb32_pbase);
                        em.movRegReg(false, .rdx, .rdi);
                        em.andRegImm(false, .rdx, 0xfff);
                        em.orRegReg(false, .rax, .rdx);

                        if (is_load) {
                            em.movRegSib(is64, .rcx, .r13, .rax, 0, 0);
                            em.movMemReg(is64, .rbx, arm32VfpSOff(d.rd), .rcx);
                        } else {
                            em.movRegMem(is64, .rcx, .rbx, arm32VfpSOff(d.rd));
                            em.movSibReg(is64, .r13, .rax, 0, 0, .rcx);
                        }
                        em.jmpLabel(done_vfp);
                        emitSlowVfpCall(&em, slow_vfp, done_vfp, pc_page_off, raw, abort_epilogue_label);
                    },

                    .vldm_al, .vstm_al => {
                        const is_load = op == .vldm_al;
                        const nbytes: u16 = @truncate(d.imm);
                        const last_off: u16 = @truncate(d.imm >> 16);
                        const start_off: i32 = @as(i16, @bitCast(@as(u16, @truncate(d.imm >> 32))));
                        const wb_off: i32 = @as(i16, @bitCast(@as(u16, @truncate(d.imm >> 48))));
                        const slow_vfp = em.newLabel();
                        const done_vfp = em.newLabel();
                        emitVfpReadyCheck(&em, slow_vfp);

                        emitLoadArm32Reg(&em, .rdi, d.rn, pc_page_off);
                        if (start_off != 0) em.addRegImm(false, .rdi, start_off);

                        em.movRegReg(false, .rcx, .rdi);
                        em.shrImm(false, .rcx, 8);
                        em.andRegImm(false, .rcx, 0xfff0);

                        em.movRegReg(false, .rax, .rdi);
                        em.andRegImm(false, .rax, -4093);
                        em.cmpSibReg(false, .rbp, .rcx, 0, if (is_load) off_tlb32_read_vpage else off_tlb32_write_vpage, .rax);
                        em.jccLabel(.ne, slow_vfp);
                        if (last_off != 0) {
                            em.leaRegMem(false, .rdx, .rdi, @intCast(last_off));
                            em.andRegImm(false, .rdx, -4093);
                            em.cmpRegReg(false, .rax, .rdx);
                            em.jccLabel(.ne, slow_vfp);
                        }

                        em.movRegSib(false, .rax, .rbp, .rcx, 0, off_tlb32_pbase);
                        em.movRegReg(false, .rdx, .rdi);
                        em.andRegImm(false, .rdx, 0xfff);
                        em.orRegReg(false, .rax, .rdx);

                        var cur: u16 = 0;
                        const base_s_off = arm32VfpSOff(d.rd);
                        while (cur + 8 <= nbytes) : (cur += 8) {
                            if (is_load) {
                                em.movRegSib(true, .rcx, .r13, .rax, 0, @intCast(cur));
                                em.movMemReg(true, .rbx, base_s_off + @as(i32, cur), .rcx);
                            } else {
                                em.movRegMem(true, .rcx, .rbx, base_s_off + @as(i32, cur));
                                em.movSibReg(true, .r13, .rax, 0, @intCast(cur), .rcx);
                            }
                        }
                        if (cur < nbytes) {
                            if (is_load) {
                                em.movRegSib(false, .rcx, .r13, .rax, 0, @intCast(cur));
                                em.movMemReg(false, .rbx, base_s_off + @as(i32, cur), .rcx);
                            } else {
                                em.movRegMem(false, .rcx, .rbx, base_s_off + @as(i32, cur));
                                em.movSibReg(false, .r13, .rax, 0, @intCast(cur), .rcx);
                            }
                        }
                        if (wb_off != 0) {
                            em.leaRegMem(false, .rcx, .rdi, wb_off -% start_off);
                            emitStoreArm32Reg(&em, d.rn, .rcx);
                        }
                        em.jmpLabel(done_vfp);
                        emitSlowVfpCall(&em, slow_vfp, done_vfp, pc_page_off, raw, abort_epilogue_label);
                    },

                    .vmov_r_f64_al, .vmov_f64_r_al => {
                        const slow_vfp = em.newLabel();
                        const done_vfp = em.newLabel();
                        emitVfpReadyCheck(&em, slow_vfp);
                        if (op == .vmov_r_f64_al) {
                            em.movRegMem(false, .rax, .rbx, arm32VfpSOff(d.rm));
                            emitStoreArm32Reg(&em, d.rd, .rax);
                            em.movRegMem(false, .rax, .rbx, arm32VfpSOff(d.rm + 1));
                            emitStoreArm32Reg(&em, d.rn, .rax);
                        } else {
                            emitLoadArm32Reg(&em, .rax, d.rd, pc_page_off);
                            em.movMemReg(false, .rbx, arm32VfpSOff(d.rm), .rax);
                            emitLoadArm32Reg(&em, .rax, d.rn, pc_page_off);
                            em.movMemReg(false, .rbx, arm32VfpSOff(d.rm + 1), .rax);
                        }
                        em.jmpLabel(done_vfp);
                        emitSlowVfpCall(&em, slow_vfp, done_vfp, pc_page_off, raw, abort_epilogue_label);
                    },

                    .vmov_r_f32_al, .vmov_f32_r_al => {
                        const slow_vfp = em.newLabel();
                        const done_vfp = em.newLabel();
                        emitVfpReadyCheck(&em, slow_vfp);
                        if (op == .vmov_r_f32_al) {
                            em.movRegMem(false, .rax, .rbx, arm32VfpSOff(d.rn));
                            emitStoreArm32Reg(&em, d.rd, .rax);
                        } else {
                            emitLoadArm32Reg(&em, .rax, d.rd, pc_page_off);
                            em.movMemReg(false, .rbx, arm32VfpSOff(d.rn), .rax);
                        }
                        em.jmpLabel(done_vfp);
                        emitSlowVfpCall(&em, slow_vfp, done_vfp, pc_page_off, raw, abort_epilogue_label);
                    },

                    .vmrs_apsr_al => {
                        const slow_vfp = em.newLabel();
                        const done_vfp = em.newLabel();
                        emitVfpReadyCheck(&em, slow_vfp);
                        em.movRegMem(false, .rax, .rbx, off_vfp_fpscr);
                        em.andRegImm(false, .rax, @bitCast(@as(u32, 0xf000_0000)));
                        em.movRegMem(false, .rcx, .rbx, off_cpsr);
                        em.andRegImm(false, .rcx, 0x0fff_ffff);
                        em.orRegReg(false, .rcx, .rax);
                        em.movMemReg(false, .rbx, off_cpsr, .rcx);
                        em.jmpLabel(done_vfp);
                        emitSlowVfpCall(&em, slow_vfp, done_vfp, pc_page_off, raw, abort_epilogue_label);
                    },

                    .vmov_f64_al, .vadd_f64_al, .vsub_f64_al, .vmul_f64_al, .vdiv_f64_al, .vmla_f64_al, .vmls_f64_al => {
                        const slow_vfp = em.newLabel();
                        const done_vfp = em.newLabel();
                        emitVfpReadyCheck(&em, slow_vfp);
                        switch (op) {
                            .vmov_f64_al => {
                                em.movRegMem(true, .rax, .rbx, arm32VfpDOff(d.rm));
                                em.movMemReg(true, .rbx, arm32VfpDOff(d.rd), .rax);
                            },
                            .vadd_f64_al, .vsub_f64_al, .vmul_f64_al, .vdiv_f64_al => {
                                em.movsdLoad(.xmm0, .rbx, arm32VfpDOff(d.rn));
                                em.movsdLoad(.xmm1, .rbx, arm32VfpDOff(d.rm));
                                switch (op) {
                                    .vadd_f64_al => em.addsd(.xmm0, .xmm1),
                                    .vsub_f64_al => em.subsd(.xmm0, .xmm1),
                                    .vmul_f64_al => em.mulsd(.xmm0, .xmm1),
                                    .vdiv_f64_al => em.divsd(.xmm0, .xmm1),
                                    else => unreachable,
                                }
                                em.movsdStore(.rbx, arm32VfpDOff(d.rd), .xmm0);
                            },
                            .vmla_f64_al, .vmls_f64_al => {
                                em.movsdLoad(.xmm0, .rbx, arm32VfpDOff(d.rn));
                                em.movsdLoad(.xmm1, .rbx, arm32VfpDOff(d.rm));
                                em.mulsd(.xmm0, .xmm1);
                                em.movsdLoad(.xmm1, .rbx, arm32VfpDOff(d.rd));
                                if (op == .vmla_f64_al) em.addsd(.xmm1, .xmm0) else em.subsd(.xmm1, .xmm0);
                                em.movsdStore(.rbx, arm32VfpDOff(d.rd), .xmm1);
                            },
                            else => unreachable,
                        }
                        em.jmpLabel(done_vfp);
                        emitSlowVfpCall(&em, slow_vfp, done_vfp, pc_page_off, raw, abort_epilogue_label);
                    },

                    .vmov_f32_al, .vadd_f32_al, .vsub_f32_al, .vmul_f32_al, .vdiv_f32_al, .vmla_f32_al, .vmls_f32_al => {
                        const slow_vfp = em.newLabel();
                        const done_vfp = em.newLabel();
                        emitVfpReadyCheck(&em, slow_vfp);
                        switch (op) {
                            .vmov_f32_al => {
                                em.movRegMem(false, .rax, .rbx, arm32VfpSOff(d.rm));
                                em.movMemReg(false, .rbx, arm32VfpSOff(d.rd), .rax);
                            },
                            .vadd_f32_al, .vsub_f32_al, .vmul_f32_al, .vdiv_f32_al => {
                                em.movssLoad(.xmm0, .rbx, arm32VfpSOff(d.rn));
                                em.movssLoad(.xmm1, .rbx, arm32VfpSOff(d.rm));
                                switch (op) {
                                    .vadd_f32_al => em.addss(.xmm0, .xmm1),
                                    .vsub_f32_al => em.subss(.xmm0, .xmm1),
                                    .vmul_f32_al => em.mulss(.xmm0, .xmm1),
                                    .vdiv_f32_al => em.divss(.xmm0, .xmm1),
                                    else => unreachable,
                                }
                                em.movssStore(.rbx, arm32VfpSOff(d.rd), .xmm0);
                            },
                            .vmla_f32_al, .vmls_f32_al => {
                                em.movssLoad(.xmm0, .rbx, arm32VfpSOff(d.rn));
                                em.movssLoad(.xmm1, .rbx, arm32VfpSOff(d.rm));
                                em.mulss(.xmm0, .xmm1);
                                em.movssLoad(.xmm1, .rbx, arm32VfpSOff(d.rd));
                                if (op == .vmla_f32_al) em.addss(.xmm1, .xmm0) else em.subss(.xmm1, .xmm0);
                                em.movssStore(.rbx, arm32VfpSOff(d.rd), .xmm1);
                            },
                            else => unreachable,
                        }
                        em.jmpLabel(done_vfp);
                        emitSlowVfpCall(&em, slow_vfp, done_vfp, pc_page_off, raw, abort_epilogue_label);
                    },

                    .vcmp_f64_al, .vcmpz_f64_al => {
                        const slow_vfp = em.newLabel();
                        const done_vfp = em.newLabel();
                        const nan_lbl = em.newLabel();
                        const eq_lbl = em.newLabel();
                        const lt_lbl = em.newLabel();
                        const set_lbl = em.newLabel();
                        emitVfpReadyCheck(&em, slow_vfp);
                        em.movsdLoad(.xmm0, .rbx, arm32VfpDOff(d.rd));
                        if (op == .vcmpz_f64_al) {
                            em.pxor(.xmm1, .xmm1);
                        } else {
                            em.movsdLoad(.xmm1, .rbx, arm32VfpDOff(d.rm));
                        }
                        em.ucomisd(.xmm0, .xmm1);
                        em.jccLabel(.p, nan_lbl);
                        em.jccLabel(.e, eq_lbl);
                        em.jccLabel(.b, lt_lbl);
                        em.movImm32(.rax, 0x2000_0000);
                        em.jmpLabel(set_lbl);
                        em.bindLabel(nan_lbl);
                        em.movImm32(.rax, 0x3000_0000);
                        em.jmpLabel(set_lbl);
                        em.bindLabel(eq_lbl);
                        em.movImm32(.rax, 0x6000_0000);
                        em.jmpLabel(set_lbl);
                        em.bindLabel(lt_lbl);
                        em.movImm32(.rax, 0x8000_0000);
                        em.bindLabel(set_lbl);
                        em.movRegMem(false, .rcx, .rbx, off_vfp_fpscr);
                        em.andRegImm(false, .rcx, 0x0fff_ffff);
                        em.orRegReg(false, .rcx, .rax);
                        em.movMemReg(false, .rbx, off_vfp_fpscr, .rcx);
                        em.jmpLabel(done_vfp);
                        emitSlowVfpCall(&em, slow_vfp, done_vfp, pc_page_off, raw, abort_epilogue_label);
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
            emitSpillPinned32(&em);
            em.bindLabel(abort_epilogue_label);
            em.emitEpilogue();

            if (!em.resolveFixups()) return null;
            return buf.allocCode(core_id, em.buf[0..em.len]);
        }
    };
}

// ============================================================================
// Thumb 16-bit Hot-Loop JIT Backend
// ============================================================================

pub fn ThumbJit(comptime CpuType: type, comptime Bus: type) type {
    const ThumbSlot = arm1176_mod.ThumbSlot;
    const Arm32 = Arm32Jit(CpuType, Bus);
    const off_r: i32 = @intCast(@offsetOf(CpuType, "r"));
    const off_r15: i32 = off_r + 15 * 4;
    const off_cpsr: i32 = @intCast(@offsetOf(CpuType, "cpsr"));

    return struct {
        inline fn thumbRegOff(reg: u8) i32 {
            return off_r + @as(i32, reg & 0xf) * 4;
        }

        fn emitReloadPinnedThumb(em: *X64Emitter) void {
            for (0..em.pins.count) |i| {
                const r = em.pins.guest_regs[i] & 0xf;
                em.movRegMem(false, host_pin_regs[i], .rbx, thumbRegOff(r));
            }
        }

        fn emitSpillPinnedThumb(em: *X64Emitter) void {
            for (0..em.pins.count) |i| {
                const r = em.pins.guest_regs[i] & 0xf;
                em.movMemReg(false, .rbx, thumbRegOff(r), host_pin_regs[i]);
            }
        }

        fn emitLoadThumbReg(em: *X64Emitter, dst: Reg, reg: u8, pc_page_off: u32) void {
            const r = reg & 0xf;
            if (em.pins.getHost(r)) |hreg| {
                if (dst != hreg) em.movRegReg(false, dst, hreg);
                return;
            }
            em.movRegMem(false, dst, .rbx, thumbRegOff(r));
            if (r == 15) {
                em.addRegImm(false, dst, @intCast(pc_page_off + 4));
            }
        }

        fn emitStoreThumbReg(em: *X64Emitter, reg: u8, src: Reg) void {
            const r = reg & 0xf;
            if (em.pins.getHost(r)) |hreg| {
                if (hreg != src) em.movRegReg(false, hreg, src);
                return;
            }
            em.movMemReg(false, .rbx, thumbRegOff(r), src);
        }

        fn emitSetPcInterworkingThumbAndExit(em: *X64Emitter, epilogue_label: u16) void {
            const arm_label = em.newLabel();
            em.testRegImm32(false, .rax, 1);
            em.jccLabel(.e, arm_label);
            em.andRegImm(false, .rax, -2);
            em.movMemReg(false, .rbx, off_r15, .rax);
            em.jmpLabel(epilogue_label);
            em.bindLabel(arm_label);
            em.andRegImm(false, .rax, -4);
            em.movMemReg(false, .rbx, off_r15, .rax);
            em.movRegMem(false, .rcx, .rbx, off_cpsr);
            em.andRegImm(false, .rcx, ~@as(i32, 1 << 5));
            em.movMemReg(false, .rbx, off_cpsr, .rcx);
            em.jmpLabel(epilogue_label);
        }

        pub fn canCompileSlot(td: ThumbSlot) bool {
            return switch (td.op) {
                .nop,
                .lsl_imm,
                .lsr_imm,
                .asr_imm,
                .add_reg3,
                .sub_reg3,
                .add_imm3,
                .sub_imm3,
                .mov_imm8,
                .cmp_imm8,
                .add_imm8,
                .sub_imm8,
                .alu_and,
                .alu_eor,
                .alu_tst,
                .alu_neg,
                .alu_cmp,
                .alu_cmn,
                .alu_orr,
                .alu_mul,
                .alu_bic,
                .alu_mvn,
                .hi_cmp,
                .bx,
                .ldr_lit,
                .ldr_imm,
                .str_imm,
                .ldrb_imm,
                .strb_imm,
                .ldrh_imm,
                .strh_imm,
                .ldr_reg,
                .str_reg,
                .ldrb_reg,
                .strb_reg,
                .ldrh_reg,
                .strh_reg,
                .ldrsb_reg,
                .ldrsh_reg,
                .ldr_sp,
                .str_sp,
                .add_pc,
                .add_sp_rd,
                .add_sp_imm,
                .sub_sp_imm,
                .sxth,
                .sxtb,
                .uxth,
                .uxtb,
                .rev,
                .rev16,
                .revsh,
                .b_cond,
                .b_uncond,
                => true,
                .hi_add, .hi_mov => td.rd != 15,
                else => false,
            };
        }

        fn selectPinnedRegsThumb(decoded: []const ThumbSlot) RegPinSet {
            var counts: [15]u16 = @splat(0);
            const bump = struct {
                inline fn add(c: *[15]u16, r: u8) void {
                    const idx = r & 0xf;
                    if (idx < 15) c[idx] +|= 1;
                }
            }.add;
            for (decoded) |td| {
                switch (td.op) {
                    .nop, .b_cond, .b_uncond => {},
                    .bx => bump(&counts, td.rm),
                    .mov_imm8, .cmp_imm8, .ldr_lit, .add_pc => bump(&counts, td.rd),
                    .add_imm8, .sub_imm8 => {
                        bump(&counts, td.rd);
                        bump(&counts, td.rd);
                    },
                    .add_sp_imm, .sub_sp_imm => {
                        bump(&counts, 13);
                        bump(&counts, 13);
                    },
                    .ldr_sp, .str_sp, .add_sp_rd => {
                        bump(&counts, td.rd);
                        bump(&counts, 13);
                    },
                    .lsl_imm, .lsr_imm, .asr_imm, .alu_neg, .alu_mvn, .hi_mov, .sxth, .sxtb, .uxth, .uxtb, .rev, .rev16, .revsh => {
                        bump(&counts, td.rd);
                        bump(&counts, td.rm);
                    },
                    .alu_tst, .alu_cmp, .alu_cmn, .hi_cmp => {
                        bump(&counts, td.rd);
                        bump(&counts, td.rm);
                    },
                    .alu_and, .alu_eor, .alu_orr, .alu_mul, .alu_bic, .hi_add => {
                        bump(&counts, td.rd);
                        bump(&counts, td.rd);
                        bump(&counts, td.rm);
                    },
                    .add_imm3, .sub_imm3, .ldr_imm, .str_imm, .ldrb_imm, .strb_imm, .ldrh_imm, .strh_imm => {
                        bump(&counts, td.rd);
                        bump(&counts, td.rn);
                    },
                    .add_reg3, .sub_reg3, .ldr_reg, .str_reg, .ldrb_reg, .strb_reg, .ldrh_reg, .strh_reg, .ldrsb_reg, .ldrsh_reg => {
                        bump(&counts, td.rd);
                        bump(&counts, td.rn);
                        bump(&counts, td.rm);
                    },
                    else => {},
                }
            }
            var pins = RegPinSet{};
            while (pins.count < 5) {
                var best_r: u8 = 0xff;
                var best_c: u16 = 1;
                for (0..15) |r| {
                    if (counts[r] > best_c) {
                        best_c = counts[r];
                        best_r = @intCast(r);
                    }
                }
                if (best_r == 0xff) break;
                pins.guest_regs[pins.count] = best_r;
                pins.count += 1;
                counts[best_r] = 0;
            }
            return pins;
        }

        pub fn compileTrace(
            buf: *JitCodeBuffer,
            core_id: u2,
            code_page_ptr: [*]const u8,
            start_hw: u11,
            requested_end_hw: u16,
            out_end_hw: *u16,
        ) ?JitFn {
            if (!is_x86_64_linux) return null;
            if (requested_end_hw <= start_hw + 1 or requested_end_hw - start_hw > 64 or requested_end_hw > 2048) return null;

            const trace_len: u16 = requested_end_hw - start_hw;
            var decoded: [64]ThumbSlot = undefined;
            for (0..trace_len) |i| {
                const hw = start_hw + @as(u16, @intCast(i));
                const raw16 = std.mem.readInt(u16, code_page_ptr[@as(usize, hw) * 2 ..][0..2], .little);
                // Reject 32-bit Thumb-2 prefixes inside 16-bit Thumb hot-loop traces
                if ((raw16 & 0xf800) == 0xe800 or (raw16 & 0xf000) == 0xf000) return null;
                const td = arm1176_mod.decodeThumb16(raw16, null);
                if (!canCompileSlot(td)) return null;
                decoded[i] = td;
            }

            const end_hw: u16 = start_hw + trace_len;
            out_end_hw.* = end_hw;

            var em = X64Emitter{
                .pins = selectPinnedRegsThumb(decoded[0..trace_len]),
            };
            em.emitPrologue();
            emitReloadPinnedThumb(&em);

            const epilogue_label = em.newLabel();
            const abort_epilogue_label = em.newLabel();
            var inst_labels: [64]u16 = undefined;
            for (0..trace_len) |i| {
                inst_labels[i] = em.newLabel();
            }

            var exit_stubs: [128]ExitStub = undefined;
            var exit_stub_count: usize = 0;

            for (0..trace_len) |idx| {
                const hw: u16 = start_hw + @as(u16, @intCast(idx));
                const pc_page_off: u32 = @as(u32, hw) * 2;
                const td = decoded[idx];
                const op = td.op;

                em.bindLabel(inst_labels[idx]);
                em.addRegImm(true, .r15, 1);

                switch (op) {
                    .nop => {},
                    .lsl_imm, .lsr_imm, .asr_imm => {
                        const sh: u6 = @truncate(td.imm & 0x1f);
                        emitLoadThumbReg(&em, .rax, td.rm, pc_page_off);
                        if (sh == 0) {
                            switch (op) {
                                .lsl_imm => {
                                    em.testRegReg(false, .rax, .rax);
                                    emitStoreThumbReg(&em, td.rd, .rax);
                                    emitUpdateNZ_Logic(&em, off_cpsr, true);
                                },
                                .lsr_imm => {
                                    em.shrImm(false, .rax, 31);
                                    em.shlImm(false, .rax, 29);
                                    em.orRegImm(false, .rax, 1 << 30);
                                    em.movRegMem(false, .rcx, .rbx, off_cpsr);
                                    em.andRegImm(false, .rcx, 0x1fff_ffff);
                                    em.orRegReg(false, .rcx, .rax);
                                    em.movMemReg(false, .rbx, off_cpsr, .rcx);
                                    em.xorRegReg(false, .rax, .rax);
                                    emitStoreThumbReg(&em, td.rd, .rax);
                                },
                                .asr_imm => {
                                    em.sarImm(false, .rax, 31);
                                    emitStoreThumbReg(&em, td.rd, .rax);
                                    em.andRegImm(false, .rax, @bitCast(@as(u32, 0xa000_0000)));
                                    em.setcc(.e, .rcx);
                                    em.movzx8(false, .rcx, .rcx);
                                    em.shlImm(false, .rcx, 30);
                                    em.orRegReg(false, .rax, .rcx);
                                    em.movRegMem(false, .rcx, .rbx, off_cpsr);
                                    em.andRegImm(false, .rcx, 0x1fff_ffff);
                                    em.orRegReg(false, .rcx, .rax);
                                    em.movMemReg(false, .rbx, off_cpsr, .rcx);
                                },
                                else => unreachable,
                            }
                        } else {
                            switch (op) {
                                .lsl_imm => em.shlImm(false, .rax, sh),
                                .lsr_imm => em.shrImm(false, .rax, sh),
                                .asr_imm => em.sarImm(false, .rax, sh),
                                else => unreachable,
                            }
                            emitStoreThumbReg(&em, td.rd, .rax);
                            em.setcc(.b, .rdx);
                            em.setcc(.e, .rcx);
                            em.movzx8(false, .rdx, .rdx);
                            em.movzx8(false, .rcx, .rcx);
                            em.shlImm(false, .rdx, 29);
                            em.shlImm(false, .rcx, 30);
                            em.andRegImm(false, .rax, @bitCast(@as(u32, 0x8000_0000)));
                            em.orRegReg(false, .rax, .rcx);
                            em.orRegReg(false, .rax, .rdx);
                            em.movRegMem(false, .rcx, .rbx, off_cpsr);
                            em.andRegImm(false, .rcx, 0x1fff_ffff);
                            em.orRegReg(false, .rcx, .rax);
                            em.movMemReg(false, .rbx, off_cpsr, .rcx);
                        }
                    },

                    .add_reg3, .sub_reg3 => {
                        const is_sub = op == .sub_reg3;
                        emitLoadThumbReg(&em, .rax, td.rn, pc_page_off);
                        emitLoadThumbReg(&em, .rcx, td.rm, pc_page_off);
                        if (is_sub) em.subRegReg(false, .rax, .rcx) else em.addRegReg(false, .rax, .rcx);
                        emitStoreThumbReg(&em, td.rd, .rax);
                        emitUpdateNZCV_AddSub(&em, off_cpsr, is_sub);
                    },

                    .add_imm3, .sub_imm3 => {
                        const is_sub = op == .sub_imm3;
                        emitLoadThumbReg(&em, .rax, td.rn, pc_page_off);
                        if (is_sub) em.subRegImm(false, .rax, @intCast(td.imm)) else em.addRegImm(false, .rax, @intCast(td.imm));
                        emitStoreThumbReg(&em, td.rd, .rax);
                        emitUpdateNZCV_AddSub(&em, off_cpsr, is_sub);
                    },

                    .mov_imm8 => {
                        em.movImm32(.rax, td.imm);
                        em.testRegReg(false, .rax, .rax);
                        emitStoreThumbReg(&em, td.rd, .rax);
                        emitUpdateNZ_Logic(&em, off_cpsr, true);
                    },

                    .cmp_imm8 => {
                        emitLoadThumbReg(&em, .rax, td.rd, pc_page_off);
                        em.subRegImm(false, .rax, @intCast(td.imm));
                        emitUpdateNZCV_AddSub(&em, off_cpsr, true);
                    },

                    .add_imm8, .sub_imm8 => {
                        const is_sub = op == .sub_imm8;
                        emitLoadThumbReg(&em, .rax, td.rd, pc_page_off);
                        if (is_sub) em.subRegImm(false, .rax, @intCast(td.imm)) else em.addRegImm(false, .rax, @intCast(td.imm));
                        emitStoreThumbReg(&em, td.rd, .rax);
                        emitUpdateNZCV_AddSub(&em, off_cpsr, is_sub);
                    },

                    .alu_and, .alu_eor, .alu_orr, .alu_bic, .alu_mul => {
                        emitLoadThumbReg(&em, .rax, td.rd, pc_page_off);
                        emitLoadThumbReg(&em, .rcx, td.rm, pc_page_off);
                        switch (op) {
                            .alu_and => em.andRegReg(false, .rax, .rcx),
                            .alu_eor => em.xorRegReg(false, .rax, .rcx),
                            .alu_orr => em.orRegReg(false, .rax, .rcx),
                            .alu_bic => {
                                em.notReg(false, .rcx);
                                em.andRegReg(false, .rax, .rcx);
                            },
                            .alu_mul => {
                                em.imulRegReg(false, .rax, .rcx);
                                em.testRegReg(false, .rax, .rax);
                            },
                            else => unreachable,
                        }
                        emitStoreThumbReg(&em, td.rd, .rax);
                        emitUpdateNZ_Logic(&em, off_cpsr, true);
                    },

                    .alu_mvn => {
                        emitLoadThumbReg(&em, .rax, td.rm, pc_page_off);
                        em.notReg(false, .rax);
                        em.testRegReg(false, .rax, .rax);
                        emitStoreThumbReg(&em, td.rd, .rax);
                        emitUpdateNZ_Logic(&em, off_cpsr, true);
                    },

                    .alu_tst => {
                        emitLoadThumbReg(&em, .rax, td.rd, pc_page_off);
                        emitLoadThumbReg(&em, .rcx, td.rm, pc_page_off);
                        em.andRegReg(false, .rax, .rcx);
                        emitUpdateNZ_Logic(&em, off_cpsr, true);
                    },

                    .alu_neg => {
                        em.xorRegReg(false, .rax, .rax);
                        emitLoadThumbReg(&em, .rcx, td.rm, pc_page_off);
                        em.subRegReg(false, .rax, .rcx);
                        emitStoreThumbReg(&em, td.rd, .rax);
                        emitUpdateNZCV_AddSub(&em, off_cpsr, true);
                    },

                    .alu_cmp, .alu_cmn, .hi_cmp => {
                        const is_sub = op != .alu_cmn;
                        emitLoadThumbReg(&em, .rax, td.rd, pc_page_off);
                        emitLoadThumbReg(&em, .rcx, td.rm, pc_page_off);
                        if (is_sub) em.subRegReg(false, .rax, .rcx) else em.addRegReg(false, .rax, .rcx);
                        emitUpdateNZCV_AddSub(&em, off_cpsr, is_sub);
                    },

                    .hi_add => {
                        emitLoadThumbReg(&em, .rax, td.rd, pc_page_off);
                        emitLoadThumbReg(&em, .rcx, td.rm, pc_page_off);
                        em.addRegReg(false, .rax, .rcx);
                        emitStoreThumbReg(&em, td.rd, .rax);
                    },

                    .hi_mov => {
                        emitLoadThumbReg(&em, .rax, td.rm, pc_page_off);
                        emitStoreThumbReg(&em, td.rd, .rax);
                    },

                    .bx => {
                        emitLoadThumbReg(&em, .rax, td.rm, pc_page_off);
                        emitSetPcInterworkingThumbAndExit(&em, epilogue_label);
                    },

                    .add_pc => {
                        em.movRegMem(false, .rax, .rbx, off_r15);
                        const aligned_off: u32 = ((pc_page_off + 4) & ~@as(u32, 3)) + td.imm;
                        if (aligned_off != 0) em.addRegImm(false, .rax, @intCast(aligned_off));
                        emitStoreThumbReg(&em, td.rd, .rax);
                    },

                    .add_sp_rd => {
                        emitLoadThumbReg(&em, .rax, 13, pc_page_off);
                        if (td.imm != 0) em.addRegImm(false, .rax, @intCast(td.imm));
                        emitStoreThumbReg(&em, td.rd, .rax);
                    },

                    .add_sp_imm, .sub_sp_imm => {
                        emitLoadThumbReg(&em, .rax, 13, pc_page_off);
                        if (td.imm != 0) {
                            if (op == .sub_sp_imm) em.subRegImm(false, .rax, @intCast(td.imm)) else em.addRegImm(false, .rax, @intCast(td.imm));
                        }
                        emitStoreThumbReg(&em, 13, .rax);
                    },

                    .sxth, .sxtb, .uxth, .uxtb => {
                        emitLoadThumbReg(&em, .rax, td.rm, pc_page_off);
                        switch (op) {
                            .sxth => em.movsx16(false, .rax, .rax),
                            .sxtb => em.movsx8(false, .rax, .rax),
                            .uxth => em.movzx16(false, .rax, .rax),
                            .uxtb => em.movzx8(false, .rax, .rax),
                            else => unreachable,
                        }
                        emitStoreThumbReg(&em, td.rd, .rax);
                    },

                    .rev, .rev16, .revsh => {
                        emitLoadThumbReg(&em, .rax, td.rm, pc_page_off);
                        em.bswap(false, .rax);
                        if (op == .rev16) {
                            em.rorImm(false, .rax, 16);
                        } else if (op == .revsh) {
                            em.sarImm(false, .rax, 16);
                        }
                        emitStoreThumbReg(&em, td.rd, .rax);
                    },

                    .ldr_lit, .ldr_imm, .str_imm, .ldrb_imm, .strb_imm, .ldrh_imm, .strh_imm, .ldr_reg, .str_reg, .ldrb_reg, .strb_reg, .ldrh_reg, .strh_reg, .ldrsb_reg, .ldrsh_reg, .ldr_sp, .str_sp => {
                        const is_load = switch (op) {
                            .str_imm, .strb_imm, .strh_imm, .str_reg, .strb_reg, .strh_reg, .str_sp => false,
                            else => true,
                        };
                        const size: u32 = switch (op) {
                            .ldr_lit, .ldr_imm, .str_imm, .ldr_reg, .str_reg, .ldr_sp, .str_sp => 4,
                            .ldrh_imm, .strh_imm, .ldrh_reg, .strh_reg, .ldrsh_reg => 2,
                            .ldrb_imm, .strb_imm, .ldrb_reg, .strb_reg, .ldrsb_reg => 1,
                            else => unreachable,
                        };
                        const is_signed = op == .ldrsb_reg or op == .ldrsh_reg;
                        const is_reg_off = switch (op) {
                            .ldr_reg, .str_reg, .ldrb_reg, .strb_reg, .ldrh_reg, .strh_reg, .ldrsb_reg, .ldrsh_reg => true,
                            else => false,
                        };

                        if (op == .ldr_lit) {
                            em.movRegMem(false, .rdi, .rbx, off_r15);
                            const aligned_off: u32 = ((pc_page_off + 4) & ~@as(u32, 3)) + td.imm;
                            if (aligned_off != 0) em.addRegImm(false, .rdi, @intCast(aligned_off));
                        } else if (is_reg_off) {
                            emitLoadThumbReg(&em, .rdi, td.rn, pc_page_off);
                            emitLoadThumbReg(&em, .rcx, td.rm, pc_page_off);
                            em.addRegReg(false, .rdi, .rcx);
                        } else {
                            const base_r: u8 = if (op == .ldr_sp or op == .str_sp) 13 else td.rn;
                            emitLoadThumbReg(&em, .rdi, base_r, pc_page_off);
                            if (td.imm != 0) em.addRegImm(false, .rdi, @intCast(td.imm));
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
                            emitStoreThumbReg(&em, td.rd, .rax);
                        } else {
                            emitLoadThumbReg(&em, .rcx, td.rd, pc_page_off);
                            switch (size) {
                                4 => em.movSibReg(false, .r13, .rax, 0, 0, .rcx),
                                2 => em.movSib16Reg(.r13, .rax, 0, 0, .rcx),
                                1 => em.movSib8Reg(.r13, .rax, 0, 0, .rcx),
                                else => unreachable,
                            }
                        }
                        em.jmpLabel(done_label);

                        em.bindLabel(slow_label);
                        emitSpillPinnedThumb(&em);
                        if (is_load) {
                            em.movRegReg(false, .rdx, .rdi);
                            em.movRegReg(true, .rdi, .rbx);
                            em.movRegReg(true, .rsi, .r12);
                            em.movImm32(.rcx, pc_page_off);
                            em.movImm32(.r8, size);
                            em.movImm64(.r11, @intFromPtr(&Arm32.jitSlowLoad32));
                            em.callReg(.r11);

                            em.cmpRegImm(true, .rdx, 1);
                            em.jccLabel(.e, abort_epilogue_label);
                            emitReloadPinnedThumb(&em);
                            if (is_signed) {
                                if (size == 2) em.movsx16(false, .rax, .rax) else em.movsx8(false, .rax, .rax);
                            }
                            emitStoreThumbReg(&em, td.rd, .rax);
                        } else {
                            em.movRegReg(false, .rdx, .rdi);
                            emitLoadThumbReg(&em, .rcx, td.rd, pc_page_off);
                            em.movRegReg(true, .rdi, .rbx);
                            em.movRegReg(true, .rsi, .r12);
                            em.movImm32(.r8, pc_page_off);
                            em.movImm32(.r9, size);
                            em.movImm64(.r11, @intFromPtr(&Arm32.jitSlowStore32));
                            em.callReg(.r11);

                            em.testRegReg(true, .rax, .rax);
                            em.jccLabel(.ne, abort_epilogue_label);
                            emitReloadPinnedThumb(&em);
                        }

                        em.bindLabel(done_label);
                    },

                    .b_uncond, .b_cond => {
                        const off_i32: i32 = @as(i16, @bitCast(td.imm));
                        const target_delta: i32 = @as(i32, @intCast(pc_page_off + 4)) + off_i32;
                        const target_hw_i32 = @divExact(target_delta, 2);
                        const in_trace = target_hw_i32 >= @as(i32, start_hw) and target_hw_i32 < @as(i32, end_hw);

                        if (op == .b_uncond) {
                            if (in_trace) {
                                const target_hw: u16 = @intCast(target_hw_i32);
                                const target_idx = target_hw - start_hw;
                                if (target_hw > hw) {
                                    em.jmpLabel(inst_labels[target_idx]);
                                } else {
                                    const rem: i32 = @intCast(end_hw - target_hw);
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
                            emitArmCondBranch(&em, off_cpsr, @intCast(td.rd & 0xf), false, not_taken);
                            if (in_trace) {
                                const target_hw: u16 = @intCast(target_hw_i32);
                                const target_idx = target_hw - start_hw;
                                if (target_hw > hw) {
                                    em.jmpLabel(inst_labels[target_idx]);
                                } else {
                                    const rem: i32 = @intCast(end_hw - target_hw);
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
                    },

                    else => unreachable,
                }
            }

            const last_op = decoded[trace_len - 1].op;
            if (last_op != .b_uncond and last_op != .bx) {
                em.addMemImm32(false, .rbx, off_r15, @intCast(@as(u32, end_hw) * 2));
                em.jmpLabel(epilogue_label);
            }

            for (exit_stubs[0..exit_stub_count]) |stub| {
                em.bindLabel(stub.label);
                em.addMemImm32(false, .rbx, off_r15, stub.pc_delta);
                em.jmpLabel(epilogue_label);
            }

            em.bindLabel(epilogue_label);
            emitSpillPinnedThumb(&em);
            em.bindLabel(abort_epilogue_label);
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



