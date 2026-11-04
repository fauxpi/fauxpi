//! What FauxPi's window shows and keeps, apart from how it is drawn: the
//! board's identity (serial number, MAC addresses), its Wi-Fi network, the
//! SD card images (made in the background, and kept with the settings under
//! `$XDG_DATA_HOME/fauxpi`), the CPU temperature and the message the window
//! shows at its bottom.

const std = @import("std");
const host_posix = @import("../host/posix.zig");
const board = @import("board.zig");
const qcow2_mod = @import("../soc/qcow2.zig");

pub const SdCardSize = qcow2_mod.SdCardSize;
pub const Qcow2Disk = qcow2_mod.Qcow2Disk;

pub const SdCardEntry = struct {
    name_buf: [64]u8 = @splat(0),
    name_len: usize = 0,
    image_path_buf: [512]u8 = @splat(0),
    image_path_len: usize = 0,
    image_size_bytes: u64 = 0,
    size: SdCardSize = .gb_4,
    has_persistent_file: bool = false,
    disk: Qcow2Disk,

    pub fn name(self: *const SdCardEntry) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn imagePath(self: *const SdCardEntry) []const u8 {
        return self.image_path_buf[0..self.image_path_len];
    }

    pub fn deinit(self: *SdCardEntry) void {
        self.disk.deinit();
    }
};

/// Formats a byte count using human-readable binary units (`B`, `KB`, `MB`, `GB`),
/// matching `SdCardSize.label()` unit naming.
pub fn formatByteSize(buf: []u8, bytes: u64) []const u8 {
    const kb_unit: u64 = 1024;
    const mb_unit: u64 = 1024 * 1024;
    const gb_unit: u64 = 1024 * 1024 * 1024;

    if (bytes >= gb_unit) {
        const tenths = (bytes * 10 + gb_unit / 2) / gb_unit;
        if (tenths % 10 == 0 or tenths >= 100) {
            return std.fmt.bufPrint(buf, "{d} GB", .{tenths / 10}) catch "0 GB";
        }
        return std.fmt.bufPrint(buf, "{d}.{d} GB", .{ tenths / 10, tenths % 10 }) catch "0 GB";
    }
    if (bytes >= mb_unit) {
        const tenths = (bytes * 10 + mb_unit / 2) / mb_unit;
        if (tenths >= 10240) {
            return std.fmt.bufPrint(buf, "1 GB", .{}) catch "1 GB";
        }
        if (tenths % 10 == 0 or tenths >= 100) {
            return std.fmt.bufPrint(buf, "{d} MB", .{tenths / 10}) catch "0 MB";
        }
        return std.fmt.bufPrint(buf, "{d}.{d} MB", .{ tenths / 10, tenths % 10 }) catch "0 MB";
    }
    if (bytes >= kb_unit) {
        const kb = (bytes + kb_unit - 1) / kb_unit;
        if (kb >= 1024) {
            return std.fmt.bufPrint(buf, "1 MB", .{}) catch "1 MB";
        }
        return std.fmt.bufPrint(buf, "{d} KB", .{kb}) catch "0 KB";
    }
    return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "0 B";
}

pub const BoardModel = board.BoardModel;

pub const SystemStatus = struct {
    board_model: BoardModel = .pi_3_b_plus,
    serial: []const u8 = "00000000fa000001",
    serial_u64: u64 = 0x00000000fa000001,
    mac_address: [6]u8 = .{ 0xb8, 0x27, 0xeb, 0x12, 0x34, 0x56 },
    wifi_mac_address: [6]u8 = .{ 0xb8, 0x27, 0xeb, 0x65, 0x43, 0x21 },
    dhcp_enabled: bool = true,
    hdmi_width: u16 = 1280,
    hdmi_height: u16 = 720,
    hdmi_connected: bool = true,
    hdmi_active: bool = false,
    audio_connected: bool = true,
    power_connected: bool = false,
    sd_connected: bool = false,
    gpio_connected: bool = false,
    usb_hub_connected: bool = true,
    usb_keyboard_connected: bool = true,
    usb_mouse_connected: bool = true,
    ethernet_connected: bool = true,
    act_led_on: bool = false,
    pwr_led_on: bool = false,
    cpu_temperature_c: u8 = 42,
};

/// Security of the emulated Wi-Fi access point
pub const WifiSecurity = enum {
    open,
    wpa2_personal,

    pub const all = [_]WifiSecurity{ .open, .wpa2_personal };

    pub fn label(self: WifiSecurity) []const u8 {
        return switch (self) {
            .open => "Open",
            .wpa2_personal => "WPA2-Personal",
        };
    }

    /// Name in `settings.json`
    pub fn id(self: WifiSecurity) []const u8 {
        return switch (self) {
            .open => "open",
            .wpa2_personal => "wpa2_personal",
        };
    }

    pub fn fromId(s: []const u8) ?WifiSecurity {
        for (all) |sec| if (std.mem.eql(u8, s, sec.id())) return sec;
        return null;
    }
};

/// The Wi-Fi password until one is set
pub const default_wifi_password = "raspberry";

fn defaultWifiPasswordBuf() [63]u8 {
    var buf: [63]u8 = @splat(0);
    @memcpy(buf[0..default_wifi_password.len], default_wifi_password);
    return buf;
}

/// A WPA2 passphrase is 8 to 63 characters of printable ASCII
pub fn isValidWifiPassword(p: []const u8) bool {
    if (p.len < 8 or p.len > 63) return false;
    for (p) |ch| if (ch < 0x20 or ch > 0x7e) return false;
    return true;
}

/// The board's settings and SD cards: what the window shows of them, and
/// changes, and keeps in `settings.json`.
pub const BoardState = struct {
    gpa: std.mem.Allocator,

    serial_hex: [16]u8 = "00000000fa000001".*,
    serial_len: usize = 16,
    mac_hex: [12]u8 = "B827EB123456".*,
    mac_len: usize = 12,
    wifi_mac_hex: [12]u8 = "B827EB654321".*,
    wifi_mac_len: usize = 12,
    /// Counts the times the identity changed other than by typing (made
    /// anew, or loaded), for fields showing it to start again.
    identity_gen: u32 = 0,
    /// The emulated Wi-Fi access point's security, and its WPA2 passphrase
    wifi_security: WifiSecurity = .wpa2_personal,
    wifi_password_buf: [63]u8 = defaultWifiPasswordBuf(),
    wifi_password_len: usize = default_wifi_password.len,
    /// Persistent storage paths under `$XDG_DATA_HOME/fauxpi`.
    data_dir_buf: [512]u8 = @splat(0),
    data_dir_len: usize = 0,
    images_dir_buf: [512]u8 = @splat(0),
    images_dir_len: usize = 0,
    settings_path_buf: [512]u8 = @splat(0),
    settings_path_len: usize = 0,

    /// The SD card images, the one in the slot (or to go in it), and whether
    /// the Manage SD Cards dialog is open (and making a card).
    sd_cards: std.ArrayListUnmanaged(SdCardEntry) = .empty,
    selected_sd_card_idx: ?usize = null,
    sd_manage_open: bool = false,
    sd_create_open: bool = false,
    cpu_temperature_c: u8 = 42,
    cpu_temp_modified: bool = false,
    new_card_name_buf: [64]u8 = @splat(0),
    new_card_name_len: usize = 0,
    /// Counts the times `new_card_name_buf` was set other than by typing.
    new_card_name_gen: u32 = 0,
    new_card_size: SdCardSize = .gb_4,
    renaming_sd_card_idx: ?usize = null,
    rename_card_name_buf: [64]u8 = @splat(0),
    rename_card_name_len: usize = 0,
    pending_sd_image_path_buf: [512]u8 = @splat(0),
    pending_sd_image_path_len: usize = 0,
    pending_sd_image_size: u64 = 0,
    pending_sd_image_slice: ?[]const u8 = null,
    sd_error_buf: [160]u8 = @splat(0),
    sd_error_len: usize = 0,
    sd_create_task: ?*AsyncSdCreateTask = null,

    /// The message shown at the bottom of the window (a boot error), if any.
    snackbar_buf: [256]u8 = @splat(0),
    snackbar_len: usize = 0,

    pub const AsyncSdCreateTask = struct {
        card_name_buf: [64]u8 = @splat(0),
        card_name_len: usize = 0,
        src_path_buf: [std.fs.max_path_bytes]u8 = @splat(0),
        src_path_len: usize = 0,
        qcow2_path_buf: [std.fs.max_path_bytes]u8 = @splat(0),
        qcow2_path_len: usize = 0,
        has_qcow2_path: bool = false,
        size: SdCardSize = .gb_4,
        image_size_bytes: u64 = 0,

        progress_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        result_disk: ?Qcow2Disk = null,
        err_msg_buf: [160]u8 = @splat(0),
        err_msg_len: usize = 0,
        thread: ?std.Thread = null,

        fn workerMain(self: *AsyncSdCreateTask) void {
            const src_path = self.src_path_buf[0..self.src_path_len];
            const qcow2_path: ?[]const u8 = if (self.has_qcow2_path)
                self.qcow2_path_buf[0..self.qcow2_path_len]
            else
                null;

            if (Qcow2Disk.createFromImageFileAtPathWithProgress(
                std.heap.page_allocator,
                self.size.bytes(),
                src_path,
                qcow2_path,
                &self.progress_bytes,
            )) |disk| {
                self.result_disk = disk;
            } else |err| {
                const msg = std.fmt.bufPrint(&self.err_msg_buf, "Error: {s}", .{@errorName(err)}) catch "Error creating SD card image";
                self.err_msg_len = msg.len;
            }
            self.done.store(true, .release);
        }
    };

    pub fn init(gpa: std.mem.Allocator) !BoardState {
        var ui: BoardState = .{ .gpa = gpa };
        ui.randomizeIdentity();
        ui.resetDefaultNewCardName();
        return ui;
    }

    pub fn deinit(self: *BoardState) void {
        if (self.sd_create_task) |task| {
            if (task.thread) |t| t.join();
            if (task.result_disk) |*d| d.deinit();
            self.gpa.destroy(task);
            self.sd_create_task = null;
        }
        for (self.sd_cards.items) |*card| {
            card.deinit();
        }
        self.sd_cards.deinit(self.gpa);
    }

    pub fn dataDir(self: *const BoardState) []const u8 {
        return self.data_dir_buf[0..self.data_dir_len];
    }

    pub fn imagesDir(self: *const BoardState) []const u8 {
        return self.images_dir_buf[0..self.images_dir_len];
    }

    pub fn settingsPath(self: *const BoardState) []const u8 {
        return self.settings_path_buf[0..self.settings_path_len];
    }

    pub fn newCardName(self: *const BoardState) []const u8 {
        return self.new_card_name_buf[0..self.new_card_name_len];
    }

    pub fn setNewCardName(self: *BoardState, name: []const u8) void {
        const n = @min(name.len, self.new_card_name_buf.len);
        @memcpy(self.new_card_name_buf[0..n], name[0..n]);
        self.new_card_name_len = n;
    }

    /// Sets `new_card_name_buf` to the first unused `"Card N"` (`"Card 1"`, `"Card 2"`, ...).
    pub fn resetDefaultNewCardName(self: *BoardState) void {
        var n: usize = 1;
        while (n < 10_000) : (n += 1) {
            var cand_buf: [64]u8 = undefined;
            const cand = std.fmt.bufPrint(&cand_buf, "Card {d}", .{n}) catch break;
            if (!self.hasCardNamed(cand)) {
                self.setNewCardName(cand);
                self.new_card_name_gen +%= 1;
                return;
            }
        }
        self.setNewCardName("Card 1");
        self.new_card_name_gen +%= 1;
    }

    pub fn hasCardNamed(self: *const BoardState, candidate: []const u8) bool {
        for (self.sd_cards.items) |*card| {
            if (std.ascii.eqlIgnoreCase(card.name(), candidate)) return true;
        }
        return false;
    }

    /// Resolves `$XDG_DATA_HOME/fauxpi` (or `$HOME/.local/share/fauxpi` on POSIX, `%LOCALAPPDATA%/fauxpi` on Windows).
    pub fn resolveXdgDataDir(buf: []u8, environ: std.process.Environ) ?[]const u8 {
        return host_posix.resolveAppDataDir(buf, environ);
    }

    /// Configures persistent storage under `$XDG_DATA_HOME/fauxpi`, loading existing QCOW2 images
    /// from `$XDG_DATA_HOME/fauxpi/images` and board settings from `$XDG_DATA_HOME/fauxpi/settings.json`.
    pub fn configureXdgStorage(self: *BoardState, environ: std.process.Environ, status: *SystemStatus) void {
        var dir_buf: [512]u8 = undefined;
        if (resolveXdgDataDir(&dir_buf, environ)) |dir| {
            self.configureDataDir(dir, status);
        }
    }

    /// Configures persistent storage under `data_dir` (`{data_dir}/images` and `{data_dir}/settings.json`),
    /// loads existing `.qcow2` images, and loads or initializes `settings.json`.
    pub fn configureDataDir(self: *BoardState, data_dir: []const u8, status: *SystemStatus) void {
        const dlen = @min(data_dir.len, self.data_dir_buf.len);
        @memcpy(self.data_dir_buf[0..dlen], data_dir[0..dlen]);
        self.data_dir_len = dlen;

        const imgs = std.fmt.bufPrint(&self.images_dir_buf, "{s}/images", .{self.dataDir()}) catch "";
        self.images_dir_len = imgs.len;

        const spath = std.fmt.bufPrint(&self.settings_path_buf, "{s}/settings.json", .{self.dataDir()}) catch "";
        self.settings_path_len = spath.len;

        ensureDirPathLinux(self.dataDir());
        if (self.images_dir_len > 0) {
            ensureDirPathLinux(self.imagesDir());
            self.loadImagesFromDir();
        }
        if (self.settings_path_len > 0) {
            const loaded = self.loadSettings(status) catch false;
            if (!loaded) {
                self.saveSettings(status.*) catch {};
            }
        }
    }

    fn appendDiscoveredQcow2(self: *BoardState, card_name: []const u8, full_path: []const u8) void {
        if (self.hasCardNamed(card_name)) return;
        var disk = Qcow2Disk.openExistingFile(self.gpa, full_path) catch return;
        const sz = SdCardSize.smallestFitting(disk.virtual_size) orelse .gb_32;
        var entry = makeNamedSdCardEntry(card_name, full_path, disk.diskAllocatedBytes(), sz, disk);
        entry.has_persistent_file = true;
        self.sd_cards.append(self.gpa, entry) catch {
            disk.deinit();
        };
    }

    /// Scans `self.imagesDir()` (`$XDG_DATA_HOME/fauxpi/images`) for `.qcow2` files and opens them.
    pub fn loadImagesFromDir(self: *BoardState) void {
        if (self.images_dir_len == 0) return;
        const dir_path = self.imagesDir();
        host_posix.forEachQcow2File(dir_path, self, appendDiscoveredQcow2);

        var i: usize = 1;
        while (i < self.sd_cards.items.len) : (i += 1) {
            var j = i;
            while (j > 0 and std.mem.order(u8, self.sd_cards.items[j].name(), self.sd_cards.items[j - 1].name()) == .lt) : (j -= 1) {
                std.mem.swap(SdCardEntry, &self.sd_cards.items[j], &self.sd_cards.items[j - 1]);
            }
        }

        if (self.sd_cards.items.len > 0 and self.selected_sd_card_idx == null) {
            self.selected_sd_card_idx = 0;
        }
        self.resetDefaultNewCardName();
    }

    const PersistedSettings = struct {
        board_model: ?[]const u8 = null,
        serial: ?[]const u8 = null,
        mac_address: ?[]const u8 = null,
        wifi_mac_address: ?[]const u8 = null,
        wifi_security: ?[]const u8 = null,
        wifi_password: ?[]const u8 = null,
        dhcp_enabled: ?bool = null,
        selected_sd_card: ?[]const u8 = null,
        sd_connected: ?bool = null,
        gpio_connected: ?bool = null,
        hdmi_connected: ?bool = null,
        audio_connected: ?bool = null,
        usb_hub_connected: ?bool = null,
        usb_keyboard_connected: ?bool = null,
        usb_mouse_connected: ?bool = null,
        ethernet_connected: ?bool = null,
        cpu_temperature_c: ?u8 = null,
    };

    /// Writes the current board settings to `$XDG_DATA_HOME/fauxpi/settings.json`.
    pub fn saveSettings(self: *const BoardState, status: SystemStatus) !void {
        if (self.settings_path_len == 0) return;
        if (self.data_dir_len > 0) ensureDirPathLinux(self.dataDir());

        const sel_name = if (self.selected_sd_card_idx) |idx|
            (if (idx < self.sd_cards.items.len) self.sd_cards.items[idx].name() else "")
        else
            "";

        var esc_name_buf: [140]u8 = undefined;
        var esc_len: usize = 0;
        for (sel_name) |ch| {
            if (ch == '"' or ch == '\\') {
                if (esc_len + 2 > esc_name_buf.len) break;
                esc_name_buf[esc_len] = '\\';
                esc_name_buf[esc_len + 1] = ch;
                esc_len += 2;
            } else if (ch >= 0x20) {
                if (esc_len + 1 > esc_name_buf.len) break;
                esc_name_buf[esc_len] = ch;
                esc_len += 1;
            }
        }

        var esc_password_buf: [2 * 63]u8 = undefined;
        var esc_password_len: usize = 0;
        for (self.wifiPassword()) |ch| {
            if (ch == '"' or ch == '\\') {
                esc_password_buf[esc_password_len] = '\\';
                esc_password_len += 1;
            }
            esc_password_buf[esc_password_len] = ch;
            esc_password_len += 1;
        }

        var json_buf: [2048]u8 = undefined;
        const json_str = try std.fmt.bufPrint(
            &json_buf,
            \\{{
            \\  "board_model": "{s}",
            \\  "serial": "{s}",
            \\  "mac_address": "{s}",
            \\  "wifi_mac_address": "{s}",
            \\  "wifi_security": "{s}",
            \\  "wifi_password": "{s}",
            \\  "dhcp_enabled": {},
            \\  "selected_sd_card": "{s}",
            \\  "sd_connected": {},
            \\  "gpio_connected": {},
            \\  "hdmi_connected": {},
            \\  "audio_connected": {},
            \\  "usb_hub_connected": {},
            \\  "usb_keyboard_connected": {},
            \\  "usb_mouse_connected": {},
            \\  "ethernet_connected": {},
            \\  "cpu_temperature_c": {d}
            \\}}
            \\
        ,
            .{
                status.board_model.id(),
                self.serial_hex[0..self.serial_len],
                self.mac_hex[0..self.mac_len],
                self.wifi_mac_hex[0..self.wifi_mac_len],
                self.wifi_security.id(),
                esc_password_buf[0..esc_password_len],
                status.dhcp_enabled,
                esc_name_buf[0..esc_len],
                status.sd_connected,
                status.gpio_connected,
                status.hdmi_connected,
                status.audio_connected,
                status.usb_hub_connected,
                status.usb_keyboard_connected,
                status.usb_mouse_connected,
                status.ethernet_connected,
                self.effectiveCpuTemperature(status),
            },
        );

        const path = self.settingsPath();
        const fd = try host_posix.openCreateTruncWrite(path, false);
        defer host_posix.close(fd);
        try host_posix.writeAll(fd, json_str);
    }

    /// Reads board settings from `$XDG_DATA_HOME/fauxpi/settings.json` into `self` and `status`.
    /// Returns `true` if `settings.json` existed and was parsed.
    pub fn loadSettings(self: *BoardState, status: *SystemStatus) !bool {
        if (self.settings_path_len == 0) return false;
        const path = self.settingsPath();

        const fd = host_posix.openRead(path) catch return false;
        defer host_posix.close(fd);

        var file_buf: [4096]u8 = undefined;
        var total: usize = 0;
        while (total < file_buf.len) {
            const rc = try host_posix.read(fd, file_buf[total..]);
            if (rc == 0) break;
            total += rc;
        }

        const parsed = try std.json.parseFromSlice(
            PersistedSettings,
            self.gpa,
            file_buf[0..total],
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();
        const cfg = parsed.value;

        if (cfg.board_model) |bm_str| {
            if (BoardModel.fromId(bm_str)) |bm| {
                status.board_model = bm;
            }
        }
        if (cfg.serial) |ser| {
            setHexField(&self.serial_hex, &self.serial_len, ser, false);
        }
        if (cfg.mac_address) |mac| {
            setHexField(&self.mac_hex, &self.mac_len, mac, true);
        }
        if (cfg.wifi_mac_address) |wmac| {
            setHexField(&self.wifi_mac_hex, &self.wifi_mac_len, wmac, true);
        }
        self.identity_gen +%= 1;
        status.serial_u64 = self.parsedSerial();
        status.mac_address = self.parsedMac();
        status.wifi_mac_address = self.parsedWifiMac();
        if (cfg.wifi_security) |sec| {
            if (WifiSecurity.fromId(sec)) |v| self.wifi_security = v;
        }
        if (cfg.wifi_password) |pw| self.setWifiPassword(pw);

        if (cfg.dhcp_enabled) |v| status.dhcp_enabled = v;
        if (cfg.gpio_connected) |v| status.gpio_connected = v;
        if (cfg.hdmi_connected) |v| status.hdmi_connected = v;
        if (cfg.audio_connected) |v| status.audio_connected = v;
        if (cfg.usb_hub_connected) |v| status.usb_hub_connected = v;
        if (cfg.usb_keyboard_connected) |v| status.usb_keyboard_connected = v;
        if (cfg.usb_mouse_connected) |v| status.usb_mouse_connected = v;
        if (cfg.ethernet_connected) |v| status.ethernet_connected = v;
        if (cfg.cpu_temperature_c) |temp_c| {
            const clamped = std.math.clamp(temp_c, 0, 100);
            self.cpu_temperature_c = clamped;
            self.cpu_temp_modified = true;
            status.cpu_temperature_c = clamped;
        }
        if (!status.board_model.usesExternalUsbHub()) {
            status.usb_hub_connected = true;
        }

        if (cfg.selected_sd_card) |sel_name| {
            if (sel_name.len > 0) {
                for (self.sd_cards.items, 0..) |*card, idx| {
                    if (std.mem.eql(u8, card.name(), sel_name)) {
                        self.selected_sd_card_idx = idx;
                        break;
                    }
                }
            }
        }
        if (cfg.sd_connected) |v| {
            status.sd_connected = v and (self.selected_sd_card_idx != null);
        }
        status.power_connected = false;
        return true;
    }

    pub fn wifiPassword(self: *const BoardState) []const u8 {
        return self.wifi_password_buf[0..self.wifi_password_len];
    }

    /// Sets the Wi-Fi password, keeping its printable ASCII characters (63 at most)
    pub fn setWifiPassword(self: *BoardState, pw: []const u8) void {
        self.wifi_password_len = 0;
        for (pw) |ch| {
            if (ch < 0x20 or ch > 0x7e or self.wifi_password_len == self.wifi_password_buf.len) continue;
            self.wifi_password_buf[self.wifi_password_len] = ch;
            self.wifi_password_len += 1;
        }
    }

    /// Sets the serial number from `text`, keeping its hex digits.
    pub fn setSerial(self: *BoardState, text: []const u8) void {
        setHexField(&self.serial_hex, &self.serial_len, text, false);
    }

    /// Sets the Ethernet MAC address from `text`, keeping its hex digits.
    pub fn setMac(self: *BoardState, text: []const u8) void {
        setHexField(&self.mac_hex, &self.mac_len, text, true);
    }

    pub fn setWifiMac(self: *BoardState, text: []const u8) void {
        setHexField(&self.wifi_mac_hex, &self.wifi_mac_len, text, true);
    }

    pub fn serialText(self: *const BoardState) []const u8 {
        return self.serial_hex[0..self.serial_len];
    }

    /// The Ethernet MAC address as shown: `B8:27:EB:12:34:56`.
    pub fn macText(self: *const BoardState, buf: *[17]u8) []const u8 {
        return formatMac(buf, self.mac_hex[0..self.mac_len]);
    }

    pub fn wifiMacText(self: *const BoardState, buf: *[17]u8) []const u8 {
        return formatMac(buf, self.wifi_mac_hex[0..self.wifi_mac_len]);
    }

    fn formatMac(buf: *[17]u8, hex: []const u8) []const u8 {
        var len: usize = 0;
        for (hex, 0..) |ch, i| {
            if (i > 0 and i % 2 == 0) {
                buf[len] = ':';
                len += 1;
            }
            buf[len] = ch;
            len += 1;
        }
        return buf[0..len];
    }

    /// Keeps the hex digits of `src` (up to `dst`'s length), in one case;
    /// with none, `dst` is left as it was.
    fn setHexField(dst: []u8, dst_len: *usize, src: []const u8, uppercase: bool) void {
        var out_i: usize = 0;
        for (src) |ch| {
            if (std.ascii.isHex(ch) and out_i < dst.len) {
                dst[out_i] = if (uppercase) std.ascii.toUpper(ch) else std.ascii.toLower(ch);
                out_i += 1;
            }
        }
        if (out_i > 0) {
            dst_len.* = out_i;
        }
    }

    pub fn activeSdCard(self: *BoardState) ?*SdCardEntry {
        const idx = self.selected_sd_card_idx orelse return null;
        if (idx >= self.sd_cards.items.len) return null;
        return &self.sd_cards.items[idx];
    }

    /// Whether there is a card image to insert.
    pub fn hasActiveSdCard(self: *const BoardState) bool {
        const idx = self.selected_sd_card_idx orelse return false;
        return idx < self.sd_cards.items.len;
    }

    pub fn activeSdCardName(self: *const BoardState) []const u8 {
        const idx = self.selected_sd_card_idx orelse return "";
        if (idx >= self.sd_cards.items.len) return "";
        return self.sd_cards.items[idx].name();
    }

    pub fn sdErrorMessage(self: *const BoardState) []const u8 {
        return self.sd_error_buf[0..self.sd_error_len];
    }

    pub fn hasSnackbar(self: *const BoardState) bool {
        return self.snackbar_len > 0;
    }

    pub fn snackbarMessage(self: *const BoardState) []const u8 {
        return self.snackbar_buf[0..self.snackbar_len];
    }

    pub fn showSnackbar(self: *BoardState, msg: []const u8) void {
        const n = @min(msg.len, self.snackbar_buf.len);
        @memcpy(self.snackbar_buf[0..n], msg[0..n]);
        self.snackbar_len = n;
    }

    pub fn dismissSnackbar(self: *BoardState) void {
        self.snackbar_len = 0;
    }

    pub fn showBootErrorSnackbar(self: *BoardState, err: anyerror) void {
        var buf: [256]u8 = undefined;
        const msg: []const u8 = switch (err) {
            error.Requires64BitBoard => "64-bit OS image requires a 64-bit board (Raspberry Pi 3 or Zero 2 W)",
            error.KernelNotFound => "Failed to boot SD card: kernel image not found on boot partition",
            error.DtbNotFound => "Failed to boot SD card: device tree (.dtb) not found for this board",
            error.InitramfsNotFound => "Failed to boot SD card: initramfs image not found on boot partition",
            error.InvalidMbr,
            error.NoBootPartition,
            error.InvalidFatBootSector,
            error.UnsupportedFatType,
            => "Failed to boot SD card: no valid FAT boot partition found",
            error.TruncatedImage => "Failed to boot SD card: disk image is truncated",
            error.KernelTooLarge,
            error.DtbTooLarge,
            error.InitrdTooLarge,
            => "Failed to boot SD card: boot image is too large for memory",
            else => std.fmt.bufPrint(&buf, "Failed to boot SD card: {s}", .{@errorName(err)}) catch "Failed to boot SD card",
        };
        self.showSnackbar(msg);
    }

    pub fn hasImageTooLargeError(self: *const BoardState) bool {
        return self.pending_sd_image_path_len > 0 and self.pending_sd_image_size > self.new_card_size.bytes();
    }

    fn setSdError(self: *BoardState, msg: []const u8) void {
        const n = @min(msg.len, self.sd_error_buf.len);
        @memcpy(self.sd_error_buf[0..n], msg[0..n]);
        self.sd_error_len = n;
    }

    pub fn revalidatePendingSdImage(self: *BoardState) void {
        if (self.pending_sd_image_path_len == 0) {
            self.sd_error_len = 0;
            return;
        }
        if (self.pending_sd_image_size > self.new_card_size.bytes()) {
            var sz_buf: [32]u8 = undefined;
            const img_sz = formatByteSize(&sz_buf, self.pending_sd_image_size);
            const msg = std.fmt.bufPrint(
                &self.sd_error_buf,
                "Error: Image ({s}) is too large for a {s} SD card",
                .{ img_sz, self.new_card_size.label() },
            ) catch "Error: Image is too large for selected SD card size";
            self.sd_error_len = msg.len;
        } else {
            self.sd_error_len = 0;
        }
    }

    /// Returns true when the Manage SD Cards modal should display the Create Card UI instead of the card list.
    pub fn isSdCreateView(self: *const BoardState) bool {
        return self.sd_create_open or self.sd_cards.items.len == 0 or self.isCreatingSdCard();
    }

    /// Deletes SD card `idx`, closing its `Qcow2Disk` and unlinking its backing `.qcow2` file if persisted.
    pub fn deleteSdCard(self: *BoardState, idx: usize) bool {
        if (idx >= self.sd_cards.items.len) return false;
        self.cancelRenamingSdCard();
        var removed = self.sd_cards.orderedRemove(idx);
        var path_buf: [512]u8 = undefined;
        const path_len = removed.image_path_len;
        @memcpy(path_buf[0..path_len], removed.image_path_buf[0..path_len]);
        const is_persistent = removed.has_persistent_file;
        removed.deinit();
        if (is_persistent and path_len > 0) {
            host_posix.unlinkFile(path_buf[0..path_len]);
        }
        if (self.sd_cards.items.len == 0) {
            self.selected_sd_card_idx = null;
            self.sd_create_open = true;
        } else if (self.selected_sd_card_idx) |sel| {
            if (sel == idx) {
                self.selected_sd_card_idx = if (idx < self.sd_cards.items.len) idx else (self.sd_cards.items.len - 1);
            } else if (sel > idx) {
                self.selected_sd_card_idx = sel - 1;
            }
        }
        self.resetDefaultNewCardName();
        return true;
    }

    pub fn renameCardName(self: *const BoardState) []const u8 {
        return self.rename_card_name_buf[0..self.rename_card_name_len];
    }

    pub fn setRenameCardName(self: *BoardState, name: []const u8) void {
        const n = @min(name.len, self.rename_card_name_buf.len);
        @memcpy(self.rename_card_name_buf[0..n], name[0..n]);
        self.rename_card_name_len = n;
    }

    pub fn startRenamingSdCard(self: *BoardState, idx: usize) bool {
        if (idx >= self.sd_cards.items.len) return false;
        if (self.renaming_sd_card_idx) |prev_idx| {
            if (prev_idx != idx) {
                _ = self.commitRenamingSdCard();
            }
        }
        self.renaming_sd_card_idx = idx;
        self.setRenameCardName(self.sd_cards.items[idx].name());
        return true;
    }

    pub fn cancelRenamingSdCard(self: *BoardState) void {
        self.renaming_sd_card_idx = null;
        self.rename_card_name_len = 0;
    }

    pub fn commitRenamingSdCard(self: *BoardState) bool {
        const idx = self.renaming_sd_card_idx orelse return false;
        var name_copy: [64]u8 = undefined;
        const len = self.rename_card_name_len;
        @memcpy(name_copy[0..len], self.rename_card_name_buf[0..len]);
        self.renaming_sd_card_idx = null;
        self.rename_card_name_len = 0;
        return self.renameSdCard(idx, name_copy[0..len]);
    }

    /// Renames SD card `idx` to `new_name` (and renames its persistent `.qcow2` file on disk if present).
    pub fn renameSdCard(self: *BoardState, idx: usize, new_name: []const u8) bool {
        if (idx >= self.sd_cards.items.len) return false;
        const trimmed = std.mem.trim(u8, new_name, " \t\r\n");
        if (trimmed.len == 0) return false;

        var safe_buf: [64]u8 = undefined;
        var safe_len: usize = 0;
        for (trimmed) |ch| {
            if (safe_len >= safe_buf.len) break;
            if (ch == '/' or ch == '\\' or ch < 0x20) {
                safe_buf[safe_len] = '_';
            } else {
                safe_buf[safe_len] = ch;
            }
            safe_len += 1;
        }
        if (safe_len == 0) return false;
        const clean_name = safe_buf[0..safe_len];

        const card = &self.sd_cards.items[idx];
        if (std.mem.eql(u8, card.name(), clean_name)) return true;

        for (self.sd_cards.items, 0..) |*other, other_idx| {
            if (other_idx != idx and std.ascii.eqlIgnoreCase(other.name(), clean_name)) {
                return false;
            }
        }

        if (card.has_persistent_file and card.image_path_len > 0 and self.images_dir_len > 0) {
            var new_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const cand_path = std.fmt.bufPrint(&new_path_buf, "{s}/{s}.qcow2", .{ self.imagesDir(), clean_name }) catch return false;
            if (cand_path.len > card.image_path_buf.len) return false;

            const old_path = card.imagePath();
            if (!std.mem.eql(u8, old_path, cand_path)) {
                if (!std.ascii.eqlIgnoreCase(old_path, cand_path) and fileExistsLinux(cand_path)) {
                    return false;
                }
                card.disk.flush() catch {};
                if (host_posix.is_windows) {
                    host_posix.close(card.disk.fd);
                    const ok = host_posix.renameFile(old_path, cand_path);
                    const reopen_path = if (ok) cand_path else old_path;
                    card.disk.fd = host_posix.openReadWrite(reopen_path) catch -1;
                    if (!ok) return false;
                } else {
                    if (!host_posix.renameFile(old_path, cand_path)) return false;
                }
                @memcpy(card.image_path_buf[0..cand_path.len], cand_path);
                card.image_path_len = cand_path.len;
            }
        }

        @memcpy(card.name_buf[0..clean_name.len], clean_name);
        card.name_len = clean_name.len;
        self.resetDefaultNewCardName();
        return true;
    }

    /// Sets the pending image path and byte size in the Manage SD Cards dialog and validates it against `new_card_size`.
    pub fn setPendingSdImageFile(self: *BoardState, path: []const u8, size_bytes: u64) void {
        const n = @min(path.len, self.pending_sd_image_path_buf.len);
        @memcpy(self.pending_sd_image_path_buf[0..n], path[0..n]);
        self.pending_sd_image_path_len = n;
        self.pending_sd_image_size = size_bytes;
        self.pending_sd_image_slice = null;
        self.sd_create_open = true;
        self.revalidatePendingSdImage();
    }

    /// Sets an in-memory image slice as the pending image in the Manage SD Cards dialog and validates it against `new_card_size`.
    pub fn setPendingSdImageSlice(self: *BoardState, name_or_path: []const u8, data: []const u8) void {
        const n = @min(name_or_path.len, self.pending_sd_image_path_buf.len);
        @memcpy(self.pending_sd_image_path_buf[0..n], name_or_path[0..n]);
        self.pending_sd_image_path_len = n;
        self.pending_sd_image_size = Qcow2Disk.getSliceLogicalSize(data) catch data.len;
        self.pending_sd_image_slice = data;
        self.sd_create_open = true;
        self.revalidatePendingSdImage();
    }

    fn resolveNewCardName(self: *BoardState, custom_name: ?[]const u8, buf: *[64]u8) []const u8 {
        if (custom_name) |cn| {
            const trimmed = std.mem.trim(u8, cn, " \t\r\n");
            if (trimmed.len > 0) {
                const n = @min(trimmed.len, buf.len);
                @memcpy(buf[0..n], trimmed[0..n]);
                return buf[0..n];
            }
        }
        const cur_trimmed = std.mem.trim(u8, self.newCardName(), " \t\r\n");
        if (cur_trimmed.len == 0) {
            self.resetDefaultNewCardName();
        }
        const active = std.mem.trim(u8, self.newCardName(), " \t\r\n");
        const n = @min(active.len, buf.len);
        @memcpy(buf[0..n], active[0..n]);
        return buf[0..n];
    }

    fn buildPersistentQcow2Path(self: *const BoardState, card_name: []const u8, out_buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
        if (self.images_dir_len == 0) return null;
        ensureDirPathLinux(self.imagesDir());

        var safe_buf: [64]u8 = undefined;
        var safe_len: usize = 0;
        for (card_name) |ch| {
            if (safe_len >= safe_buf.len) break;
            if (ch == '/' or ch == '\\' or ch < 0x20) {
                safe_buf[safe_len] = '_';
            } else {
                safe_buf[safe_len] = ch;
            }
            safe_len += 1;
        }
        const stem = if (safe_len > 0) safe_buf[0..safe_len] else "Card";

        var suffix: usize = 1;
        while (suffix < 10_000) : (suffix += 1) {
            const path = if (suffix == 1)
                std.fmt.bufPrint(out_buf, "{s}/{s}.qcow2", .{ self.imagesDir(), stem }) catch return null
            else
                std.fmt.bufPrint(out_buf, "{s}/{s}-{d}.qcow2", .{ self.imagesDir(), stem, suffix }) catch return null;
            if (!fileExistsLinux(path)) return path;
        }
        return null;
    }

    /// Creates a new QCOW2-backed SD card from an in-memory image slice using the current `newCardName()`
    /// (defaulting to `"Card 1"`, `"Card 2"`, etc.).
    pub fn addSdCardFromSlice(self: *BoardState, label_or_path: []const u8, size: SdCardSize, image_bytes: []const u8) !usize {
        return self.addNamedSdCardFromSlice(null, label_or_path, size, image_bytes);
    }

    /// Creates a new QCOW2-backed SD card with an optional explicit `card_name` from an in-memory image slice.
    pub fn addNamedSdCardFromSlice(
        self: *BoardState,
        card_name_opt: ?[]const u8,
        label_or_path: []const u8,
        size: SdCardSize,
        image_bytes: []const u8,
    ) !usize {
        const logical_size = try Qcow2Disk.getSliceLogicalSize(image_bytes);
        if (logical_size > size.bytes()) {
            self.new_card_size = size;
            self.setPendingSdImageSlice(label_or_path, image_bytes);
            return error.ImageTooLarge;
        }
        var name_buf: [64]u8 = undefined;
        const card_name = self.resolveNewCardName(card_name_opt, &name_buf);

        var qcow2_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const qcow2_path = self.buildPersistentQcow2Path(card_name, &qcow2_path_buf);

        var disk = try Qcow2Disk.createFromSliceAtPath(self.gpa, size.bytes(), image_bytes, qcow2_path);
        errdefer disk.deinit();

        const entry_path = qcow2_path orelse label_or_path;
        var entry = makeNamedSdCardEntry(card_name, entry_path, logical_size, size, disk);
        entry.has_persistent_file = (qcow2_path != null);
        try self.sd_cards.append(self.gpa, entry);
        const idx = self.sd_cards.items.len - 1;
        self.selected_sd_card_idx = idx;
        self.sd_error_len = 0;
        self.sd_create_open = false;
        self.resetDefaultNewCardName();
        return idx;
    }

    /// Creates a new QCOW2-backed SD card by streaming an image file from disk using the current `newCardName()`
    /// (defaulting to `"Card 1"`, `"Card 2"`, etc.).
    pub fn addSdCardFromFile(self: *BoardState, path: []const u8, size: SdCardSize) !usize {
        return self.addNamedSdCardFromFile(null, path, size);
    }

    /// Creates a new QCOW2-backed SD card with an optional explicit `card_name` by streaming an image file from disk.
    pub fn addNamedSdCardFromFile(self: *BoardState, card_name_opt: ?[]const u8, path: []const u8, size: SdCardSize) !usize {
        const file_size = try Qcow2Disk.getFileSizeLinux(path);
        if (file_size > size.bytes()) {
            self.new_card_size = size;
            self.setPendingSdImageFile(path, file_size);
            return error.ImageTooLarge;
        }
        var name_buf: [64]u8 = undefined;
        const card_name = self.resolveNewCardName(card_name_opt, &name_buf);

        var qcow2_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const qcow2_path = self.buildPersistentQcow2Path(card_name, &qcow2_path_buf);

        var disk = try Qcow2Disk.createFromImageFileAtPath(self.gpa, size.bytes(), path, qcow2_path);
        errdefer disk.deinit();

        const entry_path = qcow2_path orelse path;
        var entry = makeNamedSdCardEntry(card_name, entry_path, file_size, size, disk);
        entry.has_persistent_file = (qcow2_path != null);
        try self.sd_cards.append(self.gpa, entry);
        const idx = self.sd_cards.items.len - 1;
        self.selected_sd_card_idx = idx;
        self.sd_error_len = 0;
        self.sd_create_open = false;
        self.resetDefaultNewCardName();
        return idx;
    }

    pub fn isCreatingSdCard(self: *const BoardState) bool {
        return self.sd_create_task != null;
    }

    pub fn addPendingSdCard(self: *BoardState) bool {
        if (self.sd_create_task != null) return false;
        if (self.pending_sd_image_path_len == 0) {
            self.setSdError("Error: Choose an image file to put on the SD card");
            return false;
        }
        self.revalidatePendingSdImage();
        if (self.sd_error_len > 0) return false;

        var path_copy: [512]u8 = undefined;
        const path_len = self.pending_sd_image_path_len;
        @memcpy(path_copy[0..path_len], self.pending_sd_image_path_buf[0..path_len]);
        const path = path_copy[0..path_len];

        if (self.pending_sd_image_slice) |slice| {
            _ = self.addSdCardFromSlice(path, self.new_card_size, slice) catch |err| {
                self.setSdError(@errorName(err));
                return false;
            };
            self.pending_sd_image_path_len = 0;
            self.pending_sd_image_size = 0;
            self.pending_sd_image_slice = null;
            return true;
        } else {
            return self.startPendingSdCardAsync(path, self.new_card_size);
        }
    }

    fn startPendingSdCardAsync(self: *BoardState, path: []const u8, size: SdCardSize) bool {
        const file_size = Qcow2Disk.getFileSizeLinux(path) catch |err| {
            self.setSdError(@errorName(err));
            return false;
        };
        if (file_size > size.bytes()) {
            self.new_card_size = size;
            self.setPendingSdImageFile(path, file_size);
            return false;
        }

        var name_buf: [64]u8 = undefined;
        const card_name = self.resolveNewCardName(null, &name_buf);

        var qcow2_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const qcow2_path = self.buildPersistentQcow2Path(card_name, &qcow2_path_buf);

        const task = self.gpa.create(AsyncSdCreateTask) catch {
            // Fallback to synchronous if task struct allocation fails
            _ = self.addSdCardFromFile(path, size) catch |err| {
                self.setSdError(@errorName(err));
                return false;
            };
            self.pending_sd_image_path_len = 0;
            self.pending_sd_image_size = 0;
            self.pending_sd_image_slice = null;
            return true;
        };
        task.* = .{
            .size = size,
            .image_size_bytes = file_size,
        };
        @memcpy(task.card_name_buf[0..card_name.len], card_name);
        task.card_name_len = card_name.len;
        const plen = @min(path.len, task.src_path_buf.len);
        @memcpy(task.src_path_buf[0..plen], path[0..plen]);
        task.src_path_len = plen;
        if (qcow2_path) |qp| {
            const qlen = @min(qp.len, task.qcow2_path_buf.len);
            @memcpy(task.qcow2_path_buf[0..qlen], qp[0..qlen]);
            task.qcow2_path_len = qlen;
            task.has_qcow2_path = true;
        }

        task.thread = std.Thread.spawn(.{}, AsyncSdCreateTask.workerMain, .{task}) catch {
            self.gpa.destroy(task);
            _ = self.addSdCardFromFile(path, size) catch |err| {
                self.setSdError(@errorName(err));
                return false;
            };
            self.pending_sd_image_path_len = 0;
            self.pending_sd_image_size = 0;
            self.pending_sd_image_slice = null;
            return true;
        };

        self.sd_create_task = task;
        self.sd_error_len = 0;
        return false;
    }

    pub const AsyncSdPollResult = enum {
        idle,
        in_progress,
        completed_ok,
        completed_err,
    };

    /// How far the card being made in the background is (0 to 1), if one is.
    pub fn sdCreationProgress(self: *const BoardState) ?f32 {
        const task = self.sd_create_task orelse return null;
        if (task.image_size_bytes == 0) return 0;
        const done: f32 = @floatFromInt(task.progress_bytes.load(.monotonic));
        return @min(0.99, done / @as(f32, @floatFromInt(task.image_size_bytes)));
    }

    /// Polls any active background SD card image creation thread, finalizing
    /// the new `SdCardEntry` once complete.
    pub fn pollAsyncSdCreation(self: *BoardState) AsyncSdPollResult {
        const task = self.sd_create_task orelse return .idle;

        if (!task.done.load(.acquire)) {
            return .in_progress;
        }

        if (task.thread) |t| {
            t.join();
            task.thread = null;
        }
        self.sd_create_task = null;
        defer self.gpa.destroy(task);

        if (task.result_disk) |disk| {
            var owned_disk = disk;
            const card_name = task.card_name_buf[0..task.card_name_len];
            const entry_path = if (task.has_qcow2_path)
                task.qcow2_path_buf[0..task.qcow2_path_len]
            else
                task.src_path_buf[0..task.src_path_len];
            var entry = makeNamedSdCardEntry(card_name, entry_path, task.image_size_bytes, task.size, owned_disk);
            entry.has_persistent_file = task.has_qcow2_path;
            self.sd_cards.append(self.gpa, entry) catch |err| {
                owned_disk.deinit();
                self.setSdError(@errorName(err));
                return .completed_err;
            };
            self.selected_sd_card_idx = self.sd_cards.items.len - 1;
            self.sd_error_len = 0;
            self.pending_sd_image_path_len = 0;
            self.pending_sd_image_size = 0;
            self.pending_sd_image_slice = null;
            self.resetDefaultNewCardName();
            self.sd_create_open = false;
            self.sd_manage_open = false;
            return .completed_ok;
        } else {
            const err_msg = if (task.err_msg_len > 0)
                task.err_msg_buf[0..task.err_msg_len]
            else
                "Error creating SD card image";
            self.setSdError(err_msg);
            return .completed_err;
        }
    }

    fn makeNamedSdCardEntry(card_name: []const u8, path: []const u8, img_size: u64, size: SdCardSize, disk: Qcow2Disk) SdCardEntry {
        var entry: SdCardEntry = .{
            .image_size_bytes = img_size,
            .size = size,
            .disk = disk,
        };
        const plen = @min(path.len, entry.image_path_buf.len);
        @memcpy(entry.image_path_buf[0..plen], path[0..plen]);
        entry.image_path_len = plen;

        const nlen = @min(card_name.len, entry.name_buf.len);
        @memcpy(entry.name_buf[0..nlen], card_name[0..nlen]);
        entry.name_len = nlen;
        return entry;
    }

    pub fn effectiveCpuTemperature(self: *const BoardState, status: SystemStatus) u8 {
        if (self.cpu_temp_modified) return self.cpu_temperature_c;
        if (status.cpu_temperature_c != 42) return std.math.clamp(status.cpu_temperature_c, 0, 100);
        return self.cpu_temperature_c;
    }

    pub fn setCpuTemperature(self: *BoardState, temp_c: u8) void {
        self.cpu_temperature_c = std.math.clamp(temp_c, 0, 100);
        self.cpu_temp_modified = true;
    }

    pub fn parsedSerial(self: *const BoardState) u64 {
        if (self.serial_len == 0) return 0;
        return std.fmt.parseInt(u64, self.serial_hex[0..self.serial_len], 16) catch 0x00000000fa000001;
    }

    pub fn parsedMac(self: *const BoardState) [6]u8 {
        var out: [6]u8 = .{ 0xb8, 0x27, 0xeb, 0x12, 0x34, 0x56 };
        if (self.mac_len < 12) return out;
        for (0..6) |i| {
            out[i] = std.fmt.parseInt(u8, self.mac_hex[i * 2 .. i * 2 + 2], 16) catch out[i];
        }
        return out;
    }

    pub fn parsedWifiMac(self: *const BoardState) [6]u8 {
        var out: [6]u8 = .{ 0xb8, 0x27, 0xeb, 0x65, 0x43, 0x21 };
        if (self.wifi_mac_len < 12) return out;
        for (0..6) |i| {
            out[i] = std.fmt.parseInt(u8, self.wifi_mac_hex[i * 2 .. i * 2 + 2], 16) catch out[i];
        }
        return out;
    }

    pub fn randomizeSerial(self: *BoardState) void {
        var rnd: [4]u8 = undefined;
        host_posix.getRandomBytes(&rnd);
        const low = std.mem.readInt(u32, &rnd, .big);
        _ = std.fmt.bufPrint(&self.serial_hex, "00000000{x:0>8}", .{low}) catch {};
        self.serial_len = 16;
    }

    pub fn randomizeMac(self: *BoardState) void {
        var rnd: [3]u8 = undefined;
        host_posix.getRandomBytes(&rnd);
        _ = std.fmt.bufPrint(&self.mac_hex, "B827EB{X:0>2}{X:0>2}{X:0>2}", .{ rnd[0], rnd[1], rnd[2] }) catch {};
        self.mac_len = 12;
    }

    pub fn randomizeWifiMac(self: *BoardState) void {
        var rnd: [3]u8 = undefined;
        host_posix.getRandomBytes(&rnd);
        _ = std.fmt.bufPrint(&self.wifi_mac_hex, "B827EB{X:0>2}{X:0>2}{X:0>2}", .{ rnd[0], rnd[1], rnd[2] }) catch {};
        self.wifi_mac_len = 12;
    }

    pub fn randomizeIdentity(self: *BoardState) void {
        self.randomizeSerial();
        self.randomizeMac();
        self.randomizeWifiMac();
        self.identity_gen +%= 1;
    }
};

pub fn ensureDirPathLinux(path: []const u8) void {
    host_posix.ensureDirPath(path);
}

pub fn fileExistsLinux(path: []const u8) bool {
    return host_posix.fileExists(path);
}

const testing = std.testing;

/// A data directory of its own for a test, removed with what is in it.
const TestDataDir = struct {
    buf: [96]u8 = undefined,
    len: usize = 0,

    fn init(tag: []const u8) TestDataDir {
        var d: TestDataDir = .{};
        var rnd: [4]u8 = undefined;
        host_posix.getRandomBytes(&rnd);
        d.len = (std.fmt.bufPrint(&d.buf, "/tmp/fauxpi-test-{s}-{x}", .{ tag, std.mem.readInt(u32, &rnd, .little) }) catch unreachable).len;
        return d;
    }

    fn path(d: *const TestDataDir) []const u8 {
        return d.buf[0..d.len];
    }

    fn file(d: *const TestDataDir, buf: []u8, name: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ d.path(), name }) catch unreachable;
    }

    fn deinit(d: *const TestDataDir, files: []const []const u8) void {
        var buf: [160]u8 = undefined;
        for (files) |f| host_posix.unlinkFile(d.file(&buf, f));
        host_posix.unlinkFile(d.file(&buf, "settings.json"));
        host_posix.removeDir(d.file(&buf, "images"));
        host_posix.removeDir(d.path());
    }
};

/// A disk image with an MBR's signature.
fn testImage() [512]u8 {
    var img: [512]u8 = @splat(0);
    img[510] = 0x55;
    img[511] = 0xAA;
    return img;
}

test "the settings, and the card images, are kept in the data directory" {
    const dir = TestDataDir.init("settings");
    defer dir.deinit(&.{ "images/Card 1.qcow2", "images/Custom OS.qcow2" });
    const img = testImage();

    {
        var b = try BoardState.init(testing.allocator);
        defer b.deinit();
        var status: SystemStatus = .{ .board_model = .pi_zero };
        b.configureDataDir(dir.path(), &status);

        // Cards are called "Card 1", "Card 2" and so on, unless named.
        try testing.expectEqualStrings("Card 1", b.newCardName());
        _ = try b.addSdCardFromSlice("raspios-lite.img", .gb_4, &img);
        try testing.expectEqualStrings("Card 1", b.sd_cards.items[0].name());
        try testing.expectEqualStrings("Card 2", b.newCardName());
        b.sd_cards.items[0].disk.writeByte(0, 0x42);
        b.sd_cards.items[0].disk.writeByte(511, 0x99);
        _ = try b.addNamedSdCardFromSlice("Custom OS", "custom-os.img", .gb_4, &img);
        try testing.expectEqualStrings("Custom OS", b.sd_cards.items[1].name());
        try testing.expectEqualStrings("Card 2", b.newCardName());

        status.board_model = .pi_zero_2_w;
        b.setSerial("00000000cafebabe");
        b.setMac("B8:27:EB:11:22:33");
        b.setWifiMac("b827eb445566");
        b.setWifiPassword("say \"friend\" \\ enter");
        status.dhcp_enabled = false;
        status.sd_connected = true;
        status.hdmi_connected = false;
        b.selected_sd_card_idx = 0;
        try b.saveSettings(status);
    }

    var b = try BoardState.init(testing.allocator);
    defer b.deinit();
    var status: SystemStatus = .{};
    const gen = b.identity_gen;
    b.configureDataDir(dir.path(), &status);

    try testing.expectEqual(BoardModel.pi_zero_2_w, status.board_model);
    // Fields showing the identity start again with what was loaded.
    try testing.expect(b.identity_gen != gen);
    try testing.expectEqual(@as(u64, 0xCAFEBABE), status.serial_u64);
    try testing.expectEqualSlices(u8, &.{ 0xB8, 0x27, 0xEB, 0x11, 0x22, 0x33 }, &status.mac_address);
    try testing.expectEqualSlices(u8, &.{ 0xB8, 0x27, 0xEB, 0x44, 0x55, 0x66 }, &status.wifi_mac_address);
    var mac_buf: [17]u8 = undefined;
    try testing.expectEqualStrings("B8:27:EB:11:22:33", b.macText(&mac_buf));
    try testing.expectEqualStrings("say \"friend\" \\ enter", b.wifiPassword());
    try testing.expect(!status.dhcp_enabled);
    try testing.expect(status.sd_connected);
    try testing.expect(!status.hdmi_connected);

    try testing.expectEqual(@as(usize, 2), b.sd_cards.items.len);
    try testing.expectEqualStrings("Card 1", b.activeSdCardName());
    try testing.expectEqual(@as(u8, 0x42), b.activeSdCard().?.disk.readByte(0));
    try testing.expectEqual(@as(u8, 0x99), b.activeSdCard().?.disk.readByte(511));

    // Deleting a card deletes its file; with none left the dialog makes one.
    var path_buf: [160]u8 = undefined;
    try testing.expect(b.deleteSdCard(0));
    try testing.expect(!fileExistsLinux(dir.file(&path_buf, "images/Card 1.qcow2")));
    try testing.expectEqualStrings("Card 1", b.newCardName());
    try testing.expect(b.deleteSdCard(0));
    try testing.expectEqual(@as(?usize, null), b.selected_sd_card_idx);
    try testing.expect(b.isSdCreateView());
}

test "renaming a card renames its file, but not to another card's name" {
    const dir = TestDataDir.init("rename");
    defer dir.deinit(&.{ "images/Card 1.qcow2", "images/Card 2.qcow2", "images/Ubuntu.qcow2" });
    const img = testImage();
    var b = try BoardState.init(testing.allocator);
    defer b.deinit();
    var status: SystemStatus = .{};
    b.configureDataDir(dir.path(), &status);
    _ = try b.addSdCardFromSlice("a.img", .gb_4, &img);
    _ = try b.addSdCardFromSlice("b.img", .gb_4, &img);

    try testing.expect(b.startRenamingSdCard(0));
    try testing.expectEqualStrings("Card 1", b.renameCardName());
    b.setRenameCardName("  Ubuntu ");
    try testing.expect(b.commitRenamingSdCard());
    try testing.expectEqualStrings("Ubuntu", b.sd_cards.items[0].name());
    var path_buf: [160]u8 = undefined;
    try testing.expectEqualStrings(dir.file(&path_buf, "images/Ubuntu.qcow2"), b.sd_cards.items[0].imagePath());
    try testing.expect(fileExistsLinux(dir.file(&path_buf, "images/Ubuntu.qcow2")));

    // Another card has the name (whatever its case): no change.
    try testing.expect(!b.renameSdCard(1, "ubuntu"));
    try testing.expectEqualStrings("Card 2", b.sd_cards.items[1].name());
    // A slash would be a directory: it is changed.
    try testing.expect(b.renameSdCard(1, "a/b"));
    try testing.expectEqualStrings("a_b", b.sd_cards.items[1].name());
    try testing.expect(b.renameSdCard(1, "Card 2"));
}

test "a card is made from an image file in the background" {
    var rnd: [8]u8 = undefined;
    host_posix.getRandomBytes(&rnd);
    var src_buf: [128]u8 = undefined;
    const src = try std.fmt.bufPrint(&src_buf, "/tmp/fauxpi-async-test-{x}.img", .{std.mem.readInt(u64, &rnd, .little)});
    defer host_posix.unlinkFile(src);
    {
        const fd = try host_posix.openCreateTruncWrite(src, false);
        defer host_posix.close(fd);
        const img = testImage();
        try host_posix.writeAll(fd, &img);
    }

    var b = try BoardState.init(testing.allocator);
    defer b.deinit();
    b.sd_manage_open = true;
    try testing.expect(!b.addPendingSdCard());
    try testing.expectEqualStrings("Error: Choose an image file to put on the SD card", b.sdErrorMessage());

    b.setPendingSdImageFile(src, 512);
    // Made in the background: the dialog stays open, showing how far it is.
    try testing.expect(!b.addPendingSdCard());
    try testing.expect(b.isCreatingSdCard());
    try testing.expect(b.sdCreationProgress() != null);
    var spins: usize = 0;
    while (true) : (spins += 1) {
        const res = b.pollAsyncSdCreation();
        if (res == .completed_ok) break;
        try testing.expect(res == .in_progress);
        try testing.expect(spins < 100_000);
        var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 1_000_000 };
        _ = std.os.linux.nanosleep(&ts, null);
    }
    try testing.expect(!b.isCreatingSdCard());
    try testing.expect(!b.sd_manage_open);
    try testing.expectEqual(@as(?usize, 0), b.selected_sd_card_idx);
    try testing.expectEqual(@as(u8, 0x55), b.sd_cards.items[0].disk.readByte(510));
    try testing.expectEqual(@as(u8, 0xAA), b.sd_cards.items[0].disk.readByte(511));
}

test "an image too big for the card size is an error until a big enough size is picked" {
    var b = try BoardState.init(testing.allocator);
    defer b.deinit();
    b.new_card_size = .mb_256;
    b.setPendingSdImageFile("/tmp/big.img", 300 * 1024 * 1024);
    try testing.expect(b.hasImageTooLargeError());
    try testing.expectEqualStrings("Error: Image (300 MB) is too large for a 256 MB SD card", b.sdErrorMessage());
    b.new_card_size = .gb_1;
    b.revalidatePendingSdImage();
    try testing.expect(!b.hasImageTooLargeError());
    try testing.expectEqualStrings("", b.sdErrorMessage());
}

test "boot errors are told in words" {
    var b = try BoardState.init(testing.allocator);
    defer b.deinit();
    try testing.expect(!b.hasSnackbar());
    b.showBootErrorSnackbar(error.Requires64BitBoard);
    try testing.expectEqualStrings("64-bit OS image requires a 64-bit board (Raspberry Pi 3 or Zero 2 W)", b.snackbarMessage());
    b.showBootErrorSnackbar(error.Unexpected);
    try testing.expectEqualStrings("Failed to boot SD card: Unexpected", b.snackbarMessage());
    b.dismissSnackbar();
    try testing.expect(!b.hasSnackbar());
}

test "formatByteSize picks appropriate human-readable units" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0 B", formatByteSize(&buf, 0));
    try testing.expectEqualStrings("512 B", formatByteSize(&buf, 512));
    try testing.expectEqualStrings("1 KB", formatByteSize(&buf, 1024));
    try testing.expectEqualStrings("256 KB", formatByteSize(&buf, 256 * 1024));
    try testing.expectEqualStrings("1 MB", formatByteSize(&buf, 1024 * 1024));
    try testing.expectEqualStrings("1.5 MB", formatByteSize(&buf, 1536 * 1024));
    try testing.expectEqualStrings("42 MB", formatByteSize(&buf, 42 * 1024 * 1024));
    try testing.expectEqualStrings("1 GB", formatByteSize(&buf, 1024 * 1024 * 1024));
    try testing.expectEqualStrings("1.5 GB", formatByteSize(&buf, 1536 * 1024 * 1024));
    try testing.expectEqualStrings("16 GB", formatByteSize(&buf, 16 * 1024 * 1024 * 1024));
}
