//! Flattened Device Tree (FDT / `.dtb`) parser, patcher, and serializer.
//!
//! Emulates the device-tree setup performed by the Raspberry Pi VideoCore
//! firmware (`start.elf`):
//! - Patches `/chosen` (`bootargs`, `linux,initrd-start`, `linux,initrd-end`)
//! - Patches `/memory@0` (`reg = <0x00000000 ram_size>`)
//! - Applies the `vc4-kms-v3d` overlay configuration (`i2c2`, `pixelvalve0..2`,
//!   `hvs`, `hdmi`, `v3d`, `vc4`, `txp` enabled; legacy `fb` disabled; `cma` sized)
//! - Sets `/soc/usb@7e980000` `compatible = "brcm,bcm2835-usb"` so mainline `dwc2` binds.
//! - Applies `.dtbo` overlays and `__overrides__` parameters (`dtoverlay=` / `dtparam=`).

const std = @import("std");
const BoardModel = @import("../ui/board.zig").BoardModel;
const HubKind = @import("../usb/hid.zig").HubKind;

pub const fdt_magic: u32 = 0xd00dfeed;
pub const fdt_version: u32 = 17;
pub const fdt_last_comp_version: u32 = 16;

const FDT_BEGIN_NODE: u32 = 0x00000001;
const FDT_END_NODE: u32 = 0x00000002;
const FDT_PROP: u32 = 0x00000003;
const FDT_NOP: u32 = 0x00000004;
const FDT_END: u32 = 0x00000009;

pub const ReserveEntry = struct {
    address: u64,
    size: u64,
};

pub const Prop = struct {
    name: []const u8,
    value: []const u8,
};

pub const Node = struct {
    name: []const u8,
    props: std.ArrayList(Prop) = .empty,
    children: std.ArrayList(*Node) = .empty,

    pub fn getProp(self: *const Node, name: []const u8) ?[]const u8 {
        for (self.props.items) |p| {
            if (std.mem.eql(u8, p.name, name)) return p.value;
        }
        return null;
    }

    pub fn getStringProp(self: *const Node, name: []const u8) ?[]const u8 {
        const raw = self.getProp(name) orelse return null;
        return std.mem.sliceTo(raw, 0);
    }

    pub fn setProp(self: *Node, allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        const val_copy = try allocator.dupe(u8, value);
        for (self.props.items) |*p| {
            if (std.mem.eql(u8, p.name, name)) {
                p.value = val_copy;
                return;
            }
        }
        const name_copy = try allocator.dupe(u8, name);
        try self.props.append(allocator, .{ .name = name_copy, .value = val_copy });
    }

    pub fn setStringProp(self: *Node, allocator: std.mem.Allocator, name: []const u8, str: []const u8) !void {
        const buf = try allocator.alloc(u8, str.len + 1);
        @memcpy(buf[0..str.len], str);
        buf[str.len] = 0;
        try self.setProp(allocator, name, buf);
    }

    pub fn setU32Prop(self: *Node, allocator: std.mem.Allocator, name: []const u8, val: u32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, val, .big);
        try self.setProp(allocator, name, &buf);
    }

    pub fn setCellsProp(self: *Node, allocator: std.mem.Allocator, name: []const u8, cells: []const u32) !void {
        const buf = try allocator.alloc(u8, cells.len * 4);
        for (cells, 0..) |c, i| {
            std.mem.writeInt(u32, buf[i * 4 ..][0..4], c, .big);
        }
        try self.setProp(allocator, name, buf);
    }

    pub fn deleteProp(self: *Node, name: []const u8) void {
        for (self.props.items, 0..) |p, i| {
            if (std.mem.eql(u8, p.name, name)) {
                _ = self.props.orderedRemove(i);
                return;
            }
        }
    }

    /// Returns the node's `phandle` (or legacy `linux,phandle`), if any.
    pub fn phandle(self: *const Node) ?u32 {
        const raw = self.getProp("phandle") orelse self.getProp("linux,phandle") orelse return null;
        if (raw.len != 4) return null;
        return std.mem.readInt(u32, raw[0..4], .big);
    }

    pub fn findChild(self: *const Node, name: []const u8) ?*Node {
        for (self.children.items) |c| {
            if (std.mem.eql(u8, c.name, name)) return c;
        }
        return null;
    }

    pub fn findOrCreateChild(self: *Node, allocator: std.mem.Allocator, name: []const u8) !*Node {
        if (self.findChild(name)) |c| return c;
        const c = try allocator.create(Node);
        c.* = .{ .name = try allocator.dupe(u8, name) };
        try self.children.append(allocator, c);
        return c;
    }
};

pub const Tree = struct {
    allocator: std.mem.Allocator,
    boot_cpuid_phys: u32 = 0,
    reserves: std.ArrayList(ReserveEntry) = .empty,
    root: *Node,

    pub fn initEmpty(allocator: std.mem.Allocator) !Tree {
        const root = try allocator.create(Node);
        root.* = .{ .name = "" };
        return .{
            .allocator = allocator,
            .root = root,
        };
    }

    /// Parses a binary `.dtb` blob into a mutable `Tree`.
    pub fn parse(allocator: std.mem.Allocator, dtb: []const u8) !Tree {
        if (dtb.len < 40) return error.InvalidDtbHeader;
        const magic = std.mem.readInt(u32, dtb[0..4], .big);
        if (magic != fdt_magic) return error.BadDtbMagic;

        const totalsize = std.mem.readInt(u32, dtb[4..8], .big);
        const off_dt_struct = std.mem.readInt(u32, dtb[8..12], .big);
        const off_dt_strings = std.mem.readInt(u32, dtb[12..16], .big);
        const off_mem_rsvmap = std.mem.readInt(u32, dtb[16..20], .big);
        const boot_cpuid_phys = std.mem.readInt(u32, dtb[28..32], .big);
        const size_dt_strings = std.mem.readInt(u32, dtb[32..36], .big);
        const size_dt_struct = std.mem.readInt(u32, dtb[36..40], .big);

        if (totalsize > dtb.len) return error.TruncatedDtb;
        if (off_dt_struct + size_dt_struct > dtb.len) return error.InvalidStructOffset;
        if (off_dt_strings + size_dt_strings > dtb.len) return error.InvalidStringsOffset;

        var tree: Tree = .{
            .allocator = allocator,
            .boot_cpuid_phys = boot_cpuid_phys,
            .root = undefined,
        };

        // Read memory reservation block
        var rsv_off: usize = off_mem_rsvmap;
        while (rsv_off + 16 <= dtb.len) : (rsv_off += 16) {
            const addr = std.mem.readInt(u64, dtb[rsv_off..][0..8], .big);
            const size = std.mem.readInt(u64, dtb[rsv_off + 8 ..][0..8], .big);
            if (addr == 0 and size == 0) break;
            try tree.reserves.append(allocator, .{ .address = addr, .size = size });
        }

        const struct_block = dtb[off_dt_struct .. off_dt_struct + size_dt_struct];
        const strings_block = dtb[off_dt_strings .. off_dt_strings + size_dt_strings];

        var stack: std.ArrayList(*Node) = .empty;
        defer stack.deinit(allocator);

        var pos: usize = 0;
        var root_node: ?*Node = null;

        while (pos + 4 <= struct_block.len) {
            const token = std.mem.readInt(u32, struct_block[pos..][0..4], .big);
            pos += 4;
            switch (token) {
                FDT_BEGIN_NODE => {
                    const name = std.mem.sliceTo(struct_block[pos..], 0);
                    pos = std.mem.alignForward(usize, pos + name.len + 1, 4);
                    const node = try allocator.create(Node);
                    node.* = .{ .name = try allocator.dupe(u8, name) };
                    if (stack.items.len > 0) {
                        const parent = stack.items[stack.items.len - 1];
                        try parent.children.append(allocator, node);
                    } else {
                        root_node = node;
                    }
                    try stack.append(allocator, node);
                },
                FDT_END_NODE => {
                    if (stack.items.len == 0) return error.UnexpectedEndNode;
                    _ = stack.pop();
                },
                FDT_PROP => {
                    if (pos + 8 > struct_block.len) return error.TruncatedProp;
                    const len = std.mem.readInt(u32, struct_block[pos..][0..4], .big);
                    const nameoff = std.mem.readInt(u32, struct_block[pos + 4 ..][0..4], .big);
                    pos += 8;
                    if (pos + len > struct_block.len) return error.TruncatedPropValue;
                    if (nameoff >= strings_block.len) return error.InvalidPropNameOffset;
                    const prop_name = std.mem.sliceTo(strings_block[nameoff..], 0);
                    const prop_val = struct_block[pos .. pos + len];
                    pos = std.mem.alignForward(usize, pos + len, 4);

                    if (stack.items.len == 0) return error.PropOutsideNode;
                    const cur = stack.items[stack.items.len - 1];
                    try cur.props.append(allocator, .{
                        .name = try allocator.dupe(u8, prop_name),
                        .value = try allocator.dupe(u8, prop_val),
                    });
                },
                FDT_NOP => {},
                FDT_END => break,
                else => return error.UnknownFdtToken,
            }
        }

        tree.root = root_node orelse return error.MissingRootNode;
        return tree;
    }

    /// Finds a node by path (e.g. `"/soc/usb@7e980000"`) or by symbol name in `/__symbols__`.
    pub fn findNode(self: *const Tree, path_or_symbol: []const u8) ?*Node {
        if (std.mem.eql(u8, path_or_symbol, "/")) return self.root;
        if (!std.mem.startsWith(u8, path_or_symbol, "/")) {
            if (self.root.findChild("__symbols__")) |syms| {
                if (syms.getStringProp(path_or_symbol)) |resolved_path| {
                    return self.findNode(resolved_path);
                }
            }
            return null;
        }

        var cur = self.root;
        var it = std.mem.tokenizeScalar(u8, path_or_symbol, '/');
        while (it.next()) |part| {
            cur = cur.findChild(part) orelse return null;
        }
        return cur;
    }

    pub fn findOrCreateNode(self: *Tree, path: []const u8) !*Node {
        if (std.mem.eql(u8, path, "/")) return self.root;
        var cur = self.root;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |part| {
            cur = try cur.findOrCreateChild(self.allocator, part);
        }
        return cur;
    }

    /// Configures the Device Tree for booting on the simulated Raspberry Pi Zero:
    /// - Sets memory size in `/memory@0`
    /// - Sets `bootargs` and optional `initrd` range in `/chosen`
    /// - Enables `vc4-kms-v3d` display + 3D nodes (`i2c2`, `pixelvalve0..2`, `hvs`, `hdmi`, `v3d`, `vc4`, `txp`)
    /// - Configures `/soc/usb@7e980000` for mainline `dwc2` (`brcm,bcm2835-usb`)
    pub const InitrdRange = struct {
        start: u32,
        end: u32,
    };

    pub fn setBoardSerial(self: *Tree, serial: u64) !void {
        const sys_node = try self.findOrCreateNode("/system");
        try sys_node.setCellsProp(self.allocator, "linux,serial", &.{
            @truncate(serial >> 32),
            @truncate(serial),
        });
        var sbuf: [16]u8 = undefined;
        const sstr = std.fmt.bufPrint(&sbuf, "{x:0>16}", .{serial}) catch "00000000fa000001";
        try self.root.setStringProp(self.allocator, "serial-number", sstr);
    }

    pub fn setBoardModel(self: *Tree, board_model: BoardModel) !void {
        try self.root.setStringProp(self.allocator, "model", board_model.dtModel());
        const sys_node = try self.findOrCreateNode("/system");
        try sys_node.setU32Prop(self.allocator, "linux,revision", board_model.boardRevision());
        try self.setBuiltInUsbHub(board_model.hubKind());
        try self.setHeadphoneAudioEnabled(board_model.hasHeadphoneJack());
    }

    pub fn setHeadphoneAudioEnabled(self: *Tree, enabled: bool) !void {
        // Configure audio_pins under /soc/gpio@7e200000 so pinctrl-bcm2835 succeeds when vchiq probes
        if (self.findNode("audio_pins") orelse self.findNode("/soc/gpio@7e200000/audio_pins")) |ap| {
            const existing_pins = ap.getProp("brcm,pins") orelse &.{};
            if (existing_pins.len == 0) {
                try ap.setCellsProp(self.allocator, "brcm,pins", &.{ 40, 45 });
                try ap.setU32Prop(self.allocator, "brcm,function", 4); // ALT0 (PWM0/PWM1)
                try ap.setU32Prop(self.allocator, "brcm,pull", 0);
            }
        }
        if (self.findNode("vchiq") orelse self.findNode("/soc/mailbox@7e00b840")) |vchiq_node| {
            try vchiq_node.setStringProp(self.allocator, "status", "okay");
            if (vchiq_node.findChild("audio")) |audio_child| {
                try audio_child.setStringProp(self.allocator, "status", if (enabled) "okay" else "disabled");
                try audio_child.setU32Prop(self.allocator, "brcm,enable-headphones", if (enabled) 1 else 0);
            }
        }
        if (self.findNode("audio")) |audio_node| {
            try audio_node.setStringProp(self.allocator, "status", if (enabled) "okay" else "disabled");
            try audio_node.setU32Prop(self.allocator, "brcm,enable-headphones", if (enabled) 1 else 0);
        }

        // Update snd_bcm2835.enable_headphones in /chosen/bootargs
        const chosen = try self.findOrCreateNode("/chosen");
        const cur_bootargs = chosen.getStringProp("bootargs") orelse "";
        var clean_buf: std.ArrayList(u8) = .empty;
        var tok = std.mem.tokenizeScalar(u8, cur_bootargs, ' ');
        while (tok.next()) |part| {
            if (std.mem.startsWith(u8, part, "snd_bcm2835.enable_headphones=")) continue;
            if (clean_buf.items.len > 0) try clean_buf.append(self.allocator, ' ');
            try clean_buf.appendSlice(self.allocator, part);
        }
        if (clean_buf.items.len > 0) try clean_buf.append(self.allocator, ' ');
        try clean_buf.appendSlice(
            self.allocator,
            if (enabled) "snd_bcm2835.enable_headphones=1" else "snd_bcm2835.enable_headphones=0",
        );
        try chosen.setStringProp(self.allocator, "bootargs", clean_buf.items);
    }

    pub fn setBuiltInUsbHub(self: *Tree, hub_kind: HubKind) !void {
        const usb = self.findNode("usb") orelse self.findNode("/soc/usb@7e980000") orelse return;
        usb.children.clearRetainingCapacity();
        if (hub_kind.dtHubCompatible()) |compat| {
            try usb.setU32Prop(self.allocator, "#address-cells", 1);
            try usb.setU32Prop(self.allocator, "#size-cells", 0);
            const hub_node = try usb.findOrCreateChild(self.allocator, "usb1@1");
            try hub_node.setStringProp(self.allocator, "compatible", compat);
            try hub_node.setU32Prop(self.allocator, "reg", 1);
        }
    }

    pub fn setWirelessMac(self: *Tree, wifi_mac: [6]u8) !void {
        const mmcnr = self.findNode("/soc/mmcnr@7e300000") orelse self.findNode("mmcnr");
        const mmc = self.findNode("/soc/mmc@7e300000") orelse self.findNode("sdhci") orelse self.findNode("mmc");
        const target = mmcnr orelse mmc;

        if (target) |sdhci_node| {
            // If both mmcnr@7e300000 and mmc@7e300000 exist, keep the non-selected clone disabled
            if (mmcnr != null and mmc != null and mmc.? != sdhci_node) {
                try mmc.?.setStringProp(self.allocator, "status", "disabled");
            }
            try sdhci_node.setStringProp(self.allocator, "status", "okay");
            try sdhci_node.setProp(self.allocator, "non-removable", &.{});
            try sdhci_node.setU32Prop(self.allocator, "bus-width", 4);
            try sdhci_node.setU32Prop(self.allocator, "#address-cells", 1);
            try sdhci_node.setU32Prop(self.allocator, "#size-cells", 0);

            const wifi = try sdhci_node.findOrCreateChild(self.allocator, "wifi@1");
            try wifi.setU32Prop(self.allocator, "reg", 1);
            try wifi.setStringProp(self.allocator, "compatible", "brcm,bcm4329-fmac");
            try wifi.setProp(self.allocator, "local-mac-address", &wifi_mac);

            if (self.findNode("/aliases")) |aliases| {
                const alias_path = if (std.mem.eql(u8, sdhci_node.name, "mmcnr@7e300000"))
                    "/soc/mmcnr@7e300000"
                else
                    "/soc/mmc@7e300000";
                try aliases.setStringProp(self.allocator, "mmc1", alias_path);
            }
        }
    }

    pub fn disableWireless(self: *Tree) !void {
        if (self.findNode("/soc/mmcnr@7e300000") orelse self.findNode("mmcnr")) |mmcnr| {
            try mmcnr.setStringProp(self.allocator, "status", "disabled");
        }
        // Only disable /soc/mmc@7e300000 if it has a wifi@1 child or if sdhost (/soc/mmc@7e202000) is enabled,
        // so upstream DTBs or dtoverlay=sdio that route the primary SD card to Arasan SDHCI continue to work.
        const sdhost_node = self.findNode("sdhost") orelse self.findNode("/soc/mmc@7e202000") orelse self.findNode("/soc/sdhost@7e202000");
        const sdhost_enabled = if (sdhost_node) |sh|
            std.mem.eql(u8, sh.getStringProp("status") orelse "okay", "okay")
        else
            false;

        for ([_][]const u8{ "/soc/mmc@7e300000", "sdhci" }) |path| {
            if (self.findNode(path)) |n| {
                if (n.findChild("wifi@1") != null or sdhost_enabled) {
                    try n.setStringProp(self.allocator, "status", "disabled");
                }
            }
        }
    }

    /// Fills in `local-bd-address` (LSB first, as the firmware does) on the Bluetooth serdev
    /// nodes (`bt` on the PL011, `minibt` on the mini UART), or disables them when the board
    /// has no Bluetooth (`bd_addr` null).
    pub fn setBluetooth(self: *Tree, bd_addr: ?[6]u8) !void {
        const candidates = [_]?*Node{
            self.findNode("bt") orelse self.findNode("/soc/serial@7e201000/bluetooth"),
            self.findNode("minibt") orelse self.findNode("/soc/serial@7e215040/bluetooth"),
        };
        for (candidates) |candidate| {
            const node = candidate orelse continue;
            if (bd_addr) |addr| {
                try node.setProp(self.allocator, "local-bd-address", &addr);
            } else {
                try node.setStringProp(self.allocator, "status", "disabled");
            }
        }
    }

    pub fn configureSpinTable64(self: *Tree) !void {
        var has_zero_reserve = false;
        for (self.reserves.items) |r| {
            if (r.address == 0) {
                has_zero_reserve = true;
                break;
            }
        }
        if (!has_zero_reserve) {
            try self.reserves.append(self.allocator, .{ .address = 0, .size = 0x1000 });
        }

        const cpus = try self.findOrCreateNode("/cpus");
        const cpu_names = [_][]const u8{ "cpu@0", "cpu@1", "cpu@2", "cpu@3" };
        for (cpu_names, 0..) |cname, i| {
            const cnode = try cpus.findOrCreateChild(self.allocator, cname);
            try cnode.setStringProp(self.allocator, "device_type", "cpu");
            try cnode.setStringProp(self.allocator, "compatible", "arm,cortex-a53");
            try cnode.setU32Prop(self.allocator, "reg", @intCast(i));
            try cnode.setStringProp(self.allocator, "enable-method", "spin-table");
            try cnode.setCellsProp(self.allocator, "cpu-release-addr", &.{ 0, @intCast(0xd8 + i * 8) });
        }
    }

    pub fn setSimpleFramebuffer(self: *Tree, width: u32, height: u32) !void {
        const chosen = try self.findOrCreateNode("/chosen");
        try chosen.setU32Prop(self.allocator, "#address-cells", 1);
        try chosen.setU32Prop(self.allocator, "#size-cells", 1);
        try chosen.setProp(self.allocator, "ranges", &.{});
        const fb_node = try chosen.findOrCreateChild(self.allocator, "framebuffer@1c100000");
        const stride: u32 = width * 4;
        const fb_size: u32 = stride * height;
        try fb_node.setStringProp(self.allocator, "compatible", "simple-framebuffer");
        try fb_node.setCellsProp(self.allocator, "reg", &.{ 0x1c10_0000, fb_size });
        try fb_node.setU32Prop(self.allocator, "width", width);
        try fb_node.setU32Prop(self.allocator, "height", height);
        try fb_node.setU32Prop(self.allocator, "stride", stride);
        try fb_node.setStringProp(self.allocator, "format", "x8r8g8b8");
        try fb_node.setStringProp(self.allocator, "status", "okay");
    }

    pub fn patchForPiZero(
        self: *Tree,
        ram_size: u32,
        cmdline: []const u8,
        initrd: ?InitrdRange,
        enable_vc4_kms: bool,
    ) !void {
        // 1. Memory size (reserve top 64 MiB at 0x1c000000..0x20000000 for VideoCore framebuffer & allocations)
        const arm_ram_size: u32 = if (enable_vc4_kms and ram_size > 0x1c00_0000) 0x1c00_0000 else ram_size;
        const mem_node = self.findNode("/memory@0") orelse self.findNode("/memory") orelse try self.findOrCreateNode("/memory@0");
        try mem_node.setCellsProp(self.allocator, "reg", &.{ 0, arm_ram_size });

        // 2. /chosen bootargs, initrd, and rng-seed (initializes kernel CRNG immediately at boot)
        const chosen = try self.findOrCreateNode("/chosen");
        const serial0_target = if (self.findNode("/aliases")) |aliases|
            aliases.getStringProp("serial0")
        else
            null;
        const serial0_is_aux = if (serial0_target) |st|
            std.mem.indexOf(u8, st, "7e215040") != null
        else
            false;
        if (cmdline.len > 0) {
            const serial0_tty = if (serial0_is_aux) "ttyS0" else "ttyAMA0";
            const serial1_tty = if (serial0_is_aux) "ttyAMA0" else "ttyS0";

            var bootargs_buf: std.ArrayList(u8) = .empty;
            if (serial0_is_aux and std.mem.indexOf(u8, cmdline, "8250.nr_uarts=") == null) {
                try bootargs_buf.appendSlice(self.allocator, "8250.nr_uarts=1 ");
            }
            var i: usize = 0;
            while (i < cmdline.len) {
                if (std.mem.startsWith(u8, cmdline[i..], "console=serial0")) {
                    try bootargs_buf.appendSlice(self.allocator, "console=");
                    try bootargs_buf.appendSlice(self.allocator, serial0_tty);
                    i += "console=serial0".len;
                } else if (std.mem.startsWith(u8, cmdline[i..], "console=serial1")) {
                    try bootargs_buf.appendSlice(self.allocator, "console=");
                    try bootargs_buf.appendSlice(self.allocator, serial1_tty);
                    i += "console=serial1".len;
                } else {
                    try bootargs_buf.append(self.allocator, cmdline[i]);
                    i += 1;
                }
            }
            try chosen.setStringProp(self.allocator, "bootargs", bootargs_buf.items);
        }
        if (initrd) |rd| {
            try chosen.setU32Prop(self.allocator, "linux,initrd-start", rd.start);
            try chosen.setU32Prop(self.allocator, "linux,initrd-end", rd.end);
        }
        var rng_seed: [64]u8 = undefined;
        @import("../host/posix.zig").getRandomBytes(&rng_seed);
        try chosen.setProp(self.allocator, "rng-seed", &rng_seed);

        // 2b. /system board revision (0x00900093 = Raspberry Pi Zero v1.3, 512MB) and serial
        const sys_node = try self.findOrCreateNode("/system");
        try sys_node.setU32Prop(self.allocator, "linux,revision", 0x00900093);
        try self.setBoardSerial(0x00000000fa000001);

        // 2c. Ensure PL011 UART0 (/soc/serial@7e201000) is enabled (its Bluetooth serdev child is set up by `setBluetooth`)
        if (self.findNode("/soc/serial@7e201000") orelse self.findNode("uart0")) |uart0| {
            try uart0.setStringProp(self.allocator, "status", "okay");
            if (!serial0_is_aux) {
                if (self.findNode("/aliases")) |aliases| {
                    try aliases.setStringProp(self.allocator, "serial0", "/soc/serial@7e201000");
                }
            }
        }

        // 3. Ensure USB controller uses mainline dwc2 compatible string
        if (self.findNode("usb") orelse self.findNode("/soc/usb@7e980000")) |usb| {
            try usb.setStringProp(self.allocator, "compatible", "brcm,bcm2835-usb");
            try usb.setStringProp(self.allocator, "status", "okay");
        }

        // Configure audio_pins so /soc/mailbox@7e00b840 (vchiq) probes without pinctrl errors
        if (self.findNode("audio_pins") orelse self.findNode("/soc/gpio@7e200000/audio_pins")) |ap| {
            const existing_pins = ap.getProp("brcm,pins") orelse &.{};
            if (existing_pins.len == 0) {
                try ap.setCellsProp(self.allocator, "brcm,pins", &.{ 40, 45 });
                try ap.setU32Prop(self.allocator, "brcm,function", 4);
                try ap.setU32Prop(self.allocator, "brcm,pull", 0);
            }
        }

        // 4. Enable vc4-kms-v3d nodes (equivalent to dtoverlay=vc4-kms-v3d)
        if (enable_vc4_kms) {
            // With firmware KMS (dtoverlay=vc4-fkms-v3d) the firmware drives the display pipeline, so its
            // nodes stay disabled as on hardware; enabling them too gives vc4 a second set of CRTCs whose
            // vblanks never arrive, and the first modeset never completes.
            const firmware_kms = if (self.findNode("firmwarekms") orelse self.findNode("/soc/firmwarekms@7e600000")) |n|
                std.mem.eql(u8, n.getStringProp("status") orelse "", "okay")
            else
                false;
            const pipeline_targets = [_][]const u8{
                "i2c2",
                "/soc/i2c@7e805000",
                "pixelvalve0",
                "/soc/pixelvalve@7e206000",
                "pixelvalve1",
                "/soc/pixelvalve@7e207000",
                "pixelvalve2",
                "/soc/pixelvalve@7e807000",
                "hvs",
                "/soc/hvs@7e400000",
                "hdmi",
                "/soc/hdmi@7e902000",
                "txp",
                "/soc/txp@7e004000",
            };
            const gpu_targets = [_][]const u8{
                "v3d",
                "/soc/v3d@7ec00000",
                "vc4",
                "/soc/gpu",
                "/gpu",
            };
            for (gpu_targets) |t| {
                if (self.findNode(t)) |n| {
                    try n.setStringProp(self.allocator, "status", "okay");
                }
            }
            if (!firmware_kms) {
                for (pipeline_targets) |t| {
                    if (self.findNode(t)) |n| {
                        try n.setStringProp(self.allocator, "status", "okay");
                    }
                }
            }
            // Disable legacy bcm2708_fb
            for ([_][]const u8{ "fb", "/soc/fb" }) |t| {
                if (self.findNode(t)) |n| {
                    try n.setStringProp(self.allocator, "status", "disabled");
                }
            }
            // Claim PLL clocks on cprman
            if (self.findNode("clocks") orelse self.findNode("/soc/cprman@7e101000")) |clocks| {
                // BCM2835_PLLD_DSI0 (13), BCM2835_PLLD_DSI1 (14), BCM2835_PLLH_AUX (16), BCM2835_PLLH_PIX (17)
                try clocks.setCellsProp(self.allocator, "claim-clocks", &.{ 13, 14, 16, 17 });
            }
            // Set CMA size to 128 MiB (plenty for 512 MiB Pi Zero while leaving 384 MiB for kernel + userland)
            if (self.findNode("cma") orelse self.findNode("/reserved-memory/linux,cma")) |cma| {
                try cma.setU32Prop(self.allocator, "size", 128 * 1024 * 1024);
            }
            // Populate /chosen/framebuffer@1c100000 for early boot simpledrm / simplefb console output
            try self.setSimpleFramebuffer(1280, 720);
        }
    }

    // Device-tree overlays (`dtoverlay=` / `dtparam=`), following the Raspberry Pi `dtoverlay`
    // library (raspberrypi/utils `dtmerge/dtoverlay.c`): an overlay is first fixed up against the
    // base (`fixupOverlay`), then parameters are applied through `__overrides__` (`applyParam`),
    // then its fragments are merged into the base (`mergeOverlay`).

    fn maxPhandleIn(node: *const Node) u32 {
        var m: u32 = 0;
        for ([_][]const u8{ "phandle", "linux,phandle" }) |name| {
            if (node.getProp(name)) |raw| {
                if (raw.len == 4) {
                    const ph = std.mem.readInt(u32, raw[0..4], .big);
                    if (ph != 0xffffffff) m = @max(m, ph);
                }
            }
        }
        for (node.children.items) |c| m = @max(m, maxPhandleIn(c));
        return m;
    }

    pub fn maxPhandle(self: *const Tree) u32 {
        return maxPhandleIn(self.root);
    }

    fn findByPhandleIn(node: *Node, ph: u32) ?*Node {
        if (node.phandle()) |p| {
            if (p == ph) return node;
        }
        for (node.children.items) |c| {
            if (findByPhandleIn(c, ph)) |n| return n;
        }
        return null;
    }

    pub fn findByPhandle(self: *const Tree, ph: u32) ?*Node {
        if (ph == 0 or ph == 0xffffffff) return null;
        return findByPhandleIn(self.root, ph);
    }

    fn pathOfIn(allocator: std.mem.Allocator, node: *const Node, target: *const Node, buf: *std.ArrayList(u8)) !bool {
        if (node == target) return true;
        for (node.children.items) |c| {
            const mark = buf.items.len;
            try buf.append(allocator, '/');
            try buf.appendSlice(allocator, c.name);
            if (try pathOfIn(allocator, c, target, buf)) return true;
            buf.shrinkRetainingCapacity(mark);
        }
        return false;
    }

    /// Returns the absolute path of `target` (e.g. `"/soc/i2c@7e804000"`), or null if it is not in this tree.
    pub fn pathOf(self: *const Tree, target: *const Node) !?[]const u8 {
        if (target == self.root) return "/";
        var buf: std.ArrayList(u8) = .empty;
        if (try pathOfIn(self.allocator, self.root, target, &buf)) return buf.items;
        buf.deinit(self.allocator);
        return null;
    }

    fn ensurePhandle(self: *Tree, node: *Node) !u32 {
        if (node.phandle()) |p| return p;
        const p = self.maxPhandle() + 1;
        try node.setU32Prop(self.allocator, "phandle", p);
        return p;
    }

    /// Sets (or adds to) the big-endian cell at byte `offset` of `prop_name` in place.
    /// Property values are always allocator-owned copies, so mutating them is safe.
    fn patchCell(node: *Node, prop_name: []const u8, offset: usize, val: u32, add: bool) !void {
        const raw = node.getProp(prop_name) orelse return error.FixupPropertyNotFound;
        if (offset + 4 > raw.len) return error.FixupOutOfRange;
        const cell = @constCast(raw[offset..][0..4]);
        const new = if (add) std.mem.readInt(u32, cell, .big) +% val else val;
        std.mem.writeInt(u32, cell, new, .big);
    }

    const FixupRef = struct {
        path: []const u8,
        prop: []const u8,
        offset: usize,
    };

    /// Parses a `"path:property:offset"` fixup reference.
    fn parseFixupRef(s: []const u8) !FixupRef {
        const c2 = std.mem.lastIndexOfScalar(u8, s, ':') orelse return error.MalformedFixup;
        const c1 = std.mem.lastIndexOfScalar(u8, s[0..c2], ':') orelse return error.MalformedFixup;
        return .{
            .path = s[0..c1],
            .prop = s[c1 + 1 .. c2],
            .offset = std.fmt.parseInt(usize, s[c2 + 1 ..], 10) catch return error.MalformedFixup,
        };
    }

    fn relocatePhandles(node: *Node, delta: u32) void {
        if (std.mem.eql(u8, node.name, "__local_fixups__") or std.mem.eql(u8, node.name, "__fixups__")) return;
        for (node.props.items) |p| {
            if ((std.mem.eql(u8, p.name, "phandle") or std.mem.eql(u8, p.name, "linux,phandle")) and p.value.len == 4) {
                const cell = @constCast(p.value[0..4]);
                const ph = std.mem.readInt(u32, cell, .big);
                if (ph != 0 and ph != 0xffffffff) std.mem.writeInt(u32, cell, ph +% delta, .big);
            }
        }
        for (node.children.items) |c| relocatePhandles(c, delta);
    }

    fn applyLocalFixups(fixups: *const Node, node: *Node, delta: u32) !void {
        for (fixups.props.items) |p| {
            var i: usize = 0;
            while (i + 4 <= p.value.len) : (i += 4) {
                const offset = std.mem.readInt(u32, p.value[i..][0..4], .big);
                try patchCell(node, p.name, offset, delta, true);
            }
        }
        for (fixups.children.items) |c| {
            const child = node.findChild(c.name) orelse return error.FixupNodeNotFound;
            try applyLocalFixups(c, child, delta);
        }
    }

    /// Resolves an overlay's external (`__fixups__`) references against this base tree and
    /// relocates its local phandles (`__local_fixups__`) above the base's highest phandle.
    pub fn fixupOverlay(self: *Tree, overlay: *Tree) !void {
        if (overlay.root.findChild("__fixups__")) |fixups| {
            if (fixups.props.items.len > 0) {
                const symbols = self.root.findChild("__symbols__") orelse return error.BaseHasNoSymbols;
                for (fixups.props.items) |p| {
                    const target_path = if (p.name.len > 0 and p.name[0] == '/')
                        p.name
                    else
                        symbols.getStringProp(p.name) orelse return error.UnknownOverlaySymbol;
                    const target = self.findNode(target_path) orelse return error.UnknownOverlaySymbol;
                    const ph = try self.ensurePhandle(target);
                    var it = std.mem.splitScalar(u8, p.value, 0);
                    while (it.next()) |entry| {
                        if (entry.len == 0) break;
                        const ref = try parseFixupRef(entry);
                        const node = overlay.findNode(ref.path) orelse return error.FixupNodeNotFound;
                        try patchCell(node, ref.prop, ref.offset, ph, false);
                    }
                }
            }
        }

        const delta = self.maxPhandle();
        if (delta == 0) return;
        relocatePhandles(overlay.root, delta);
        if (overlay.root.findChild("__local_fixups__")) |local_fixups| {
            if (local_fixups.getProp("fixup")) |old_style| {
                var it = std.mem.splitScalar(u8, old_style, 0);
                while (it.next()) |entry| {
                    if (entry.len == 0) break;
                    const ref = try parseFixupRef(entry);
                    const node = overlay.findNode(ref.path) orelse return error.FixupNodeNotFound;
                    try patchCell(node, ref.prop, ref.offset, delta, true);
                }
            } else {
                try applyLocalFixups(local_fixups, overlay.root, delta);
            }
        }
    }

    /// Applies parameter `name` = `value` using the overlay's `__overrides__`, falling back to this
    /// (base) tree's `__overrides__`. Returns false if neither declares the parameter.
    pub fn applyParam(self: *Tree, overlay: ?*Tree, name: []const u8, value: []const u8) !bool {
        if (overlay) |ov| {
            if (ov.root.findChild("__overrides__")) |overrides| {
                if (overrides.getProp(name)) |decl| {
                    try ov.applyOverride(decl, value);
                    return true;
                }
            }
        }
        if (self.root.findChild("__overrides__")) |overrides| {
            if (overrides.getProp(name)) |decl| {
                try self.applyOverride(decl, value);
                return true;
            }
        }
        return false;
    }

    const OverrideKind = enum { integer, boolean, boolean_inv, string, byte_string };

    /// Applies one `__overrides__` declaration: a sequence of `<phandle> "property<type>[offset][=literal|{lookup}]"` targets.
    fn applyOverride(self: *Tree, data: []const u8, param_value: []const u8) !void {
        const alloc = self.allocator;
        var pos: usize = 0;
        while (pos < data.len) {
            if (data.len - pos < 6) return error.MalformedOverride;
            const ph = std.mem.readInt(u32, data[pos..][0..4], .big);
            pos += 4;
            const decl = std.mem.sliceTo(data[pos..], 0);
            pos = @min(data.len, pos + decl.len + 1);

            if (ph == 0) {
                try self.applyFragmentControl(decl, param_value);
                continue;
            }

            const target_len = std.mem.indexOfAny(u8, decl, "={") orelse decl.len;
            const name_len = std.mem.indexOfAny(u8, decl, ".;:#?![{=") orelse decl.len;
            const prop = decl[0..name_len];
            var kind: OverrideKind = .string;
            var size: u4 = 0;
            var offset: usize = 0;
            if (name_len < target_len) {
                const sep = decl[name_len];
                switch (sep) {
                    '.', ';', ':', '#' => {
                        kind = .integer;
                        size = switch (sep) {
                            '.' => 1,
                            ';' => 2,
                            ':' => 4,
                            else => 8,
                        };
                        offset = parseLeadingDecimal(decl[name_len + 1 .. target_len]);
                    },
                    '?' => kind = .boolean,
                    '!' => kind = .boolean_inv,
                    '[' => kind = .byte_string,
                    else => {},
                }
            }

            var value = param_value;
            var cell_buf: [16]u8 = undefined;
            if (target_len < decl.len) {
                const literal = decl[target_len + 1 ..];
                if (decl[target_len] == '{') {
                    value = (try lookupOverrideValue(literal, value)) orelse return error.OverrideLookupNoMatch;
                } else if (literal.len > 0 or kind == .byte_string) {
                    value = literal;
                } else if (kind == .string) {
                    // `"prop=",&label` - the value is the following string (e.g. a label's path)
                    value = std.mem.sliceTo(data[pos..], 0);
                    pos = @min(data.len, pos + value.len + 1);
                } else {
                    // `"prop:0=",<cell>` - the value is the following cell
                    if (data.len - pos < 4) return error.MalformedOverride;
                    const cell = std.mem.readInt(u32, data[pos..][0..4], .big);
                    pos += 4;
                    value = std.fmt.bufPrint(&cell_buf, "{d}", .{cell}) catch unreachable;
                }
            }
            if (kind == .string and std.mem.eql(u8, prop, "status")) value = statusValue(value);

            const node = self.findByPhandle(ph) orelse continue;
            switch (kind) {
                .string => {
                    const s = try unescapeOverrideString(alloc, value);
                    if (std.mem.eql(u8, prop, "name")) {
                        node.name = try alloc.dupe(u8, s);
                    } else if (std.mem.eql(u8, prop, "bootargs")) {
                        try appendBootargs(alloc, node, s);
                    } else {
                        try node.setStringProp(alloc, prop, s);
                    }
                },
                .byte_string => {
                    var bytes: [32]u8 = undefined;
                    var n: usize = 0;
                    var i: usize = 0;
                    while (i < value.len) {
                        if (value[i] == ':' or value[i] == ' ' or value[i] == '\t') {
                            i += 1;
                            continue;
                        }
                        if (i + 2 > value.len or n == bytes.len) return error.InvalidOverrideValue;
                        bytes[n] = std.fmt.parseInt(u8, value[i .. i + 2], 16) catch return error.InvalidOverrideValue;
                        n += 1;
                        i += 2;
                    }
                    try node.setProp(alloc, prop, bytes[0..n]);
                },
                .integer => {
                    const n = parseOverrideInt(value, false) orelse continue;
                    const is_reg = std.mem.eql(u8, prop, "reg");
                    const existing = node.getProp(prop) orelse &.{};
                    if (existing.len >= offset + size or !is_reg) {
                        const buf = try alloc.alloc(u8, @max(existing.len, offset + size));
                        @memset(buf, 0);
                        @memcpy(buf[0..existing.len], existing);
                        for (0..size) |b| {
                            const shift: u6 = @intCast(8 * (size - 1 - b));
                            buf[offset + b] = @truncate(n >> shift);
                        }
                        try node.setProp(alloc, prop, buf);
                    }
                    if (is_reg and offset == 0) {
                        const at = std.mem.indexOfScalar(u8, node.name, '@') orelse node.name.len;
                        node.name = try std.fmt.allocPrint(alloc, "{s}@{x}", .{ node.name[0..at], @as(u32, @truncate(n)) });
                    }
                },
                .boolean, .boolean_inv => {
                    const n = parseOverrideInt(value, false) orelse continue;
                    if ((n != 0) != (kind == .boolean_inv)) {
                        try node.setProp(alloc, prop, &.{});
                    } else {
                        node.deleteProp(prop);
                    }
                },
            }
        }
    }

    /// Applies a fragment control string (`"+0-1=2!3"`), renaming each fragment's
    /// `__overlay__` / `__dormant__` child to enable or disable it.
    fn applyFragmentControl(self: *Tree, decl: []const u8, param_value: []const u8) !void {
        const value = (parseOverrideInt(param_value, true) orelse 0) != 0;
        var i: usize = 0;
        while (i < decl.len) {
            const op = decl[i];
            i += 1;
            const start = i;
            while (i < decl.len and std.ascii.isAlphanumeric(decl[i])) i += 1;
            const index = if (i == start) 0 else parseCInt(decl[start..i]) orelse return error.InvalidFragmentControl;
            const active = switch (op) {
                '+' => true,
                '-' => false,
                '=' => value,
                '!' => !value,
                else => return error.InvalidFragmentControl,
            };
            var name_buf: [32]u8 = undefined;
            const frag = self.root.findChild(std.fmt.bufPrint(&name_buf, "fragment@{d}", .{index}) catch unreachable) orelse
                self.root.findChild(std.fmt.bufPrint(&name_buf, "fragment-{d}", .{index}) catch unreachable) orelse
                continue;
            const from: []const u8 = if (active) "__dormant__" else "__overlay__";
            if (frag.findChild(from)) |c| c.name = if (active) "__overlay__" else "__dormant__";
        }
    }

    fn parseLeadingDecimal(s: []const u8) usize {
        var n: usize = 0;
        for (s) |c| {
            if (c < '0' or c > '9') break;
            n = n *% 10 +% (c - '0');
        }
        return n;
    }

    /// Parses an integer like C `strtoull(s, NULL, 0)` (decimal, `0x` hex, or leading-`0` octal).
    fn parseCInt(s: []const u8) ?u64 {
        if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) return std.fmt.parseInt(u64, s[2..], 16) catch null;
        if (s.len > 1 and s[0] == '0') return std.fmt.parseInt(u64, s[1..], 8) catch null;
        return std.fmt.parseInt(u64, s, 10) catch null;
    }

    /// Parses an override value as an integer or boolean keyword. For fragment control, any
    /// other non-empty value counts as true.
    fn parseOverrideInt(s: []const u8, fragment_control: bool) ?u64 {
        if (s.len == 0) return 0;
        if (parseCInt(s)) |n| return n;
        for ([_][]const u8{ "y", "yes", "on", "true", "down" }) |w| {
            if (std.mem.eql(u8, s, w)) return 1;
        }
        for ([_][]const u8{ "n", "no", "off", "false" }) |w| {
            if (std.mem.eql(u8, s, w)) return 0;
        }
        if (std.mem.eql(u8, s, "up")) return 2;
        return if (fragment_control) 1 else null;
    }

    fn statusValue(s: []const u8) []const u8 {
        for ([_][]const u8{ "y", "yes", "on", "true", "enable", "1" }) |w| {
            if (std.mem.eql(u8, s, w)) return "okay";
        }
        for ([_][]const u8{ "n", "no", "off", "false", "0" }) |w| {
            if (std.mem.eql(u8, s, w)) return "disabled";
        }
        return s;
    }

    /// Looks `key` up in an override lookup table (`a=1,b='x,y',=default}`).
    fn lookupOverrideValue(table: []const u8, key: []const u8) !?[]const u8 {
        var default: ?[]const u8 = null;
        var i: usize = 0;
        while (true) {
            const key_end = i + (std.mem.indexOfAny(u8, table[i..], "=,}") orelse return error.MalformedOverrideLookup);
            const k = table[i..key_end];
            var v: ?[]const u8 = null;
            i = key_end;
            if (table[i] == '=') {
                i += 1;
                if (i < table.len and table[i] == '\'') {
                    const close = std.mem.indexOfScalarPos(u8, table, i + 1, '\'') orelse return error.MalformedOverrideLookup;
                    v = table[i + 1 .. close];
                    i = close + 1;
                } else {
                    // A value that continues as a following cell (`key=",<&label>`) is not supported.
                    const value_end = i + (std.mem.indexOfAny(u8, table[i..], ",}") orelse return error.UnsupportedOverrideLookup);
                    v = table[i..value_end];
                    i = value_end;
                }
            }
            if (k.len == 0) {
                if (default == null) default = v orelse key;
            } else if (std.mem.eql(u8, k, key)) {
                return v orelse key;
            }
            if (i >= table.len) return error.MalformedOverrideLookup;
            if (table[i] == '}') break;
            i += 1;
        }
        return default;
    }

    fn unescapeOverrideString(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
        if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            if (s[i] != '\\') {
                try out.append(allocator, s[i]);
                continue;
            }
            i += 1;
            if (i >= s.len) return error.InvalidOverrideEscape;
            const c: u8 = switch (s[i]) {
                'a' => 0x07,
                'b' => 0x08,
                'f' => 0x0c,
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                'v' => 0x0b,
                '\\', '\'', '"' => s[i],
                'x' => blk: {
                    if (i + 3 > s.len) return error.InvalidOverrideEscape;
                    const b = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return error.InvalidOverrideEscape;
                    i += 2;
                    break :blk b;
                },
                '0'...'7' => blk: {
                    var n: u16 = 0;
                    var digits: usize = 0;
                    while (digits < 3 and i < s.len and s[i] >= '0' and s[i] <= '7') : (digits += 1) {
                        n = n * 8 + (s[i] - '0');
                        i += 1;
                    }
                    i -= 1;
                    if (n > 255) return error.InvalidOverrideEscape;
                    break :blk @intCast(n);
                },
                else => return error.InvalidOverrideEscape,
            };
            try out.append(allocator, c);
        }
        return out.items;
    }

    fn appendBootargs(allocator: std.mem.Allocator, node: *Node, s: []const u8) !void {
        const existing = node.getStringProp("bootargs") orelse "";
        if (existing.len == 0) return node.setStringProp(allocator, "bootargs", s);
        try node.setStringProp(allocator, "bootargs", try std.fmt.allocPrint(allocator, "{s} {s}", .{ existing, s }));
    }

    fn fragmentTargetPhandle(frag: *const Node) ?u32 {
        const raw = frag.getProp("target") orelse return null;
        if (raw.len != 4) return null;
        return std.mem.readInt(u32, raw[0..4], .big);
    }

    /// Resolves an overlay fragment's `target-path` (path or alias) or `target` (phandle) in this tree.
    fn resolveFragmentTarget(self: *const Tree, frag: *const Node) ?*Node {
        if (frag.getProp("target-path")) |raw| {
            const path = std.mem.sliceTo(raw, 0);
            if (path.len > 0 and path[0] != '/') {
                if (self.root.findChild("aliases")) |aliases| {
                    if (aliases.getStringProp(path)) |p| return self.findNode(p);
                }
            }
            return self.findNode(path);
        }
        return self.findByPhandle(fragmentTargetPhandle(frag) orelse return null);
    }

    /// Rewrites an overlay path `/<fragment>/__overlay__[/rest]` to the matching path in this tree.
    fn rewriteOverlayPath(self: *const Tree, overlay: *const Tree, raw: []const u8) ![]const u8 {
        const path = std.mem.sliceTo(raw, 0);
        if (path.len < 2 or path[0] != '/') return raw;
        const frag_end = std.mem.indexOfScalarPos(u8, path, 1, '/') orelse return raw;
        const after = path[frag_end + 1 ..];
        if (!std.mem.startsWith(u8, after, "__overlay__")) return raw;
        const rest = after["__overlay__".len..];
        if (rest.len > 0 and rest[0] != '/') return raw;
        const frag = overlay.root.findChild(path[1..frag_end]) orelse return raw;
        const target = self.resolveFragmentTarget(frag) orelse return raw;
        const target_path = (try self.pathOf(target)) orelse return raw;
        const base = if (std.mem.eql(u8, target_path, "/") and rest.len > 0) "" else target_path;
        return std.fmt.allocPrint(self.allocator, "{s}{s}\x00", .{ base, rest });
    }

    fn mergeNode(allocator: std.mem.Allocator, dst: *Node, src: *const Node, depth: u32) !void {
        const preserve_phandle = src.getProp("dtoverlay,preserve-phandle") != null;
        for (src.props.items) |p| {
            if (std.mem.eql(u8, p.name, "name") or std.mem.eql(u8, p.name, "dtoverlay,preserve-phandle")) continue;
            if (depth == 0 and !preserve_phandle and
                (std.mem.eql(u8, p.name, "phandle") or std.mem.eql(u8, p.name, "linux,phandle"))) continue;
            if (std.mem.eql(u8, p.name, "bootargs")) {
                try appendBootargs(allocator, dst, std.mem.sliceTo(p.value, 0));
                continue;
            }
            try dst.setProp(allocator, p.name, p.value);
        }
        for (src.children.items) |c| {
            try mergeNode(allocator, try dst.findOrCreateChild(allocator, c.name), c, depth + 1);
        }
    }

    /// Merges a fixed-up overlay's enabled fragments (and exported symbols) into this base tree.
    pub fn mergeOverlay(self: *Tree, overlay: *Tree) !void {
        // Fragments targeting nodes inside the overlay itself are merged first.
        for (overlay.root.children.items) |frag| {
            const ov = frag.findChild("__overlay__") orelse continue;
            if (frag.getProp("target-path") != null) continue;
            const target = overlay.findByPhandle(fragmentTargetPhandle(frag) orelse continue) orelse continue;
            try mergeNode(self.allocator, target, ov, 0);
            ov.name = "__dormant__";
        }

        for (overlay.root.children.items) |frag| {
            const ov = frag.findChild("__overlay__") orelse continue;
            const target = self.resolveFragmentTarget(frag) orelse return error.OverlayTargetNotFound;
            if (std.mem.eql(u8, target.name, "aliases")) {
                for (ov.props.items) |p| {
                    try target.setProp(self.allocator, p.name, try self.rewriteOverlayPath(overlay, p.value));
                }
            } else {
                try mergeNode(self.allocator, target, ov, 0);
            }
        }

        // Only symbols listed in `__exports__` are visible to the base and later overlays.
        const symbols = overlay.root.findChild("__symbols__") orelse return;
        const exports = overlay.root.findChild("__exports__") orelse return;
        const base_symbols = self.root.findChild("__symbols__") orelse return;
        for (symbols.props.items) |p| {
            if (exports.getProp(p.name) == null) continue;
            try base_symbols.setProp(self.allocator, p.name, try self.rewriteOverlayPath(overlay, p.value));
        }
    }

    /// Serializes the `Tree` back into a binary `.dtb` byte slice.
    pub fn serialize(self: *const Tree, allocator: std.mem.Allocator) ![]u8 {
        var struct_buf: std.ArrayList(u8) = .empty;
        defer struct_buf.deinit(allocator);

        var strings_buf: std.ArrayList(u8) = .empty;
        defer strings_buf.deinit(allocator);

        var string_offsets: std.StringHashMapUnmanaged(u32) = .empty;
        defer string_offsets.deinit(allocator);

        try serializeNode(allocator, self.root, &struct_buf, &strings_buf, &string_offsets);
        try appendU32Be(allocator, &struct_buf, FDT_END);

        const header_size: usize = 40;
        const rsv_offset = std.mem.alignForward(usize, header_size, 8);
        const rsv_size = (self.reserves.items.len + 1) * 16;
        const struct_offset = std.mem.alignForward(usize, rsv_offset + rsv_size, 4);
        const struct_size = struct_buf.items.len;
        const strings_offset = struct_offset + struct_size;
        const strings_size = strings_buf.items.len;
        const total_size = strings_offset + strings_size;

        const out = try allocator.alloc(u8, total_size);
        @memset(out, 0);

        std.mem.writeInt(u32, out[0..4], fdt_magic, .big);
        std.mem.writeInt(u32, out[4..8], @intCast(total_size), .big);
        std.mem.writeInt(u32, out[8..12], @intCast(struct_offset), .big);
        std.mem.writeInt(u32, out[12..16], @intCast(strings_offset), .big);
        std.mem.writeInt(u32, out[16..20], @intCast(rsv_offset), .big);
        std.mem.writeInt(u32, out[20..24], fdt_version, .big);
        std.mem.writeInt(u32, out[24..28], fdt_last_comp_version, .big);
        std.mem.writeInt(u32, out[28..32], self.boot_cpuid_phys, .big);
        std.mem.writeInt(u32, out[32..36], @intCast(strings_size), .big);
        std.mem.writeInt(u32, out[36..40], @intCast(struct_size), .big);

        for (self.reserves.items, 0..) |r, i| {
            const at = rsv_offset + i * 16;
            std.mem.writeInt(u64, out[at..][0..8], r.address, .big);
            std.mem.writeInt(u64, out[at + 8 ..][0..8], r.size, .big);
        }

        @memcpy(out[struct_offset .. struct_offset + struct_size], struct_buf.items);
        @memcpy(out[strings_offset .. strings_offset + strings_size], strings_buf.items);

        return out;
    }

    fn serializeNode(
        allocator: std.mem.Allocator,
        node: *const Node,
        struct_buf: *std.ArrayList(u8),
        strings_buf: *std.ArrayList(u8),
        string_offsets: *std.StringHashMapUnmanaged(u32),
    ) !void {
        try appendU32Be(allocator, struct_buf, FDT_BEGIN_NODE);
        try struct_buf.appendSlice(allocator, node.name);
        try struct_buf.append(allocator, 0);
        while ((struct_buf.items.len & 3) != 0) {
            try struct_buf.append(allocator, 0);
        }

        for (node.props.items) |prop| {
            const name_off = blk: {
                if (string_offsets.get(prop.name)) |off| break :blk off;
                const off: u32 = @intCast(strings_buf.items.len);
                try strings_buf.appendSlice(allocator, prop.name);
                try strings_buf.append(allocator, 0);
                try string_offsets.put(allocator, prop.name, off);
                break :blk off;
            };
            try appendU32Be(allocator, struct_buf, FDT_PROP);
            try appendU32Be(allocator, struct_buf, @intCast(prop.value.len));
            try appendU32Be(allocator, struct_buf, name_off);
            try struct_buf.appendSlice(allocator, prop.value);
            while ((struct_buf.items.len & 3) != 0) {
                try struct_buf.append(allocator, 0);
            }
        }

        for (node.children.items) |child| {
            try serializeNode(allocator, child, struct_buf, strings_buf, string_offsets);
        }

        try appendU32Be(allocator, struct_buf, FDT_END_NODE);
    }

    fn appendU32Be(allocator: std.mem.Allocator, list: *std.ArrayList(u8), val: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, val, .big);
        try list.appendSlice(allocator, &b);
    }
};

test "FDT roundtrip and Pi Zero patching" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tree = try Tree.initEmpty(alloc);
    const soc = try tree.findOrCreateNode("/soc");
    const usb = try soc.findOrCreateChild(alloc, "usb@7e980000");
    try usb.setStringProp(alloc, "compatible", "brcm,bcm2708-usb");
    const hvs = try soc.findOrCreateChild(alloc, "hvs@7e400000");
    try hvs.setStringProp(alloc, "status", "disabled");
    const mmcnr = try soc.findOrCreateChild(alloc, "mmcnr@7e300000");
    try mmcnr.setStringProp(alloc, "status", "disabled");

    try tree.patchForPiZero(512 * 1024 * 1024, "console=ttyAMA0,115200", .{ .start = 0x02000000, .end = 0x02500000 }, true);
    try tree.setWirelessMac(.{ 0xb8, 0x27, 0xeb, 0x47, 0x61, 0x03 });

    const blob = try tree.serialize(alloc);
    var parsed = try Tree.parse(alloc, blob);

    const chosen = parsed.findNode("/chosen").?;
    try std.testing.expectEqualStrings("console=ttyAMA0,115200", chosen.getStringProp("bootargs").?);
    try std.testing.expectEqual(@as(u32, 0x02000000), std.mem.readInt(u32, chosen.getProp("linux,initrd-start").?[0..4], .big));

    const mem_parsed = parsed.findNode("/memory@0").?;
    try std.testing.expectEqual(@as(u32, 0x1c000000), std.mem.readInt(u32, mem_parsed.getProp("reg").?[4..8], .big));

    const fb_parsed = parsed.findNode("/chosen/framebuffer@1c100000").?;
    try std.testing.expectEqualStrings("simple-framebuffer", fb_parsed.getStringProp("compatible").?);
    try std.testing.expectEqualStrings("x8r8g8b8", fb_parsed.getStringProp("format").?);
    try std.testing.expectEqualStrings("okay", fb_parsed.getStringProp("status").?);
    try std.testing.expectEqual(@as(u32, 1280), std.mem.readInt(u32, fb_parsed.getProp("width").?[0..4], .big));
    try std.testing.expectEqual(@as(u32, 720), std.mem.readInt(u32, fb_parsed.getProp("height").?[0..4], .big));

    const usb_parsed = parsed.findNode("/soc/usb@7e980000").?;
    try std.testing.expectEqualStrings("brcm,bcm2835-usb", usb_parsed.getStringProp("compatible").?);

    const hvs_parsed = parsed.findNode("/soc/hvs@7e400000").?;
    try std.testing.expectEqualStrings("okay", hvs_parsed.getStringProp("status").?);

    // Built-in USB hub node usb1@1 is populated for boards with built-in hubs (e.g. Pi 1 Model B+ -> usb424,9514)
    try parsed.setBoardModel(.pi_1_b_plus);
    const hub_node = parsed.findNode("/soc/usb@7e980000/usb1@1").?;
    try std.testing.expectEqualStrings("usb424,9514", hub_node.getStringProp("compatible").?);

    // And removed for boards with an external hub (e.g. Pi Zero)
    try parsed.setBoardModel(.pi_zero);
    try std.testing.expect(parsed.findNode("/soc/usb@7e980000/usb1@1") == null);

    const mmcnr_parsed = parsed.findNode("/soc/mmcnr@7e300000").?;
    try std.testing.expectEqualStrings("okay", mmcnr_parsed.getStringProp("status").?);
    const wifi_parsed = parsed.findNode("/soc/mmcnr@7e300000/wifi@1").?;
    try std.testing.expectEqualStrings("brcm,bcm4329-fmac", wifi_parsed.getStringProp("compatible").?);
    try std.testing.expectEqualSlices(u8, &.{ 0xb8, 0x27, 0xeb, 0x47, 0x61, 0x03 }, wifi_parsed.getProp("local-mac-address").?);
}

test "overlay fixups, parameters and merge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Decl = struct {
        fn make(a: std.mem.Allocator, targets: []const struct { u32, []const u8 }) ![]const u8 {
            var buf: std.ArrayList(u8) = .empty;
            for (targets) |t| {
                var cell: [4]u8 = undefined;
                std.mem.writeInt(u32, &cell, t[0], .big);
                try buf.appendSlice(a, &cell);
                try buf.appendSlice(a, t[1]);
                try buf.append(a, 0);
            }
            return buf.items;
        }
    };

    // Base: i2c1 (phandle 5, disabled) with a `dtparam=i2c_arm` override, as in the Raspberry Pi DTBs.
    var base = try Tree.initEmpty(alloc);
    const i2c1 = try base.findOrCreateNode("/soc/i2c@7e804000");
    try i2c1.setStringProp(alloc, "status", "disabled");
    try i2c1.setU32Prop(alloc, "phandle", 5);
    try (try base.findOrCreateNode("/__symbols__")).setStringProp(alloc, "i2c1", "/soc/i2c@7e804000");
    try (try base.findOrCreateNode("/__overrides__")).setProp(alloc, "i2c_arm", try Decl.make(alloc, &.{.{ 5, "status" }}));
    try (try base.findOrCreateNode("/chosen")).setStringProp(alloc, "bootargs", "console=tty1");

    // Overlay, laid out as `dtc -@` compiles it.
    var ov = try Tree.initEmpty(alloc);
    const frag0 = try ov.findOrCreateNode("/fragment@0");
    try frag0.setU32Prop(alloc, "target", 0xffffffff);
    const rtc = try ov.findOrCreateNode("/fragment@0/__overlay__/rtc@68");
    try rtc.setStringProp(alloc, "compatible", "nxp,pcf8523");
    try rtc.setU32Prop(alloc, "reg", 0x68);
    try rtc.setU32Prop(alloc, "phandle", 1);
    const frag1 = try ov.findOrCreateNode("/fragment@1");
    try frag1.setStringProp(alloc, "target-path", "/chosen");
    try (try ov.findOrCreateNode("/fragment@1/__dormant__")).setStringProp(alloc, "bootargs", "rtc.hctosys=1");
    const overrides = try ov.findOrCreateNode("/__overrides__");
    try overrides.setProp(alloc, "addr", try Decl.make(alloc, &.{.{ 1, "reg:0" }}));
    try overrides.setProp(alloc, "wakeup", try Decl.make(alloc, &.{.{ 1, "wakeup-source?" }}));
    try overrides.setProp(alloc, "hctosys", try Decl.make(alloc, &.{.{ 0, "=1" }}));
    try overrides.setProp(alloc, "chip", try Decl.make(alloc, &.{.{ 1, "compatible{pcf8563='nxp,pcf8563',=nxp\\x2cpcf85063}" }}));
    try (try ov.findOrCreateNode("/__fixups__")).setStringProp(alloc, "i2c1", "/fragment@0:target:0");
    const lf = try ov.findOrCreateNode("/__local_fixups__/__overrides__");
    for ([_][]const u8{ "addr", "wakeup", "chip" }) |name| try lf.setU32Prop(alloc, name, 0);
    try (try ov.findOrCreateNode("/__symbols__")).setStringProp(alloc, "rtc_i2c", "/fragment@0/__overlay__");
    try (try ov.findOrCreateNode("/__exports__")).setProp(alloc, "rtc_i2c", &.{});

    try base.fixupOverlay(&ov);
    try std.testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, frag0.getProp("target").?[0..4], .big));
    try std.testing.expectEqual(@as(?u32, 6), rtc.phandle());

    try std.testing.expect(try base.applyParam(&ov, "addr", "0x51"));
    try std.testing.expect(try base.applyParam(&ov, "wakeup", "on"));
    try std.testing.expect(try base.applyParam(&ov, "hctosys", "yes"));
    try std.testing.expect(try base.applyParam(&ov, "chip", "pcf8563"));
    try std.testing.expect(try base.applyParam(&ov, "i2c_arm", "on")); // falls back to the base
    try std.testing.expect(!try base.applyParam(&ov, "bogus", "1"));
    try base.mergeOverlay(&ov);

    try std.testing.expectEqualStrings("okay", i2c1.getStringProp("status").?);
    const merged = base.findNode("/soc/i2c@7e804000/rtc@51").?;
    try std.testing.expectEqual(@as(u32, 0x51), std.mem.readInt(u32, merged.getProp("reg").?[0..4], .big));
    try std.testing.expect(merged.getProp("wakeup-source") != null);
    try std.testing.expectEqualStrings("nxp,pcf8563", merged.getStringProp("compatible").?);
    try std.testing.expectEqual(@as(?u32, 6), merged.phandle());
    try std.testing.expectEqual(@as(?u32, 5), i2c1.phandle());
    try std.testing.expectEqualStrings("console=tty1 rtc.hctosys=1", base.findNode("/chosen").?.getStringProp("bootargs").?);
    try std.testing.expectEqualStrings("/soc/i2c@7e804000", base.findNode("/__symbols__").?.getStringProp("rtc_i2c").?);

    // Lookup default and escapes
    try std.testing.expect(try base.applyParam(&ov, "chip", "other"));
    try std.testing.expectEqualStrings("nxp,pcf85063", rtc.getStringProp("compatible").?);
}
