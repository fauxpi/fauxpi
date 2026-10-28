//! Raspberry Pi Zero bootloader & VideoCore `start.elf` firmware stub.
//!
//! Parses `config.txt` and `cmdline.txt` from a FAT16/FAT32 boot partition
//! (or direct file arguments), applies `dtoverlay=` / `dtparam=` settings and
//! patches the Flattened Device Tree (`.dtb`),
//! loads `kernel.img` (`zImage`), the `.dtb`, and optional `initramfs.cpio`
//! into guest SDRAM, and returns the initial ARM CPU register state.

const std = @import("std");
const fat32 = @import("fat32.zig");
const fdt = @import("fdt.zig");
const bluetooth = @import("../soc/bluetooth.zig");
const BoardModel = @import("../ui/board_sheet.zig").BoardModel;

pub const kernel_load_addr: u32 = 0x0000_8000;
pub const kernel64_load_addr: u32 = 0x0020_0000;
/// Where the firmware loads a 64-bit kernel without a Linux `Image` header (a bare-metal binary).
pub const raw_kernel64_load_addr: u32 = 0x0008_0000;
pub const dtb_load_addr: u32 = 0x03f0_0000;
pub const initrd_load_addr: u32 = 0x0400_0000;
pub const arm64_image_magic: u32 = 0x644d_5241; // "ARM\x64" at byte offset 0x38

pub fn isArm64KernelImage(kernel_bytes: []const u8) bool {
    if (kernel_bytes.len < 64) return false;
    return std.mem.readInt(u32, kernel_bytes[0x38..0x3c], .little) == arm64_image_magic;
}

/// True for a 32-bit ARM Linux `zImage` (magic `0x016f2818` at byte offset 0x24).
pub fn isArmZImage(kernel_bytes: []const u8) bool {
    if (kernel_bytes.len < 0x28) return false;
    return std.mem.readInt(u32, kernel_bytes[0x24..0x28], .little) == 0x016f2818;
}

pub fn arm64KernelLoadOffset(kernel_bytes: []const u8) u32 {
    if (!isArm64KernelImage(kernel_bytes)) return kernel64_load_addr;
    const text_offset = std.mem.readInt(u64, kernel_bytes[0x08..0x10], .little);
    if (text_offset > 0 and text_offset <= 0x0200_0000 and (text_offset & 3) == 0) {
        return @intCast(text_offset);
    }
    return kernel64_load_addr;
}

/// A device-tree parameter (`dtparam=name=value`, or `dtoverlay=overlay,name=value`).
pub const DtParam = struct {
    name: []const u8,
    value: []const u8,
};

/// A `dtoverlay=` line and the parameters that apply to it. An empty `name` applies `params` to
/// the base device tree (`dtparam=` lines before any overlay, or after an empty `dtoverlay=`).
pub const DtOverlay = struct {
    name: []const u8 = "",
    dtbo: ?[]const u8 = null,
    params: []const DtParam = &.{},
};

pub const DtDirective = struct {
    kind: enum { overlay, param },
    /// Raw value, e.g. `"i2c-rtc,ds3231"` or `"i2c_arm=on,spi=on"`.
    text: []const u8,
};

pub const max_dt_directives = 64;

pub const BootConfig = struct {
    os_prefix: []const u8 = "",
    overlay_prefix: []const u8 = "overlays/",
    kernel: []const u8 = "kernel.img",
    kernel_explicit: bool = false,
    arm_64bit: ?bool = null,
    kernel_address: ?u32 = null,
    device_tree: ?[]const u8 = null,
    initramfs: ?[]const u8 = null,
    auto_initramfs: bool = false,
    vc4_kms_v3d: bool = false,
    dt_directives: [max_dt_directives]DtDirective = undefined,
    dt_directive_count: usize = 0,

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
            } else if (std.mem.eql(u8, key, "kernel_address")) {
                cfg.kernel_address = std.fmt.parseInt(u32, val, 0) catch null;
            } else if (std.mem.eql(u8, key, "auto_initramfs")) {
                cfg.auto_initramfs = std.mem.eql(u8, val, "1") or std.ascii.eqlIgnoreCase(val, "true");
            } else if (std.mem.eql(u8, key, "device_tree")) {
                cfg.device_tree = val;
            } else if (std.mem.eql(u8, key, "overlay_prefix")) {
                cfg.overlay_prefix = val;
            } else if (std.mem.eql(u8, key, "dtoverlay") or std.mem.eql(u8, key, "device_tree_overlay") or
                std.mem.eql(u8, key, "dtparam") or std.mem.eql(u8, key, "device_tree_param"))
            {
                const is_overlay = std.mem.eql(u8, key, "dtoverlay") or std.mem.eql(u8, key, "device_tree_overlay");
                if (is_overlay and std.mem.startsWith(u8, val, "vc4-kms-v3d")) {
                    cfg.vc4_kms_v3d = true;
                }
                if (cfg.dt_directive_count < max_dt_directives) {
                    cfg.dt_directives[cfg.dt_directive_count] = .{ .kind = if (is_overlay) .overlay else .param, .text = val };
                    cfg.dt_directive_count += 1;
                }
            }
        }
        return cfg;
    }

    /// Groups the `dtoverlay=` / `dtparam=` lines, in order, into overlays with their parameters.
    /// Parameters apply to the most recent overlay, or to the base device tree before any overlay
    /// (or after an empty `dtoverlay=`). A parameter without a value means `true`.
    pub fn dtOverlays(self: *const BootConfig, allocator: std.mem.Allocator) ![]DtOverlay {
        var overlays: std.ArrayList(DtOverlay) = .empty;
        var params: std.ArrayList(DtParam) = .empty;
        var name: []const u8 = "";
        for (self.dt_directives[0..self.dt_directive_count]) |d| {
            var parts = std.mem.splitScalar(u8, d.text, ',');
            if (d.kind == .overlay) {
                if (name.len > 0 or params.items.len > 0) {
                    try overlays.append(allocator, .{ .name = name, .params = try params.toOwnedSlice(allocator) });
                }
                name = std.mem.trim(u8, parts.first(), " \t");
            }
            while (parts.next()) |raw| {
                const p = std.mem.trim(u8, raw, " \t");
                if (p.len == 0) continue;
                if (std.mem.indexOfScalar(u8, p, '=')) |eq| {
                    try params.append(allocator, .{ .name = p[0..eq], .value = p[eq + 1 ..] });
                } else {
                    try params.append(allocator, .{ .name = p, .value = "true" });
                }
            }
        }
        if (name.len > 0 or params.items.len > 0) {
            try overlays.append(allocator, .{ .name = name, .params = try params.toOwnedSlice(allocator) });
        }
        return overlays.toOwnedSlice(allocator);
    }
};

/// Applies `dtoverlay=` / `dtparam=` settings to `tree` the way the VideoCore firmware does.
/// Problems (missing overlays, unknown parameters) are reported and skipped, as on real hardware.
fn applyDtOverlays(allocator: std.mem.Allocator, tree: *fdt.Tree, overlays: []const DtOverlay) void {
    for (overlays) |o| {
        var overlay_tree: ?fdt.Tree = null;
        if (o.dtbo) |bytes| {
            overlay_tree = fdt.Tree.parse(allocator, bytes) catch |err| {
                std.debug.print("fauxpi: dtoverlay {s}: {s}\n", .{ o.name, @errorName(err) });
                continue;
            };
            tree.fixupOverlay(&overlay_tree.?) catch |err| {
                std.debug.print("fauxpi: dtoverlay {s}: {s}\n", .{ o.name, @errorName(err) });
                continue;
            };
        } else if (o.name.len > 0) {
            continue;
        }

        const overlay_ptr: ?*fdt.Tree = if (overlay_tree) |*t| t else null;
        for (o.params) |p| {
            const known = tree.applyParam(overlay_ptr, p.name, p.value) catch |err| {
                std.debug.print("fauxpi: dtparam {s}={s}: {s}\n", .{ p.name, p.value, @errorName(err) });
                continue;
            };
            if (!known) std.debug.print("fauxpi: dtparam {s}: unknown parameter\n", .{p.name});
        }

        if (overlay_ptr) |t| {
            tree.mergeOverlay(t) catch |err| {
                std.debug.print("fauxpi: dtoverlay {s}: {s}\n", .{ o.name, @errorName(err) });
            };
        }
    }
}

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
            "bcm2710-rpi-3-a-plus.dtb",
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
) !BootResult {
    return loadFromSdImageForModel(allocator, ram, sd_image, .pi_zero);
}

/// Loads a Raspberry Pi system for `board_model` from an SD card image (`sd_image`) into `ram`.
pub fn loadFromSdImageForModel(
    allocator: std.mem.Allocator,
    ram: []u8,
    sd_image: []const u8,
    board_model: BoardModel,
) !BootResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const fs = try fat32.FatFs.init(sd_image);

    const config_txt = fs.readFileAlloc(alloc, "config.txt") catch "";
    const cfg = BootConfig.parseForModel(config_txt, board_model);

    // The firmware starts the kernel in AArch64 on 64-bit boards with `arm_64bit=1`, or, when
    // `arm_64bit` is unset, for its default 64-bit kernel name `kernel8.img`.
    var kernel_name = cfg.kernel;
    const kernel_bytes = blk: {
        const kernel_path = try std.fmt.allocPrint(alloc, "{s}{s}", .{ cfg.os_prefix, cfg.kernel });
        if (fs.readFileAlloc(alloc, kernel_path)) |kb| break :blk kb else |err| {
            if (board_model.isBcm2837() and !cfg.kernel_explicit) {
                for ([_][]const u8{ "kernel7.img", "kernel.img" }) |fb_name| {
                    const fallback_path = try std.fmt.allocPrint(alloc, "{s}{s}", .{ cfg.os_prefix, fb_name });
                    if (fs.readFileAlloc(alloc, fallback_path)) |kb| {
                        kernel_name = fb_name;
                        break :blk kb;
                    } else |_| {}
                }
            } else if (!board_model.isBcm2837() and !cfg.kernel_explicit) {
                const k8_path = try std.fmt.allocPrint(alloc, "{s}kernel8.img", .{cfg.os_prefix});
                if (fs.readFileAlloc(alloc, k8_path)) |_| {
                    return error.Requires64BitBoard;
                } else |_| {}
            }
            if (err == error.FileNotFound) return error.KernelNotFound;
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
        break :blk fs.readFileAlloc(alloc, p) catch |err| {
            if (err == error.FileNotFound) return error.InitramfsNotFound;
            return err;
        };
    } else if (cfg.auto_initramfs) blk: {
        const auto_name = if (std.mem.indexOf(u8, cfg.kernel, "8") != null or (cfg.arm_64bit orelse board_model.isBcm2837()))
            "initramfs8"
        else if (std.mem.indexOf(u8, cfg.kernel, "7l") != null)
            "initramfs7l"
        else if (std.mem.indexOf(u8, cfg.kernel, "7") != null)
            "initramfs7"
        else
            "initramfs";
        const p = try std.fmt.allocPrint(alloc, "{s}{s}", .{ cfg.os_prefix, auto_name });
        break :blk fs.readFileAlloc(alloc, p) catch null;
    } else null;

    const cmdline_path = try std.fmt.allocPrint(alloc, "{s}cmdline.txt", .{cfg.os_prefix});
    const raw_cmdline = fs.readFileAlloc(alloc, cmdline_path) catch
        (fs.readFileAlloc(alloc, "cmdline.txt") catch "");
    const trimmed_cmdline = std.mem.trim(u8, raw_cmdline, " \t\r\n");

    const full_cmdline = if (std.mem.indexOf(u8, trimmed_cmdline, "console=") == null)
        try std.fmt.allocPrint(alloc, "console=ttyAMA0,115200 {s}", .{trimmed_cmdline})
    else
        trimmed_cmdline;

    const overlays = try cfg.dtOverlays(alloc);
    for (overlays) |*o| {
        if (o.name.len == 0) continue;
        const p = try std.fmt.allocPrint(alloc, "{s}{s}{s}.dtbo", .{ cfg.os_prefix, cfg.overlay_prefix, o.name });
        o.dtbo = fs.readFileAlloc(alloc, p) catch |err| blk: {
            std.debug.print("fauxpi: dtoverlay {s}: failed to load {s}: {s}\n", .{ o.name, p, @errorName(err) });
            break :blk null;
        };
    }

    const boot64 = board_model.isBcm2837() and (cfg.arm_64bit orelse std.mem.eql(u8, kernel_name, "kernel8.img"));
    return loadDirectWithOverlays(allocator, ram, kernel_bytes, dtb_bytes, initrd_bytes, full_cmdline, cfg.vc4_kms_v3d or true, overlays, .{
        .aarch64 = boot64,
        .kernel_address = cfg.kernel_address,
    });
}

/// How the firmware starts a kernel without a Linux `Image` header, which would say for itself.
pub const KernelStart = struct {
    /// Start in AArch64 (`arm_64bit=1`, or `kernel8.img` on a 64-bit board).
    aarch64: bool = false,
    /// `kernel_address` from config.txt.
    kernel_address: ?u32 = null,
};

const SliceLzma2Buffer = struct {
    dest: []u8,
    pos: usize = 0,
    len: usize = 0,

    pub fn resetDict(self: *SliceLzma2Buffer) void {
        self.len = 0;
    }

    pub fn lastOr(self: *const SliceLzma2Buffer, lit: u8) u8 {
        if (self.len == 0) return lit;
        return self.dest[self.pos - 1];
    }

    pub fn lastN(self: *const SliceLzma2Buffer, dist: usize) !u8 {
        if (dist == 0 or dist > self.len) return error.CorruptInput;
        return self.dest[self.pos - dist];
    }

    pub fn appendByteDirect(self: *SliceLzma2Buffer, b: u8) !void {
        if (self.pos >= self.dest.len) return error.NoSpaceLeft;
        self.dest[self.pos] = b;
        self.pos += 1;
        self.len += 1;
    }

    pub fn appendLiteral(
        self: *SliceLzma2Buffer,
        _: std.mem.Allocator,
        lit: u8,
        _: *std.Io.Writer,
    ) !void {
        try self.appendByteDirect(lit);
    }

    pub fn appendLz(
        self: *SliceLzma2Buffer,
        _: std.mem.Allocator,
        match_len: usize,
        dist: usize,
        _: *std.Io.Writer,
    ) !void {
        if (dist == 0 or dist > self.len) return error.CorruptInput;
        if (self.pos + match_len > self.dest.len) return error.NoSpaceLeft;
        var src_pos = self.pos - dist;
        for (0..match_len) |_| {
            self.dest[self.pos] = self.dest[src_pos];
            self.pos += 1;
            src_pos += 1;
        }
        self.len += match_len;
    }
};

fn decodeXzVliSlice(buf: []const u8, pos: *usize) !u64 {
    var result: u64 = 0;
    var i: usize = 0;
    while (i < 9) : (i += 1) {
        if (pos.* >= buf.len) return error.CorruptInput;
        const b = buf[pos.*];
        pos.* += 1;
        if (b == 0 and i > 0) return error.CorruptInput;
        result |= @as(u64, b & 0x7F) << @intCast(i * 7);
        if ((b & 0x80) == 0) return result;
    }
    return error.CorruptInput;
}

fn decompressXzSingleBlock(allocator: std.mem.Allocator, xz_bytes: []const u8, dest: []u8) !usize {
    var input: std.Io.Reader = .fixed(xz_bytes);
    const magic = try input.takeArray(6);
    if (!std.mem.eql(u8, magic, &.{ 0xFD, '7', 'z', 'X', 'Z', 0x00 })) return error.NotXzStream;

    const stream_flags: [2]u8 = (try input.takeArray(2)).*;
    const header_crc = try input.takeInt(u32, .little);
    if (header_crc != std.hash.Crc32.hash(&stream_flags)) return error.WrongChecksum;
    if (stream_flags[0] != 0 or (stream_flags[1] & 0xF0) != 0) return error.CorruptInput;

    const first_byte: usize = try input.peekByte();
    if (first_byte == 0) return error.CorruptInput;

    const declared_header_size = first_byte * 4;
    const header_bytes = try input.take(declared_header_size);
    const declared_hdr_crc = try input.takeInt(u32, .little);
    if (declared_hdr_crc != std.hash.Crc32.hash(header_bytes)) return error.WrongChecksum;

    var hdr_pos: usize = 1;
    const blk_flags = header_bytes[hdr_pos];
    hdr_pos += 1;
    const filter_count = @as(usize, blk_flags & 0x03) + 1;
    if ((blk_flags & 0x3C) != 0 or filter_count > 2) return error.Unsupported;

    if ((blk_flags & 0x40) != 0) _ = try decodeXzVliSlice(header_bytes, &hdr_pos);
    if ((blk_flags & 0x80) != 0) _ = try decodeXzVliSlice(header_bytes, &hdr_pos);

    var use_arm_bcj = false;
    var arm_bcj_start_offset: u32 = 0;
    if (filter_count == 2) {
        const f0_id = try decodeXzVliSlice(header_bytes, &hdr_pos);
        if (f0_id != 0x07) return error.Unsupported; // 0x07 = ARM BCJ
        use_arm_bcj = true;
        const f0_props_size = try decodeXzVliSlice(header_bytes, &hdr_pos);
        if (f0_props_size == 4) {
            if (hdr_pos + 4 > header_bytes.len) return error.CorruptInput;
            arm_bcj_start_offset = std.mem.readInt(u32, header_bytes[hdr_pos..][0..4], .little);
            hdr_pos += 4;
        } else if (f0_props_size != 0) {
            return error.CorruptInput;
        }
    }

    const filter_id = try decodeXzVliSlice(header_bytes, &hdr_pos);
    if (filter_id != 0x21) return error.Unsupported; // 0x21 = LZMA2
    const props_size = try decodeXzVliSlice(header_bytes, &hdr_pos);
    if (props_size != 1 or hdr_pos >= header_bytes.len) return error.CorruptInput;
    hdr_pos += 1; // dict_size prop

    var lzma_decode = try std.compress.lzma.Decode.init(allocator, .{ .lc = 0, .lp = 0, .pb = 0 });
    defer lzma_decode.deinit(allocator);

    var dummy_allocating = std.Io.Writer.Allocating.init(allocator);
    defer dummy_allocating.deinit();

    var lzma2_buf: SliceLzma2Buffer = .{ .dest = dest };
    var packed_bytes_read: u64 = 0;

    while (true) {
        const status = try input.takeByte();
        packed_bytes_read += 1;
        if (status == 0) break;

        if (status == 1 or status == 2) {
            const chunk_unpacked = @as(usize, try input.takeInt(u16, .big)) + 1;
            packed_bytes_read += 2 + chunk_unpacked;
            if (status == 1) lzma2_buf.resetDict();
            for (0..chunk_unpacked) |_| {
                try lzma2_buf.appendByteDirect(try input.takeByte());
            }
        } else {
            if ((status & 0x80) == 0) return error.CorruptInput;
            const reset_mode: u2 = @truncate((status >> 5) & 0x03);
            const reset_dict = (reset_mode == 3);
            const reset_state = (reset_mode >= 1);
            const reset_props = (reset_mode >= 2);

            const chunk_unpacked: usize = (@as(usize, status & 0x1F) << 16) +
                @as(usize, try input.takeInt(u16, .big)) + 1;
            const chunk_packed: u64 = @as(u64, try input.takeInt(u16, .big)) + 1;
            packed_bytes_read += 4;

            if (reset_dict) lzma2_buf.resetDict();
            if (reset_state) {
                var new_props = lzma_decode.properties;
                if (reset_props) {
                    var props = try input.takeByte();
                    packed_bytes_read += 1;
                    if (props >= 225) return error.CorruptInput;
                    const lc: u4 = @intCast(props % 9);
                    props /= 9;
                    const lp: u3 = @intCast(props % 5);
                    props /= 5;
                    const pb: u3 = @intCast(props);
                    if (lc + lp > 4) return error.CorruptInput;
                    new_props = .{ .lc = lc, .lp = lp, .pb = pb };
                }
                try lzma_decode.resetState(allocator, new_props);
            }

            const target_pos = lzma2_buf.pos + chunk_unpacked;
            const start_packed = packed_bytes_read;
            var range_decoder = try std.compress.lzma.RangeDecoder.initCounting(&input, &packed_bytes_read);
            while (lzma2_buf.pos < target_pos) {
                switch (try lzma_decode.process(&input, &dummy_allocating, &lzma2_buf, &range_decoder, &packed_bytes_read)) {
                    .more => continue,
                    .finished => break,
                }
            }
            if (lzma2_buf.pos != target_pos) return error.DecompressedSizeMismatch;
            if (packed_bytes_read - start_packed != chunk_packed) return error.CompressedSizeMismatch;
        }
    }

    if (use_arm_bcj) {
        const out = dest[0..lzma2_buf.pos];
        const aligned_len = out.len & ~@as(usize, 3);
        var i: usize = 0;
        while (i < aligned_len) : (i += 4) {
            if (out[i + 3] == 0xeb) {
                var addr: u32 = @as(u32, out[i]) |
                    (@as(u32, out[i + 1]) << 8) |
                    (@as(u32, out[i + 2]) << 16);
                addr <<= 2;
                addr -%= arm_bcj_start_offset +% @as(u32, @intCast(i)) +% 8;
                addr >>= 2;
                out[i] = @truncate(addr);
                out[i + 1] = @truncate(addr >> 8);
                out[i + 2] = @truncate(addr >> 16);
            }
        }
    }

    return lzma2_buf.pos;
}

fn tryDecompressArmZImage(allocator: std.mem.Allocator, kernel_bytes: []const u8, dest: []u8) ?usize {
    if (kernel_bytes.len < 0x40) return null;
    // 32-bit ARM zImage magic at 0x24
    if (std.mem.readInt(u32, kernel_bytes[0x24..0x28], .little) != 0x016f2818) return null;

    const xz_magic = [_]u8{ 0xFD, '7', 'z', 'X', 'Z', 0x00 };
    var search_pos: usize = 0;
    while (std.mem.indexOfPos(u8, kernel_bytes, search_pos, &xz_magic)) |off| {
        search_pos = off + 1;
        if (off + 12 > kernel_bytes.len) break;
        const flags = kernel_bytes[off + 6 .. off + 8];
        if (flags[0] != 0 or (flags[1] & 0xF0) != 0) continue;
        const crc = std.mem.readInt(u32, kernel_bytes[off + 8 ..][0..4], .little);
        if (crc != std.hash.Crc32.hash(flags)) continue;

        if (decompressXzSingleBlock(allocator, kernel_bytes[off..], dest)) |unpacked_len| {
            if (unpacked_len > kernel_bytes.len) {
                return unpacked_len;
            }
        } else |_| {}
    }
    return null;
}

/// Loads `kernel_bytes`, `dtb_bytes`, and optional `initrd_bytes` directly into `ram`.
pub fn loadDirect(
    allocator: std.mem.Allocator,
    ram: []u8,
    raw_kernel_bytes: []const u8,
    dtb_bytes: []const u8,
    initrd_bytes: ?[]const u8,
    cmdline: []const u8,
    enable_vc4_kms: bool,
) !BootResult {
    return loadDirectWithOverlays(allocator, ram, raw_kernel_bytes, dtb_bytes, initrd_bytes, cmdline, enable_vc4_kms, &.{}, .{});
}

/// Like `loadDirect`, also applying `dtoverlay=` / `dtparam=` settings to the device tree.
pub fn loadDirectWithOverlays(
    allocator: std.mem.Allocator,
    ram: []u8,
    raw_kernel_bytes: []const u8,
    dtb_bytes: []const u8,
    initrd_bytes: ?[]const u8,
    cmdline: []const u8,
    enable_vc4_kms: bool,
    overlays: []const DtOverlay,
    start: KernelStart,
) !BootResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const kernel_bytes = if (raw_kernel_bytes.len >= 18 and
        raw_kernel_bytes[0] == 0x1f and
        raw_kernel_bytes[1] == 0x8b and
        raw_kernel_bytes[2] == 0x08)
    blk: {
        var in: std.Io.Reader = .fixed(raw_kernel_bytes);
        var aw: std.Io.Writer.Allocating = .init(alloc);
        var decomp: std.compress.flate.Decompress = .init(&in, .gzip, &.{});
        _ = try decomp.reader.streamRemaining(&aw.writer);
        break :blk aw.written();
    } else raw_kernel_bytes;

    // A Linux arm64 `Image` says where it loads; a bare-metal 64-bit binary loads at `kernel_address`
    // or the firmware's default, 0x80000, as on the board.
    const is_aarch64 = isArm64KernelImage(kernel_bytes) or start.aarch64;
    const load_addr: u32 = if (isArm64KernelImage(kernel_bytes))
        arm64KernelLoadOffset(kernel_bytes)
    else if (is_aarch64)
        start.kernel_address orelse raw_kernel64_load_addr
    else
        start.kernel_address orelse kernel_load_addr;

    if (load_addr + kernel_bytes.len > ram.len) return error.KernelTooLarge;
    const max_kernel_dest = if (!is_aarch64 and dtb_load_addr <= ram.len and dtb_load_addr > load_addr)
        dtb_load_addr
    else
        ram.len;
    const loaded_kernel_size: usize = if (!is_aarch64)
        tryDecompressArmZImage(alloc, kernel_bytes, ram[load_addr..max_kernel_dest]) orelse blk: {
            @memcpy(ram[load_addr .. load_addr + kernel_bytes.len], kernel_bytes);
            break :blk kernel_bytes.len;
        }
    else blk: {
        @memcpy(ram[load_addr .. load_addr + kernel_bytes.len], kernel_bytes);
        break :blk kernel_bytes.len;
    };

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

    // Overlays may append to /chosen/bootargs; keep those additions after the command line,
    // which otherwise replaces the device tree's bootargs.
    const base_bootargs = if (tree.findNode("/chosen")) |c| c.getStringProp("bootargs") orelse "" else "";
    applyDtOverlays(alloc, &tree, overlays);
    const overlay_bootargs = if (tree.findNode("/chosen")) |c| c.getStringProp("bootargs") orelse "" else "";
    const full_cmdline = if (overlay_bootargs.len > base_bootargs.len and std.mem.startsWith(u8, overlay_bootargs, base_bootargs))
        std.mem.trim(u8, try std.fmt.allocPrint(alloc, "{s} {s}", .{ cmdline, overlay_bootargs[base_bootargs.len..] }), " ")
    else
        cmdline;

    const linux_kernel = isArm64KernelImage(kernel_bytes) or isArmZImage(kernel_bytes);
    try tree.patchForPiZero(@intCast(ram.len), full_cmdline, initrd_range, enable_vc4_kms, linux_kernel);
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
        .kernel_size = loaded_kernel_size,
        .dtb_size = patched_dtb.len,
        .initrd_size = initrd_len,
    };
}

/// Updates `/model`, `/system/linux,revision`, `/system/linux,serial`, `/serial-number`, and optional wireless MAC and Bluetooth address in the in-RAM DTB at `dtb_load_addr`.
pub fn applyBoardConfigToRamDtb(
    allocator: std.mem.Allocator,
    ram: []u8,
    dtb_size: usize,
    board_model: BoardModel,
    serial: u64,
    wifi_mac: ?[6]u8,
) !usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    if (dtb_load_addr + dtb_size > ram.len) return error.DtbTooLarge;
    var tree = try fdt.Tree.parse(alloc, ram[dtb_load_addr .. dtb_load_addr + dtb_size]);
    try tree.setBoardModel(board_model);
    try tree.setBoardSerial(serial);
    if (wifi_mac) |wmac| {
        try tree.setWirelessMac(wmac);
        try tree.setBluetooth(bluetooth.hciOrder(bluetooth.addressFromWifiMac(wmac)));
    } else {
        try tree.disableWireless();
        try tree.setBluetooth(null);
    }
    const updated_dtb = try tree.serialize(alloc);
    if (dtb_load_addr + updated_dtb.len > ram.len) return error.DtbTooLarge;
    @memcpy(ram[dtb_load_addr .. dtb_load_addr + updated_dtb.len], updated_dtb);
    return updated_dtb.len;
}



test "parse config.txt" {
    const sample =
        \\# Raspberry Pi config.txt
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

test "config.txt dtoverlay and dtparam grouping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sample =
        \\dtparam=audio=on,i2c_arm
        \\dtoverlay=i2c-rtc,ds3231
        \\dtparam=wakeup-source
        \\dtoverlay=
        \\dtparam=spi=on
        \\[pi4]
        \\dtoverlay=disable-bt
        \\[all]
        \\dtoverlay=gpio-fan,gpiopin=18,temp=55000
    ;
    const cfg = BootConfig.parseForModel(sample, .pi_3_b_plus);
    const overlays = try cfg.dtOverlays(arena.allocator());
    try std.testing.expectEqual(@as(usize, 4), overlays.len);

    try std.testing.expectEqualStrings("", overlays[0].name);
    try std.testing.expectEqual(@as(usize, 2), overlays[0].params.len);
    try std.testing.expectEqualStrings("audio", overlays[0].params[0].name);
    try std.testing.expectEqualStrings("on", overlays[0].params[0].value);
    try std.testing.expectEqualStrings("i2c_arm", overlays[0].params[1].name);
    try std.testing.expectEqualStrings("true", overlays[0].params[1].value);

    try std.testing.expectEqualStrings("i2c-rtc", overlays[1].name);
    try std.testing.expectEqual(@as(usize, 2), overlays[1].params.len);
    try std.testing.expectEqualStrings("ds3231", overlays[1].params[0].name);
    try std.testing.expectEqualStrings("wakeup-source", overlays[1].params[1].name);

    try std.testing.expectEqualStrings("", overlays[2].name);
    try std.testing.expectEqualStrings("spi", overlays[2].params[0].name);

    try std.testing.expectEqualStrings("gpio-fan", overlays[3].name);
    try std.testing.expectEqualStrings("55000", overlays[3].params[1].value);
}

test "raw AArch64 kernels load at kernel_address or 0x80000" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectEqual(@as(?u32, 0x100000), BootConfig.parseForModel("kernel_address=0x100000\n", .pi_3_b_plus).kernel_address);

    var tree = try fdt.Tree.initEmpty(alloc);
    const dtb = try tree.serialize(alloc);
    const ram = try alloc.alloc(u8, 0x0800_0000);
    @memset(ram, 0);
    const kernel: [128]u8 = @splat(0xaa); // No `Image` header

    const res = try loadDirectWithOverlays(alloc, ram, &kernel, dtb, null, "", false, &.{}, .{ .aarch64 = true });
    try std.testing.expect(res.is_aarch64);
    try std.testing.expectEqual(raw_kernel64_load_addr, res.entry_pc);
    try std.testing.expectEqual(dtb_load_addr, res.r0);
    try std.testing.expectEqualSlices(u8, &kernel, ram[raw_kernel64_load_addr..][0..kernel.len]);

    const res2 = try loadDirectWithOverlays(alloc, ram, &kernel, dtb, null, "", false, &.{}, .{ .aarch64 = true, .kernel_address = 0x100000 });
    try std.testing.expectEqual(@as(u32, 0x100000), res2.entry_pc);
}
