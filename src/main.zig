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
pub const local_intc = @import("soc/local_intc.zig");
pub const timer = @import("soc/timer.zig");
pub const mailbox = @import("soc/mailbox.zig");
pub const cprman = @import("soc/cprman.zig");
pub const pm = @import("soc/pm.zig");
pub const gpio = @import("soc/gpio.zig");
pub const uart = @import("soc/uart.zig");
pub const dma = @import("soc/dma.zig");
pub const qcow2 = @import("soc/qcow2.zig");
pub const sdhost = @import("soc/sdhost.zig");
pub const cyw43430 = @import("soc/cyw43430.zig");
pub const i2c = @import("soc/i2c.zig");
pub const soc_audio = @import("soc/audio.zig");
pub const bcm2835 = @import("soc/bcm2835.zig");

pub const hid = @import("usb/hid.zig");
pub const usb_net = @import("usb/net.zig");
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
pub const app_audio = @import("app/audio.zig");

const Bcm2835 = bcm2835.Bcm2835;
const Cpu = arm1176.Arm1176(Bcm2835);

const CliOptions = struct {
    sd_path: ?[]const u8 = null,
    kernel_path: ?[]const u8 = null,
    dtb_path: ?[]const u8 = null,
    initramfs_path: ?[]const u8 = null,
    cmdline: ?[]const u8 = null,
    board_model: ?ui_board_sheet.BoardModel = null,
    width: u16 = 1280,
    height: u16 = 720,
    power: bool = false,
    headless: bool = false,
    max_steps: u64 = 0,
};

fn readFileLinux(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return readFileWithMinSizeLinux(allocator, path, 0);
}

fn readSdImageLinux(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    // Ensure simulated SD card is at least 256 MiB so guest OSes (like Dazzle) have room
    // to grow the boot partition and format a /data partition.
    return readFileWithMinSizeLinux(allocator, path, 256 * 1024 * 1024);
}

fn readFileWithMinSizeLinux(allocator: std.mem.Allocator, path: []const u8, min_size: usize) ![]u8 {
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

    const alloc_size = @max(file_size, min_size);
    const buf = try allocator.alloc(u8, alloc_size);
    errdefer allocator.free(buf);

    var off: usize = 0;
    while (off < file_size) {
        const rc = linux.read(fd, buf[off..].ptr, file_size - off);
        if (linux.errno(rc) != .SUCCESS) return error.FileReadFailed;
        if (rc == 0) break;
        off += rc;
    }
    if (alloc_size > off) {
        @memset(buf[off..alloc_size], 0);
    }
    return buf[0..alloc_size];
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
        \\  --sd <path>         Insert a Raspberry Pi SD card image (FAT32 + rootfs)
        \\  --power             Start with the 5V power supply connected
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
        } else if (std.mem.eql(u8, arg, "--power")) {
            opts.power = true;
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
        } else if (std.mem.eql(u8, arg, "--model")) {
            const m = args.next() orelse {
                printUsage();
                return 1;
            };
            if (std.mem.eql(u8, m, "zero") or std.mem.eql(u8, m, "pi_zero")) {
                opts.board_model = .pi_zero;
            } else if (std.mem.eql(u8, m, "zero-w") or std.mem.eql(u8, m, "pi_zero_w")) {
                opts.board_model = .pi_zero_w;
            } else if (std.mem.eql(u8, m, "zero-2-w") or std.mem.eql(u8, m, "pi_zero_2_w")) {
                opts.board_model = .pi_zero_2_w;
            } else if (std.mem.eql(u8, m, "1a+") or std.mem.eql(u8, m, "pi_1_a_plus")) {
                opts.board_model = .pi_1_a_plus;
            } else if (std.mem.eql(u8, m, "1b+") or std.mem.eql(u8, m, "pi_1_b_plus")) {
                opts.board_model = .pi_1_b_plus;
            } else if (std.mem.eql(u8, m, "3a+") or std.mem.eql(u8, m, "pi_3_a_plus")) {
                opts.board_model = .pi_3_a_plus;
            } else if (std.mem.eql(u8, m, "3b+") or std.mem.eql(u8, m, "pi_3_b_plus")) {
                opts.board_model = .pi_3_b_plus;
            } else {
                std.debug.print("Unknown model: {s} (expected zero, zero-w, zero-2-w, 1a+, 1b+, 3a+, or 3b+)\n", .{m});
                return 1;
            }
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

    if (opts.headless and opts.sd_path == null and opts.kernel_path == null) {
        printUsage();
        return 1;
    }

    runSimulator(gpa, init.environ, opts) catch |err| {
        std.debug.print("fauxpi error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn loadGuestBoot(
    gpa: std.mem.Allocator,
    opts: CliOptions,
    ram: []u8,
    soc: *Bcm2835,
    sd_qcow2: ?*qcow2.Qcow2Disk,
    sd_image_buf: ?[]u8,
    board_model: ui_board_sheet.BoardModel,
    board_serial: u64,
    mac_address: [6]u8,
    wifi_mac_address: [6]u8,
) !loader.BootResult {
    const saved_hdr_ext_mask = soc.gpio.ext_mask & gpio.Gpio.HEADER_PIN_MASK;
    const saved_hdr_ext_level = soc.gpio.ext_level & gpio.Gpio.HEADER_PIN_MASK;
    soc.usb.hid.net.deinit();
    @memset(ram, 0);
    soc.* = Bcm2835.init(ram, opts.width, opts.height);
    soc.gpio.ext_mask = (soc.gpio.ext_mask & ~gpio.Gpio.HEADER_PIN_MASK) | saved_hdr_ext_mask;
    soc.gpio.ext_level = (soc.gpio.ext_level & ~gpio.Gpio.HEADER_PIN_MASK) | saved_hdr_ext_level;
    soc.is_bcm2837 = board_model.isBcm2837();
    soc.setHdmiConnected(true);
    soc.mailbox.board_revision = board_model.boardRevision();
    soc.mailbox.board_serial = board_serial;
    soc.mailbox.mac_address = if (board_model.hasWireless()) wifi_mac_address else mac_address;
    soc.usb.hid.setHubKind(hid.HubKind.fromModel(board_model.dtModel()));
    soc.usb.hid.net.guest_mac = mac_address;
    soc.sdhci.wireless_enabled = board_model.hasWireless();
    soc.sdhci.wifi.mac_address = wifi_mac_address;

    const boot_res = if (sd_qcow2) |disk| blk: {
        soc.sdhost.attachQcow2(disk);
        const boot_vol = try disk.readBootVolumeAlloc(gpa);
        defer gpa.free(boot_vol);
        const k_override = if (opts.kernel_path) |kp| try readFileLinux(gpa, kp) else null;
        defer if (k_override) |ko| gpa.free(ko);
        break :blk try loader.loadFromSdImageForModel(gpa, ram, boot_vol, board_model, opts.cmdline, k_override);
    } else if (sd_image_buf) |img| blk: {
        soc.sdhost.attachMutableSlice(img);
        const k_override = if (opts.kernel_path) |kp| try readFileLinux(gpa, kp) else null;
        defer if (k_override) |ko| gpa.free(ko);
        break :blk try loader.loadFromSdImageForModel(gpa, ram, img, board_model, opts.cmdline, k_override);
    } else blk: {
        const k_path = opts.kernel_path orelse return error.MissingKernel;
        const d_path = opts.dtb_path orelse return error.MissingDtb;
        const k_bytes = try readFileLinux(gpa, k_path);
        defer gpa.free(k_bytes);
        const d_bytes = try readFileLinux(gpa, d_path);
        defer gpa.free(d_bytes);
        const rd_bytes = if (opts.initramfs_path) |rd_p| try readFileLinux(gpa, rd_p) else null;
        defer if (rd_bytes) |rd| gpa.free(rd);

        const default_cmdline = if (board_model.isBcm2837())
            "console=ttyAMA0,115200 earlycon=pl011,0x3f201000"
        else
            "console=ttyAMA0,115200 earlycon=pl011,0x20201000";
        const cmdline = opts.cmdline orelse default_cmdline;
        break :blk try loader.loadDirect(gpa, ram, k_bytes, d_bytes, rd_bytes, cmdline, true);
    };

    const wifi_mac_opt: ?[6]u8 = if (board_model.hasWireless()) wifi_mac_address else null;
    _ = try loader.applyBoardConfigToRamDtb(
        gpa,
        ram,
        boot_res.dtb_size,
        board_model.dtModel(),
        board_model.boardRevision(),
        board_serial,
        wifi_mac_opt,
    );
    return boot_res;
}

fn resetCpusForBoard(
    cpus: *[4]Cpu,
    num_cores: *usize,
    board_model: ui_board_sheet.BoardModel,
    boot_res: loader.BootResult,
) void {
    const is_a53 = board_model.isBcm2837() or boot_res.is_aarch64;
    cpus[0] = .{};
    if (boot_res.is_aarch64) {
        cpus[0].initReset64(boot_res.entry_pc, boot_res.r0);
    } else {
        cpus[0].initReset(boot_res.entry_pc, boot_res.r0, boot_res.r1, boot_res.r2);
        cpus[0].mmu.is_cortex_a53 = is_a53;
        cpus[0].vfp.is_vfpv4 = is_a53;
    }
    if (is_a53) {
        num_cores.* = 4;
        for (1..4) |i| {
            cpus[i] = .{};
            if (boot_res.is_aarch64) {
                cpus[i].initSecondaryCore64(@intCast(i));
            } else {
                cpus[i].initSecondaryCore(@intCast(i));
            }
        }
    } else {
        num_cores.* = 1;
    }
}

fn syncWindowPeripheralsToSoc(w: *const window.WaylandWindow, soc: *Bcm2835) void {
    soc.setHdmiConnected(w.status.hdmi_connected);
    soc.setAudioConnected(w.status.audio_connected);
    soc.usb.hid.setHubKind(hid.HubKind.fromModel(w.status.model));
    soc.usb.hid.hub_connected = w.status.usb_hub_connected;
    soc.usb.hid.keyboard_connected = w.status.usb_keyboard_connected;
    soc.usb.hid.mouse_connected = w.status.usb_mouse_connected;
    soc.usb.hid.ethernet_connected = w.status.ethernet_connected;
    soc.usb.hid.net.dhcp_enabled = w.status.dhcp_enabled;
}

fn runSimulator(gpa: std.mem.Allocator, environ: std.process.Environ, opts: CliOptions) !void {
    const ram = try gpa.alloc(u8, Bcm2835.RAM_SIZE);
    defer gpa.free(ram);
    @memset(ram, 0);

    var headless_qcow2: ?qcow2.Qcow2Disk = null;
    defer if (headless_qcow2) |*d| d.deinit();
    var sd_image_buf: ?[]u8 = null;
    defer if (sd_image_buf) |b| gpa.free(b);
    if (opts.sd_path) |sd_path| {
        if (qcow2.Qcow2Disk.openExistingFile(gpa, sd_path)) |disk| {
            headless_qcow2 = disk;
        } else |_| {
            sd_image_buf = try readSdImageLinux(gpa, sd_path);
        }
    }

    var soc = Bcm2835.init(ram, opts.width, opts.height);
    defer soc.usb.hid.net.deinit();
    var cpus: [4]Cpu = @splat(.{});
    var num_cores: usize = 1;
    var guest_booted = false;

    const initial_power = opts.power or opts.headless;

    var wl_win: ?*window.WaylandWindow = null;
    defer if (wl_win) |w| w.destroy();

    if (!opts.headless) {
        wl_win = try window.WaylandWindow.create(gpa, environ, opts.width, opts.height, &soc.usb.hid, &soc.gpio);
        wl_win.?.status.power_connected = opts.power;
        if (opts.sd_path) |sd_path| {
            const fsize = try qcow2.Qcow2Disk.getFileSizeLinux(sd_path);
            const card_sz = ui_board_sheet.SdCardSize.smallestFitting(@max(fsize, 256 * 1024 * 1024)) orelse .gb_32;
            _ = try wl_win.?.ui.addSdCardFromFile(sd_path, card_sz);
            wl_win.?.status.sd_connected = true;
            wl_win.?.ui.saveSettings(wl_win.?.status) catch {};
        }
        if (opts.board_model) |bm| {
            wl_win.?.setBoardModel(bm);
        }
    }

    const initial_sd = if (wl_win) |w|
        (w.status.sd_connected and (w.ui.activeSdCard() != null or sd_image_buf != null or headless_qcow2 != null))
    else
        (sd_image_buf != null or headless_qcow2 != null);

    if (initial_power and (initial_sd or opts.kernel_path != null)) {
        const bm = if (wl_win) |w| w.status.board_model else (opts.board_model orelse .pi_zero);
        const serial = if (wl_win) |w| w.status.serial_u64 else 0x00000000fa000001;
        const mac = if (wl_win) |w| w.status.mac_address else [6]u8{ 0xb8, 0x27, 0xeb, 0x12, 0x34, 0x56 };
        const wifi_mac = if (wl_win) |w| w.status.wifi_mac_address else [6]u8{ 0xb8, 0x27, 0xeb, 0x47, 0x61, 0x03 };
        const active_qcow2: ?*qcow2.Qcow2Disk = if (wl_win) |w|
            (if (initial_sd and w.ui.activeSdCard() != null) &w.ui.activeSdCard().?.disk else if (initial_sd and headless_qcow2 != null) &(headless_qcow2.?) else null)
        else if (initial_sd and headless_qcow2 != null)
            &(headless_qcow2.?)
        else
            null;
        const boot_res = try loadGuestBoot(gpa, opts, ram, &soc, active_qcow2, if (initial_sd) sd_image_buf else null, bm, serial, mac, wifi_mac);
        if (wl_win) |w| syncWindowPeripheralsToSoc(w, &soc);
        resetCpusForBoard(&cpus, &num_cores, bm, boot_res);
        guest_booted = true;
    }

    const host_audio: ?*app_audio.HostAudioOutput = if (!opts.headless)
        try app_audio.HostAudioOutput.create(gpa, &soc.audio_fifo)
    else
        null;
    defer if (host_audio) |ha| ha.destroy(gpa);
    if (host_audio) |ha| ha.setPaused(!guest_booted);

    var idle_rendered_power: ?bool = null;
    var idle_rendered_booted: ?bool = null;

    if (wl_win) |w| {
        const disp_pixels = w.displayPixels();
        @memset(disp_pixels, 0xFF101418);
        idle_rendered_power = w.status.power_connected;
        idle_rendered_booted = guest_booted;
        w.compositeUi();
        try w.present();
    }

    const vblank_interval_ns: u64 = 16_666_667; // 60 Hz
    var last_vblank_ns: u64 = monotonicNs();
    var last_guest_vblank_us: u64 = 0;
    var active_us_accum: u64 = 0;
    var idle_us_accum: u64 = 0;

    while (true) {
        if (wl_win) |w| {
            if (w.closed) break;

            if (w.sd_disconnected) {
                w.sd_disconnected = false;
                soc.sdhost.detach();
            }

            if (w.sd_reconnected) {
                w.sd_reconnected = false;
                if (w.ui.activeSdCard()) |card| {
                    soc.sdhost.attachQcow2(&card.disk);
                } else if (sd_image_buf) |img| {
                    soc.sdhost.attachMutableSlice(img);
                }
            }

            if (w.sd_image_chosen) {
                w.sd_image_chosen = false;
                if (w.ui.activeSdCard()) |card| {
                    if (w.status.sd_connected) {
                        soc.sdhost.attachQcow2(&card.disk);
                    }
                }
            }

            const has_sd_media = (w.ui.activeSdCard() != null) or (sd_image_buf != null);
            const has_boot_media = (w.status.sd_connected and has_sd_media) or opts.kernel_path != null;
            if (!w.status.power_connected) {
                guest_booted = false;
            } else if (w.power_reconnected or (!guest_booted and has_boot_media)) {
                w.power_reconnected = false;
                const active_qcow2: ?*qcow2.Qcow2Disk = if (w.status.sd_connected and w.ui.activeSdCard() != null) &w.ui.activeSdCard().?.disk else null;
                const active_sd = if (w.status.sd_connected) sd_image_buf else null;
                if (active_qcow2 != null or active_sd != null or opts.kernel_path != null) {
                    if (host_audio) |ha| ha.setPaused(true);
                    if (loadGuestBoot(gpa, opts, ram, &soc, active_qcow2, active_sd, w.status.board_model, w.status.serial_u64, w.status.mac_address, w.status.wifi_mac_address)) |reboot_res| {
                        syncWindowPeripheralsToSoc(w, &soc);
                        resetCpusForBoard(&cpus, &num_cores, w.status.board_model, reboot_res);
                        guest_booted = true;
                        last_guest_vblank_us = 0;
                        active_us_accum = 0;
                        idle_us_accum = 0;
                        if (host_audio) |ha| ha.setPaused(false);
                    } else |err| {
                        std.debug.print("fauxpi: failed to boot SD image: {s}\n", .{@errorName(err)});
                        guest_booted = false;
                    }
                } else {
                    guest_booted = false;
                }
            }

            soc.usb.hid.net.dhcp_enabled = w.status.dhcp_enabled;

            if (!w.status.power_connected or !guest_booted) {
                if (host_audio) |ha| ha.setPaused(true);
                const state_changed = (idle_rendered_power != w.status.power_connected) or
                    (idle_rendered_booted != guest_booted);
                const needs_redraw = w.ui_dirty or
                    soc.gpio.takeUiDirty() or
                    state_changed or
                    (w.pending_scale != w.scale);

                if (needs_redraw) {
                    const now_ns = monotonicNs();
                    const elapsed_ns = now_ns -| last_vblank_ns;
                    if (state_changed or elapsed_ns >= vblank_interval_ns) {
                        last_vblank_ns = now_ns;
                        w.status.cpu_busy_percent = 0.0;
                        w.status.temperature_c = 25.0;
                        w.status.hdmi_active = false;
                        w.status.act_led_on = false;
                        w.status.pwr_led_on = w.status.power_connected;
                        idle_rendered_power = w.status.power_connected;
                        idle_rendered_booted = guest_booted;
                        w.compositeUi();
                        try w.present();
                    } else {
                        const wait_ms: i32 = @intCast(@max((vblank_interval_ns - elapsed_ns + 999_999) / 1_000_000, 1));
                        try w.waitEvents(wait_ms);
                    }
                } else {
                    try w.waitEvents(-1);
                }
                continue;
            }
            idle_rendered_booted = null;
        }
        if (soc.pm.reboot_requested) break;
        if (opts.max_steps != 0 and cpus[0].cycles >= opts.max_steps) break;

        // Check secondary core wakeup via bcm2836-l1-intc mailbox 3 or spin-table at 0xd8..0xf0
        for (1..num_cores) |i| {
            if (cpus[i].halted_spin) {
                if (soc.local_intc.takeCoreWakeup(@intCast(i))) |wakeup_addr| {
                    cpus[i].halted_spin = false;
                    cpus[i].mmu.halted_wfi = false;
                    cpus[i].pc64 = wakeup_addr;
                    cpus[i].r[15] = wakeup_addr;
                } else {
                    const spin_off: usize = 0xd8 + i * 8;
                    if (cpus[i].is_aarch64) {
                        const spin_addr64 = std.mem.readInt(u64, ram[spin_off..][0..8], .little);
                        if (spin_addr64 != 0) {
                            cpus[i].halted_spin = false;
                            cpus[i].mmu.halted_wfi = false;
                            cpus[i].pc64 = spin_addr64;
                            cpus[i].r[15] = @truncate(spin_addr64);
                        }
                    } else {
                        const spin_addr = std.mem.readInt(u32, ram[spin_off..][0..4], .little);
                        if (spin_addr != 0) {
                            cpus[i].halted_spin = false;
                            cpus[i].mmu.halted_wfi = false;
                            cpus[i].r[15] = spin_addr;
                        }
                    }
                }
            }
        }

        const max_slice: u64 = if (num_cores > 1) 4096 else 65536;
        const batch: usize = if (opts.max_steps != 0)
            @intCast(@min(max_slice, opts.max_steps - cpus[0].cycles))
        else
            @intCast(max_slice);

        var total_ran: usize = 0;
        var active_cores: usize = 0;
        for (0..num_cores) |i| {
            if (cpus[i].halted_spin) continue;
            active_cores += 1;
            soc.local_intc.core_timer_lines[i] = cpus[i].mmu.syncGenericTimer(soc.timer.counter);
            const ran = cpus[i].runSteps(&soc, batch);
            total_ran += ran;
            soc.local_intc.core_timer_lines[i] = cpus[i].mmu.syncGenericTimer(soc.timer.counter);
        }

        // Advance 1 MHz system timer proportionally to instructions executed (~256 instructions per us)
        const ran_per_core = if (active_cores > 0) total_ran / active_cores else 0;
        const timer_ticks: u64 = if (ran_per_core > 0) @max(ran_per_core / 256, 1) else 1;
        active_us_accum += timer_ticks;
        soc.timer.advance(timer_ticks, &soc.intc);
        soc.advanceAudio(timer_ticks);
        for (0..num_cores) |i| {
            if (!cpus[i].halted_spin) {
                soc.local_intc.core_timer_lines[i] = cpus[i].mmu.syncGenericTimer(soc.timer.counter);
            }
        }
        soc.updateIrqs();

        const guest_ready_for_realtime_sleep = (wl_win != null) and
            (soc.hvs.isActive() or soc.mailbox.fb_allocated) and
            soc.usb.hid.allConnectedDevicesConfigured();

        var all_wfi = true;
        for (0..num_cores) |i| {
            if (cpus[i].halted_spin) continue;
            const cid: u2 = @intCast(i);
            if (!cpus[i].mmu.halted_wfi or soc.hasPendingIrqForCore(cid) or soc.hasPendingFiqForCore(cid)) {
                all_wfi = false;
                break;
            }
        }

        if (all_wfi) {
            soc.usb.pollNetwork(soc.ram);
            soc.usb.wakeIfPending();
            soc.updateIrqs();
            for (0..num_cores) |i| {
                if (cpus[i].halted_spin) continue;
                const cid: u2 = @intCast(i);
                if (!cpus[i].mmu.halted_wfi or soc.hasPendingIrqForCore(cid) or soc.hasPendingFiqForCore(cid)) {
                    all_wfi = false;
                    break;
                }
            }
        }

        if (all_wfi) {
            if (guest_ready_for_realtime_sleep) {
                const w = wl_win.?;
                var timer_wait_us = soc.timer.usUntilNextMatch(1_000_000);
                for (0..num_cores) |i| {
                    if (!cpus[i].halted_spin) {
                        timer_wait_us = @min(timer_wait_us, cpus[i].mmu.usUntilNextGenericTimer(1_000_000));
                    }
                }
                timer_wait_us = @max(timer_wait_us, 1);

                const guest_vblank_irq_enabled = (soc.pv0.inten != 0) or
                    (soc.pv1.inten != 0) or
                    (soc.pv2.inten != 0) or
                    ((soc.hvs.dispctrl & 0x3f80) != 0);
                const has_activity = soc.hvs.dlist_updated or
                    (soc.act_led_hold_frames > 0) or
                    soc.sdhost.activity_latch or
                    soc.gpio.act_pulse_latch or
                    soc.gpio.ui_dirty_latch or
                    soc.mailbox.exp_act_latch or
                    w.ui_dirty or
                    (w.pending_scale != w.scale) or
                    soc.usb.pending_csplit_sof or
                    (soc.usb.sof_wakeup_frames > 0) or
                    soc.usb.hid.hasPendingInterruptIn();

                const sleep_start_ns = monotonicNs();
                const sleep_us: u64 = if (guest_vblank_irq_enabled or has_activity) blk: {
                    const elapsed_ns = sleep_start_ns -| last_vblank_ns;
                    const until_vblank_us: u64 = if (elapsed_ns >= vblank_interval_ns)
                        0
                    else
                        (vblank_interval_ns - elapsed_ns) / 1000;
                    break :blk @min(timer_wait_us, until_vblank_us);
                } else timer_wait_us;

                if (sleep_us > 0) {
                    try w.waitEventsUs(sleep_us);
                } else {
                    try w.pollEvents();
                }
                const sleep_end_ns = monotonicNs();
                const elapsed_sleep_us = @max((sleep_end_ns -| sleep_start_ns) / 1000, 1);
                const jump = if (w.ui_dirty or soc.usb.hid.hasPendingInterruptIn() or soc.usb.hid.hasEthBulkIn())
                    @min(elapsed_sleep_us, timer_wait_us)
                else
                    @max(elapsed_sleep_us, sleep_us);
                idle_us_accum += jump;
                soc.timer.advance(jump, &soc.intc);
                soc.advanceAudio(jump);
                soc.usb.pollNetwork(soc.ram);
                soc.usb.wakeIfPending();
                for (0..num_cores) |i| {
                    if (!cpus[i].halted_spin) {
                        soc.local_intc.core_timer_lines[i] = cpus[i].mmu.syncGenericTimer(soc.timer.counter);
                        cpus[i].mmu.halted_wfi = false;
                    }
                }
                soc.updateIrqs();
            } else {
                // Fast-forward timer to next compare match or core generic timer during boot / headless mode
                var jump = soc.timer.usUntilNextMatch(2000);
                for (0..num_cores) |i| {
                    if (!cpus[i].halted_spin) {
                        jump = @min(jump, cpus[i].mmu.usUntilNextGenericTimer(2000));
                    }
                }
                jump = @max(jump, 1);
                idle_us_accum += jump;
                soc.timer.advance(jump, &soc.intc);
                soc.advanceAudio(jump);
                for (0..num_cores) |i| {
                    if (!cpus[i].halted_spin) {
                        soc.local_intc.core_timer_lines[i] = cpus[i].mmu.syncGenericTimer(soc.timer.counter);
                        cpus[i].mmu.halted_wfi = false;
                    }
                }
                soc.updateIrqs();
            }
        }

        if (!guest_ready_for_realtime_sleep and soc.timer.counter -| last_guest_vblank_us >= 16_667) {
            last_guest_vblank_us = soc.timer.counter;
            soc.triggerVblank();
        }

        const now_ns = monotonicNs();
        if (now_ns -| last_vblank_ns >= vblank_interval_ns) {
            last_vblank_ns = now_ns;
            last_guest_vblank_us = soc.timer.counter;
            soc.triggerVblank();

            if (wl_win) |w| {
                const frame_active_us = active_us_accum;
                const total_us = active_us_accum + idle_us_accum;
                if (total_us > 0) {
                    const busy = (@as(f32, @floatFromInt(active_us_accum)) * 100.0) / @as(f32, @floatFromInt(total_us));
                    const weight: f32 = if (total_us >= 100_000) 1.0 else 0.3;
                    w.status.cpu_busy_percent = w.status.cpu_busy_percent * (1.0 - weight) + busy * weight;
                    w.status.temperature_c = 38.0 + (w.status.cpu_busy_percent * 0.14);
                }
                active_us_accum = 0;
                idle_us_accum = 0;

                try w.pollEvents();
                soc.setHdmiConnected(w.status.hdmi_connected);
                soc.setAudioConnected(w.status.audio_connected);
                soc.usb.hid.net.dhcp_enabled = w.status.dhcp_enabled;
                soc.usb.wakeIfPending();
                soc.updateIrqs();

                const prev_act = w.status.act_led_on;
                const prev_pwr = w.status.pwr_led_on;
                const leds = soc.sampleBoardLeds(w.status.power_connected);
                w.status.act_led_on = leds.act_on;
                w.status.pwr_led_on = leds.pwr_on;
                const leds_changed = (leds.act_on != prev_act) or (leds.pwr_on != prev_pwr);

                const need_hdmi_render = soc.hvs.dlist_updated or
                    !w.status.hdmi_active or
                    (!soc.hvs.isActive() and soc.mailbox.fb_allocated) or
                    (frame_active_us > 200);
                var hdmi_changed = false;
                if (need_hdmi_render) {
                    soc.hvs.dlist_updated = false;
                    const disp_pixels = w.displayPixels();
                    w.status.hdmi_active = soc.renderDisplayFrame(disp_pixels, opts.width, opts.height);
                    hdmi_changed = true;
                }

                const gpio_ui_dirty = soc.gpio.takeUiDirty();
                const need_present = hdmi_changed or
                    leds_changed or
                    gpio_ui_dirty or
                    w.ui_dirty or
                    (w.pending_scale != w.scale);
                if (need_present) {
                    w.compositeUi();
                    try w.present();
                }
            }
        }
    }

    if (opts.headless) {
        if (cpus[0].is_aarch64) {
            std.debug.print(
                "\n[fauxpi] Stopped (AArch64) at cycle={d} pc=0x{x:0>16} lr=0x{x:0>16} sp=0x{x:0>16} pstate=0x{x:0>8} sctlr_el1=0x{x:0>8} ttbr0_el1=0x{x:0>16} timer_us={d} uart_tx={d}\n",
                .{
                    cpus[0].cycles,
                    cpus[0].pc64,
                    cpus[0].x[30],
                    cpus[0].sp_el[1],
                    cpus[0].pstate,
                    cpus[0].mmu.sctlr_el1,
                    cpus[0].mmu.ttbr0_64,
                    soc.timer.counter,
                    soc.uart0.tx_log_len,
                },
            );
        } else {
            std.debug.print(
                "\n[fauxpi] Stopped at cycle={d} pc=0x{x:0>8} lr=0x{x:0>8} sp=0x{x:0>8} cpsr=0x{x:0>8} sctlr=0x{x:0>8} ttbr0=0x{x:0>8} timer_us={d} uart_us={d}\n",
                .{
                    cpus[0].cycles,
                    cpus[0].r[15],
                    cpus[0].r[14],
                    cpus[0].r[13],
                    cpus[0].cpsr,
                    cpus[0].mmu.sctlr,
                    cpus[0].mmu.ttbr0,
                    soc.timer.counter,
                    soc.uart0.tx_log_len,
                },
            );
        }
        if (num_cores > 1) {
            for (1..num_cores) |i| {
                const pc_val: u64 = if (cpus[i].is_aarch64) cpus[i].pc64 else cpus[i].r[15];
                std.debug.print(
                    "  core[{d}] spin={} wfi={} cycles={d} pc=0x{x:0>8} cpsr=0x{x:0>8}\n",
                    .{ i, cpus[i].halted_spin, cpus[i].mmu.halted_wfi, cpus[i].cycles, pc_val, cpus[i].cpsr },
                );
            }
        }
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
