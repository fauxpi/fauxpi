const std = @import("std");
const linux = std.os.linux;

pub const fat32 = @import("boot/fat32.zig");
pub const fdt = @import("boot/fdt.zig");
pub const loader = @import("boot/loader.zig");

pub const mmu = @import("cpu/mmu.zig");
pub const vfp = @import("cpu/vfp.zig");
pub const decoder = @import("cpu/decoder.zig");
pub const arm1176 = @import("cpu/arm1176.zig");

pub const intc = @import("soc/intc.zig");
pub const timer = @import("soc/timer.zig");
pub const mailbox = @import("soc/mailbox.zig");
pub const cprman = @import("soc/cprman.zig");
pub const pm = @import("soc/pm.zig");
pub const gpio = @import("soc/gpio.zig");
pub const uart = @import("soc/uart.zig");
pub const dma = @import("soc/dma.zig");
pub const sdhost = @import("soc/sdhost.zig");
pub const i2c = @import("soc/i2c.zig");
pub const bcm2835 = @import("soc/bcm2835.zig");

pub const hid = @import("usb/hid.zig");
pub const dwc2 = @import("usb/dwc2.zig");

pub const vc4_format = @import("vc4/format.zig");
pub const vc4_texture = @import("vc4/texture.zig");
pub const vc4_qpu = @import("vc4/qpu.zig");
pub const vc4_qpu_sim = @import("vc4/qpu_sim.zig");
pub const vc4_qpu_to_glsl = @import("vc4/qpu_to_glsl.zig");
pub const vc4_gl_renderer = @import("vc4/gl_renderer.zig");
pub const vc4_v3d = @import("vc4/v3d.zig");
pub const vc4_hvs = @import("vc4/hvs.zig");
pub const vc4_pv = @import("vc4/pixelvalve.zig");
pub const vc4_hdmi = @import("vc4/hdmi.zig");

pub const wl_protocol = @import("wayland/protocol.zig");
pub const wl_client = @import("wayland/client.zig");
pub const font = @import("font/font.zig");
pub const ui_board = @import("ui/board.zig");
pub const ui_gpio_model = @import("ui/gpio_model.zig");
pub const ui_canvas = @import("ui/canvas.zig");
pub const ui_board_sheet = @import("ui/board_sheet.zig");
pub const window = @import("app/window.zig");

const Bcm2835 = bcm2835.Bcm2835;
const Cpu = arm1176.Arm1176(Bcm2835);

const CliOptions = struct {
    sd_path: ?[]const u8 = null,
    kernel_path: ?[]const u8 = null,
    dtb_path: ?[]const u8 = null,
    initramfs_path: ?[]const u8 = null,
    cmdline: ?[]const u8 = null,
    width: u16 = 1280,
    height: u16 = 720,
    headless: bool = false,
    max_steps: u64 = 0,
};

fn readFileLinux(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const fd_rc = linux.openat(linux.AT.FDCWD, path_buf[0..path.len :0], .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(fd_rc) != .SUCCESS) return error.FileOpenFailed;
    const fd: linux.fd_t = @intCast(fd_rc);
    defer _ = linux.close(fd);

    const end_rc = linux.lseek(fd, 0, linux.SEEK.END);
    if (linux.errno(end_rc) != .SUCCESS) return error.FileSeekFailed;
    const file_size: usize = @intCast(end_rc);
    _ = linux.lseek(fd, 0, linux.SEEK.SET);

    const buf = try allocator.alloc(u8, file_size);
    errdefer allocator.free(buf);

    var off: usize = 0;
    while (off < file_size) {
        const rc = linux.read(fd, buf[off..].ptr, file_size - off);
        if (linux.errno(rc) != .SUCCESS) return error.FileReadFailed;
        if (rc == 0) break;
        off += rc;
    }
    return buf[0..off];
}

fn monotonicNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn printUsage() void {
    const msg =
        \\Usage: fauxpi [options]
        \\
        \\Options:
        \\  --sd <path>         Boot from a Raspberry Pi SD card image (FAT32 + rootfs)
        \\  --kernel <path>     Boot kernel.img / zImage directly
        \\  --dtb <path>        Device Tree Blob (.dtb) when using --kernel
        \\  --initramfs <path>  Optional initramfs.cpio when using --kernel
        \\  --cmdline <string>  Additional kernel command line parameters
        \\  --width <px>        HDMI output width (default: 1280)
        \\  --height <px>       HDMI output height (default: 720)
        \\  --headless          Run without opening a Wayland window
        \\  --max-steps <n>     Stop simulation after <n> ARM instructions
        \\  --help              Show this help message
        \\
    ;
    _ = linux.write(linux.STDOUT_FILENO, msg.ptr, msg.len);
}

pub fn main(init: std.process.Init.Minimal) u8 {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var opts: CliOptions = .{};
    var args = init.args.iterate();
    _ = args.next(); // program name

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--sd")) {
            opts.sd_path = args.next() orelse {
                printUsage();
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--kernel")) {
            opts.kernel_path = args.next() orelse {
                printUsage();
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--dtb")) {
            opts.dtb_path = args.next() orelse {
                printUsage();
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--initramfs")) {
            opts.initramfs_path = args.next() orelse {
                printUsage();
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--cmdline")) {
            opts.cmdline = args.next() orelse {
                printUsage();
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--width")) {
            const s = args.next() orelse return 1;
            opts.width = std.fmt.parseInt(u16, s, 10) catch return 1;
        } else if (std.mem.eql(u8, arg, "--height")) {
            const s = args.next() orelse return 1;
            opts.height = std.fmt.parseInt(u16, s, 10) catch return 1;
        } else if (std.mem.eql(u8, arg, "--headless")) {
            opts.headless = true;
        } else if (std.mem.eql(u8, arg, "--max-steps")) {
            const s = args.next() orelse return 1;
            opts.max_steps = std.fmt.parseInt(u64, s, 10) catch return 1;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return 0;
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            printUsage();
            return 1;
        }
    }

    if (opts.sd_path == null and opts.kernel_path == null) {
        printUsage();
        return 1;
    }

    runSimulator(gpa, init.environ, opts) catch |err| {
        std.debug.print("fauxpi error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn runSimulator(gpa: std.mem.Allocator, environ: std.process.Environ, opts: CliOptions) !void {
    const ram = try gpa.alloc(u8, Bcm2835.RAM_SIZE);
    defer gpa.free(ram);
    @memset(ram, 0);

    var soc = Bcm2835.init(ram, opts.width, opts.height);

    var sd_image_buf: ?[]u8 = null;
    defer if (sd_image_buf) |b| gpa.free(b);

    const boot_res = if (opts.sd_path) |sd_path| blk: {
        const img = try readFileLinux(gpa, sd_path);
        sd_image_buf = img;
        soc.sdhost.attachMutableSlice(img);
        const k_override = if (opts.kernel_path) |kp| try readFileLinux(gpa, kp) else null;
        defer if (k_override) |ko| gpa.free(ko);
        break :blk try loader.loadFromSdImage(gpa, ram, img, opts.cmdline, k_override);
    } else blk: {
        const k_path = opts.kernel_path orelse return error.MissingKernel;
        const d_path = opts.dtb_path orelse return error.MissingDtb;
        const k_bytes = try readFileLinux(gpa, k_path);
        defer gpa.free(k_bytes);
        const d_bytes = try readFileLinux(gpa, d_path);
        defer gpa.free(d_bytes);
        const rd_bytes = if (opts.initramfs_path) |rd_p| try readFileLinux(gpa, rd_p) else null;
        defer if (rd_bytes) |rd| gpa.free(rd);

        const cmdline = opts.cmdline orelse "console=ttyAMA0,115200 earlycon=pl011,0x20201000";
        break :blk try loader.loadDirect(gpa, ram, k_bytes, d_bytes, rd_bytes, cmdline, true);
    };

    var cpu: Cpu = .{};
    cpu.initReset(boot_res.entry_pc, boot_res.r0, boot_res.r1, boot_res.r2);

    var wl_win: ?*window.WaylandWindow = null;
    defer if (wl_win) |w| w.destroy();

    if (!opts.headless) {
        wl_win = try window.WaylandWindow.create(gpa, environ, opts.width, opts.height, &soc.usb.hid, &soc.gpio);
        const disp_pixels = wl_win.?.displayPixels();
        @memset(disp_pixels, 0xFF101418);
        wl_win.?.compositeUi();
        try wl_win.?.present();
    }

    const vblank_interval_ns: u64 = 16_666_667; // 60 Hz
    var last_vblank_ns: u64 = monotonicNs();
    var last_guest_vblank_us: u64 = 0;
    var active_us_accum: u64 = 0;
    var idle_us_accum: u64 = 0;

    while (true) {
        if (wl_win) |w| {
            if (w.closed) break;
        }
        if (soc.pm.reboot_requested) break;
        if (opts.max_steps != 0 and cpu.cycles >= opts.max_steps) break;

        const batch: usize = if (opts.max_steps != 0)
            @intCast(@min(@as(u64, 16384), opts.max_steps - cpu.cycles))
        else
            16384;

        const ran = cpu.runSteps(&soc, batch);

        // Advance 1 MHz system timer proportionally to instructions executed (~4 instructions per us at 1 GHz -> min 1 us)
        const timer_ticks: u64 = if (ran > 0) @max(ran / 16, 1) else 1;
        active_us_accum += timer_ticks;
        soc.timer.advance(timer_ticks, &soc.intc);
        soc.updateIrqs();

        if (cpu.mmu.halted_wfi and !soc.hasPendingIrq() and !soc.hasPendingFiq()) {
            // Fast-forward timer to next compare match (capped at 2000 us so vblank/UI stays responsive)
            const jump = @max(soc.timer.usUntilNextMatch(2000), 1);
            idle_us_accum += jump;
            soc.timer.advance(jump, &soc.intc);
            soc.updateIrqs();
            cpu.mmu.halted_wfi = false;
        }

        if (soc.timer.counter -| last_guest_vblank_us >= 16_667) {
            last_guest_vblank_us = soc.timer.counter;
            soc.triggerVblank();
        }

        const now_ns = monotonicNs();
        if (now_ns -| last_vblank_ns >= vblank_interval_ns) {
            last_vblank_ns = now_ns;
            soc.triggerVblank();

            if (wl_win) |w| {
                const total_us = active_us_accum + idle_us_accum;
                if (total_us > 0) {
                    const busy = (@as(f32, @floatFromInt(active_us_accum)) * 100.0) / @as(f32, @floatFromInt(total_us));
                    w.status.cpu_busy_percent = w.status.cpu_busy_percent * 0.7 + busy * 0.3;
                    w.status.temperature_c = 38.0 + (w.status.cpu_busy_percent * 0.14);
                }
                active_us_accum = 0;
                idle_us_accum = 0;

                soc.setHdmiConnected(w.status.hdmi_connected);
                const disp_pixels = w.displayPixels();
                w.status.hdmi_active = soc.renderDisplayFrame(disp_pixels, opts.width, opts.height);
                w.compositeUi();
                try w.present();
            }
        }
    }

    if (opts.headless) {
        std.debug.print(
            "\n[fauxpi] Stopped at cycle={d} pc=0x{x:0>8} lr=0x{x:0>8} sp=0x{x:0>8} cpsr=0x{x:0>8} sctlr=0x{x:0>8} ttbr0=0x{x:0>8} timer_us={d} uart_tx={d}\n",
            .{
                cpu.cycles,
                cpu.r[15],
                cpu.r[14],
                cpu.r[13],
                cpu.cpsr,
                cpu.mmu.sctlr,
                cpu.mmu.ttbr0,
                soc.timer.counter,
                soc.uart0.tx_log_len,
            },
        );
        const test_fb = try gpa.alloc(u32, @as(usize, opts.width) * @as(usize, opts.height));
        defer gpa.free(test_fb);
        const active_disp = soc.renderDisplayFrame(test_fb, opts.width, opts.height);
        var non_black: usize = 0;
        for (test_fb) |px| {
            if ((px & 0x00FF_FFFF) != 0) non_black += 1;
        }
        std.debug.print(
            "  hvs displist=[0x{x},0x{x},0x{x}] active={} non_black_pixels={d}/{d}\n",
            .{
                soc.hvs.displist[0],
                soc.hvs.displist[1],
                soc.hvs.displist[2],
                active_disp,
                non_black,
                test_fb.len,
            },
        );
    }
}

test {
    std.testing.refAllDecls(@This());
}
