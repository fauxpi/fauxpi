//! What the V3D feature tests are built with: control lists with every record the VideoCore IV
//! 3D Architecture Reference Guide lists, shader records of each kind (GL, NV and VG), frames
//! drawn into any target the tile buffer can store, waits that give up rather than hang, and
//! checksums of whole buffers. The record layouts are the guide's (section 9).

const std = @import("std");
const qpu = @import("qpu");
const hw = @import("hw.zig");

pub const base = hw.peripherals + 0xc0_0000;

/// V3D's registers (the guide's table 48).
pub const reg = struct {
    pub const ident0 = base + 0x000;
    pub const ident1 = base + 0x004;
    pub const ident2 = base + 0x008;
    pub const scratch = base + 0x010;
    pub const l2cactl = base + 0x020;
    pub const slcactl = base + 0x024;
    pub const intctl = base + 0x030;
    pub const intena = base + 0x034;
    pub const intdis = base + 0x038;
    pub const ct0cs = base + 0x100;
    pub const ct1cs = base + 0x104;
    pub const ct0ea = base + 0x108;
    pub const ct1ea = base + 0x10c;
    pub const ct0ca = base + 0x110;
    pub const ct1ca = base + 0x114;
    pub const ct0ra0 = base + 0x118;
    pub const ct1ra0 = base + 0x11c;
    pub const ct0lc = base + 0x120;
    pub const ct1lc = base + 0x124;
    pub const ct0pc = base + 0x128;
    pub const ct1pc = base + 0x12c;
    pub const pcs = base + 0x130;
    pub const bfc = base + 0x134;
    pub const rfc = base + 0x138;
    pub const bpca = base + 0x300;
    pub const bpcs = base + 0x304;
    pub const bpoa = base + 0x308;
    pub const bpos = base + 0x30c;
    pub const bxcf = base + 0x310;
    pub const sqrsv0 = base + 0x410;
    pub const sqrsv1 = base + 0x414;
    pub const sqcntl = base + 0x418;
    pub const srqpc = base + 0x430;
    pub const srqua = base + 0x434;
    pub const srqul = base + 0x438;
    pub const srqcs = base + 0x43c;
    pub const vpacntl = base + 0x500;
    pub const vpmbase = base + 0x504;
    pub const pctrc = base + 0x670;
    pub const pctre = base + 0x674;
    pub fn pctr(n: u32) usize {
        return base + 0x680 + n * 8;
    }
    pub fn pctrs(n: u32) usize {
        return base + 0x684 + n * 8;
    }
    pub const dbqite = base + 0xe2c;
    pub const dbqitc = base + 0xe30;
    pub const dbge = base + 0xf00;
    pub const fdbgo = base + 0xf04;
    pub const fdbgb = base + 0xf08;
    pub const fdbgr = base + 0xf0c;
    pub const fdbgs = base + 0xf10;
    pub const errstat = base + 0xf20;
};

/// The interrupt bits of INTCTL, INTENA and INTDIS.
pub const int_frdone: u32 = 1 << 0;
pub const int_fldone: u32 = 1 << 1;
pub const int_outomem: u32 = 1 << 2;
pub const int_spilluse: u32 = 1 << 3;

/// How long a test waits for V3D before giving up on it (the board's microseconds): long
/// enough for any frame here on the Pi, short enough that a feature FauxPi lacks doesn't stall
/// the run.
pub const timeout_us: u64 = 3_000_000;

/// Waits until `addr`'s low byte isn't `prev`'s (a frame counter moving on), or the time is up:
/// whether it moved.
pub fn waitCount(addr: usize, prev: u32) bool {
    const until = hw.timer.now() + timeout_us;
    while (hw.read(addr) & 0xff == prev & 0xff) {
        if (hw.timer.now() > until) return false;
    }
    return true;
}

/// Stops both control list threads (CTnCS's reset bit), after a frame that didn't finish.
pub fn resetThreads() void {
    hw.write(reg.ct0cs, 1 << 15);
    hw.write(reg.ct1cs, 1 << 15);
}

/// Runs a binning list (`bcl`) then a rendering list (`rcl`), each waited for: false if either
/// didn't finish in time (the threads are then reset).
pub fn run(bcl: ?*const Cl, rcl: ?*const Cl) bool {
    if (bcl) |b| {
        const bins = hw.read(reg.bfc);
        hw.write(reg.ct0ca, b.start());
        hw.write(reg.ct0ea, b.end());
        if (!waitCount(reg.bfc, bins)) {
            resetThreads();
            return false;
        }
    }
    if (rcl) |r| {
        const renders = hw.read(reg.rfc);
        hw.write(reg.ct1ca, r.start());
        hw.write(reg.ct1ea, r.end());
        if (!waitCount(reg.rfc, renders)) {
            resetThreads();
            return false;
        }
    }
    return true;
}

/// A checksum of `bytes` (FNV-1a, a word at a time): all of a buffer, so any difference shows.
pub fn checksum(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    const ws = std.mem.bytesAsSlice(u32, bytes[0 .. bytes.len / 4 * 4]);
    for (ws) |w| h = (h ^ w) *% 0x100000001b3;
    for (bytes[bytes.len / 4 * 4 ..]) |b| h = (h ^ b) *% 0x100000001b3;
    return h;
}

/// Memory the GPU reads or writes: `n` `T`s, aligned, zeroed.
pub fn alloc(comptime T: type, n: usize, alignment: usize) []T {
    const mem = hw.heap.alloc(T, n, alignment);
    @memset(std.mem.sliceAsBytes(mem), 0);
    return mem;
}

/// A shader in memory the QPUs read.
pub fn upload(code: []const qpu.Inst) u32 {
    const mem = alloc(qpu.Inst, code.len, 16);
    @memcpy(mem, code);
    return hw.bus(mem.ptr);
}

/// Words in memory (uniforms, say).
pub fn words(values: []const u32) u32 {
    const mem = alloc(u32, @max(values.len, 1), 16);
    @memcpy(mem[0..values.len], values);
    return hw.bus(mem.ptr);
}

pub fn floatBits(f: f32) u32 {
    return @bitCast(f);
}

/// A control list being written: every record of the guide's table 38.
pub const Cl = struct {
    buf: []u8,
    len: usize = 0,

    pub fn init(size: usize) Cl {
        return .{ .buf = alloc(u8, size, 32) };
    }

    pub fn byte(c: *Cl, v: u8) void {
        c.buf[c.len] = v;
        c.len += 1;
    }
    pub fn half(c: *Cl, v: u16) void {
        std.mem.writeInt(u16, c.buf[c.len..][0..2], v, .little);
        c.len += 2;
    }
    pub fn word(c: *Cl, v: u32) void {
        std.mem.writeInt(u32, c.buf[c.len..][0..4], v, .little);
        c.len += 4;
    }
    pub fn float(c: *Cl, v: f32) void {
        c.word(@bitCast(v));
    }
    pub fn bytes(c: *Cl, v: []const u8) void {
        @memcpy(c.buf[c.len..][0..v.len], v);
        c.len += v.len;
    }
    pub fn start(c: *const Cl) u32 {
        return hw.bus(c.buf.ptr);
    }
    pub fn end(c: *const Cl) u32 {
        return hw.bus(c.buf.ptr) + @as(u32, @intCast(c.len));
    }
    /// Where the next record goes, on the bus.
    pub fn here(c: *const Cl) u32 {
        return c.end();
    }
    pub fn reset(c: *Cl) void {
        c.len = 0;
    }

    // System control (0-18).
    pub fn halt(c: *Cl) void {
        c.byte(0);
    }
    pub fn nop(c: *Cl) void {
        c.byte(1);
    }
    pub fn flush(c: *Cl) void {
        c.byte(4);
    }
    pub fn flushAllState(c: *Cl) void {
        c.byte(5);
    }
    pub fn startTileBinning(c: *Cl) void {
        c.byte(6);
    }
    pub fn incrementSemaphore(c: *Cl) void {
        c.byte(7);
    }
    pub fn waitOnSemaphore(c: *Cl) void {
        c.byte(8);
    }
    pub fn branch(c: *Cl, addr: u32) void {
        c.byte(16);
        c.word(addr);
    }
    pub fn branchToSubList(c: *Cl, addr: u32) void {
        c.byte(17);
        c.word(addr);
    }
    pub fn returnFromSubList(c: *Cl) void {
        c.byte(18);
    }

    // Tile buffer stores and loads (24-29).
    pub fn storeMsResolved(c: *Cl, eof: bool) void {
        c.byte(if (eof) 25 else 24);
    }
    pub const FullRes = packed struct(u4) {
        disable_color: bool = false,
        disable_zs: bool = false,
        /// Store: the tile buffer isn't cleared after (more stores follow).
        disable_clear: bool = false,
        /// Store: the frame's last tile.
        last: bool = false,
    };
    pub fn storeFullRes(c: *Cl, addr: u32, flags: FullRes) void {
        c.byte(26);
        c.word(addr & ~@as(u32, 0xf) | @as(u4, @bitCast(flags)));
    }
    pub fn loadFullRes(c: *Cl, addr: u32, flags: FullRes) void {
        c.byte(27);
        c.word(addr & ~@as(u32, 0xf) | @as(u4, @bitCast(flags)) & 3);
    }
    pub const Buffer = enum(u3) { none = 0, color = 1, zs = 2, z = 3, vg_mask = 4, full = 5 };
    pub const MemFormat = enum(u2) { raster = 0, t = 1, lt = 2 };
    pub const PixelFormat = enum(u2) { rgba8888 = 0, bgr565_dithered = 1, bgr565 = 2 };
    pub const Decimate = enum(u2) { sample0 = 0, x4 = 1, x16 = 2 };
    pub const General = struct {
        buffer: Buffer,
        format: MemFormat = .raster,
        decimate: Decimate = .sample0,
        pixel: PixelFormat = .rgba8888,
        disable_double_buffer_swap: bool = false,
        disable_color_clear: bool = false,
        disable_zs_clear: bool = false,
        disable_vg_clear: bool = false,
        /// Full dump/reload: buffers left out.
        disable_color: bool = false,
        disable_zs: bool = false,
        disable_vg: bool = false,
        last: bool = false,
    };
    fn generalBits(g: General) u16 {
        return @as(u16, @backingInt(g.buffer)) | @as(u16, @backingInt(g.format)) << 4 |
            @as(u16, @backingInt(g.decimate)) << 6 | @as(u16, @backingInt(g.pixel)) << 8 |
            @as(u16, @intFromBool(g.disable_double_buffer_swap)) << 12 |
            @as(u16, @intFromBool(g.disable_color_clear)) << 13 |
            @as(u16, @intFromBool(g.disable_zs_clear)) << 14 |
            @as(u16, @intFromBool(g.disable_vg_clear)) << 15;
    }
    fn generalAddr(g: General, addr: u32) u32 {
        return addr & ~@as(u32, 0xf) | @as(u32, @intFromBool(g.last)) << 3 |
            @as(u32, @intFromBool(g.disable_vg)) << 2 | @as(u32, @intFromBool(g.disable_zs)) << 1 |
            @as(u32, @intFromBool(g.disable_color));
    }
    pub fn storeGeneral(c: *Cl, g: General, addr: u32) void {
        c.byte(28);
        c.half(generalBits(g));
        c.word(generalAddr(g, addr));
    }
    pub fn loadGeneral(c: *Cl, g: General, addr: u32) void {
        c.byte(29);
        c.half(generalBits(g) & 0x3ff);
        c.word(generalAddr(g, addr) & ~@as(u32, 8));
    }

    // Primitive lists (32-49).
    pub const Mode = enum(u4) { points = 0, lines = 1, line_loop = 2, line_strip = 3, triangles = 4, triangle_strip = 5, triangle_fan = 6 };
    pub fn indexed(c: *Cl, mode: Mode, sixteen_bit: bool, count: u32, indices: u32, max_index: u32) void {
        c.byte(32);
        c.byte(@as(u8, @backingInt(mode)) | @as(u8, @intFromBool(sixteen_bit)) << 4);
        c.word(count);
        c.word(indices);
        c.word(max_index);
    }
    pub fn arrays(c: *Cl, mode: Mode, count: u32, first: u32) void {
        c.byte(33);
        c.byte(@backingInt(mode));
        c.word(count);
        c.word(first);
    }
    pub const VgType = enum(u4) { rhts = 1, rht_strip = 3, triangles = 4, triangle_strip = 5, triangle_fan = 6 };
    pub fn vgCoordinateArray(c: *Cl, t: VgType, continuation: bool, count: u32, coords: u32) void {
        c.byte(41);
        c.byte(@as(u8, @backingInt(t)) | @as(u8, @intFromBool(continuation)) << 4);
        c.word(count);
        c.word(coords);
    }
    /// VG inline primitives: `coords` (Xs in the low 16 bits, Ys in the high), escape-terminated
    /// by the caller.
    pub fn vgInline(c: *Cl, t: VgType, continuation: bool, coords: []const u32) void {
        c.byte(42);
        c.byte(@as(u8, @backingInt(t)) | @as(u8, @intFromBool(continuation)) << 4);
        for (coords) |w| c.word(w);
    }
    pub const vg_escape: u32 = 0xbfff0000;
    pub const vg_pad: u32 = 0xbfff0001;
    /// A compressed primitive list (in a tile list): its coded bytes, escape included.
    pub fn compressed(c: *Cl, coded: []const u8) void {
        c.byte(48);
        c.bytes(coded);
    }
    /// A clipped primitive record: the clipped vertices' data at `data` (8-byte aligned), and
    /// which of the next primitive's vertices are clipped; then its compressed list.
    pub fn clippedPrimitive(c: *Cl, data: u32, clipped: u3, coded: []const u8) void {
        c.byte(49);
        c.word(data & ~@as(u32, 7) | clipped);
        c.bytes(coded);
    }
    pub const ListType = enum(u4) { points = 0, lines = 1, triangles = 2, rhts = 3 };
    pub fn primitiveListFormat(c: *Cl, t: ListType, xy: bool) void {
        c.byte(56);
        c.byte(@as(u8, @backingInt(t)) | @as(u8, if (xy) 3 else 1) << 4);
    }

    // Shader state (64-67).
    pub fn glShaderState(c: *Cl, record: u32, num_attrs: u3, extended: bool) void {
        c.byte(64);
        c.word(record | @as(u32, @intFromBool(extended)) << 3 | num_attrs);
    }
    pub fn nvShaderState(c: *Cl, record: u32) void {
        c.byte(65);
        c.word(record);
    }
    pub fn vgShaderState(c: *Cl, record: u32) void {
        c.byte(66);
        c.word(record);
    }
    pub fn vgInlineShaderRecord(c: *Cl, fs_code: u32, fs_unifs: u32, single_threaded: bool) void {
        c.byte(67);
        c.word(fs_code & ~@as(u32, 7) | @intFromBool(single_threaded));
        c.word(fs_unifs);
    }

    // State (96-106).
    pub const Config = packed struct(u24) {
        forward: bool = true,
        reverse: bool = true,
        clockwise: bool = false,
        depth_offset: bool = false,
        antialiased_points_lines: bool = false,
        coverage_read_type: u1 = 0,
        oversample: u2 = 0,
        coverage_pipe: bool = false,
        coverage_update: u2 = 0,
        coverage_read_mode: u1 = 0,
        depth_func: u3 = 7,
        z_updates: bool = false,
        early_z: bool = false,
        early_z_updates: bool = false,
        _unused: u6 = 0,
    };
    pub fn config(c: *Cl, cfg: Config) void {
        c.byte(96);
        const v: u24 = @bitCast(cfg);
        c.byte(@truncate(v));
        c.byte(@truncate(v >> 8));
        c.byte(@truncate(v >> 16));
    }
    pub fn flatShadeFlags(c: *Cl, flags: u32) void {
        c.byte(97);
        c.word(flags);
    }
    pub fn pointSize(c: *Cl, size: f32) void {
        c.byte(98);
        c.float(size);
    }
    pub fn lineWidth(c: *Cl, width: f32) void {
        c.byte(99);
        c.float(width);
    }
    pub fn rhtXBoundary(c: *Cl, x: i16) void {
        c.byte(100);
        c.half(@bitCast(x));
    }
    /// Depth offset: factor and units as float1-8-7 (a float32's top 16 bits).
    pub fn depthOffset(c: *Cl, factor: f32, units: f32) void {
        c.byte(101);
        c.half(@truncate(@as(u32, @bitCast(factor)) >> 16));
        c.half(@truncate(@as(u32, @bitCast(units)) >> 16));
    }
    pub fn clipWindow(c: *Cl, x: u16, y: u16, w: u16, h: u16) void {
        c.byte(102);
        c.half(x);
        c.half(y);
        c.half(w);
        c.half(h);
    }
    /// The viewport's centre, in 16ths of a pixel.
    pub fn viewportOffset(c: *Cl, x16: i16, y16: i16) void {
        c.byte(103);
        c.half(@bitCast(x16));
        c.half(@bitCast(y16));
    }
    pub fn zClippingPlanes(c: *Cl, min: f32, max: f32) void {
        c.byte(104);
        c.float(min);
        c.float(max);
    }
    pub fn clipperXyScaling(c: *Cl, half_w16: f32, half_h16: f32) void {
        c.byte(105);
        c.float(half_w16);
        c.float(half_h16);
    }
    pub fn clipperZScaling(c: *Cl, scale: f32, offset: f32) void {
        c.byte(106);
        c.float(scale);
        c.float(offset);
    }

    // Frame configuration (112-115).
    pub const BinConfig = struct {
        tile_alloc: u32,
        tile_alloc_size: u32,
        tile_state: u32,
        width_tiles: u8,
        height_tiles: u8,
        msaa: bool = false,
        hdr: bool = false,
        auto_init_tile_state: bool = true,
        initial_block_size: u2 = 0,
        block_size: u2 = 0,
        double_buffer: bool = false,
    };
    pub fn binConfig(c: *Cl, b: BinConfig) void {
        c.byte(112);
        c.word(b.tile_alloc);
        c.word(b.tile_alloc_size);
        c.word(b.tile_state);
        c.byte(b.width_tiles);
        c.byte(b.height_tiles);
        c.byte(@as(u8, @intFromBool(b.msaa)) | @as(u8, @intFromBool(b.hdr)) << 1 |
            @as(u8, @intFromBool(b.auto_init_tile_state)) << 2 | @as(u8, b.initial_block_size) << 3 |
            @as(u8, b.block_size) << 5 | @as(u8, @intFromBool(b.double_buffer)) << 7);
    }
    pub const RenderConfig = struct {
        addr: u32,
        width: u16,
        height: u16,
        msaa: bool = false,
        hdr: bool = false,
        /// 0, 1, 2: BGR565 dithered, RGBA8888, BGR565.
        format: u2 = 1,
        decimate: Decimate = .sample0,
        mem_format: MemFormat = .raster,
        vg_mask: bool = false,
        coverage_mode: bool = false,
        early_z_gt: bool = false,
        early_z_disable: bool = false,
        double_buffer: bool = false,
    };
    pub fn renderConfig(c: *Cl, r: RenderConfig) void {
        c.byte(113);
        c.word(r.addr);
        c.half(r.width);
        c.half(r.height);
        c.half(@as(u16, @intFromBool(r.msaa)) | @as(u16, @intFromBool(r.hdr)) << 1 |
            @as(u16, r.format) << 2 | @as(u16, @backingInt(r.decimate)) << 4 |
            @as(u16, @backingInt(r.mem_format)) << 6 | @as(u16, @intFromBool(r.vg_mask)) << 8 |
            @as(u16, @intFromBool(r.coverage_mode)) << 9 | @as(u16, @intFromBool(r.early_z_gt)) << 10 |
            @as(u16, @intFromBool(r.early_z_disable)) << 11 | @as(u16, @intFromBool(r.double_buffer)) << 12);
    }
    pub fn clearColors(c: *Cl, color: u64, zs: u24, vg_mask: u8, stencil: u8) void {
        c.byte(114);
        c.word(@truncate(color));
        c.word(@truncate(color >> 32));
        c.word(@as(u32, zs) | @as(u32, vg_mask) << 24);
        c.byte(stencil);
    }
    pub fn tileCoordinates(c: *Cl, x: u8, y: u8) void {
        c.byte(115);
        c.byte(x);
        c.byte(y);
    }
};

/// A GL shader record (the guide's table 45): the shaders, their uniforms and the attribute
/// arrays. In memory, 16-byte aligned (its address for `Cl.glShaderState`).
pub const GlRecord = struct {
    pub const Attr = struct {
        addr: u32,
        bytes: u8,
        stride: u32,
        vs_offset: u8 = 0,
        cs_offset: u8 = 0,
    };
    single_threaded: bool = true,
    point_size: bool = false,
    clipping: bool = true,
    fs_varyings: u8,
    fs_code: u32,
    fs_unifs: u32,
    vs_attr_mask: u8,
    vs_attr_size: u8,
    vs_code: u32,
    vs_unifs: u32,
    cs_attr_mask: u8,
    cs_attr_size: u8,
    cs_code: u32,
    cs_unifs: u32,
    attrs: []const Attr,
    /// Each attribute's stride as 32 bits (after the arrays): `Cl.glShaderState`'s `extended`.
    extended: bool = false,

    pub fn write(r: GlRecord) u32 {
        const rec = alloc(u8, 36 + 8 * 8 + 32 + 16, 16);
        var c: Cl = .{ .buf = rec };
        c.half(@as(u16, @intFromBool(r.single_threaded)) | @as(u16, @intFromBool(r.point_size)) << 1 | @as(u16, @intFromBool(r.clipping)) << 2);
        c.byte(0);
        c.byte(r.fs_varyings);
        c.word(r.fs_code);
        c.word(r.fs_unifs);
        c.half(0);
        c.byte(r.vs_attr_mask);
        c.byte(r.vs_attr_size);
        c.word(r.vs_code);
        c.word(r.vs_unifs);
        c.half(0);
        c.byte(r.cs_attr_mask);
        c.byte(r.cs_attr_size);
        c.word(r.cs_code);
        c.word(r.cs_unifs);
        for (r.attrs) |a| {
            c.word(a.addr);
            c.byte(a.bytes - 1);
            c.byte(@truncate(a.stride));
            c.byte(a.vs_offset);
            c.byte(a.cs_offset);
        }
        if (r.extended) {
            c.len = 100;
            for (r.attrs) |a| c.word(a.stride);
        }
        return hw.bus(rec.ptr);
    }
};

/// An NV shader record (table 46): pre-shaded vertices, and the fragment shader.
pub const NvRecord = struct {
    single_threaded: bool = true,
    point_size: bool = false,
    clipping: bool = false,
    clip_header: bool = false,
    stride: u8,
    fs_varyings: u8,
    fs_code: u32,
    fs_unifs: u32,
    vertices: u32,

    pub fn write(r: NvRecord) u32 {
        const rec = alloc(u8, 16, 16);
        var c: Cl = .{ .buf = rec };
        c.byte(@as(u8, @intFromBool(r.single_threaded)) | @as(u8, @intFromBool(r.point_size)) << 1 |
            @as(u8, @intFromBool(r.clipping)) << 2 | @as(u8, @intFromBool(r.clip_header)) << 3);
        c.byte(r.stride);
        c.byte(0);
        c.byte(r.fs_varyings);
        c.word(r.fs_code);
        c.word(r.fs_unifs);
        c.word(r.vertices);
        return hw.bus(rec.ptr);
    }
};

/// A VG shader record (table 47): just the fragment shader.
pub fn vgRecord(fs_code: u32, fs_unifs: u32, fs_varyings: u8, single_threaded: bool) u32 {
    const rec = alloc(u8, 16, 16);
    var c: Cl = .{ .buf = rec };
    c.byte(@intFromBool(single_threaded));
    c.byte(0);
    c.byte(0);
    c.byte(fs_varyings);
    c.word(fs_code);
    c.word(fs_unifs);
    return hw.bus(rec.ptr);
}

/// XS and YS packed as a shaded vertex has them: signed 12.4 fixed point, in pixels from the
/// viewport centre.
pub fn packXy(xs: f32, ys: f32) u32 {
    const x: i16 = @intFromFloat(@round(xs * 16));
    const y: i16 = @intFromFloat(@round(ys * 16));
    return @as(u32, @as(u16, @bitCast(x))) | @as(u32, @as(u16, @bitCast(y))) << 16;
}

/// Where frames are drawn: a target, and the memory V3D bins into.
pub const Target = struct {
    width: u32,
    height: u32,
    /// Bytes per pixel as stored (4, or 2 for BGR565; 8 for an HDR full dump).
    cpp: u32 = 4,
    fb: []u8,
    tile_alloc: []u8,
    tile_state: []u8,
    msaa: bool = false,
    hdr: bool = false,
    double_buffer: bool = false,
    /// The binner's tile allocation block sizes (32 << n bytes).
    initial_block_size: u2 = 0,
    block_size: u2 = 0,

    pub fn init(width: u32, height: u32, cpp: u32) Target {
        const max_tiles = ((width + 31) / 32) * ((height + 15) / 16);
        return .{
            .width = width,
            .height = height,
            .cpp = cpp,
            // Room for T-format's padding to 4 KiB tiles.
            .fb = alloc(u8, ((width + 63) / 64 * 64) * ((height + 63) / 64 * 64) * @max(cpp, 4), 4096),
            .tile_alloc = alloc(u8, 32 << 20, 4096),
            .tile_state = alloc(u8, max_tiles * 48, 16),
        };
    }

    /// Tiles' width and height, in pixels: 64 square, halved multisampled, and their height
    /// halved again with a 64-bit (HDR) tile buffer.
    pub fn tileSize(t: *const Target) [2]u32 {
        const w: u32 = if (t.msaa) 32 else 64;
        return .{ w, if (t.hdr) w / 2 else w };
    }

    pub fn tiles(t: *const Target) [2]u32 {
        const s = t.tileSize();
        return .{ (t.width + s[0] - 1) / s[0], (t.height + s[1] - 1) / s[1] };
    }

    /// Starts a binning list into `bcl`: the binning configuration (with the whole tile
    /// allocation memory as the pool), the clip window over the target, the viewport at its
    /// centre and the clipper's scaling to match, then Start Tile Binning.
    pub fn beginBinning(t: *const Target, bcl: *Cl) void {
        const n = t.tiles();
        bcl.binConfig(.{
            .tile_alloc = hw.bus(t.tile_alloc.ptr),
            .tile_alloc_size = @intCast(t.tile_alloc.len),
            .tile_state = hw.bus(t.tile_state.ptr),
            .width_tiles = @intCast(n[0]),
            .height_tiles = @intCast(n[1]),
            .msaa = t.msaa,
            .hdr = t.hdr,
            .double_buffer = t.double_buffer,
            .initial_block_size = t.initial_block_size,
            .block_size = t.block_size,
        });
        bcl.startTileBinning();
        t.viewState(bcl);
    }

    /// The clip window over the target, the viewport at its centre, and the clipper's scaling.
    pub fn viewState(t: *const Target, cl: *Cl) void {
        cl.clipWindow(0, 0, @intCast(t.width), @intCast(t.height));
        cl.viewportOffset(@intCast(t.width * 8), @intCast(t.height * 8));
        cl.clipperXyScaling(@as(f32, @floatFromInt(t.width)) * 8, -@as(f32, @floatFromInt(t.height)) * 8);
        cl.clipperZScaling(0.5, 0.5);
    }

    /// The clip-space-to-pixels scales a vertex shader multiplies x and y by (16ths of a pixel).
    pub fn scales(t: *const Target) [2]u32 {
        return .{ floatBits(@as(f32, @floatFromInt(t.width)) * 8), floatBits(-@as(f32, @floatFromInt(t.height)) * 8) };
    }

    pub const Render = struct {
        clear_color: u64 = 0xff000000_ff000000,
        clear_z: u24 = 0xffffff,
        clear_vg_mask: u8 = 0,
        clear_stencil: u8 = 0,
        config: Cl.RenderConfig,
        /// Each tile's lists: branched to from the rendering list (the binner's, by default).
        tile_lists: ?*const fn (t: *const Target, x: u32, y: u32) u32 = null,
        /// Whether the binner's tile lists are branched to (else just the stores: a clear).
        binned: bool = true,
        /// Whether it waits for the binning first (on the semaphore its flush increments): the
        /// first rendering of what was binned only (another would wait for ever).
        wait: bool = true,
        /// Per tile, before its coordinates (loads) and after its lists (stores other than the
        /// last, which is `store`).
        before: ?*const fn (t: *const Target, cl: *Cl, x: u32, y: u32) void = null,
        after: ?*const fn (t: *const Target, cl: *Cl, x: u32, y: u32, last: bool) void = null,
    };

    /// A rendering list into `rcl` over every tile: clear colours, rendering configuration, then
    /// each tile's (loads), coordinates, lists and store (resolved, and end of frame last).
    pub fn renderList(t: *const Target, rcl: *Cl, r: Render) void {
        rcl.clearColors(r.clear_color, r.clear_z, r.clear_vg_mask, r.clear_stencil);
        rcl.renderConfig(r.config);
        const n = t.tiles();
        if (r.binned and r.wait) rcl.waitOnSemaphore();
        for (0..n[1]) |ty| {
            for (0..n[0]) |tx| {
                const x: u32 = @intCast(tx);
                const y: u32 = @intCast(ty);
                const last = ty + 1 == n[1] and tx + 1 == n[0];
                if (r.before) |f| f(t, rcl, x, y);
                rcl.tileCoordinates(@intCast(x), @intCast(y));
                if (r.tile_lists) |f| {
                    rcl.branchToSubList(f(t, x, y));
                } else if (r.binned) {
                    rcl.branchToSubList(hw.bus(t.tile_alloc.ptr) + (y * n[0] + x) * (@as(u32, 32) << t.initial_block_size));
                }
                if (r.after) |f| f(t, rcl, x, y, last) else rcl.storeMsResolved(last);
            }
        }
    }

    /// The render configuration for this target: stored at its framebuffer, RGBA8888, raster.
    pub fn renderConfig(t: *const Target) Cl.RenderConfig {
        return .{
            .addr = hw.bus(t.fb.ptr),
            .width = @intCast(t.width),
            .height = @intCast(t.height),
            .msaa = t.msaa,
            .hdr = t.hdr,
            .decimate = if (t.msaa) .x4 else .sample0,
            .double_buffer = t.double_buffer,
        };
    }

    pub fn checksum(t: *const Target) u64 {
        return checksumOf(t.fb[0 .. t.width * t.height * t.cpp]);
    }
};

fn checksumOf(b: []const u8) u64 {
    return checksum(b);
}

/// Tiles for a binning list: a binning frame of draws then flush; `draws` writes the state and
/// primitives.
pub fn binFrame(t: *const Target, bcl: *Cl, ctx: anytype, comptime draws: fn (@TypeOf(ctx), *Cl) void) void {
    bcl.reset();
    t.beginBinning(bcl);
    draws(ctx, bcl);
    bcl.flushAllState();
    bcl.incrementSemaphore();
    bcl.flush();
}
