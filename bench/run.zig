//! Runs FauxPi's benchmark: boots the bare-metal tests (bench/baremetal), or with --linux the Linux
//! ones (a minimal Raspberry Pi kernel and bench/linux/init.zig), in FauxPi, headless, a test a
//! boot, and reports how long each took and where FauxPi spent the time (its `--profile` report),
//! as JSON on stdout (or `--json <file>`) and a table on stderr.
//!
//! `zig build bench` builds FauxPi, the tests and this, and passes this the paths of all three;
//! what comes after `--` is for this (`zig build bench -- --help`).

const std = @import("std");
const bench_tests = @import("bench_tests");

const usage =
    \\usage: zig build bench -- [options] [test ...]
    \\
    \\Boots FauxPi's bare-metal benchmark (bench/baremetal), or the Linux one (--linux), a test a
    \\boot, headless, and reports each test's time and where FauxPi spent it, as JSON (stdout, or
    \\--json) and a table (stderr). With no tests named, runs them all.
    \\
    \\  --linux           The Linux tests: a minimal Raspberry Pi kernel for the Pi Zero (built
    \\                    once, into ~/.cache/fauxpi-bench, with arm-linux-gnueabihf-gcc), and init
    \\                    drawing through vc4 and KMS; naming one of them does too
    \\  --linux-src <dir> Build the kernel from this Raspberry Pi kernel tree, as it is (default:
    \\                    the pinned commit, fetched once)
    \\  --v3d <mode>      Where V3D draws: gpu (default), gpu-fragments, cpu, or all (each in turn);
    \\                    may be given more than once
    \\  --scale <n>       How much work each test does: 100 is usual (default), 1 to 10000
    \\  --size <WxH>      The display and framebuffer size (default 1280x720)
    \\  --repeat <n>      Run each test n times (default 1)
    \\  --timeout <s>     Stop a test's boot after s seconds (default 300)
    \\  --json <file>     Write the JSON there, not to stdout
    \\  --log <dir>       Keep each boot's serial output and FauxPi's messages there
    \\  --image <file>    Only write an SD card image that runs the tests (all, bare-metal or Linux)
    \\                    on a Raspberry Pi Zero (with its firmware), printing results on the
    \\                    serial port
    \\  --list            List the tests
    \\
;

/// The firmware and device trees, from Raspberry Pi's firmware repository at a release.
const firmware_tag = "1.20260915";
const Download = struct { name: []const u8, sha256: []const u8 };
const device_tree: Download = .{ .name = "bcm2708-rpi-zero.dtb", .sha256 = "203959c26da495c119fa0b75ce3f85797a91ab61070f4a8f4938349409ddb8f7" };
const firmware = [_]Download{
    .{ .name = "bootcode.bin", .sha256 = "4245ec23b58158dc3e55f3e065eb4ecc0c0705d76c8db506e9f824941feee32e" },
    .{ .name = "start.elf", .sha256 = "32f990801e7765bae6fe5cb940ba5eeff02dd0dac8dc5474db5b3fd345281790" },
    .{ .name = "fixup.dat", .sha256 = "7853f2b51e4489f8b3ce6f9c52fd0afdda38c7383961524e0883d34afcb4827b" },
    .{ .name = "LICENCE.broadcom", .sha256 = "c7283ff51f863d93a275c66e3b4cb08021a5dd4d8c1e7acc47d872fbe52d3d6b" },
};

const config_txt =
    \\# FauxPi's bare-metal benchmark: a 32-bit kernel at 0x8000, printing on the PL011.
    \\kernel=kernel.img
    \\arm_64bit=0
    \\enable_uart=1
    \\
;

const linux_config_txt =
    \\# FauxPi's Linux benchmark: a minimal Raspberry Pi kernel, init in an initramfs, vc4 for KMS.
    \\kernel=kernel.img
    \\arm_64bit=0
    \\enable_uart=1
    \\initramfs initramfs.cpio followkernel
    \\dtoverlay=vc4-kms-v3d
    \\
;

const linux_cmdline_txt = "console=ttyAMA0,115200 cma=64M loglevel=3\n";

/// The Raspberry Pi kernel the Linux tests build: rpi-6.18.y as of 2026-11-03.
const linux_repo = "https://github.com/raspberrypi/linux.git";
const linux_commit = "a4985478de14b3a83c8e04fed68377c1bdae735d";

/// An initramfs (cpio, newc) of `init`, with /dev/console (its output, before devtmpfs), /dev and
/// /proc.
fn initramfs(arena: std.mem.Allocator, init: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    const Entry = struct { name: []const u8, mode: u32, data: []const u8 = "", rdev: [2]u32 = .{ 0, 0 } };
    const entries = [_]Entry{
        .{ .name = "dev", .mode = 0o040755 },
        .{ .name = "proc", .mode = 0o040755 },
        .{ .name = "dev/console", .mode = 0o020600, .rdev = .{ 5, 1 } },
        .{ .name = "init", .mode = 0o100755, .data = init },
        .{ .name = "TRAILER!!!", .mode = 0 },
    };
    for (entries, 1..) |e, ino| {
        try w.print("070701{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}", .{
            ino, e.mode, 0, 0, 1, 0, e.data.len, 0, 0, e.rdev[0], e.rdev[1], e.name.len + 1, 0,
        });
        try w.print("{s}\x00", .{e.name});
        try w.splatByteAll(0, (4 - (110 + e.name.len + 1) % 4) % 4);
        try w.writeAll(e.data);
        try w.splatByteAll(0, (4 - e.data.len % 4) % 4);
    }
    return out.written();
}

fn runOk(arena: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const res = try std.process.run(arena, io, .{ .argv = argv });
    if (res.term != .exited or res.term.exited != 0) {
        std.debug.print("{s} failed:\n{s}{s}\n", .{ argv[0], res.stdout, res.stderr });
        return error.CommandFailed;
    }
}

/// The Linux kernel for the tests, its device tree and vc4's overlay: built (once, for a
/// configuration) from `--linux-src`, or the pinned commit fetched into the cache.
fn buildLinux(arena: std.mem.Allocator, io: std.Io, o: Options, cache: []const u8) ![]const NamedFile {
    const cwd = std.Io.Dir.cwd();
    const fragment = try cwd.readFileAlloc(io, o.linux_config, arena, .limited(1 << 20));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(fragment, &digest, .{});
    const stamp_text = try std.fmt.allocPrint(arena, "{s} {s}\n", .{ o.linux_src orelse linux_commit, std.fmt.bytesToHex(digest, .lower) });

    const src = o.linux_src orelse blk: {
        const dir = try std.fs.path.join(arena, &.{ cache, "linux-src-" ++ linux_commit[0..12] });
        const makefile = try std.fs.path.join(arena, &.{ dir, "Makefile" });
        cwd.access(io, makefile, .{}) catch {
            std.debug.print("fetching the Raspberry Pi kernel ({s} at {s}), once\n", .{ linux_repo, linux_commit[0..12] });
            try cwd.createDirPath(io, dir);
            try runOk(arena, io, &.{ "git", "-C", dir, "init", "-q" });
            try runOk(arena, io, &.{ "git", "-C", dir, "fetch", "-q", "--depth", "1", linux_repo, linux_commit });
            try runOk(arena, io, &.{ "git", "-C", dir, "checkout", "-q", "FETCH_HEAD" });
        };
        break :blk dir;
    };
    const out = try std.fs.path.join(arena, &.{ cache, "linux-build" });
    const stamp = try std.fs.path.join(arena, &.{ out, "fauxpi-bench.stamp" });
    const zimage = try std.fs.path.join(arena, &.{ out, "arch/arm/boot/zImage" });
    const dtb = try std.fs.path.join(arena, &.{ out, "arch/arm/boot/dts/broadcom/bcm2708-rpi-zero.dtb" });
    const overlay = try std.fs.path.join(arena, &.{ out, "arch/arm/boot/dts/overlays/vc4-kms-v3d.dtbo" });
    const built = if (cwd.readFileAlloc(io, stamp, arena, .limited(4096))) |old| std.mem.eql(u8, old, stamp_text) else |_| false;
    if (!built) {
        std.debug.print("building the kernel (tinyconfig and {s}), once: a minute or two\n", .{o.linux_config});
        try cwd.createDirPath(io, out);
        const o_arg = try std.fmt.allocPrint(arena, "O={s}", .{out});
        const jobs = try std.fmt.allocPrint(arena, "-j{d}", .{std.Thread.getCpuCount() catch 4});
        const make: []const []const u8 = &.{ "make", "-s", "-C", src, o_arg, "ARCH=arm", "CROSS_COMPILE=arm-linux-gnueabihf-" };
        try runOk(arena, io, try std.mem.concat(arena, []const u8, &.{ make, &.{"tinyconfig"} }));
        const dot_config = try std.fs.path.join(arena, &.{ out, ".config" });
        try runOk(arena, io, &.{ try std.fs.path.join(arena, &.{ src, "scripts/kconfig/merge_config.sh" }), "-m", "-O", out, dot_config, o.linux_config });
        try runOk(arena, io, try std.mem.concat(arena, []const u8, &.{ make, &.{"olddefconfig"} }));
        // Every option set took effect (one whose dependencies aren't met is dropped quietly).
        const config = try cwd.readFileAlloc(io, dot_config, arena, .limited(1 << 20));
        var lines = std.mem.splitScalar(u8, fragment, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "CONFIG_")) continue;
            if (std.mem.indexOf(u8, config, line) == null) {
                std.debug.print("the kernel's configuration lacks {s} (its dependencies?)\n", .{line});
                return error.KernelConfig;
            }
        }
        try runOk(arena, io, try std.mem.concat(arena, []const u8, &.{ make, &.{ jobs, "zImage", "broadcom/bcm2708-rpi-zero.dtb", "overlays/vc4-kms-v3d.dtbo" } }));
        try cwd.writeFile(io, .{ .sub_path = stamp, .data = stamp_text });
    }
    return try arena.dupe(NamedFile, &.{
        .{ .name = "kernel.img", .data = try cwd.readFileAlloc(io, zimage, arena, .limited(64 << 20)) },
        .{ .name = "bcm2708-rpi-zero.dtb", .data = try cwd.readFileAlloc(io, dtb, arena, .limited(1 << 20)) },
        .{ .name = "overlays/vc4-kms-v3d.dtbo", .data = try cwd.readFileAlloc(io, overlay, arena, .limited(1 << 20)) },
    });
}

const Options = struct {
    fauxpi: []const u8 = "",
    kernel: []const u8 = "",
    mkimage: []const u8 = "",
    init: []const u8 = "",
    linux_config: []const u8 = "",
    linux: bool = false,
    linux_src: ?[]const u8 = null,
    tests: std.ArrayList([]const u8) = .empty,
    modes: std.ArrayList([]const u8) = .empty,
    scale: u32 = 100,
    width: u32 = 1280,
    height: u32 = 720,
    repeat: u32 = 1,
    timeout_s: u32 = 300,
    json: ?[]const u8 = null,
    log: ?[]const u8 = null,
    image: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    var o: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const value = struct {
            fn next(list: []const []const u8, at: *usize, name: []const u8) []const u8 {
                at.* += 1;
                if (at.* >= list.len) {
                    std.debug.print("{s} needs a value\n{s}", .{ name, usage });
                    std.process.exit(2);
                }
                return list[at.*];
            }
        }.next;
        if (std.mem.startsWith(u8, a, "--fauxpi=")) {
            o.fauxpi = a["--fauxpi=".len..];
        } else if (std.mem.startsWith(u8, a, "--kernel=")) {
            o.kernel = a["--kernel=".len..];
        } else if (std.mem.startsWith(u8, a, "--mkimage=")) {
            o.mkimage = a["--mkimage=".len..];
        } else if (std.mem.startsWith(u8, a, "--init=")) {
            o.init = a["--init=".len..];
        } else if (std.mem.startsWith(u8, a, "--linux-config=")) {
            o.linux_config = a["--linux-config=".len..];
        } else if (std.mem.eql(u8, a, "--linux")) {
            o.linux = true;
        } else if (std.mem.eql(u8, a, "--linux-src")) {
            o.linux_src = value(args, &i, a);
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print("{s}", .{usage});
            return 0;
        } else if (std.mem.eql(u8, a, "--list")) {
            std.debug.print("Bare-metal:\n", .{});
            for (bench_tests.all) |t| std.debug.print("  {s:<16} {s}\n", .{ t.name, t.about });
            std.debug.print("Linux (--linux):\n", .{});
            for (bench_tests.linux) |t| std.debug.print("  {s:<16} {s}\n", .{ t.name, t.about });
            return 0;
        } else if (std.mem.eql(u8, a, "--v3d")) {
            const m = value(args, &i, a);
            if (std.mem.eql(u8, m, "all")) {
                try o.modes.appendSlice(arena, &.{ "gpu", "gpu-fragments", "cpu" });
            } else if (std.mem.eql(u8, m, "gpu") or std.mem.eql(u8, m, "gpu-fragments") or std.mem.eql(u8, m, "cpu")) {
                try o.modes.append(arena, m);
            } else {
                std.debug.print("--v3d takes gpu, gpu-fragments, cpu or all\n", .{});
                return 2;
            }
        } else if (std.mem.eql(u8, a, "--scale")) {
            o.scale = std.math.clamp(try std.fmt.parseInt(u32, value(args, &i, a), 10), 1, 10000);
        } else if (std.mem.eql(u8, a, "--size")) {
            const s = value(args, &i, a);
            const x = std.mem.indexOfAny(u8, s, "xX") orelse return error.BadSize;
            o.width = try std.fmt.parseInt(u32, s[0..x], 10);
            o.height = try std.fmt.parseInt(u32, s[x + 1 ..], 10);
        } else if (std.mem.eql(u8, a, "--repeat")) {
            o.repeat = @max(try std.fmt.parseInt(u32, value(args, &i, a), 10), 1);
        } else if (std.mem.eql(u8, a, "--timeout")) {
            o.timeout_s = try std.fmt.parseInt(u32, value(args, &i, a), 10);
        } else if (std.mem.eql(u8, a, "--json")) {
            o.json = value(args, &i, a);
        } else if (std.mem.eql(u8, a, "--log")) {
            o.log = value(args, &i, a);
        } else if (std.mem.eql(u8, a, "--image")) {
            o.image = value(args, &i, a);
        } else if (std.mem.startsWith(u8, a, "-")) {
            std.debug.print("unknown option {s}\n{s}", .{ a, usage });
            return 2;
        } else {
            if (isTestIn(&bench_tests.linux, a)) {
                o.linux = true;
            } else if (!isTestIn(&bench_tests.all, a)) {
                std.debug.print("no test named {s} (--list lists them)\n", .{a});
                return 2;
            }
            try o.tests.append(arena, a);
        }
    }
    if (o.fauxpi.len == 0 or o.kernel.len == 0 or o.mkimage.len == 0) {
        std.debug.print("run this with zig build bench\n", .{});
        return 2;
    }
    const list: []const bench_tests.Test = if (o.linux) &bench_tests.linux else &bench_tests.all;
    for (o.tests.items) |t| if (!isTestIn(list, t)) {
        std.debug.print("{s} isn't a {s} test: run the bare-metal and Linux tests apart\n", .{ t, if (o.linux) "Linux" else "bare-metal" });
        return 2;
    };
    if (o.tests.items.len == 0) for (list) |t| try o.tests.append(arena, t.name);
    if (o.modes.items.len == 0) try o.modes.append(arena, "gpu");

    const cwd = std.Io.Dir.cwd();
    // The guest: the bare-metal kernel.img, or Linux's init (and the kernel, built).
    const kernel = try cwd.readFileAlloc(io, if (o.linux) o.init else o.kernel, arena, .limited(16 << 20));
    const cache = try cacheDir(arena, init.environ_map);
    try cwd.createDirPath(io, cache);

    if (o.image) |path| {
        // For a real Pi Zero: every test, and the firmware to boot it (and Linux, built).
        const files = if (o.linux)
            try std.mem.concat(arena, NamedFile, &.{ try fetchAll(arena, io, cache, &firmware), try buildLinux(arena, io, o, cache) })
        else
            try fetchAll(arena, io, cache, &(firmware ++ [_]Download{device_tree}));
        const patched = try patch(arena, kernel, "all", o);
        try makeImage(arena, io, o, cache, path, patched, files);
        std.debug.print("wrote {s}: the benchmark for a Raspberry Pi Zero (results on the serial port, GPIO 14, 115200 baud)\n", .{path});
        return 0;
    }
    const dtb: []const NamedFile = if (o.linux) try buildLinux(arena, io, o, cache) else try fetchAll(arena, io, cache, &.{device_tree});

    var runs: std.ArrayList(Run) = .empty;
    var failed = false;
    for (o.modes.items) |mode| {
        for (o.tests.items) |name| {
            for (0..o.repeat) |rep| {
                std.debug.print("{s} ({s}{s}{s})...\n", .{ name, mode, if (o.repeat > 1) ", run " else "", if (o.repeat > 1) try std.fmt.allocPrint(arena, "{d}", .{rep + 1}) else "" });
                const r = try runTest(arena, io, o, cache, kernel, dtb, name, mode);
                if (r.err != null) failed = true;
                try runs.append(arena, r);
            }
        }
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    try writeJson(&out.writer, o, runs.items);
    if (o.json) |path| {
        try cwd.writeFile(io, .{ .sub_path = path, .data = out.written() });
    } else {
        try std.Io.File.stdout().writeStreamingAll(io, out.written());
    }
    printTable(runs.items);
    return if (failed) 1 else 0;
}

fn isTestIn(list: []const bench_tests.Test, name: []const u8) bool {
    for (list) |t| if (std.mem.eql(u8, t.name, name)) return true;
    return std.mem.eql(u8, name, "all");
}

/// $XDG_CACHE_HOME/fauxpi-bench, or ~/.cache/fauxpi-bench.
fn cacheDir(arena: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    if (env.get("XDG_CACHE_HOME")) |x| if (x.len > 0) return std.fs.path.join(arena, &.{ x, "fauxpi-bench" });
    const home = env.get("HOME") orelse return error.NoHome;
    return std.fs.path.join(arena, &.{ home, ".cache", "fauxpi-bench" });
}

/// The files, downloaded (once, into the cache) and checked: name and contents.
fn fetchAll(arena: std.mem.Allocator, io: std.Io, cache: []const u8, files: []const Download) ![]const NamedFile {
    var out: std.ArrayList(NamedFile) = .empty;
    const dir = try std.fs.path.join(arena, &.{ cache, firmware_tag });
    try std.Io.Dir.cwd().createDirPath(io, dir);
    for (files) |f| {
        const path = try std.fs.path.join(arena, &.{ dir, f.name });
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20)) catch blk: {
            const url = try std.fmt.allocPrint(arena, "https://raw.githubusercontent.com/raspberrypi/firmware/{s}/boot/{s}", .{ firmware_tag, f.name });
            std.debug.print("downloading {s}\n", .{url});
            const tmp = try std.fmt.allocPrint(arena, "{s}.part", .{path});
            const res = try std.process.run(arena, io, .{ .argv = &.{ "curl", "-fsSL", "-o", tmp, url } });
            if (res.term != .exited or res.term.exited != 0) {
                std.debug.print("downloading {s} failed: {s}\n", .{ url, res.stderr });
                return error.DownloadFailed;
            }
            try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, io);
            break :blk try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20));
        };
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        if (!std.mem.eql(u8, &hex, f.sha256)) {
            std.debug.print("{s} is not the file expected (SHA-256 {s}); delete it to download it again\n", .{ path, &hex });
            return error.ChecksumMismatch;
        }
        try out.append(arena, .{ .name = f.name, .data = data });
    }
    return out.items;
}

const NamedFile = struct { name: []const u8, data: []const u8 };

/// `kernel` with its config (found by its magic) set to run `name`, sized as `o` says.
fn patch(arena: std.mem.Allocator, kernel: []const u8, name: []const u8, o: Options) ![]u8 {
    const magic = "FAUXPI-BENCH-CFG";
    const at = std.mem.indexOf(u8, kernel, magic) orelse return error.NoConfigInKernel;
    const out = try arena.dupe(u8, kernel);
    const cfg = out[at + magic.len ..];
    if (name.len >= 32) return error.TestNameTooLong;
    @memset(cfg[0..32], 0);
    @memcpy(cfg[0..name.len], name);
    std.mem.writeInt(u32, cfg[32..36], o.scale, .little);
    std.mem.writeInt(u32, cfg[36..40], o.width, .little);
    std.mem.writeInt(u32, cfg[40..44], o.height, .little);
    return out;
}

/// Writes an SD card image at `path`: config.txt, kernel.img, and `files`; or for Linux, `kernel`
/// is init, in an initramfs, and `files` the kernel and its device tree and overlay.
fn makeImage(arena: std.mem.Allocator, io: std.Io, o: Options, work: []const u8, path: []const u8, kernel: []const u8, files: []const NamedFile) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ o.mkimage, path, "auto" });
    const boot: []const NamedFile = if (o.linux) &.{
        .{ .name = "config.txt", .data = linux_config_txt },
        .{ .name = "cmdline.txt", .data = linux_cmdline_txt },
        .{ .name = "initramfs.cpio", .data = try initramfs(arena, kernel) },
    } else &.{
        .{ .name = "config.txt", .data = config_txt },
        .{ .name = "kernel.img", .data = kernel },
    };
    const all = try std.mem.concat(arena, NamedFile, &.{ boot, files });
    for (all) |f| {
        const flat = try arena.dupe(u8, f.name);
        std.mem.replaceScalar(u8, flat, '/', '-');
        const src = try std.fs.path.join(arena, &.{ work, try std.fmt.allocPrint(arena, "image-{s}", .{flat}) });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = src, .data = f.data });
        try argv.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ f.name, src }));
    }
    const res = try std.process.run(arena, io, .{ .argv = argv.items });
    if (res.term != .exited or res.term.exited != 0) {
        std.debug.print("mkimage failed: {s}\n", .{res.stderr});
        return error.MkimageFailed;
    }
}

/// A test's run: what the guest said, and FauxPi's report.
const Run = struct {
    name: []const u8,
    mode: []const u8,
    /// The host's time from the test's start to its end (the boot not counted), the whole boot, and
    /// from FauxPi starting to the first test (the guest booting).
    wall_ms: f64 = 0,
    boot_ms: f64 = 0,
    to_test_ms: f64 = 0,
    /// The board's own time for it.
    guest_ms: f64 = 0,
    /// The test's numbers (name=value), as it printed them.
    values: []const u8 = "",
    /// FauxPi's `--profile` report (JSON), or empty.
    profile: []const u8 = "",
    err: ?[]const u8 = null,
};

fn now(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn runTest(arena: std.mem.Allocator, io: std.Io, o: Options, cache: []const u8, kernel: []const u8, dtb: []const NamedFile, name: []const u8, mode: []const u8) !Run {
    var run: Run = .{ .name = name, .mode = mode };
    const work = try std.fs.path.join(arena, &.{ cache, "work" });
    try std.Io.Dir.cwd().createDirPath(io, work);
    const image = try std.fs.path.join(arena, &.{ work, "bench.img" });
    const profile_path = try std.fs.path.join(arena, &.{ work, "profile.json" });
    std.Io.Dir.cwd().deleteFile(io, profile_path) catch {};
    try makeImage(arena, io, o, work, image, try patch(arena, kernel, name, o), dtb);

    const size = try std.fmt.allocPrint(arena, "{d}x{d}", .{ o.width, o.height });
    const v3d_mode = if (std.mem.eql(u8, mode, "gpu-fragments")) "gpu_fragments" else mode;
    // FauxPi's own messages go to a file (with --log), or nowhere.
    const stderr_path = if (o.log) |dir| blk: {
        try std.Io.Dir.cwd().createDirPath(io, dir);
        break :blk try std.fmt.allocPrint(arena, "{s}/{s}-{s}.stderr", .{ dir, name, mode });
    } else "/dev/null";
    const stderr_file = try std.Io.Dir.cwd().createFile(io, stderr_path, .{});
    defer stderr_file.close(io);
    const boot_start = now(io);
    var child = try std.process.spawn(io, .{
        .argv = &.{ o.fauxpi, "--headless", "--sd", image, "--model", "zero", "--hdmi-size", size, "--profile", profile_path, "--v3d", v3d_mode },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .{ .file = stderr_file },
    });

    // A boot that runs too long is stopped (FauxPi still writes its report).
    const Watchdog = struct {
        fn watch(io_: std.Io, pid: std.posix.pid_t, seconds: u32, done: *std.atomic.Value(bool)) void {
            var waited: u32 = 0;
            while (waited < seconds * 10 and !done.load(.acquire)) : (waited += 1) {
                io_.sleep(.{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch return;
            }
            if (!done.load(.acquire)) std.posix.kill(pid, .TERM) catch {};
        }
    };
    var done: std.atomic.Value(bool) = .init(false);
    const watchdog = try std.Thread.spawn(.{}, Watchdog.watch, .{ io, child.id.?, o.timeout_s, &done });

    var serial: std.Io.Writer.Allocating = .init(arena);
    var buf: [4096]u8 = undefined;
    var reader = child.stdout.?.reader(io, &buf);
    var begin: ?i96 = null;
    var ended = false;
    while (reader.interface.takeDelimiter('\n') catch null) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        try serial.writer.print("{s}\n", .{line});
        if (std.mem.startsWith(u8, line, "BENCH-BEGIN ")) {
            begin = now(io);
            if (run.to_test_ms == 0) run.to_test_ms = @as(f64, @floatFromInt(begin.? - boot_start)) / 1e6;
        } else if (std.mem.startsWith(u8, line, "BENCH-END ")) {
            const end = now(io);
            ended = true;
            if (begin) |b| run.wall_ms = @as(f64, @floatFromInt(end - b)) / 1e6;
            var fields = std.mem.tokenizeScalar(u8, line["BENCH-END ".len..], ' ');
            _ = fields.next();
            var values: std.ArrayList(u8) = .empty;
            while (fields.next()) |f| {
                const eq = std.mem.indexOfScalar(u8, f, '=') orelse continue;
                if (std.mem.eql(u8, f[0..eq], "guest_us")) {
                    run.guest_ms = @as(f64, @floatFromInt(std.fmt.parseInt(u64, f[eq + 1 ..], 10) catch 0)) / 1e3;
                } else {
                    try values.print(arena, "{s}\"{s}\": {s}", .{ if (values.items.len == 0) "" else ", ", f[0..eq], f[eq + 1 ..] });
                }
            }
            run.values = values.items;
        } else if (std.mem.startsWith(u8, line, "BENCH-ERROR ")) {
            run.err = try arena.dupe(u8, line["BENCH-ERROR ".len..]);
        }
    }
    const term = try child.wait(io);
    run.boot_ms = @as(f64, @floatFromInt(now(io) - boot_start)) / 1e6;
    done.store(true, .release);
    watchdog.join();
    if (!ended and run.err == null) run.err = if (term == .exited) "the test didn't finish" else "FauxPi stopped (timeout?)";
    run.profile = std.Io.Dir.cwd().readFileAlloc(io, profile_path, arena, .limited(1 << 20)) catch "";
    if (o.log) |dir| {
        const p = try std.fmt.allocPrint(arena, "{s}/{s}-{s}.serial", .{ dir, name, mode });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = serial.written() });
    }
    if (run.err) |e| std.debug.print("  {s} ({s}): {s}\n", .{ name, mode, e });
    return run;
}

fn writeJson(w: *std.Io.Writer, o: Options, runs: []const Run) !void {
    try w.print("{{\n  \"scale\": {d},\n  \"size\": \"{d}x{d}\",\n  \"runs\": [", .{ o.scale, o.width, o.height });
    for (runs, 0..) |r, i| {
        try w.print("{s}\n    {{\n      \"test\": \"{s}\",\n      \"v3d\": \"{s}\",\n      \"wall_ms\": {d:.3},\n      \"guest_ms\": {d:.3},\n      \"boot_ms\": {d:.3},\n      \"to_test_ms\": {d:.3},\n      \"values\": {{ {s} }}", .{ if (i == 0) "" else ",", r.name, r.mode, r.wall_ms, r.guest_ms, r.boot_ms, r.to_test_ms, r.values });
        if (r.err) |e| try w.print(",\n      \"error\": \"{f}\"", .{std.zig.fmtString(e)});
        if (r.profile.len > 0) {
            try w.writeAll(",\n      \"fauxpi\": ");
            var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, r.profile, "\n"), '\n');
            var first = true;
            while (lines.next()) |l| {
                if (!first) try w.writeAll("\n      ");
                try w.writeAll(l);
                first = false;
            }
        }
        try w.writeAll("\n    }");
    }
    try w.writeAll("\n  ]\n}\n");
}

/// A table of the runs on stderr: each test's times, and FauxPi's biggest stages.
fn printTable(runs: []const Run) void {
    std.debug.print("\n{s:<14} {s:<13} {s:>10} {s:>10}  {s}\n", .{ "test", "v3d", "wall ms", "guest ms", "FauxPi's biggest stages (ms)" });
    for (runs) |r| {
        std.debug.print("{s:<14} {s:<13} {d:>10.1} {d:>10.1}  ", .{ r.name, r.mode, r.wall_ms, r.guest_ms });
        if (r.err) |e| {
            std.debug.print("error: {s}\n", .{e});
            continue;
        }
        printStages(r.profile);
        std.debug.print("\n", .{});
    }
}

/// The three stages that took longest, from a FauxPi report.
fn printStages(profile: []const u8) void {
    var gpa_buf: [64 * 1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&gpa_buf);
    const parsed = std.json.parseFromSlice(std.json.Value, fba.allocator(), profile, .{}) catch return;
    const stages = (parsed.value.object.get("stages") orelse return).object;
    var top: [3]struct { name: []const u8 = "", ms: f64 = 0 } = @splat(.{});
    var it = stages.iterator();
    while (it.next()) |e| {
        const ms = switch (e.value_ptr.object.get("ms") orelse continue) {
            .float => |f| f,
            .integer => |n| @as(f64, @floatFromInt(n)),
            else => continue,
        };
        for (&top, 0..) |*t, k| {
            if (ms > t.ms) {
                var j: usize = top.len - 1;
                while (j > k) : (j -= 1) top[j] = top[j - 1];
                t.* = .{ .name = e.key_ptr.*, .ms = ms };
                break;
            }
        }
    }
    for (top) |t| {
        if (t.ms >= 0.05) std.debug.print("{s} {d:.1}  ", .{ t.name, t.ms });
    }
}

test "the config is patched where its magic is" {
    const kernel = "abcFAUXPI-BENCH-CFG";
    var padded: [19 + 48]u8 = @splat(0xaa);
    @memcpy(padded[0..kernel.len], kernel);
    const out = try patch(std.testing.allocator, &padded, "v3d_fill", .{ .scale = 50, .width = 640, .height = 480 });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("v3d_fill", std.mem.sliceTo(out[19..51], 0));
    try std.testing.expectEqual(@as(u32, 50), std.mem.readInt(u32, out[51..55], .little));
    try std.testing.expectEqual(@as(u32, 480), std.mem.readInt(u32, out[59..63], .little));
}
