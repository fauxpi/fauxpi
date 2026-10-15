//! Raspberry Pi Zero bootloader & VideoCore `start.elf` firmware stub.
//!
//! Parses `config.txt` and `cmdline.txt` from a FAT16/FAT32 boot partition
//! (or direct file arguments), patches the Flattened Device Tree (`.dtb`),
//! loads `kernel.img` (`zImage`), the `.dtb`, and optional `initramfs.cpio`
//! into guest SDRAM, and returns the initial ARM CPU register state.

const std = @import("std");
const fat32 = @import("fat32.zig");
const fdt = @import("fdt.zig");

pub const kernel_load_addr: u32 = 0x0000_8000;
pub const dtb_load_addr: u32 = 0x03f0_0000;
pub const initrd_load_addr: u32 = 0x0400_0000;

pub const BootConfig = struct {
    os_prefix: []const u8 = "",
    kernel: []const u8 = "kernel.img",
    device_tree: ?[]const u8 = null,
    initramfs: ?[]const u8 = null,
    vc4_kms_v3d: bool = false,

    pub fn parse(text: []const u8) BootConfig {
        var cfg: BootConfig = .{};
        var section_active = true;
        var lines = std.mem.tokenizeAny(u8, text, "\r\n");
        while (lines.next()) |raw_line| {
            const hash = std.mem.indexOfScalar(u8, raw_line, '#') orelse raw_line.len;
            const line = std.mem.trim(u8, raw_line[0..hash], " \t");
            if (line.len == 0) continue;
            if (line[0] == '[' and line[line.len - 1] == ']') {
                const sec = line[1 .. line.len - 1];
                section_active = std.mem.eql(u8, sec, "all") or
                    std.mem.eql(u8, sec, "pi0") or
                    std.mem.eql(u8, sec, "pi0w");
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
    r0: u32 = 0,
    r1: u32 = 0xffffffff, // Device-tree machine ID
    r2: u32 = dtb_load_addr,
    kernel_size: usize,
    dtb_size: usize,
    initrd_size: usize,
};

/// Loads a Raspberry Pi Zero system from an SD card image (`sd_image`) into `ram`.
pub fn loadFromSdImage(
    allocator: std.mem.Allocator,
    ram: []u8,
    sd_image: []const u8,
    extra_cmdline: ?[]const u8,
    override_kernel: ?[]const u8,
) !BootResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const fs = try fat32.FatFs.init(sd_image);

    const config_txt = fs.readFileAlloc(alloc, "config.txt") catch "";
    const cfg = BootConfig.parse(config_txt);

    const kernel_bytes = if (override_kernel) |ok| ok else blk: {
        const kernel_path = try std.fmt.allocPrint(alloc, "{s}{s}", .{ cfg.os_prefix, cfg.kernel });
        break :blk try fs.readFileAlloc(alloc, kernel_path);
    };

    const dtb_candidates = [_][]const u8{
        cfg.device_tree orelse "bcm2708-rpi-zero.dtb",
        "bcm2835-rpi-zero.dtb",
        "bcm2708-rpi-zero-w.dtb",
        "bcm2835-rpi-zero-w.dtb",
    };
    const dtb_bytes = for (dtb_candidates) |cand| {
        const p = try std.fmt.allocPrint(alloc, "{s}{s}", .{ cfg.os_prefix, cand });
        if (fs.readFileAlloc(alloc, p)) |b| break b else |_| {}
    } else return error.DtbNotFound;

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

    if (kernel_load_addr + kernel_bytes.len > ram.len) return error.KernelTooLarge;
    @memcpy(ram[kernel_load_addr .. kernel_load_addr + kernel_bytes.len], kernel_bytes);

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
    const patched_dtb = try tree.serialize(alloc);

    if (dtb_load_addr + patched_dtb.len > ram.len) return error.DtbTooLarge;
    @memcpy(ram[dtb_load_addr .. dtb_load_addr + patched_dtb.len], patched_dtb);

    return .{
        .entry_pc = kernel_load_addr,
        .r0 = 0,
        .r1 = 0xffffffff,
        .r2 = dtb_load_addr,
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
}
