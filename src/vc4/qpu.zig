//! Instruction encoding and decoding for the VideoCore IV QPU (the shader processor in the
//! BCM2835 V3D block).

const std = @import("std");

pub const Inst = u64;

pub const Sig = enum(u4) {
    breakpoint = 0,
    none = 1,
    thread_switch = 2,
    prog_end = 3,
    wait_scoreboard = 4,
    scoreboard_unlock = 5,
    last_thread_switch = 6,
    coverage_load = 7,
    color_load = 8,
    color_load_end = 9,
    load_tmu0 = 10,
    load_tmu1 = 11,
    alpha_mask_load = 12,
    small_imm = 13,
    load_imm = 14,
    branch = 15,
};

pub const AddOp = enum(u5) {
    nop = 0,
    fadd = 1,
    fsub = 2,
    fmin = 3,
    fmax = 4,
    fminabs = 5,
    fmaxabs = 6,
    ftoi = 7,
    itof = 8,
    add = 12,
    sub = 13,
    shr = 14,
    asr = 15,
    ror = 16,
    shl = 17,
    min = 18,
    max = 19,
    @"and" = 20,
    @"or" = 21,
    xor = 22,
    not = 23,
    clz = 24,
    v8adds = 30,
    v8subs = 31,
    _,
};

pub const MulOp = enum(u3) {
    nop = 0,
    fmul = 1,
    mul24 = 2,
    v8muld = 3,
    v8min = 4,
    v8max = 5,
    v8adds = 6,
    v8subs = 7,
};

pub const Cond = enum(u3) {
    never = 0,
    always = 1,
    zs = 2,
    zc = 3,
    ns = 4,
    nc = 5,
    cs = 6,
    cc = 7,
};

pub const Mux = enum(u3) { r0, r1, r2, r3, r4, r5, a, b };

pub const R = struct {
    pub const frag_payload_zw = 15;
    pub const unif = 32;
    pub const vary = 35;
    pub const elem_qpu = 38;
    pub const nop = 39;
    pub const xy_pixel_coord = 41;
    pub const ms_rev_flags = 42;
    pub const vpm = 48;
    pub const vpm_ld_busy = 49;
    pub const vpm_ld_wait = 50;
    pub const mutex_acquire = 51;
};

pub const W = struct {
    pub const acc0 = 32;
    pub const tmu_noswap = 36;
    pub const acc5 = 37;
    pub const host_int = 38;
    pub const nop = 39;
    pub const uniforms_address = 40;
    pub const quad_xy = 41;
    pub const ms_flags = 42;
    pub const tlb_stencil_setup = 43;
    pub const tlb_z = 44;
    pub const tlb_color_ms = 45;
    pub const tlb_color_all = 46;
    pub const tlb_alpha_mask = 47;
    pub const vpm = 48;
    pub const vpmvcd_setup = 49;
    pub const vpm_addr = 50;
    pub const mutex_release = 51;
    pub const sfu_recip = 52;
    pub const sfu_recipsqrt = 53;
    pub const sfu_exp = 54;
    pub const sfu_log = 55;
    pub const tmu0_s = 56;
    pub const tmu0_t = 57;
    pub const tmu0_r = 58;
    pub const tmu0_b = 59;
    pub const tmu1_s = 60;
    pub const tmu1_t = 61;
    pub const tmu1_r = 62;
    pub const tmu1_b = 63;
};

pub const PackA = enum(u4) {
    none = 0,
    @"16a" = 1,
    @"16b" = 2,
    @"8888" = 3,
    @"8a" = 4,
    @"8b" = 5,
    @"8c" = 6,
    @"8d" = 7,
    @"32_sat" = 8,
    @"16a_sat" = 9,
    @"16b_sat" = 10,
    @"8888_sat" = 11,
    @"8a_sat" = 12,
    @"8b_sat" = 13,
    @"8c_sat" = 14,
    @"8d_sat" = 15,
};

pub const PackMul = enum(u4) {
    none = 0,
    @"8888" = 3,
    @"8a" = 4,
    @"8b" = 5,
    @"8c" = 6,
    @"8d" = 7,
};

pub const Pack = union(enum) {
    none,
    regfile_a: PackA,
    mul: PackMul,
};

pub const UnpackMode = enum(u3) {
    none = 0,
    @"16a" = 1,
    @"16b" = 2,
    @"8d_rep" = 3,
    @"8a" = 4,
    @"8b" = 5,
    @"8c" = 6,
    @"8d" = 7,
};

pub const Unpack = union(enum) {
    none,
    regfile_a: UnpackMode,
    r4: UnpackMode,
};

pub const Src = union(enum) {
    acc: u3,
    a: u6,
    b: u6,
    imm: u6,
};

pub const Dst = union(enum) {
    nop,
    acc: u3,
    a: u6,
    b: u6,
    periph: u6,

    fn waddr(d: Dst) u6 {
        return switch (d) {
            .nop => W.nop,
            .acc => |n| W.acc0 + @as(u6, n),
            .a, .b, .periph => |n| n,
        };
    }

    const File = enum { any, a, b };

    fn file(d: Dst) File {
        return switch (d) {
            .nop, .acc, .periph => .any,
            .a => .a,
            .b => .b,
        };
    }
};

pub fn r(n: u3) Src {
    return .{ .acc = n };
}
pub fn ra(n: u6) Src {
    return .{ .a = n };
}
pub fn rb(n: u6) Src {
    return .{ .b = n };
}
pub const unif: Src = .{ .a = R.unif };
pub const vpm_read: Src = .{ .a = R.vpm };
pub const vary: Src = .{ .b = R.vary };
pub const frag_w: Src = .{ .a = R.frag_payload_zw };
pub const frag_z: Src = .{ .b = R.frag_payload_zw };

pub fn wr(n: u3) Dst {
    std.debug.assert(n != 4);
    return .{ .acc = n };
}
pub fn wa(n: u6) Dst {
    return .{ .a = n };
}
pub fn wb(n: u6) Dst {
    return .{ .b = n };
}
pub const vpm_write: Dst = .{ .periph = W.vpm };
pub const vpm_read_setup: Dst = .{ .a = W.vpmvcd_setup };
pub const vpm_write_setup: Dst = .{ .b = W.vpmvcd_setup };
pub const tlb_color_all: Dst = .{ .periph = W.tlb_color_all };
pub const tlb_z: Dst = .{ .periph = W.tlb_z };

pub fn smallImmInt(i: i5) Src {
    return .{ .imm = @as(u5, @bitCast(i)) };
}

pub fn smallImmFloat(comptime f: f32) Src {
    const bits: u32 = @bitCast(f);
    const exp: i32 = @as(i32, @intCast((bits >> 23) & 0xff)) - 127;
    if (bits & 0x807fffff != 0 or exp < -8 or exp > 7)
        @compileError("float is not representable as a QPU small immediate");
    return .{ .imm = if (exp >= 0) @intCast(32 + exp) else @intCast(48 + exp) };
}

pub const AddInst = struct {
    op: AddOp = .nop,
    dst: Dst = .nop,
    a: Src = .{ .acc = 0 },
    b: Src = .{ .acc = 0 },
    cond: Cond = .always,
};

pub const MulInst = struct {
    op: MulOp = .nop,
    dst: Dst = .nop,
    a: Src = .{ .acc = 0 },
    b: Src = .{ .acc = 0 },
    cond: Cond = .always,
};

pub const Alu = struct {
    add: AddInst = .{},
    mul: MulInst = .{},
    sig: Sig = .none,
    sf: bool = false,
    pack: Pack = .none,
    unpack: Unpack = .none,
};

pub const EncodeError = error{
    ReadPortConflict,
    WritePortConflict,
    PackNeedsRegfileA,
    BadSmallImmediate,
    PackUnpackConflict,
};

const Ports = struct {
    raddr_a: ?u6 = null,
    raddr_b: ?u6 = null,
    small_imm: bool = false,

    fn mux(p: *Ports, s: Src) EncodeError!Mux {
        switch (s) {
            .acc => |n| return @fromBackingInt(@intCast(n)),
            .a => |addr| {
                if (p.raddr_a) |cur| if (cur != addr) return error.ReadPortConflict;
                p.raddr_a = addr;
                return .a;
            },
            .b => |addr| {
                if (p.small_imm) return error.ReadPortConflict;
                if (p.raddr_b) |cur| if (cur != addr) return error.ReadPortConflict;
                p.raddr_b = addr;
                return .b;
            },
            .imm => |v| {
                if (p.raddr_b) |cur| if (!p.small_imm or cur != v) return error.ReadPortConflict;
                p.raddr_b = v;
                p.small_imm = true;
                return .b;
            },
        }
    }
};

fn field(v: u64, comptime shift: u6) u64 {
    return v << shift;
}

pub fn alu(i: Alu) EncodeError!Inst {
    var ports: Ports = .{};
    const add_a = try ports.mux(i.add.a);
    const add_b = try ports.mux(i.add.b);
    const mul_a = try ports.mux(i.mul.a);
    const mul_b = try ports.mux(i.mul.b);

    var sig = i.sig;
    if (ports.small_imm) {
        if (sig != .none and sig != .small_imm) return error.BadSmallImmediate;
        sig = .small_imm;
    } else if (sig == .small_imm) return error.BadSmallImmediate;

    const add_file = i.add.dst.file();
    const mul_file = i.mul.dst.file();
    const ws = add_file == .b or mul_file == .a;
    if (ws and (add_file == .a or mul_file == .b)) return error.WritePortConflict;

    var pm = false;
    var pack: u4 = 0;
    switch (i.pack) {
        .none => {},
        .mul => |m| {
            pm = true;
            pack = @backingInt(m);
        },
        .regfile_a => |m| {
            const a_dst = if (ws) i.mul.dst else i.add.dst;
            if (a_dst != .a) return error.PackNeedsRegfileA;
            pack = @backingInt(m);
        },
    }

    var unpack: u3 = 0;
    switch (i.unpack) {
        .none => {},
        .regfile_a => |m| {
            if (pm) return error.PackUnpackConflict;
            unpack = @backingInt(m);
        },
        .r4 => |m| {
            if (i.pack == .regfile_a) return error.PackUnpackConflict;
            pm = true;
            unpack = @backingInt(m);
        },
    }

    const cond_add: Cond = if (i.add.op == .nop) .never else i.add.cond;
    const cond_mul: Cond = if (i.mul.op == .nop) .never else i.mul.cond;

    return field(@backingInt(sig), 60) |
        field(unpack, 57) |
        field(@intFromBool(pm), 56) |
        field(pack, 52) |
        field(@backingInt(cond_add), 49) |
        field(@backingInt(cond_mul), 46) |
        field(@intFromBool(i.sf), 45) |
        field(@intFromBool(ws), 44) |
        field(i.add.dst.waddr(), 38) |
        field(i.mul.dst.waddr(), 32) |
        field(@backingInt(i.mul.op), 29) |
        field(@backingInt(i.add.op), 24) |
        field(ports.raddr_a orelse R.nop, 18) |
        field(ports.raddr_b orelse R.nop, 12) |
        field(@backingInt(add_a), 9) |
        field(@backingInt(add_b), 6) |
        field(@backingInt(mul_a), 3) |
        field(@backingInt(mul_b), 0);
}

pub const LoadImm = struct {
    add_dst: Dst = .nop,
    mul_dst: Dst = .nop,
    value: u32,
};

pub fn loadImm(i: LoadImm) EncodeError!Inst {
    const add_file = i.add_dst.file();
    const mul_file = i.mul_dst.file();
    const ws = add_file == .b or mul_file == .a;
    if (ws and (add_file == .a or mul_file == .b)) return error.WritePortConflict;
    const cond_add: Cond = if (i.add_dst == .nop) .never else .always;
    const cond_mul: Cond = if (i.mul_dst == .nop) .never else .always;
    return field(@backingInt(Sig.load_imm), 60) |
        field(@backingInt(cond_add), 49) |
        field(@backingInt(cond_mul), 46) |
        field(@intFromBool(ws), 44) |
        field(i.add_dst.waddr(), 38) |
        field(i.mul_dst.waddr(), 32) |
        i.value;
}

pub fn nop(sig: Sig) Inst {
    return alu(.{ .sig = sig }) catch unreachable;
}

pub fn mov(dst: Dst, src: Src) EncodeError!Inst {
    return alu(.{ .add = .{ .op = .@"or", .dst = dst, .a = src, .b = src } });
}

pub fn getSig(i: Inst) Sig {
    return @fromBackingInt(@intCast(@as(u4, @truncate(i >> 60))));
}
pub fn getWaddrAdd(i: Inst) u6 {
    return @truncate(i >> 38);
}
pub fn getWaddrMul(i: Inst) u6 {
    return @truncate(i >> 32);
}
pub fn getWs(i: Inst) bool {
    return (i >> 44) & 1 != 0;
}
pub fn getRaddrA(i: Inst) u6 {
    return @truncate(i >> 18);
}
pub fn getRaddrB(i: Inst) u6 {
    return @truncate(i >> 12);
}
pub fn getAddOp(i: Inst) AddOp {
    return @fromBackingInt(@intCast(@as(u5, @truncate(i >> 24))));
}
pub fn getMulOp(i: Inst) MulOp {
    return @fromBackingInt(@intCast(@as(u3, @truncate(i >> 29))));
}
pub fn getMuxAddA(i: Inst) Mux {
    return @fromBackingInt(@intCast(@as(u3, @truncate(i >> 9))));
}
pub fn getMuxAddB(i: Inst) Mux {
    return @fromBackingInt(@intCast(@as(u3, @truncate(i >> 6))));
}
pub fn getMuxMulA(i: Inst) Mux {
    return @fromBackingInt(@intCast(@as(u3, @truncate(i >> 3))));
}
pub fn getMuxMulB(i: Inst) Mux {
    return @fromBackingInt(@intCast(@as(u3, @truncate(i >> 0))));
}

pub const Stage = enum { vertex, coordinate, fragment };

pub fn Program(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        insts: [capacity]Inst = undefined,
        len: usize = 0,

        pub fn emit(p: *Self, i: Inst) void {
            p.insts[p.len] = i;
            p.len += 1;
        }

        pub fn end(p: *Self, stage: Stage) void {
            p.emit(nop(.prog_end));
            p.emit(nop(.none));
            p.emit(nop(if (stage == .fragment) .scoreboard_unlock else .none));
        }

        pub fn code(p: *const Self) []const Inst {
            return p.insts[0..p.len];
        }
    };
}

test "nop matches the canonical encoding" {
    try std.testing.expectEqual(@as(Inst, 0x100009e7_009e7000), nop(.none));
    try std.testing.expectEqual(@as(Inst, 0x300009e7_009e7000), nop(.prog_end));
}
