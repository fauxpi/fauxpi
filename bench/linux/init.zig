//! FauxPi's Linux benchmark: init (PID 1) for a minimal Raspberry Pi kernel on the Pi Zero
//! (bench/linux/bench.config), run from an initramfs. It times the boot, system calls and page
//! faults, then draws the GPU tests' scenes (bench/scene.zig) through the vc4 DRM driver: the
//! kernel validates each frame's binning control list and shaders (SUBMIT_CL) and writes the
//! rendering list, and KMS shows the frames by page flips. It prints, on the console:
//!
//!     BENCH-BEGIN <test>
//!     BENCH-END <test> guest_us=<µs> <name>=<value> ...
//!
//! then `BENCH-DONE`, and restarts the board (through the watchdog), which ends FauxPi's run.
//! What runs is chosen by patching `config` in this binary (found by its magic), as in the
//! bare-metal suite.

const std = @import("std");
const linux = std.os.linux;
const scene = @import("scene");
const bench_tests = @import("bench_tests");

/// What to run: patched in by the runner (as bench/baremetal/main.zig's).
const Config = extern struct {
    magic: [16]u8 = "FAUXPI-BENCH-CFG".*,
    test_name: [32]u8 = padded("all"),
    scale: u32 = 100,
    width: u32 = 1280,
    height: u32 = 720,
    reserved: [9]u32 = @splat(0),
};

fn padded(comptime name: []const u8) [32]u8 {
    var out: [32]u8 = @splat(0);
    @memcpy(out[0..name.len], name);
    return out;
}

export const config: Config = .{};

/// The config as patched: a volatile word at a time (a volatile read of the whole struct is
/// copied from the compiler's own copy).
fn readConfig() Config {
    var c: Config = undefined;
    const src: [*]const volatile u32 = @ptrCast(&config);
    const dst: [*]u32 = @ptrCast(&c);
    for (0..@sizeOf(Config) / 4) |i| dst[i] = src[i];
    return c;
}

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
    _ = linux.write(1, s.ptr, s.len);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    print("BENCH-ERROR " ++ fmt ++ "\n", args);
    finish();
}

/// Ends the run: the board restarts (FauxPi stops).
fn finish() noreturn {
    print("BENCH-DONE\n", .{});
    _ = linux.reboot(.MAGIC1, .MAGIC2, .RESTART, null);
    while (true) _ = linux.pause();
}

fn clockUs(clock: linux.clockid_t) u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(clock, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
}

fn now() u64 {
    return clockUs(.MONOTONIC);
}

pub fn main() noreturn {
    const boot_us = clockUs(.BOOTTIME);
    // /dev is devtmpfs (the console was opened from the initramfs's own /dev/console).
    _ = linux.mount("devtmpfs", "/dev", "devtmpfs", 0, 0);
    _ = linux.mount("proc", "/proc", "proc", 0, 0);

    const cfg = readConfig();
    const name = std.mem.sliceTo(&cfg.test_name, 0);
    const p: Params = .{ .scale = std.math.clamp(cfg.scale, 1, 10000), .width = cfg.width, .height = cfg.height, .boot_us = boot_us };
    print("BENCH-START tests={s} scale={d} size={d}x{d}\n", .{ name, p.scale, p.width, p.height });
    var ran: usize = 0;
    for (tests) |t| {
        if (!std.mem.eql(u8, name, "all") and !std.mem.eql(u8, name, t.name)) continue;
        print("BENCH-BEGIN {s}\n", .{t.name});
        const start = now();
        var result: Result = .{};
        t.run(p, &result);
        const us = now() - start;
        print("BENCH-END {s} guest_us={d}", .{ t.name, us });
        for (result.values[0..result.len]) |v| print(" {s}={d}", .{ v.name, v.value });
        print("\n", .{});
        ran += 1;
    }
    if (ran == 0) print("BENCH-ERROR no test named {s}\n", .{name});
    finish();
}

const Params = struct {
    scale: u32,
    width: u32,
    height: u32,
    /// When init started, since the kernel did.
    boot_us: u64,

    fn amount(p: Params, usual: u64) usize {
        return @intCast(@max(usual * p.scale / 100, 1));
    }
};

const Result = struct {
    values: [8]struct { name: []const u8, value: u64 } = undefined,
    len: usize = 0,

    fn add(r: *Result, name: []const u8, value: u64) void {
        if (r.len == r.values.len) return;
        r.values[r.len] = .{ .name = name, .value = value };
        r.len += 1;
    }
};

const Test = struct {
    name: []const u8,
    run: *const fn (Params, *Result) void,
};

comptime {
    if (tests.len != bench_tests.linux.len) @compileError("bench/tests.zig lists other tests");
    for (tests, bench_tests.linux) |t, known| {
        if (!std.mem.eql(u8, t.name, known.name)) @compileError("bench/tests.zig lists " ++ known.name ++ ", not " ++ t.name);
    }
}

const tests = [_]Test{
    .{ .name = "linux_boot", .run = boot },
    .{ .name = "linux_syscalls", .run = syscalls },
    .{ .name = "linux_pagefault", .run = pageFaults },
    .{ .name = "kms_flip", .run = flips },
    .{ .name = "kms_triangles", .run = trianglesScene },
    .{ .name = "kms_fill", .run = fillScene },
    .{ .name = "kms_texture", .run = textureScene },
    .{ .name = "kms_blend", .run = blendScene },
    .{ .name = "kms_draws", .run = drawsScene },
};

/// The boot: the kernel to init, and the vc4 driver to its device.
fn boot(p: Params, r: *Result) void {
    r.add("kernel_to_init_us", p.boot_us);
    const start = now();
    const fd = openCard();
    _ = linux.close(fd);
    r.add("card_us", now() - start);
}

fn syscalls(p: Params, r: *Result) void {
    const n = p.amount(200_000);
    var sum: u64 = 0;
    for (0..n) |_| sum +%= @intCast(linux.getppid());
    r.add("calls", n);
    r.add("checksum", sum);
}

fn pageFaults(p: Params, r: *Result) void {
    const size = 32 << 20;
    const rounds = p.amount(4);
    var faults: u64 = 0;
    for (0..rounds) |_| {
        const addr = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        if (linux.errno(addr) != .SUCCESS) fail("mmap: {s}", .{@tagName(linux.errno(addr))});
        const mem: [*]volatile u8 = @ptrFromInt(addr);
        var off: usize = 0;
        while (off < size) : (off += 4096) {
            mem[off] = 1;
            faults += 1;
        }
        _ = linux.munmap(@ptrFromInt(addr), size);
    }
    r.add("pages", faults);
}

// --- DRM and vc4 --------------------------------------------------------------------------------

fn drmIowr(nr: u8, comptime T: type) u32 {
    return linux.IOCTL.IOWR('d', nr, T);
}

fn ioctl(fd: i32, req: u32, arg: anytype) linux.E {
    while (true) {
        const rc = linux.ioctl(fd, req, @intFromPtr(arg));
        const e = linux.errno(rc);
        if (e != .INTR and e != .AGAIN) return e;
    }
}

fn must(e: linux.E, what: []const u8) void {
    if (e != .SUCCESS) fail("{s}: {s}", .{ what, @tagName(e) });
}

const CardRes = extern struct {
    fb_id_ptr: u64 = 0,
    crtc_id_ptr: u64 = 0,
    connector_id_ptr: u64 = 0,
    encoder_id_ptr: u64 = 0,
    count_fbs: u32 = 0,
    count_crtcs: u32 = 0,
    count_connectors: u32 = 0,
    count_encoders: u32 = 0,
    min_width: u32 = 0,
    max_width: u32 = 0,
    min_height: u32 = 0,
    max_height: u32 = 0,
};

const ModeInfo = extern struct {
    clock: u32,
    hdisplay: u16,
    hsync_start: u16,
    hsync_end: u16,
    htotal: u16,
    hskew: u16,
    vdisplay: u16,
    vsync_start: u16,
    vsync_end: u16,
    vtotal: u16,
    vscan: u16,
    vrefresh: u32,
    flags: u32,
    type: u32,
    name: [32]u8,
};

const GetConnector = extern struct {
    encoders_ptr: u64 = 0,
    modes_ptr: u64 = 0,
    props_ptr: u64 = 0,
    prop_values_ptr: u64 = 0,
    count_modes: u32 = 0,
    count_props: u32 = 0,
    count_encoders: u32 = 0,
    encoder_id: u32 = 0,
    connector_id: u32 = 0,
    connector_type: u32 = 0,
    connector_type_id: u32 = 0,
    connection: u32 = 0,
    mm_width: u32 = 0,
    mm_height: u32 = 0,
    subpixel: u32 = 0,
    pad: u32 = 0,
};

const GetEncoder = extern struct {
    encoder_id: u32,
    encoder_type: u32 = 0,
    crtc_id: u32 = 0,
    possible_crtcs: u32 = 0,
    possible_clones: u32 = 0,
};

const SetCrtc = extern struct {
    set_connectors_ptr: u64,
    count_connectors: u32,
    crtc_id: u32,
    fb_id: u32,
    x: u32 = 0,
    y: u32 = 0,
    gamma_size: u32 = 0,
    mode_valid: u32 = 1,
    mode: ModeInfo,
};

const FbCmd2 = extern struct {
    fb_id: u32 = 0,
    width: u32,
    height: u32,
    pixel_format: u32,
    flags: u32 = 0,
    handles: [4]u32 = @splat(0),
    pitches: [4]u32 = @splat(0),
    offsets: [4]u32 = @splat(0),
    modifier: [4]u64 = @splat(0),
};

const PageFlip = extern struct {
    crtc_id: u32,
    fb_id: u32,
    flags: u32,
    reserved: u32 = 0,
    user_data: u64 = 0,
};

const SubmitRclSurface = extern struct {
    hindex: u32 = ~@as(u32, 0),
    offset: u32 = 0,
    bits: u16 = 0,
    flags: u16 = 0,
};

const SubmitCl = extern struct {
    bin_cl: u64 = 0,
    shader_rec: u64 = 0,
    uniforms: u64 = 0,
    bo_handles: u64 = 0,
    bin_cl_size: u32 = 0,
    shader_rec_size: u32 = 0,
    shader_rec_count: u32 = 0,
    uniforms_size: u32 = 0,
    bo_handle_count: u32 = 0,
    width: u16 = 0,
    height: u16 = 0,
    min_x_tile: u8 = 0,
    min_y_tile: u8 = 0,
    max_x_tile: u8 = 0,
    max_y_tile: u8 = 0,
    color_read: SubmitRclSurface = .{},
    color_write: SubmitRclSurface = .{},
    zs_read: SubmitRclSurface = .{},
    zs_write: SubmitRclSurface = .{},
    msaa_color_write: SubmitRclSurface = .{},
    msaa_zs_write: SubmitRclSurface = .{},
    clear_color: [2]u32 = .{ 0, 0 },
    clear_z: u32 = 0,
    clear_s: u8 = 0,
    pad: [3]u8 = .{ 0, 0, 0 },
    flags: u32 = 0,
    seqno: u64 = 0,
    perfmonid: u32 = 0,
    in_sync: u32 = 0,
    out_sync: u32 = 0,
    pad2: u32 = 0,
};

const WaitSeqno = extern struct { seqno: u64, timeout_ns: u64 };
const CreateBo = extern struct { size: u32, flags: u32 = 0, handle: u32 = 0, pad: u32 = 0 };
const MmapBo = extern struct { handle: u32, flags: u32 = 0, offset: u64 = 0 };
const CreateShaderBo = extern struct { size: u32, flags: u32 = 0, data: u64, handle: u32 = 0, pad: u32 = 0 };

const drm_format_xrgb8888: u32 = 0x34325258; // 'XR24'
const page_flip_event: u32 = 1;

/// Opens the vc4 device, waiting (up to 10 s) for the driver to make it.
fn openCard() i32 {
    var tries: usize = 0;
    while (true) : (tries += 1) {
        const rc = linux.open("/dev/dri/card0", .{ .ACCMODE = .RDWR, .CLOEXEC = true, .NONBLOCK = true }, 0);
        if (linux.errno(rc) == .SUCCESS) return @intCast(rc);
        if (tries == 1000) fail("no /dev/dri/card0: {s}", .{@tagName(linux.errno(rc))});
        const ts: linux.timespec = .{ .sec = 0, .nsec = 10_000_000 };
        _ = linux.nanosleep(&ts, null);
    }
}

/// A buffer the V3D, and KMS, use, mapped.
const Bo = struct {
    handle: u32,
    bytes: []u8,

    fn create(fd: i32, size: usize) Bo {
        var c: CreateBo = .{ .size = @intCast(std.mem.alignForward(usize, size, 4096)) };
        must(ioctl(fd, drmIowr(0x43, CreateBo), &c), "VC4_CREATE_BO");
        var m: MmapBo = .{ .handle = c.handle };
        must(ioctl(fd, drmIowr(0x44, MmapBo), &m), "VC4_MMAP_BO");
        const addr = linux.mmap(null, c.size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, @intCast(m.offset));
        if (linux.errno(addr) != .SUCCESS) fail("mmap of a BO: {s}", .{@tagName(linux.errno(addr))});
        return .{ .handle = c.handle, .bytes = @as([*]u8, @ptrFromInt(addr))[0..c.size] };
    }

    fn floats(b: Bo) []f32 {
        return @as([*]f32, @ptrCast(@alignCast(b.bytes.ptr)))[0 .. b.bytes.len / 4];
    }
};

fn shaderBo(fd: i32, code: []const u64) u32 {
    var c: CreateShaderBo = .{ .size = @intCast(code.len * 8), .data = @intFromPtr(code.ptr) };
    must(ioctl(fd, drmIowr(0x45, CreateShaderBo), &c), "VC4_CREATE_SHADER_BO (the kernel rejected a shader)");
    return c.handle;
}

/// The display: a CRTC showing one of two framebuffers, each a BO the V3D draws into.
const Display = struct {
    fd: i32,
    crtc: u32,
    width: u32,
    height: u32,
    fbs: [2]struct { bo: Bo, id: u32 },
    /// The one being drawn into next, and whether a flip is waiting for its vblank.
    back: usize = 1,
    flip_pending: bool = false,
    flips: u64 = 0,

    fn init() Display {
        const fd = openCard();
        var res: CardRes = .{};
        must(ioctl(fd, drmIowr(0xA0, CardRes), &res), "MODE_GETRESOURCES");
        var crtcs: [8]u32 = undefined;
        var connectors: [8]u32 = undefined;
        var encoders: [8]u32 = undefined;
        var fb_ids: [8]u32 = undefined;
        res.count_crtcs = @min(res.count_crtcs, 8);
        res.count_connectors = @min(res.count_connectors, 8);
        res.count_encoders = @min(res.count_encoders, 8);
        res.count_fbs = @min(res.count_fbs, 8);
        res.crtc_id_ptr = @intFromPtr(&crtcs);
        res.connector_id_ptr = @intFromPtr(&connectors);
        res.encoder_id_ptr = @intFromPtr(&encoders);
        res.fb_id_ptr = @intFromPtr(&fb_ids);
        must(ioctl(fd, drmIowr(0xA0, CardRes), &res), "MODE_GETRESOURCES");
        // The first connected connector, at its first (preferred) mode.
        for (connectors[0..res.count_connectors]) |id| {
            var conn: GetConnector = .{ .connector_id = id };
            must(ioctl(fd, drmIowr(0xA7, GetConnector), &conn), "MODE_GETCONNECTOR");
            if (conn.connection != 1 or conn.count_modes == 0) continue;
            var modes: [32]ModeInfo = undefined;
            var enc_ids: [8]u32 = undefined;
            conn.count_modes = @min(conn.count_modes, 32);
            conn.count_encoders = @min(conn.count_encoders, 8);
            conn.count_props = 0;
            conn.modes_ptr = @intFromPtr(&modes);
            conn.encoders_ptr = @intFromPtr(&enc_ids);
            must(ioctl(fd, drmIowr(0xA7, GetConnector), &conn), "MODE_GETCONNECTOR");
            const mode = modes[0];
            // The CRTC its encoder drives, or one it can (on vc4, HDMI has a pixel valve of its
            // own).
            var crtc: u32 = 0;
            for (enc_ids[0..conn.count_encoders]) |enc_id| {
                var enc: GetEncoder = .{ .encoder_id = enc_id };
                if (ioctl(fd, drmIowr(0xA6, GetEncoder), &enc) != .SUCCESS) continue;
                if (enc.crtc_id != 0) {
                    crtc = enc.crtc_id;
                    break;
                }
                for (crtcs[0..res.count_crtcs], 0..) |c, k| {
                    if (enc.possible_crtcs & (@as(u32, 1) << @intCast(k)) != 0) {
                        crtc = c;
                        break;
                    }
                }
                if (crtc != 0) break;
            }
            if (crtc == 0) fail("no CRTC for the display", .{});
            var d: Display = .{ .fd = fd, .crtc = crtc, .width = mode.hdisplay, .height = mode.vdisplay, .fbs = undefined };
            for (&d.fbs) |*fb| {
                fb.bo = .create(fd, @as(usize, d.width) * d.height * 4);
                var cmd: FbCmd2 = .{ .width = d.width, .height = d.height, .pixel_format = drm_format_xrgb8888 };
                cmd.handles[0] = fb.bo.handle;
                cmd.pitches[0] = d.width * 4;
                must(ioctl(fd, drmIowr(0xB8, FbCmd2), &cmd), "MODE_ADDFB2");
                fb.id = cmd.fb_id;
            }
            var conn_id = id;
            var set: SetCrtc = .{ .set_connectors_ptr = @intFromPtr(&conn_id), .count_connectors = 1, .crtc_id = crtc, .fb_id = d.fbs[0].id, .mode = mode };
            must(ioctl(fd, drmIowr(0xA2, SetCrtc), &set), "MODE_SETCRTC");
            return d;
        }
        fail("no connected display", .{});
    }

    /// Shows the back framebuffer at the next vblank, unless a flip is still waiting (then it is
    /// drawn again). `wait`: until it is shown.
    fn flip(d: *Display, wait: bool) void {
        d.drainEvents(false);
        if (d.flip_pending) {
            if (!wait) return;
            d.drainEvents(true);
        }
        var pf: PageFlip = .{ .crtc_id = d.crtc, .fb_id = d.fbs[d.back].id, .flags = page_flip_event };
        must(ioctl(d.fd, drmIowr(0xB0, PageFlip), &pf), "MODE_PAGE_FLIP");
        d.flip_pending = true;
        d.flips += 1;
        d.back = 1 - d.back;
        if (wait) d.drainEvents(true);
    }

    /// Reads the flips' events: those there are, or (`block`) until the pending one comes.
    fn drainEvents(d: *Display, block: bool) void {
        while (true) {
            var buf: [256]u8 = undefined;
            const rc = linux.read(d.fd, &buf, buf.len);
            const e = linux.errno(rc);
            if (e == .SUCCESS and rc > 0) {
                d.flip_pending = false;
                if (!block) continue;
                return;
            }
            if (!block or !d.flip_pending) return;
            var pfd = [1]linux.pollfd{.{ .fd = d.fd, .events = linux.POLL.IN, .revents = 0 }};
            _ = linux.poll(&pfd, 1, 1000);
        }
    }
};

/// A frame being built: a binning list, shader records and uniforms, as SUBMIT_CL takes them.
const Job = struct {
    bcl: [64 * 1024]u8 = undefined,
    bcl_len: usize = 0,
    rec: [96 * 1024]u8 = undefined,
    rec_len: usize = 0,
    rec_count: u32 = 0,
    unifs: [32 * 1024]u32 = undefined,
    unifs_len: usize = 0,
    handles: [64]u32 = undefined,
    handle_count: u32 = 0,

    fn byte(j: *Job, v: u8) void {
        j.bcl[j.bcl_len] = v;
        j.bcl_len += 1;
    }
    fn half(j: *Job, v: u16) void {
        std.mem.writeInt(u16, j.bcl[j.bcl_len..][0..2], v, .little);
        j.bcl_len += 2;
    }
    fn word(j: *Job, v: u32) void {
        std.mem.writeInt(u32, j.bcl[j.bcl_len..][0..4], v, .little);
        j.bcl_len += 4;
    }
    fn recWord(j: *Job, v: u32) void {
        std.mem.writeInt(u32, j.rec[j.rec_len..][0..4], v, .little);
        j.rec_len += 4;
    }
    fn recHalf(j: *Job, v: u16) void {
        std.mem.writeInt(u16, j.rec[j.rec_len..][0..2], v, .little);
        j.rec_len += 2;
    }
    fn recByte(j: *Job, v: u8) void {
        j.rec[j.rec_len] = v;
        j.rec_len += 1;
    }
    fn unif(j: *Job, v: u32) void {
        j.unifs[j.unifs_len] = v;
        j.unifs_len += 1;
    }

    /// `handle`'s index in the job's buffers.
    fn index(j: *Job, handle: u32) u32 {
        for (j.handles[0..j.handle_count], 0..) |h, i| if (h == handle) return @intCast(i);
        j.handles[j.handle_count] = handle;
        j.handle_count += 1;
        return j.handle_count - 1;
    }

    /// Starts a frame drawn into `target` (`width` by `height`).
    fn begin(j: *Job, target: u32, width: u32, height: u32) void {
        j.* = .{};
        _ = j.index(target);
        // TILE_BINNING_MODE_CONFIG: the kernel's memory, the tiles.
        j.byte(112);
        j.word(0);
        j.word(0);
        j.word(0);
        j.byte(@intCast((width + 63) / 64));
        j.byte(@intCast((height + 63) / 64));
        j.byte(0);
        j.byte(6); // START_TILE_BINNING
        j.byte(56); // PRIMITIVE_LIST_FORMAT: 16-bit indices, triangles
        j.byte(0x12);
    }

    /// A draw of `count` vertices (triangles) from `first`, of `vertices` shaded as `s` says.
    fn draw(j: *Job, d: *const Display, sh: *const ShaderSet, vertices: u32, first: u32, count: u32, depth_test: bool, texture: ?u32) void {
        // CLIP_WINDOW, CONFIGURATION_BITS, VIEWPORT_OFFSET, CLIPPER_XY_SCALING and _Z_.
        j.byte(102);
        j.half(0);
        j.half(0);
        j.half(@intCast(d.width));
        j.half(@intCast(d.height));
        j.byte(96);
        j.byte(0x03);
        j.byte(if (depth_test) 0x80 | (3 << 4) else 7 << 4);
        j.byte(0x02);
        j.byte(103);
        j.half(@intCast(d.width * 8));
        j.half(@intCast(d.height * 8));
        j.byte(105);
        j.word(@bitCast(@as(f32, @floatFromInt(d.width)) * 8.0));
        j.word(@bitCast(-@as(f32, @floatFromInt(d.height)) * 8.0));
        j.byte(106);
        j.word(@bitCast(@as(f32, 0.5)));
        j.word(@bitCast(@as(f32, 0.5)));

        // The shader record: the buffers (as indices), then the record, the code and uniform
        // addresses the kernel's.
        const stride: u8 = sh.words * 4;
        j.recWord(j.index(sh.fs));
        j.recWord(j.index(sh.vs));
        j.recWord(j.index(sh.cs));
        j.recWord(j.index(vertices));
        j.recHalf(1 | 4); // single-threaded fragment shader, clipping
        j.recByte(0);
        j.recByte(sh.varyings);
        j.recWord(0);
        j.recWord(0);
        j.recHalf(0);
        j.recByte(1);
        j.recByte(stride);
        j.recWord(0);
        j.recWord(0);
        j.recHalf(0);
        j.recByte(1);
        j.recByte(stride);
        j.recWord(0);
        j.recWord(0);
        j.recWord(0); // attribute 0: from the start of the vertices
        j.recByte(stride - 1);
        j.recByte(stride);
        j.recByte(0);
        j.recByte(0);
        j.rec_count += 1;

        // Uniforms: the fragment shader's (a texture: its buffer's index, then its parameters),
        // the vertex shader's, the coordinate shader's.
        if (texture) |tex| {
            j.unif(j.index(tex));
            j.unif(0); // P0: the texture at the start of its buffer, RGBA8888 T-format
            j.unif((scene.texture_size << 20) | (scene.texture_size << 8));
        }
        for (0..2) |_| {
            j.unif(@bitCast(@as(f32, @floatFromInt(d.width)) * 8.0));
            j.unif(@bitCast(-@as(f32, @floatFromInt(d.height)) * 8.0));
        }

        j.byte(64); // GL_SHADER_STATE: the next record, 1 attribute
        j.word(1);
        j.byte(33); // GL_ARRAY_PRIMITIVE: triangles
        j.byte(4);
        j.word(count);
        j.word(first);
    }

    /// Submits the frame, clearing to `clear`, and waits until it is drawn.
    fn submit(j: *Job, d: *const Display, target: u32, clear: u32, draws: bool) void {
        if (draws) {
            j.byte(7); // INCREMENT_SEMAPHORE
            j.byte(4); // FLUSH
        }
        _ = target;
        var s: SubmitCl = .{
            .bin_cl = @intFromPtr(&j.bcl),
            .bin_cl_size = if (draws) @intCast(j.bcl_len) else 0,
            .shader_rec = @intFromPtr(&j.rec),
            .shader_rec_size = if (draws) @intCast(j.rec_len) else 0,
            .shader_rec_count = if (draws) j.rec_count else 0,
            .uniforms = @intFromPtr(&j.unifs),
            .uniforms_size = if (draws) @intCast(j.unifs_len * 4) else 0,
            .bo_handles = @intFromPtr(&j.handles),
            .bo_handle_count = j.handle_count,
            .width = @intCast(d.width),
            .height = @intCast(d.height),
            .max_x_tile = @intCast((d.width + 63) / 64 - 1),
            .max_y_tile = @intCast((d.height + 63) / 64 - 1),
            // RGBA8888, linear (what KMS scans out).
            .color_write = .{ .hindex = 0, .bits = 1 << 2 },
            .clear_color = .{ clear, clear },
            .clear_z = 0xffffff,
            .flags = 1, // use the clear colour
        };
        must(ioctl(d.fd, drmIowr(0x40, SubmitCl), &s), "VC4_SUBMIT_CL (the kernel rejected the frame)");
        var w: WaitSeqno = .{ .seqno = s.seqno, .timeout_ns = 10_000_000_000 };
        must(ioctl(d.fd, drmIowr(0x41, WaitSeqno), &w), "VC4_WAIT_SEQNO");
    }
};

/// A shading's shaders, as shader buffers the kernel has validated.
const ShaderSet = struct {
    vs: u32,
    cs: u32,
    fs: u32,
    words: u8,
    varyings: u8,

    fn make(fd: i32, shading: scene.Shading) ShaderSet {
        // Each copied before the next is made (they share the encoder's buffers).
        const vs = shaderBo(fd, scene.vertexShader(shading.words(), false));
        const cs = shaderBo(fd, scene.vertexShader(shading.words(), true));
        const fs = shaderBo(fd, shading.fragmentShader());
        return .{ .vs = vs, .cs = cs, .fs = fs, .words = shading.words(), .varyings = shading.varyings() };
    }
};

var job: Job = .{};

/// Draws frames of `draws` and shows them, as fast as the V3D draws them (a flip when the last
/// one is done): the frames drawn, and flips.
fn sceneFrames(d: *Display, frames: usize, clear: u32, comptime drawFn: anytype, ctx: anytype, r: *Result) void {
    for (0..frames) |_| {
        const target = d.fbs[d.back].bo.handle;
        job.begin(target, d.width, d.height);
        drawFn(&job, d, ctx);
        job.submit(d, target, clear, true);
        d.flip(false);
    }
    r.add("frames", frames);
    r.add("flips", d.flips);
}

/// Page flips, each waited for: clear frames, shown at each vblank.
fn flips(p: Params, r: *Result) void {
    var d: Display = .init();
    const frames = p.amount(120);
    for (0..frames) |f| {
        const target = d.fbs[d.back].bo.handle;
        job.begin(target, d.width, d.height);
        job.submit(&d, target, 0xff000000 | @as(u32, @intCast(f * 0x010203 & 0xffffff)), false);
        d.flip(true);
    }
    r.add("frames", frames);
    r.add("width", d.width);
    r.add("height", d.height);
}

fn trianglesScene(p: Params, r: *Result) void {
    var d: Display = .init();
    const s: ShaderSet = .make(d.fd, .flat);
    const n: u32 = @intCast(@min(p.amount(20_000), 21_000));
    const vertices: Bo = .create(d.fd, n * 3 * 6 * 4);
    scene.triangleVertices(vertices.floats(), n);
    const Ctx = struct { s: *const ShaderSet, v: u32, n: u32 };
    sceneFrames(&d, p.amount(30), 0xff102030, struct {
        fn f(j: *Job, dd: *const Display, c: Ctx) void {
            j.draw(dd, c.s, c.v, 0, c.n * 3, false, null);
        }
    }.f, Ctx{ .s = &s, .v = vertices.handle, .n = n }, r);
    r.add("triangles", n);
}

fn fillScene(p: Params, r: *Result) void {
    var d: Display = .init();
    const s: ShaderSet = .make(d.fd, .flat);
    const vertices: Bo = .create(d.fd, scene.fill_quads * 6 * 6 * 4);
    scene.fillVertices(vertices.floats());
    const Ctx = struct { s: *const ShaderSet, v: u32 };
    sceneFrames(&d, p.amount(30), 0xff000000, struct {
        fn f(j: *Job, dd: *const Display, c: Ctx) void {
            j.draw(dd, c.s, c.v, 0, scene.fill_quads * 6, true, null);
        }
    }.f, Ctx{ .s = &s, .v = vertices.handle }, r);
}

fn textureScene(p: Params, r: *Result) void {
    var d: Display = .init();
    const s: ShaderSet = .make(d.fd, .textured);
    const tex: Bo = .create(d.fd, scene.texture_size * scene.texture_size * 4);
    scene.textureTexels(tex.bytes);
    const n: u32 = @intCast(@min(p.amount(2000), 10_000));
    const vertices: Bo = .create(d.fd, n * 6 * 5 * 4);
    scene.textureVertices(vertices.floats(), n);
    const Ctx = struct { s: *const ShaderSet, v: u32, n: u32, tex: u32 };
    sceneFrames(&d, p.amount(30), 0xff000000, struct {
        fn f(j: *Job, dd: *const Display, c: Ctx) void {
            j.draw(dd, c.s, c.v, 0, c.n * 6, false, c.tex);
        }
    }.f, Ctx{ .s = &s, .v = vertices.handle, .n = n, .tex = tex.handle }, r);
    r.add("quads", n);
}

fn blendScene(p: Params, r: *Result) void {
    var d: Display = .init();
    const s: ShaderSet = .make(d.fd, .blended);
    const n: u32 = @intCast(@min(p.amount(500), 5000));
    const vertices: Bo = .create(d.fd, n * 6 * 7 * 4);
    scene.blendVertices(vertices.floats(), n);
    const Ctx = struct { s: *const ShaderSet, v: u32, n: u32 };
    sceneFrames(&d, p.amount(30), 0xff204060, struct {
        fn f(j: *Job, dd: *const Display, c: Ctx) void {
            j.draw(dd, c.s, c.v, 0, c.n * 6, false, null);
        }
    }.f, Ctx{ .s = &s, .v = vertices.handle, .n = n }, r);
    r.add("quads", n);
}

fn drawsScene(p: Params, r: *Result) void {
    var d: Display = .init();
    const s: ShaderSet = .make(d.fd, .flat);
    // The kernel's limits on a job's records: as many draws as fit.
    const n: u32 = @intCast(@min(p.amount(1000), 1000));
    const vertices: Bo = .create(d.fd, n * 6 * 6 * 4);
    const floats = vertices.floats();
    for (0..n) |i| scene.drawQuad(floats[i * 36 ..][0..36], @intCast(i));
    const Ctx = struct { s: *const ShaderSet, v: u32, n: u32 };
    sceneFrames(&d, p.amount(30), 0xff000000, struct {
        fn f(j: *Job, dd: *const Display, c: Ctx) void {
            for (0..c.n) |i| j.draw(dd, c.s, c.v, @intCast(i * 6), 6, false, null);
        }
    }.f, Ctx{ .s = &s, .v = vertices.handle, .n = n }, r);
    r.add("draws", n);
}

pub const panic = std.debug.FullPanic(panicked);

fn panicked(msg: []const u8, _: ?usize) noreturn {
    fail("panic: {s}", .{msg});
}
