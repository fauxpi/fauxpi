//! Flattened Device Tree (FDT / `.dtb`) parser, patcher, and serializer.
//!
//! Emulates the device-tree setup performed by the Raspberry Pi VideoCore
//! firmware (`start.elf`):
//! - Patches `/chosen` (`bootargs`, `linux,initrd-start`, `linux,initrd-end`)
//! - Patches `/memory@0` (`reg = <0x00000000 ram_size>`)
//! - Applies the `vc4-kms-v3d` overlay configuration (`i2c2`, `pixelvalve0..2`,
//!   `hvs`, `hdmi`, `v3d`, `vc4`, `txp` enabled; legacy `fb` disabled; `cma` sized)
//! - Sets `/soc/usb@7e980000` `compatible = "brcm,bcm2835-usb"` so mainline `dwc2` binds.

const std = @import("std");
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

    pub fn setBoardModel(self: *Tree, model_str: []const u8, revision: u32) !void {
        try self.root.setStringProp(self.allocator, "model", model_str);
        const sys_node = try self.findOrCreateNode("/system");
        try sys_node.setU32Prop(self.allocator, "linux,revision", revision);
        try self.setBuiltInUsbHub(HubKind.fromModel(model_str));
        const has_headphone_jack = std.mem.indexOf(u8, model_str, "Zero") == null;
        try self.setHeadphoneAudioEnabled(has_headphone_jack);
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

    pub fn patchForPiZero(
        self: *Tree,
        ram_size: u32,
        cmdline: []const u8,
        initrd: ?InitrdRange,
        enable_vc4_kms: bool,
    ) !void {
        // 1. Memory size
        const mem_node = self.findNode("/memory@0") orelse self.findNode("/memory") orelse try self.findOrCreateNode("/memory@0");
        try mem_node.setCellsProp(self.allocator, "reg", &.{ 0, ram_size });

        // 2. /chosen bootargs, initrd, and rng-seed (initializes kernel CRNG immediately at boot)
        const chosen = try self.findOrCreateNode("/chosen");
        if (cmdline.len > 0) {
            try chosen.setStringProp(self.allocator, "bootargs", cmdline);
        }
        if (initrd) |rd| {
            try chosen.setU32Prop(self.allocator, "linux,initrd-start", rd.start);
            try chosen.setU32Prop(self.allocator, "linux,initrd-end", rd.end);
        }
        var rng_seed: [64]u8 = undefined;
        _ = std.os.linux.getrandom(&rng_seed, rng_seed.len, 0);
        try chosen.setProp(self.allocator, "rng-seed", &rng_seed);

        // 2b. /system board revision (0x00900093 = Raspberry Pi Zero v1.3, 512MB) and serial
        const sys_node = try self.findOrCreateNode("/system");
        try sys_node.setU32Prop(self.allocator, "linux,revision", 0x00900093);
        try self.setBoardSerial(0x00000000fa000001);

        // 3. Ensure USB controller uses mainline dwc2 compatible string
        if (self.findNode("usb") orelse self.findNode("/soc/usb@7e980000")) |usb| {
            try usb.setStringProp(self.allocator, "compatible", "brcm,bcm2835-usb");
            try usb.setStringProp(self.allocator, "status", "okay");
        }
        if (self.root.getStringProp("model")) |m| {
            try self.setBuiltInUsbHub(HubKind.fromModel(m));
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
            const enable_targets = [_][]const u8{
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
                "v3d",
                "/soc/v3d@7ec00000",
                "vc4",
                "/soc/gpu",
                "/gpu",
                "txp",
                "/soc/txp@7e004000",
            };
            for (enable_targets) |t| {
                if (self.findNode(t)) |n| {
                    try n.setStringProp(self.allocator, "status", "okay");
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

    const usb_parsed = parsed.findNode("/soc/usb@7e980000").?;
    try std.testing.expectEqualStrings("brcm,bcm2835-usb", usb_parsed.getStringProp("compatible").?);

    const hvs_parsed = parsed.findNode("/soc/hvs@7e400000").?;
    try std.testing.expectEqualStrings("okay", hvs_parsed.getStringProp("status").?);

    // Built-in USB hub node usb1@1 is populated for boards with built-in hubs (e.g. Pi 3 Model B -> usb424,9514)
    try parsed.setBoardModel("Raspberry Pi 3 Model B Rev 1.2", 0x00a02082);
    const hub_node = parsed.findNode("/soc/usb@7e980000/usb1@1").?;
    try std.testing.expectEqualStrings("usb424,9514", hub_node.getStringProp("compatible").?);

    // And removed for boards with an external hub (e.g. Pi Zero)
    try parsed.setBoardModel("Raspberry Pi Zero Rev 1.3", 0x00900093);
    try std.testing.expect(parsed.findNode("/soc/usb@7e980000/usb1@1") == null);

    const mmcnr_parsed = parsed.findNode("/soc/mmcnr@7e300000").?;
    try std.testing.expectEqualStrings("okay", mmcnr_parsed.getStringProp("status").?);
    const wifi_parsed = parsed.findNode("/soc/mmcnr@7e300000/wifi@1").?;
    try std.testing.expectEqualStrings("brcm,bcm4329-fmac", wifi_parsed.getStringProp("compatible").?);
    try std.testing.expectEqualSlices(u8, &.{ 0xb8, 0x27, 0xeb, 0x47, 0x61, 0x03 }, wifi_parsed.getProp("local-mac-address").?);
}
