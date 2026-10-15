//! Raspberry Pi Zero bootloader & VideoCore `start.elf` firmware stub.
//!
//! Parses `config.txt` and `cmdline.txt` from a FAT16/FAT32 boot partition
//! (or direct file arguments), patches the Flattened Device Tree (`.dtb`),
//! loads `kernel.img` (`zImage`), the `.dtb`, and optional `initramfs.cpio`
//! into guest SDRAM, and returns the initial ARM CPU register state.

const std = @import("std");
const fat32 = @import("fat32.zig");
const fdt = @import("fdt.zig");
const BoardModel = @import("../ui/board_sheet.zig").BoardModel;

pub const kernel_load_addr: u32 = 0x0000_8000;
pub const kernel64_load_addr: u32 = 0x0008_0000;
pub const dtb_load_addr: u32 = 0x03f0_0000;
pub const initrd_load_addr: u32 = 0x0400_0000;
pub const arm64_image_magic: u32 = 0x644d_5241; // "ARM\x64" at byte offset 0x38

pub fn isArm64KernelImage(kernel_bytes: []const u8) bool {
    if (kernel_bytes.len < 64) return false;
    return std.mem.readInt(u32, kernel_bytes[0x38..0x3c], .little) == arm64_image_magic;
}

pub fn arm64KernelLoadOffset(kernel_bytes: []const u8) u32 {
    if (!isArm64KernelImage(kernel_bytes)) return kernel64_load_addr;
    const text_offset = std.mem.readInt(u64, kernel_bytes[0x08..0x10], .little);
    if (text_offset > 0 and text_offset <= 0x0200_0000 and (text_offset & 3) == 0) {
        return @intCast(text_offset);
    }
    return kernel64_load_addr;
}

pub const BootConfig = struct {
    os_prefix: []const u8 = "",
    kernel: []const u8 = "kernel.img",
    kernel_explicit: bool = false,
    arm_64bit: ?bool = null,
    device_tree: ?[]const u8 = null,
    initramfs: ?[]const u8 = null,
    vc4_kms_v3d: bool = false,

    pub fn parse(text: []const u8) BootConfig {
        return parseForModel(text, .pi_zero);
    }

    pub fn parseForModel(text: []const u8, board_model: BoardModel) BootConfig {
        var cfg: BootConfig = .{
            .kernel = if (board_model.isBcm2837()) "kernel8.img" else "kernel.img",
        };
        var section_active = true;
        var lines = std.mem.tokenizeAny(u8, text, "\r\n");
        while (lines.next()) |raw_line| {
            const hash = std.mem.indexOfScalar(u8, raw_line, '#') orelse raw_line.len;
            const line = std.mem.trim(u8, raw_line[0..hash], " \t");
            if (line.len == 0) continue;
            if (line[0] == '[' and line[line.len - 1] == ']') {
                const sec = line[1 .. line.len - 1];
                section_active = if (std.mem.eql(u8, sec, "all"))
                    true
                else if (std.mem.eql(u8, sec, "none"))
                    false
                else if (std.mem.eql(u8, sec, "pi0"))
                    (board_model == .pi_zero or board_model == .pi_zero_w or board_model == .pi_zero_2_w)
                else if (std.mem.eql(u8, sec, "pi0w"))
                    (board_model == .pi_zero_w)
                else if (std.mem.eql(u8, sec, "pi02"))
                    (board_model == .pi_zero_2_w)
                else if (std.mem.eql(u8, sec, "pi1"))
                    (board_model == .pi_1_a_plus or board_model == .pi_1_b_plus)
                else if (std.mem.eql(u8, sec, "pi3"))
                    (board_model == .pi_3_a_plus or board_model == .pi_3_b_plus or board_model == .pi_zero_2_w)
                else if (std.mem.eql(u8, sec, "pi3+"))
                    (board_model == .pi_3_a_plus or board_model == .pi_3_b_plus)
                else
                    false;
                continue;
            }
            if (!section_active) continue;

            if (std.mem.startsWith(u8, line, "initramfs ")) {
                const rest = std.mem.trim(u8, line["initramfs ".len..], " \t");
                var tok = std.mem.tokenizeAny(u8, rest, " \t");
                if (tok.next()) |fname| {
                    cfg.initramfs = fname;
                }
                continue;
            }

            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const val = std.mem.trim(u8, line[eq + 1 ..], " \t");

            if (std.mem.eql(u8, key, "os_prefix")) {
                cfg.os_prefix = val;
            } else if (std.mem.eql(u8, key, "kernel")) {
                cfg.kernel = val;
                cfg.kernel_explicit = true;
            } else if (std.mem.eql(u8, key, "arm_64bit")) {
                const is_64 = std.mem.eql(u8, val, "1") or std.ascii.eqlIgnoreCase(val, "true");
                cfg.arm_64bit = is_64;
                if (!cfg.kernel_explicit and board_model.isBcm2837()) {
                    cfg.kernel = if (is_64) "kernel8.img" else "kernel7.img";
                }
            } else if (std.mem.eql(u8, key, "device_tree")) {
                cfg.device_tree = val;
            } else if (std.mem.eql(u8, key, "dtoverlay")) {
                if (std.mem.startsWith(u8, val, "vc4-kms-v3d")) {
                    cfg.vc4_kms_v3d = true;
                }
            }
        }
        return cfg;
    }
};

pub const BootResult = struct {
    entry_pc: u32 = kernel_load_addr,
    is_aarch64: bool = false,
    r0: u32 = 0,
    r1: u32 = 0xffffffff, // Device-tree machine ID
    r2: u32 = dtb_load_addr,
    kernel_size: usize,
    dtb_size: usize,
    initrd_size: usize,
};

pub fn dtbCandidatesForModel(board_model: BoardModel) []const []const u8 {
    return switch (board_model) {
        .pi_zero => &.{
            "bcm2708-rpi-zero.dtb",
            "bcm2835-rpi-zero.dtb",
            "bcm2708-rpi-zero-w.dtb",
            "bcm2835-rpi-zero-w.dtb",
        },
        .pi_zero_w => &.{
            "bcm2708-rpi-zero-w.dtb",
            "bcm2835-rpi-zero-w.dtb",
            "bcm2708-rpi-zero.dtb",
            "bcm2835-rpi-zero.dtb",
        },
        .pi_1_a_plus, .pi_1_b_plus => &.{
            "bcm2708-rpi-b-plus.dtb",
            "bcm2835-rpi-b-plus.dtb",
            "bcm2708-rpi-zero.dtb",
            "bcm2835-rpi-zero.dtb",
        },
        .pi_3_a_plus => &.{
            "bcm2837-rpi-3-a-plus.dtb",
            "bcm2710-rpi-3-b-plus.dtb",
            "bcm2837-rpi-3-b-plus.dtb",
            "bcm2710-rpi-3-b.dtb",
            "bcm2708-rpi-zero.dtb",
        },
        .pi_3_b_plus => &.{
            "bcm2710-rpi-3-b-plus.dtb",
            "bcm2837-rpi-3-b-plus.dtb",
            "bcm2710-rpi-3-b.dtb",
            "bcm2837-rpi-3-a-plus.dtb",
            "bcm2708-rpi-zero.dtb",
        },
        .pi_zero_2_w => &.{
            "bcm2710-rpi-zero-2-w.dtb",
            "bcm2837-rpi-zero-2-w.dtb",
            "bcm2710-rpi-zero-2.dtb",
            "bcm2710-rpi-3-b-plus.dtb",
            "bcm2708-rpi-zero-w.dtb",
        },
    };
}

/// Loads a Raspberry Pi Zero system from an SD card image (`sd_image`) into `ram`.
pub fn loadFromSdImage(
    allocator: std.mem.Allocator,
    ram: []u8,
    sd_image: []const u8,
    extra_cmdline: ?[]const u8,
    override_kernel: ?[]const u8,
) !BootResult {
    return loadFromSdImageForModel(allocator, ram, sd_image, .pi_zero, extra_cmdline, override_kernel);
}

/// Loads a Raspberry Pi system for `board_model` from an SD card image (`sd_image`) into `ram`.
pub fn loadFromSdImageForModel(
    allocator: std.mem.Allocator,
    ram: []u8,
    sd_image: []const u8,
    board_model: BoardModel,
    extra_cmdline: ?[]const u8,
    override_kernel: ?[]const u8,
) !BootResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const fs = try fat32.FatFs.init(sd_image);

    const config_txt = fs.readFileAlloc(alloc, "config.txt") catch "";
    const cfg = BootConfig.parseForModel(config_txt, board_model);

    const kernel_bytes = if (override_kernel) |ok| ok else blk: {
        const kernel_path = try std.fmt.allocPrint(alloc, "{s}{s}", .{ cfg.os_prefix, cfg.kernel });
        if (fs.readFileAlloc(alloc, kernel_path)) |kb| break :blk kb else |err| {
            if (board_model.isBcm2837() and !cfg.kernel_explicit) {
                for ([_][]const u8{ "kernel7.img", "kernel.img" }) |fb_name| {
                    const fallback_path = try std.fmt.allocPrint(alloc, "{s}{s}", .{ cfg.os_prefix, fb_name });
                    if (fs.readFileAlloc(alloc, fallback_path)) |kb| break :blk kb else |_| {}
                }
            }
            return err;
        }
    };

    const dtb_bytes = blk: {
        if (cfg.device_tree) |dt_override| {
            const p = try std.fmt.allocPrint(alloc, "{s}{s}", .{ cfg.os_prefix, dt_override });
            if (fs.readFileAlloc(alloc, p)) |b| break :blk b else |_| {}
        }
        for (dtbCandidatesForModel(board_model)) |cand| {
            const p = try std.fmt.allocPrint(alloc, "{s}{s}", .{ cfg.os_prefix, cand });
            if (fs.readFileAlloc(alloc, p)) |b| break :blk b else |_| {}
        }
        return error.DtbNotFound;
    };

    const initrd_bytes: ?[]const u8 = if (cfg.initramfs) |rd_name| blk: {
        const p = try std.fmt.allocPrint(alloc, "{s}{s}", .{ cfg.os_prefix, rd_name });
        break :blk try fs.readFileAlloc(alloc, p);
    } else null;

    const cmdline_path = try std.fmt.allocPrint(alloc, "{s}cmdline.txt", .{cfg.os_prefix});
    const raw_cmdline = fs.readFileAlloc(alloc, cmdline_path) catch
        (fs.readFileAlloc(alloc, "cmdline.txt") catch "");
    const trimmed_cmdline = std.mem.trim(u8, raw_cmdline, " \t\r\n");

    const full_cmdline = if (extra_cmdline) |extra|
        try std.fmt.allocPrint(alloc, "{s} {s}", .{ trimmed_cmdline, extra })
    else if (std.mem.indexOf(u8, trimmed_cmdline, "console=") == null)
        try std.fmt.allocPrint(alloc, "console=ttyAMA0,115200 {s}", .{trimmed_cmdline})
    else
        trimmed_cmdline;

    return loadDirect(allocator, ram, kernel_bytes, dtb_bytes, initrd_bytes, full_cmdline, cfg.vc4_kms_v3d or true);
}

/// Loads `kernel_bytes`, `dtb_bytes`, and optional `initrd_bytes` directly into `ram`.
pub fn loadDirect(
    allocator: std.mem.Allocator,
    ram: []u8,
    kernel_bytes: []const u8,
    dtb_bytes: []const u8,
    initrd_bytes: ?[]const u8,
    cmdline: []const u8,
    enable_vc4_kms: bool,
) !BootResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const is_aarch64 = isArm64KernelImage(kernel_bytes);
    const load_addr: u32 = if (is_aarch64) arm64KernelLoadOffset(kernel_bytes) else kernel_load_addr;

    if (load_addr + kernel_bytes.len > ram.len) return error.KernelTooLarge;
    @memcpy(ram[load_addr .. load_addr + kernel_bytes.len], kernel_bytes);

    var initrd_range: ?fdt.Tree.InitrdRange = null;
    var initrd_len: usize = 0;
    if (initrd_bytes) |rd| {
        if (initrd_load_addr + rd.len > ram.len) return error.InitrdTooLarge;
        @memcpy(ram[initrd_load_addr .. initrd_load_addr + rd.len], rd);
        initrd_range = .{
            .start = initrd_load_addr,
            .end = initrd_load_addr + @as(u32, @intCast(rd.len)),
        };
        initrd_len = rd.len;
    }

    var tree = try fdt.Tree.parse(alloc, dtb_bytes);
    try tree.patchForPiZero(@intCast(ram.len), cmdline, initrd_range, enable_vc4_kms);
    if (is_aarch64) {
        try tree.configureSpinTable64();
    }
    const patched_dtb = try tree.serialize(alloc);

    if (dtb_load_addr + patched_dtb.len > ram.len) return error.DtbTooLarge;
    @memcpy(ram[dtb_load_addr .. dtb_load_addr + patched_dtb.len], patched_dtb);

    return .{
        .entry_pc = load_addr,
        .is_aarch64 = is_aarch64,
        .r0 = if (is_aarch64) dtb_load_addr else 0,
        .r1 = if (is_aarch64) 0 else 0xffffffff,
        .r2 = if (is_aarch64) 0 else dtb_load_addr,
        .kernel_size = kernel_bytes.len,
        .dtb_size = patched_dtb.len,
        .initrd_size = initrd_len,
    };
}

/// Updates `/model`, `/system/linux,revision`, `/system/linux,serial`, `/serial-number`, and optional wireless MAC in the in-RAM DTB at `dtb_load_addr`.
pub fn applyBoardConfigToRamDtb(
    allocator: std.mem.Allocator,
    ram: []u8,
    dtb_size: usize,
    model_str: []const u8,
    revision: u32,
    serial: u64,
    wifi_mac: ?[6]u8,
) !usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    if (dtb_load_addr + dtb_size > ram.len) return error.DtbTooLarge;
    var tree = try fdt.Tree.parse(alloc, ram[dtb_load_addr .. dtb_load_addr + dtb_size]);
    try tree.setBoardModel(model_str, revision);
    try tree.setBoardSerial(serial);
    if (wifi_mac) |wmac| {
        try tree.setWirelessMac(wmac);
    } else {
        try tree.disableWireless();
    }
    const updated_dtb = try tree.serialize(alloc);
    if (dtb_load_addr + updated_dtb.len > ram.len) return error.DtbTooLarge;
    @memcpy(ram[dtb_load_addr .. dtb_load_addr + updated_dtb.len], updated_dtb);
    return updated_dtb.len;
}

/// Updates `/system/linux,serial` and `/serial-number` in the in-RAM DTB at `dtb_load_addr`.
pub fn applyBoardSerialToRamDtb(allocator: std.mem.Allocator, ram: []u8, dtb_size: usize, serial: u64) !usize {
    return applyBoardConfigToRamDtb(allocator, ram, dtb_size, "Raspberry Pi Zero Rev 1.3", 0x00900093, serial, null);
}


test "parse config.txt" {
    const sample =
        \\# Dazzle config.txt
        \\os_prefix=slot-a/
        \\initramfs initramfs.cpio followkernel
        \\dtoverlay=vc4-kms-v3d
        \\disable_overscan=1
    ;
    const cfg = BootConfig.parse(sample);
    try std.testing.expectEqualStrings("slot-a/", cfg.os_prefix);
    try std.testing.expectEqualStrings("kernel.img", cfg.kernel);
    try std.testing.expectEqualStrings("initramfs.cpio", cfg.initramfs.?);
    try std.testing.expect(cfg.vc4_kms_v3d);

    const cfg64 = BootConfig.parseForModel("arm_64bit=1\n", .pi_3_b_plus);
    try std.testing.expectEqualStrings("kernel8.img", cfg64.kernel);
    try std.testing.expectEqual(@as(?bool, true), cfg64.arm_64bit);

    const cfg32 = BootConfig.parseForModel("arm_64bit=0\n", .pi_3_b_plus);
    try std.testing.expectEqualStrings("kernel7.img", cfg32.kernel);
    try std.testing.expectEqual(@as(?bool, false), cfg32.arm_64bit);

    var fake_arm64_hdr: [64]u8 = @splat(0);
    std.mem.writeInt(u64, fake_arm64_hdr[0x08..0x10], 0x0008_0000, .little);
    std.mem.writeInt(u32, fake_arm64_hdr[0x38..0x3c], arm64_image_magic, .little);
    try std.testing.expect(isArm64KernelImage(&fake_arm64_hdr));
    try std.testing.expectEqual(@as(u32, 0x0008_0000), arm64KernelLoadOffset(&fake_arm64_hdr));
}

