//! FauxPi's window, as kete widgets: the title bar, the HDMI output with the
//! sheet over (or above) it, where the board is drawn with what is plugged
//! into it (each connector and peripheral a toggle) and its settings, and the
//! GPIO panel below. `Shell` is what they show and change; the window acts on
//! its `events`.
//!
//! The keyboard goes to the guest's USB keyboard unless a field has it, or
//! the sheet covers the display; the pointer over the display is the guest's
//! USB mouse.

const std = @import("std");
const kete = @import("kete");
const build_info = @import("build_info");
const host_posix = @import("../host/posix.zig");
const canvas_mod = @import("canvas.zig");
const board = @import("board.zig");
const board_state = @import("board_state.zig");
const drawing = @import("board_drawing.zig");
const gpio_model = @import("gpio_model.zig");
const Gpio = @import("../soc/gpio.zig").Gpio;
const UsbHidComposite = @import("../usb/hid.zig").UsbHidComposite;

const Widget = kete.Widget;
const BuildContext = kete.BuildContext;
const WidgetNode = kete.WidgetNode;
const Constraints = kete.Constraints;
const Size = kete.Size;
const Point = kete.Point;
const Canvas = canvas_mod.Canvas;
const Color = canvas_mod.Color;
const Rect = canvas_mod.Rect;
const Theme = canvas_mod.Theme;
const BoardModel = board.BoardModel;
const BoardState = board_state.BoardState;
const SystemStatus = board_state.SystemStatus;
const SdCardSize = board_state.SdCardSize;
const WifiSecurity = board_state.WifiSecurity;
const InteractiveTarget = drawing.InteractiveTarget;

pub const title_bar_height: u32 = 44;
pub const gpio_panel_height: u32 = 136;

/// The guest's HDMI output.
pub const Hdmi = struct {
    /// Its size, in the guest's pixels.
    width: u32,
    height: u32,
    /// Its pixels (`width` by `height`).
    fb: []const u32 = &.{},
    /// `fb` as kete draws it (scaled on the GPU), if it is no bigger than
    /// kete's images can be; or else it is scaled on the CPU.
    image: ?kete.gfx.Image = null,
    /// Changes when `fb` does.
    gen: u64 = 1,
};

/// What happened that the window acts on (and clears).
pub const Events = struct {
    /// The settings changed: to be saved.
    save: bool = false,
    /// Power was connected: the board boots.
    power_on: bool = false,
    /// The SD card went in, came out, or another card image was chosen.
    sd_in: bool = false,
    sd_out: bool = false,
    sd_chosen: bool = false,
    /// An image file is to be picked, to make an SD card from.
    pick_image: bool = false,
    /// The GPIO panel came or went: the window grows or shrinks for it.
    gpio_toggled: bool = false,
    /// Another board was chosen: the window's title changes.
    board_changed: bool = false,
};

/// What the window's widgets show and change: the board, its status and
/// GPIO, the guest's keyboard and mouse, and how the window is arranged.
pub const Shell = struct {
    board: *BoardState,
    status: *SystemStatus,
    gpio: *Gpio,
    /// The guest's USB keyboard and mouse (and network adapter), if it has them.
    hid: ?*UsbHidComposite = null,
    /// The text font, to measure what the drawings write.
    font: canvas_mod.Font,
    hdmi: Hdmi,

    /// Whether the sheet is shown over the display (when the window is too
    /// small for it to stay above it), and its settings are.
    sheet_open: bool = true,
    settings_open: bool = false,
    /// From the last layout: whether the sheet is above the display (and
    /// can't be closed), the window's size, and the display's place in the
    /// area under the title bar.
    sheet_docked: bool = false,
    width: u32 = 0,
    height: u32 = 0,
    display_rect: kete.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    display_area: Size = .{},
    /// How tall the board's drawing may be: less, above the display, for the
    /// display to fit.
    diagram_max_h: f32 = BoardDiagram.max_height,
    events: Events = .{},
    /// What each card's buttons in the SD card menu and dialog act on.
    card_actions: [max_cards]CardAction = undefined,

    const max_cards = 64;

    pub fn init(b: *BoardState, status: *SystemStatus, gpio: *Gpio, hdmi: Hdmi) !Shell {
        return .{
            .board = b,
            .status = status,
            .gpio = gpio,
            .font = try canvas_mod.Font.init(canvas_mod.fira_ttf),
            .hdmi = hdmi,
        };
    }

    /// Whether the sheet covers the display: the guest then gets no input.
    pub fn sheetCovers(sh: *const Shell) bool {
        return sh.sheet_open and !sh.sheet_docked;
    }

    fn changed(sh: *Shell) void {
        sh.events.save = true;
    }

    /// Plugs in, or pulls out, what `target` is (not the SD card or the CPU).
    pub fn toggle(sh: *Shell, target: InteractiveTarget) void {
        const st = sh.status;
        switch (target) {
            .hdmi => {
                st.hdmi_connected = !st.hdmi_connected;
                if (!st.hdmi_connected) st.hdmi_active = false;
                sh.gpio.setExternalPin(46, !st.hdmi_connected);
            },
            .audio => st.audio_connected = !st.audio_connected,
            .power => {
                st.power_connected = !st.power_connected;
                if (st.power_connected) {
                    sh.events.power_on = true;
                } else {
                    st.hdmi_active = false;
                    sh.gpio.resetSocState();
                }
                return;
            },
            .usb_hub => {
                st.usb_hub_connected = !st.usb_hub_connected;
                if (sh.hid) |h| h.hub_connected = st.usb_hub_connected;
            },
            .usb_keyboard => {
                st.usb_keyboard_connected = !st.usb_keyboard_connected;
                if (sh.hid) |h| h.keyboard_connected = st.usb_keyboard_connected;
            },
            .usb_mouse => {
                st.usb_mouse_connected = !st.usb_mouse_connected;
                if (sh.hid) |h| h.mouse_connected = st.usb_mouse_connected;
            },
            .ethernet => {
                st.ethernet_connected = !st.ethernet_connected;
                if (sh.hid) |h| h.ethernet_connected = st.ethernet_connected;
            },
            .gpio => {
                st.gpio_connected = !st.gpio_connected;
                if (!st.gpio_connected) sh.gpio.clearHeaderExternalPins();
                sh.events.gpio_toggled = true;
            },
            .sd_connector, .sd_card => return sh.toggleSd(),
            .cpu => return,
        }
        sh.changed();
    }

    /// Puts the SD card in, or takes it out: there must be a card image to
    /// put in.
    pub fn toggleSd(sh: *Shell) void {
        const st = sh.status;
        if (!st.sd_connected and !sh.board.hasActiveSdCard()) return;
        st.sd_connected = !st.sd_connected;
        if (st.sd_connected) sh.events.sd_in = true else sh.events.sd_out = true;
        sh.changed();
    }

    /// The card image in (or to go in) the slot changed.
    fn sdCardChanged(sh: *Shell) void {
        if (sh.board.activeSdCard() == null) {
            sh.status.sd_connected = false;
            sh.events.sd_out = true;
        } else {
            sh.events.sd_chosen = true;
        }
        sh.changed();
    }

    pub fn selectSdCard(sh: *Shell, idx: usize) void {
        sh.board.selected_sd_card_idx = idx;
        sh.sdCardChanged();
    }

    /// Opens the Manage SD Cards dialog: making a card, if there are none.
    pub fn openSdManager(sh: *Shell) void {
        const b = sh.board;
        b.sd_manage_open = true;
        b.sd_create_open = b.sd_cards.items.len == 0;
        if (b.new_card_name_len == 0) b.resetDefaultNewCardName();
    }

    pub fn closeSdManager(sh: *Shell) void {
        const b = sh.board;
        if (b.isCreatingSdCard()) return;
        if (b.commitRenamingSdCard()) sh.changed();
        b.sd_manage_open = false;
        b.sd_create_open = false;
    }

    /// The dialog's form for making a card, instead of the list of them.
    pub fn showCreateCard(sh: *Shell) void {
        const b = sh.board;
        if (b.commitRenamingSdCard()) sh.changed();
        b.sd_create_open = true;
        b.sd_error_len = 0;
        b.resetDefaultNewCardName();
    }

    /// Back to the list of cards, or (with none) closes the dialog.
    pub fn cancelCreateCard(sh: *Shell) void {
        const b = sh.board;
        if (b.isCreatingSdCard()) return;
        if (b.sd_cards.items.len == 0) return sh.closeSdManager();
        b.sd_create_open = false;
        b.sd_error_len = 0;
    }

    pub fn canCreateCard(sh: *const Shell) bool {
        const b = sh.board;
        return !b.isCreatingSdCard() and b.pending_sd_image_path_len > 0 and !b.hasImageTooLargeError();
    }

    /// Makes a card from the chosen image (in the background, for a file:
    /// `BoardState.pollAsyncSdCreation` finishes it).
    pub fn createCard(sh: *Shell) void {
        const b = sh.board;
        if (b.addPendingSdCard()) {
            b.sd_create_open = false;
            b.sd_manage_open = false;
            sh.sdCardChanged();
        }
    }

    pub fn chooseImage(sh: *Shell) void {
        sh.events.pick_image = true;
    }

    pub fn setNewCardName(sh: *Shell, text: []const u8) void {
        sh.board.setNewCardName(text);
    }

    pub fn setNewCardSize(sh: *Shell, idx: usize) void {
        if (idx >= SdCardSize.all.len) return;
        sh.board.new_card_size = SdCardSize.all[idx];
        sh.board.revalidatePendingSdImage();
    }

    pub fn setRenameName(sh: *Shell, text: []const u8) void {
        sh.board.setRenameCardName(text);
    }

    pub fn commitRename(sh: *Shell) void {
        if (sh.board.commitRenamingSdCard()) sh.changed();
    }

    /// Picks the board `BoardModel.all[idx]`: with a new identity, as
    /// another board has.
    pub fn selectBoard(sh: *Shell, idx: usize) void {
        if (idx >= BoardModel.all.len) return;
        const bm = BoardModel.all[idx];
        if (bm == sh.status.board_model) return;
        sh.board.randomizeIdentity();
        sh.setBoardModel(bm);
    }

    /// Makes the board a `bm`, keeping its identity.
    pub fn setBoardModel(sh: *Shell, bm: BoardModel) void {
        const st = sh.status;
        st.board_model = bm;
        sh.identityChanged();
        if (!bm.usesExternalUsbHub()) st.usb_hub_connected = true;
        if (sh.hid) |h| {
            h.setHubKind(bm.hubKind());
            h.hub_connected = st.usb_hub_connected;
        }
        sh.events.board_changed = true;
        sh.changed();
    }

    fn identityChanged(sh: *Shell) void {
        sh.status.serial_u64 = sh.board.parsedSerial();
        sh.status.mac_address = sh.board.parsedMac();
        sh.status.wifi_mac_address = sh.board.parsedWifiMac();
    }

    pub fn setSerial(sh: *Shell, text: []const u8) void {
        sh.board.setSerial(text);
        sh.identityChanged();
        sh.changed();
    }

    pub fn setMac(sh: *Shell, text: []const u8) void {
        sh.board.setMac(text);
        sh.identityChanged();
        sh.changed();
    }

    pub fn setWifiMac(sh: *Shell, text: []const u8) void {
        sh.board.setWifiMac(text);
        sh.identityChanged();
        sh.changed();
    }

    pub fn setWifiSecurity(sh: *Shell, idx: usize) void {
        if (idx >= WifiSecurity.all.len) return;
        sh.board.wifi_security = WifiSecurity.all[idx];
        sh.changed();
    }

    pub fn setWifiPassword(sh: *Shell, text: []const u8) void {
        sh.board.setWifiPassword(text);
        sh.changed();
    }

    pub fn setDhcp(sh: *Shell, on: bool) void {
        sh.status.dhcp_enabled = on;
        if (sh.hid) |h| h.net.dhcp_enabled = on;
        sh.changed();
    }

    pub fn setCpuTemperature(sh: *Shell, value: f32) void {
        sh.board.setCpuTemperature(@intFromFloat(std.math.clamp(@round(value), 0, 100)));
        sh.status.cpu_temperature_c = sh.board.cpu_temperature_c;
        sh.changed();
    }

    pub fn toggleSheet(sh: *Shell) void {
        sh.sheet_open = !sh.sheet_open;
        // Over the display, it takes the keyboard from the guest.
        if (sh.sheetCovers()) {
            if (sh.hid) |h| h.releaseAllKeys();
        }
    }

    pub fn toggleSettings(sh: *Shell) void {
        sh.settings_open = !sh.settings_open;
    }

    pub fn dismissSnackbar(sh: *Shell) void {
        sh.board.dismissSnackbar();
    }
};

/// What a card's buttons act on: the card `idx`.
const CardAction = struct {
    shell: *Shell,
    idx: usize,

    fn select(a: *CardAction) void {
        a.shell.selectSdCard(a.idx);
    }

    fn rename(a: *CardAction) void {
        const b = a.shell.board;
        if (b.renaming_sd_card_idx == a.idx) return a.shell.commitRename();
        _ = b.startRenamingSdCard(a.idx);
    }

    fn delete(a: *CardAction) void {
        if (a.shell.board.deleteSdCard(a.idx)) a.shell.sdCardChanged();
    }
};

/// The window: what `App.openWindow` is given as its root.
pub const Root = struct {
    shell: *Shell,

    pub fn build(self: *const Root, cx: *BuildContext) Widget {
        const sh = self.shell;
        var rows: [3]Widget = undefined;
        var n: usize = 0;
        rows[n] = cx.make(TitleBar{ .shell = sh });
        n += 1;
        rows[n] = cx.make(kete.Expanded{ .child = cx.make(Body{ .shell = sh, .children = bodyChildren(cx, sh) }) });
        n += 1;
        if (sh.status.gpio_connected) {
            rows[n] = cx.make(kete.SizedBox{ .height = gpio_panel_height, .child = cx.make(GpioPanel{ .shell = sh }) });
            n += 1;
        }
        var content = cx.make(kete.Column{ .cross_axis_alignment = .stretch, .children = rows[0..n] });
        if (sh.board.hasSnackbar()) {
            content = cx.make(kete.Snackbar{
                .message = sh.board.snackbarMessage(),
                .on_dismiss = .of(sh, Shell.dismissSnackbar),
                .child = content,
            });
        }
        if (sh.board.sd_manage_open) content = sdDialog(cx, sh, content);
        return cx.make(Keyboard{ .shell = sh, .child = content });
    }
};

/// The window's contents, which has the keyboard when nothing in it does:
/// the keys go to the guest (Tab too), unless the sheet covers the display,
/// when Escape closes it.
const Keyboard = struct {
    shell: *Shell,
    child: Widget,

    pub const takes_tab = true;

    pub fn layout(self: *const Keyboard, n: *WidgetNode, c: Constraints) Size {
        // Nothing else has the keyboard: the guest has it.
        if (n.ui.focused == null) n.ui.focus(n);
        const size = n.child(0).layout(c);
        n.child(0).place(0, 0);
        self.shell.width = @intFromFloat(@max(size.w, 1));
        self.shell.height = @intFromFloat(@max(size.h, 1));
        return size;
    }

    pub fn focusable(_: *const Keyboard, _: *WidgetNode) bool {
        return true;
    }

    pub fn event(self: *const Keyboard, n: *WidgetNode, e: kete.Event) bool {
        const sh = self.shell;
        switch (e) {
            .key => |k| {
                // A key a field didn't take is not the guest's.
                if (n.ui.focused != n) return false;
                if (sh.sheetCovers()) {
                    if (k.pressed and k.key == .escape) {
                        sh.sheet_open = false;
                        n.ui.needs_frame = true;
                    }
                    return true;
                }
                const code = kete.window.evdev.codeOf(k.key) orelse return false;
                if (sh.hid) |h| h.handleEvdevKey(code, k.pressed);
                return true;
            },
            .blur => if (sh.hid) |h| h.releaseAllKeys(),
            else => {},
        }
        return false;
    }
};

/// The bar across the top: the board's name, and (while the window is too
/// small for the sheet to stay above the display) the button that shows it.
/// Dragging it moves the window; kete's window buttons are over its right end.
const TitleBar = struct {
    shell: *Shell,

    pub fn build(self: *const TitleBar, cx: *BuildContext) Widget {
        const sh = self.shell;
        const t = cx.theme();
        var items: [2]Widget = undefined;
        var n: usize = 0;
        items[n] = cx.make(kete.Text{
            .text = sh.status.board_model.windowTitle(),
            .style = .{ .size = 22, .color = t.on_surface },
            .wrap = false,
            .ellipsis = true,
        });
        n += 1;
        if (!sh.sheet_docked) {
            items[n] = cx.make(kete.IconButton{
                .icon = .developer_board,
                .selected = sh.sheet_open,
                .size = 34,
                .on_press = .of(sh, Shell.toggleSheet),
            });
            n += 1;
        }
        return cx.make(kete.SizedBox{
            .height = title_bar_height,
            .child = cx.make(kete.RoundedBox{
                .color = t.surface_container,
                .child = cx.make(kete.WindowDragArea{
                    .child = cx.make(kete.Align.center(cx.make(kete.Row{ .fill = false, .spacing = 8, .children = items[0..n] }))),
                }),
            }),
        });
    }
};

/// The display, and the sheet (dimming the display when it covers it).
fn bodyChildren(cx: *BuildContext, sh: *Shell) []const Widget {
    var out: [3]Widget = undefined;
    var n: usize = 0;
    out[n] = cx.make(DisplayArea{ .shell = sh });
    n += 1;
    if (sh.sheet_docked or sh.sheet_open) {
        if (!sh.sheet_docked) {
            out[n] = cx.make(Scrim{ .shell = sh });
            n += 1;
        }
        out[n] = cx.make(Sheet{ .shell = sh });
        n += 1;
    }
    return cx.arena.dupe(Widget, out[0..n]) catch &.{};
}

/// Under the title bar: the display, with the sheet above it when there is
/// room for both (the sheet scrolling if it is taller than its share), or
/// else over it.
const Body = struct {
    shell: *Shell,
    children: []const Widget,

    /// The space between the sheet and the display when docked.
    const margin = 8;

    pub fn layout(self: *const Body, n: *WidgetNode, c: Constraints) Size {
        const sh = self.shell;
        const size = c.biggest();
        const sheet_w = @min(@min(@max(size.w - 32, 360), 740), size.w);
        const disp_h = @min(size.h, @as(f32, @floatFromInt(sh.hdmi.height)));
        // Above the display if the board (drawn smaller, if need be) and its
        // Settings button fit there.
        const above = size.h - disp_h - margin;
        const docked = above >= BoardDiagram.min_height + Sheet.chrome;
        sh.diagram_max_h = if (docked) @min(BoardDiagram.max_height, above - Sheet.chrome) else BoardDiagram.max_height;
        if (docked != sh.sheet_docked) {
            sh.sheet_docked = docked;
            // The title bar's button, and what is under the sheet.
            n.ui.needs_frame = true;
        }

        var sheet_h: f32 = 0;
        for (n.children.items) |ch| {
            if (!ch.widget.is(Sheet)) continue;
            const max_h = if (docked) size.h - disp_h - margin else size.h;
            sheet_h = @min(Sheet.contentHeight(ch, sheet_w), max_h);
            _ = ch.layout(.tight(.{ .w = sheet_w, .h = sheet_h }));
            ch.place(@round((size.w - sheet_w) / 2), 0);
        }
        for (n.children.items) |ch| {
            if (ch.widget.is(Sheet)) continue;
            if (ch.widget.is(DisplayArea) and docked) {
                _ = ch.layout(.tight(.{ .w = size.w, .h = size.h - sheet_h }));
                ch.place(0, sheet_h);
            } else {
                _ = ch.layout(.tight(size));
                ch.place(0, 0);
            }
        }
        return size;
    }

    pub fn paint(self: *const Body, n: *WidgetNode, p: *kete.Painter) void {
        // Beside the sheet above the display.
        if (self.shell.sheet_docked) p.canvas().fillRect(.{ .x = 0, .y = 0, .w = n.size.w, .h = n.size.h }, n.theme().surface);
    }
};

/// The guest's HDMI output, at its size (or smaller, if the window is), in
/// the middle of its area with a border; or the monitor's "no signal". The
/// pointer over it is the guest's mouse.
const DisplayArea = struct {
    shell: *Shell,

    pub fn layout(self: *const DisplayArea, _: *WidgetNode, c: Constraints) Size {
        const sh = self.shell;
        const size = c.biggest();
        const w = @min(size.w, @as(f32, @floatFromInt(sh.hdmi.width)));
        const h = @min(size.h, @as(f32, @floatFromInt(sh.hdmi.height)));
        sh.display_area = size;
        sh.display_rect = .{ .x = @floor((size.w - w) / 2), .y = @floor((size.h - h) / 2), .w = w, .h = h };
        return size;
    }

    pub fn paint(self: *const DisplayArea, n: *WidgetNode, p: *kete.Painter) void {
        const sh = self.shell;
        const st = sh.status;
        const theme = Theme.fromKete(n.theme());
        var c: Canvas = .{ .painter = p, .font = &sh.font };
        const dr = rectOf(sh.display_rect);

        // The surround, and a line round the display, where there is room.
        if (dr.w < n.size.w or dr.h < n.size.h) {
            c.fillRect(.{ .x = 0, .y = 0, .w = n.size.w, .h = n.size.h }, theme.surface);
            c.strokeRect(dr.outset(1.0), 1.0, theme.outline_variant);
        }
        if (!st.hdmi_connected or !st.hdmi_active) return paintNoSignal(&c, dr, st.hdmi_connected);
        const r = sh.display_rect;
        if (sh.hdmi.image) |*img| {
            // HDMI has no transparency: whatever alpha the pixels have, they
            // are over black.
            const kc = p.canvas();
            kc.fillRect(r, .{ .r = 0, .g = 0, .b = 0 });
            kc.drawImage(img, r, 1);
        } else {
            p.gpuWith(.{ .bounds = r, .key = sh.hdmi.gen, .fills = true }, sh, drawHdmi);
        }
    }

    /// Scales the HDMI framebuffer into the display's rectangle in `area`
    /// (the whole widget's: the bounds only say where it draws), nearest
    /// pixel, so it stays sharp.
    fn drawHdmi(sh: *const Shell, target: *kete.gfx.software.Image, area: kete.gfx.GpuArea) anyerror!void {
        const box = area.viewport;
        if (box.width == 0 or box.height == 0 or sh.display_area.w <= 0) return;
        const s = @as(f32, @floatFromInt(box.width)) / sh.display_area.w;
        const dr = sh.display_rect;
        const vp: kete.gfx.Viewport = .{
            .x = box.x + @as(i32, @intFromFloat(@round(dr.x * s))),
            .y = box.y + @as(i32, @intFromFloat(@round(dr.y * s))),
            .width = @intFromFloat(@max(@round(dr.w * s), 0)),
            .height = @intFromFloat(@max(@round(dr.h * s), 0)),
        };
        if (vp.width == 0 or vp.height == 0) return;
        const full: kete.gfx.Viewport = .{ .width = target.width, .height = target.height };
        const sc = full.intersect(if (area.scissor) |cut| vp.intersect(cut) orelse return else vp) orelse return;
        const dw: usize = sh.hdmi.width;
        const dh: usize = sh.hdmi.height;
        const stride = target.rowStride();
        for (0..sc.height) |row| {
            const y: usize = @intCast(sc.y + @as(i32, @intCast(row)));
            const local_y = y - @as(usize, @intCast(vp.y));
            const src_row = sh.hdmi.fb[(local_y * dh / vp.height) * dw ..][0..dw];
            const dst = target.pixels[y * stride ..];
            for (0..sc.width) |col| {
                const x: usize = @intCast(sc.x + @as(i32, @intCast(col)));
                const local_x = x - @as(usize, @intCast(vp.x));
                dst[x] = src_row[local_x * dw / vp.width] | 0xFF000000;
            }
        }
    }

    pub fn cursor(self: *const DisplayArea, _: *WidgetNode, pos: Point) ?kete.PointerCursor {
        // A cross over the display: the guest draws its own pointer.
        return if (rectOf(self.shell.display_rect).contains(pos)) .crosshair else .default;
    }

    pub fn event(self: *const DisplayArea, _: *WidgetNode, e: kete.Event) bool {
        const sh = self.shell;
        const hid = sh.hid orelse return false;
        switch (e) {
            .motion => |pos| {
                const at = self.guestPoint(pos);
                hid.setMouseTarget(at[0], at[1]);
            },
            .press, .release => {
                const pos = if (e == .press) e.press.pos else e.release.pos;
                const button = if (e == .press) e.press.button else e.release.button;
                const bit: u8 = switch (button) {
                    .left => 1 << 0,
                    .right => 1 << 1,
                    .middle => 1 << 2,
                    else => return false,
                };
                if (e == .release and e.release.pos[0] < 0) {
                    // Released away from the window: where it was last.
                } else {
                    const at = self.guestPoint(pos);
                    hid.setMouseTarget(at[0], at[1]);
                }
                hid.handleMouseButton(bit, e == .press);
            },
            .scroll => |sc| {
                if (sc.dy == 0) return false;
                hid.handleMouseMotion(0, 0, if (sc.dy < 0) 1 else -1);
            },
            else => return false,
        }
        return true;
    }

    /// Where `pos` (in the widget) is on the guest's display, in its pixels.
    fn guestPoint(self: *const DisplayArea, pos: Point) [2]i32 {
        const sh = self.shell;
        const dr = sh.display_rect;
        const fx = if (dr.w > 0) (pos[0] - dr.x) * @as(f32, @floatFromInt(sh.hdmi.width)) / dr.w else 0;
        const fy = if (dr.h > 0) (pos[1] - dr.y) * @as(f32, @floatFromInt(sh.hdmi.height)) / dr.h else 0;
        const max_x: f32 = @floatFromInt(@max(sh.hdmi.width, 1) - 1);
        const max_y: f32 = @floatFromInt(@max(sh.hdmi.height, 1) - 1);
        return .{ @intFromFloat(std.math.clamp(@floor(fx), 0, max_x)), @intFromFloat(std.math.clamp(@floor(fy), 0, max_y)) };
    }
};

/// What a monitor shows with no picture: its message box, saying whether
/// the cable is in.
fn paintNoSignal(c: *Canvas, dr: Rect, hdmi_connected: bool) void {
    if (dr.w <= 0 or dr.h <= 0) return;
    c.fillRect(dr, Color.rgb(0x0b0d11));

    const osd_w: f32 = 288.0;
    const osd_h: f32 = 122.0;
    const osd_x = @round(dr.x + (dr.w - osd_w) * 0.5);
    const osd_y = @round(dr.y + (dr.h - osd_h) * 0.5);
    const osd_rect: Rect = .{ .x = osd_x, .y = osd_y, .w = osd_w, .h = osd_h };
    c.fillRoundedRect(osd_rect, .all(12.0), Color.rgb(0x161920).withAlpha(0.96));
    c.strokeRoundedRect(osd_rect, .all(12.0), 1.5, Color.rgb(0x323846));

    // The input's name, in a badge
    const badge_w: f32 = 64.0;
    const badge_h: f32 = 22.0;
    const badge_rect: Rect = .{ .x = @round(osd_x + (osd_w - badge_w) * 0.5), .y = osd_y + 16.0, .w = badge_w, .h = badge_h };
    c.fillRoundedRect(badge_rect, .all(6.0), Color.rgb(0x252a36));
    c.strokeRoundedRect(badge_rect, .all(6.0), 1.0, Color.rgb(0x414858));
    const badge_label = "HDMI";
    const badge_style: canvas_mod.Style = .{ .font = c.font, .size = 12.0 };
    _ = c.drawText(
        12.0,
        @round(badge_rect.x + (badge_w - c.measureText(12.0, badge_label)) * 0.5),
        @round(badge_rect.y + (badge_h - badge_style.lineHeight()) * 0.5 + badge_style.ascent()),
        badge_label,
        Color.rgb(0xb8c0d0),
    );

    const msg = "No signal detected";
    _ = c.drawText(20.0, @round(osd_x + (osd_w - c.measureText(20.0, msg)) * 0.5), osd_y + 68.0, msg, Color.rgb(0xe8ecf4));

    // Why, beside a standby light
    const sub = if (hdmi_connected) "Standby  ·  Waiting for signal" else "HDMI cable disconnected";
    const sub_x0 = @round(osd_x + (osd_w - (12.0 + c.measureText(13.0, sub))) * 0.5);
    c.fillCircle(.{ sub_x0 + 3.0, osd_y + 92.0 }, 3.5, if (hdmi_connected) Color.rgb(0xfb8c00) else Color.rgb(0xe53935));
    _ = c.drawText(13.0, sub_x0 + 12.0, osd_y + 96.0, sub, Color.rgb(0x8c94a6));
}

fn rectOf(r: kete.Rect) Rect {
    return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
}

/// The display dimmed under the sheet that covers it: pressing it closes
/// the sheet.
const Scrim = struct {
    shell: *Shell,

    /// How dark the display is under it: as if 45% of it shows.
    const alpha = 0.55;

    pub fn paint(_: *const Scrim, n: *WidgetNode, p: *kete.Painter) void {
        p.canvas().fillRect(.{ .x = 0, .y = 0, .w = n.size.w, .h = n.size.h }, kete.Color.argb(0xff000000).withAlpha(alpha));
    }

    pub fn cursor(_: *const Scrim, _: *WidgetNode, _: Point) ?kete.PointerCursor {
        return .default;
    }

    pub fn event(self: *const Scrim, n: *WidgetNode, e: kete.Event) bool {
        switch (e) {
            .press => |pr| return pr.button == .left,
            .release => |r| {
                if (r.button == .left and r.inside) {
                    self.shell.sheet_open = false;
                    n.ui.needs_frame = true;
                }
                return true;
            },
            .scroll, .motion => return true,
            else => return false,
        }
    }
};

/// The sheet: the board with what is plugged into it, and its settings,
/// scrolling when it doesn't fit.
const Sheet = struct {
    shell: *Shell,

    pub fn build(self: *const Sheet, cx: *BuildContext) Widget {
        const sh = self.shell;
        const t = cx.theme();
        var items: [3]Widget = undefined;
        var n: usize = 0;
        items[n] = cx.make(BoardDiagram{ .shell = sh });
        n += 1;
        items[n] = cx.make(kete.Align{ .height_factor = 1, .child = cx.make(kete.OutlinedButton{
            .label = "Settings",
            .trailing_icon = if (sh.settings_open) .expand_less else .expand_more,
            .on_press = .of(sh, Shell.toggleSettings),
        }) });
        n += 1;
        if (sh.settings_open) {
            items[n] = settingsPanel(cx, sh);
            n += 1;
        }
        return cx.make(kete.RoundedBox{
            .color = t.surface,
            .border_color = t.outline_variant,
            .radius = .{ .bl = 16, .br = 16 },
            .child = cx.make(kete.ScrollView{
                .child = cx.make(kete.Padding{
                    .padding = padding,
                    .child = cx.make(kete.Column{ .fill = false, .cross_axis_alignment = .stretch, .spacing = spacing, .children = items[0..n] }),
                }),
            }),
        });
    }

    /// The space round what is in the sheet.
    const padding: kete.Insets = .{ .left = 24, .right = 24, .top = 24, .bottom = 14 };
    const spacing = 12;

    /// What the sheet is besides the board's drawing (with its settings
    /// closed): the Settings button, and the space round them.
    const chrome = padding.top + spacing + kete.ui.button.height + padding.bottom;

    /// How tall the sheet `n` (laid out `width` wide) is when nothing of it
    /// is hidden: what is in its scroll view, measured on its own.
    fn contentHeight(n: *WidgetNode, width: f32) f32 {
        // The sheet builds a box, holding the scroll view, holding the padding.
        if (n.childCount() == 0) return 0;
        const box = n.child(0);
        if (box.childCount() == 0) return 0;
        const scroll = box.child(0);
        if (scroll.childCount() == 0) return 0;
        return scroll.child(0).layout(.{ .min_w = width, .max_w = width }).h;
    }
};

/// The board, drawn with what is plugged into it: pressing a connector or a
/// peripheral plugs it in or pulls it out, the SD card offers the card images,
/// and the CPU its temperature.
const BoardDiagram = struct {
    shell: *Shell,

    pub const State = struct {
        hovered: ?InteractiveTarget = null,
    };

    /// As tall as the drawing is at the sheet's width, up to this (or less,
    /// down to `min_height`, for the display to fit under it).
    const max_height = 300;
    const min_height = 180;

    pub fn layout(self: *const BoardDiagram, _: *WidgetNode, c: Constraints) Size {
        return c.constrain(self.size(c));
    }

    pub fn minSize(self: *const BoardDiagram, _: *WidgetNode, c: Constraints) Size {
        return c.constrain(self.size(c));
    }

    fn size(self: *const BoardDiagram, c: Constraints) Size {
        const w = if (c.boundedWidth()) c.max_w else 600;
        const r = drawing.boardBoundsWithPeripherals(self.shell.status.board_model.drawing());
        return .{ .w = w, .h = @min(w * r.h / r.w, self.shell.diagram_max_h) };
    }

    pub fn paint(self: *const BoardDiagram, n: *WidgetNode, p: *kete.Painter) void {
        const sh = self.shell;
        const theme = Theme.fromKete(n.theme());
        var c: Canvas = .{ .painter = p, .font = &sh.font };
        drawing.paintBoard(&c, sh.status.board_model.drawing(), .{ .x = 0, .y = 0, .w = n.size.w, .h = n.size.h }, sh.status.*, .{
            .theme = &theme,
            .font = &sh.font,
            .hovered = n.state(State).hovered,
            .cpu_selected = temperatureOpen(n),
            .cpu_temperature_c = sh.board.effectiveCpuTemperature(sh.status.*),
            .sd_card_name = if (sh.board.hasActiveSdCard()) sh.board.activeSdCardName() else null,
        });
    }

    fn targetAt(self: *const BoardDiagram, n: *const WidgetNode, pos: Point) ?InteractiveTarget {
        const d = self.shell.status.board_model.drawing();
        const tr = drawing.boardTransform(d, .{ .x = 0, .y = 0, .w = n.size.w, .h = n.size.h });
        return drawing.targetAt(d, .{ (pos[0] - tr.x) / tr.scale, (pos[1] - tr.y) / tr.scale }, self.shell.status.sd_connected);
    }

    pub fn cursor(self: *const BoardDiagram, n: *WidgetNode, pos: Point) ?kete.PointerCursor {
        return if (self.targetAt(n, pos) != null) .pointer else .default;
    }

    pub fn event(self: *const BoardDiagram, n: *WidgetNode, e: kete.Event) bool {
        switch (e) {
            .motion => |pos| self.hover(n, self.targetAt(n, pos)),
            .leave => self.hover(n, null),
            .press => |pr| return pr.button == .left and self.targetAt(n, pr.pos) != null,
            .release => |r| {
                if (r.button != .left or !r.inside) return true;
                const target = self.targetAt(n, r.pos) orelse return true;
                self.press(n, target, r.pos);
                n.ui.needs_frame = true;
                return true;
            },
            else => return false,
        }
        return true;
    }

    fn hover(_: *const BoardDiagram, n: *WidgetNode, target: ?InteractiveTarget) void {
        const st = n.state(State);
        if (st.hovered == target) return;
        st.hovered = target;
        n.ui.needs_frame = true;
    }

    fn press(self: *const BoardDiagram, n: *WidgetNode, target: InteractiveTarget, pos: Point) void {
        const sh = self.shell;
        const at = n.position();
        const where: Point = .{ at[0] + pos[0], at[1] + pos[1] };
        switch (target) {
            // Without a card image there is nothing to put in: like the
            // card, the slot then offers the images (or to make one).
            .sd_connector, .sd_card => {
                if (sh.status.sd_connected or (target == .sd_connector and sh.board.hasActiveSdCard())) return sh.toggleSd();
                if (sh.board.sd_cards.items.len == 0) return sh.openSdManager();
                openCardMenu(n, sh, where);
            },
            .cpu => n.ui.openPopup(n, where, .of(sh, temperaturePopup)),
            else => sh.toggle(target),
        }
    }

    /// Whether the CPU's temperature popup (opened from `n`) is open.
    fn temperatureOpen(n: *const WidgetNode) bool {
        const m = n.ui.menu orelse return false;
        return m.owner == n and m.content == .popup;
    }
};

/// The card images to put in the slot, and the dialog to manage them.
fn openCardMenu(n: *WidgetNode, sh: *Shell, at: Point) void {
    const b = sh.board;
    const count = @min(b.sd_cards.items.len, Shell.max_cards);
    var items: [Shell.max_cards + 2]kete.MenuItem = undefined;
    var labels: [Shell.max_cards][96]u8 = undefined;
    for (b.sd_cards.items[0..count], 0..) |*card, i| {
        sh.card_actions[i] = .{ .shell = sh, .idx = i };
        items[i] = .{
            .label = std.fmt.bufPrint(&labels[i], "{s} ({s})", .{ card.name(), card.size.label() }) catch card.name(),
            .kind = .radio,
            .checked = b.selected_sd_card_idx == i,
            .on_press = .of(&sh.card_actions[i], CardAction.select),
        };
    }
    items[count] = .divider;
    items[count + 1] = .{ .label = "Manage Cards…", .on_press = .of(sh, Shell.openSdManager) };
    // The menu copies the items, and their labels.
    n.ui.openMenu(n, at, items[0 .. count + 2]);
}

/// The CPU's temperature, to set (as the guest reads it).
fn temperaturePopup(sh: *Shell, cx: *BuildContext) Widget {
    const t = cx.theme();
    const temp = sh.board.effectiveCpuTemperature(sh.status.*);
    const small: kete.TextStyle = .{ .size = 11, .color = t.on_surface_variant };
    return cx.make(kete.RoundedBox{
        .color = t.surface_container_highest,
        .border_color = t.outline_variant,
        .radius = .all(12),
        .child = cx.make(kete.Padding{ .padding = .all(12), .child = cx.make(kete.SizedBox{ .width = 260, .child = cx.make(kete.Column{
            .fill = false,
            .cross_axis_alignment = .stretch,
            .spacing = 4,
            .children = cx.makeAll(.{
                kete.Row{ .spacing = 8, .children = cx.makeAll(.{
                    kete.Icon{ .icon = .thermostat, .size = 16, .color = t.primary },
                    kete.Expanded{ .child = cx.make(kete.Text{ .text = "CPU Temperature", .style = .{ .size = 13, .color = t.on_surface } }) },
                    kete.Text{ .text = cx.fmt("{d}°C", .{temp}), .style = .{ .size = 13.5, .color = t.primary } },
                }) },
                kete.Slider{ .value = @floatFromInt(temp), .min = 0, .max = 100, .divisions = 100, .on_changed = .of(sh, Shell.setCpuTemperature) },
                kete.Row{ .main_axis_alignment = .space_between, .children = cx.makeAll(.{
                    kete.Text{ .text = "0°C", .style = small },
                    kete.Text{ .text = "100°C", .style = small },
                }) },
            }),
        }) }) }),
    });
}

/// The board's settings: which board it is, its identity (set while it is
/// off), its Wi-Fi network, and whether the network gives out addresses.
fn settingsPanel(cx: *BuildContext, sh: *Shell) Widget {
    const t = cx.theme();
    const st = sh.status;
    const b = sh.board;
    const powered = st.power_connected;
    const model = st.board_model;
    var rows: [9]Widget = undefined;
    var n: usize = 0;

    rows[n] = cx.make(kete.Text{
        .text = "Power down the board to set its model, serial number and MAC addresses",
        .style = .{ .size = 12.5, .color = t.on_surface_variant },
    });
    n += 1;
    rows[n] = cx.make(kete.HorizontalDivider{});
    n += 1;

    var board_options: [BoardModel.all.len]kete.MenuItem = undefined;
    var board_idx: usize = 0;
    for (BoardModel.all, 0..) |bm, i| {
        board_options[i] = .{ .label = bm.windowTitle() };
        if (bm == model) board_idx = i;
    }
    rows[n] = settingRow(cx, "Board", "Hardware model", powered, cx.make(kete.DropdownMenu{
        .options = &board_options,
        .selected = board_idx,
        .on_selected = if (powered) null else .of(sh, Shell.selectBoard),
        .width = field_width,
    }));
    n += 1;

    rows[n] = settingRow(cx, "Serial Number", "64-bit hex board ID", powered, cx.make(kete.TextField{
        .initial = b.serialText(),
        .max_len = 16,
        .width = field_width,
        .enabled = !powered,
        .on_changed = .of(sh, Shell.setSerial),
    }).withKey(fieldKey(1, b.identity_gen)));
    n += 1;

    var mac_buf: [17]u8 = undefined;
    const external = model.usesExternalUsbHub();
    rows[n] = settingRow(
        cx,
        if (external) "USB Ethernet MAC" else "Ethernet MAC",
        if (external) "External Ethernet hardware address" else "On-board Ethernet hardware address",
        powered,
        cx.make(kete.TextField{
            .initial = cx.fmt("{s}", .{b.macText(&mac_buf)}),
            .max_len = 17,
            .width = field_width,
            .enabled = !powered,
            .on_changed = .of(sh, Shell.setMac),
        }).withKey(fieldKey(2, b.identity_gen)),
    );
    n += 1;

    if (model.hasWireless()) {
        var wifi_buf: [17]u8 = undefined;
        rows[n] = settingRow(cx, "Wireless MAC", "On-board Wi-Fi hardware address", powered, cx.make(kete.TextField{
            .initial = cx.fmt("{s}", .{b.wifiMacText(&wifi_buf)}),
            .max_len = 17,
            .width = field_width,
            .enabled = !powered,
            .on_changed = .of(sh, Shell.setWifiMac),
        }).withKey(fieldKey(3, b.identity_gen)));
        n += 1;

        // The emulated access point (editable while the board runs)
        const open = b.wifi_security == .open;
        const invalid = !open and !board_state.isValidWifiPassword(b.wifiPassword());
        var host_buf: [64]u8 = undefined;
        const host = host_posix.hostName(&host_buf);
        var security_options: [WifiSecurity.all.len]kete.MenuItem = undefined;
        var security_idx: usize = 0;
        for (WifiSecurity.all, 0..) |sec, i| {
            security_options[i] = .{ .label = sec.label() };
            if (sec == b.wifi_security) security_idx = i;
        }
        rows[n] = cx.make(kete.Row{ .spacing = 16, .children = cx.makeAll(.{
            kete.Expanded{ .child = settingLabel(
                cx,
                "Wi-Fi Security",
                if (invalid) "Password needs 8 to 63 characters" else cx.fmt("Emulated network \u{201c}{s}\u{201d}", .{if (host.len != 0) host else "FauxPi"}),
                false,
                invalid,
            ) },
            kete.DropdownMenu{
                .options = &security_options,
                .selected = security_idx,
                .on_selected = .of(sh, Shell.setWifiSecurity),
                .width = 160,
            },
            cx.make(kete.TextField{
                .initial = b.wifiPassword(),
                .placeholder = "Password",
                .max_len = 63,
                .width = field_width,
                .enabled = !open,
                .on_changed = .of(sh, Shell.setWifiPassword),
            }).withKey(fieldKey(4, b.identity_gen)),
        }) });
        n += 1;
    }

    rows[n] = settingRow(
        cx,
        "DHCP Server",
        if (model.hasWireless())
            "Leases 10.0.2.15/24 (Ethernet), 10.0.3.15/24 (Wi-Fi) · Gateway & DNS .2"
        else
            "Lease 10.0.2.15/24 · Gateway & DNS 10.0.2.2",
        false,
        cx.make(kete.Switch{ .value = st.dhcp_enabled, .on_changed = .of(sh, Shell.setDhcp) }),
    );
    n += 1;

    // Which FauxPi this is
    rows[n] = cx.make(kete.Text{
        .text = cx.fmt("FauxPi {s} \u{00b7} {s}", .{ build_info.version, build_info.commit }),
        .style = .{ .size = 11, .color = t.on_surface_variant.withAlpha(0.7) },
        .text_align = .center,
    });
    n += 1;

    return cx.make(kete.RoundedBox{
        .color = t.surface_container,
        .border_color = t.outline_variant,
        .radius = .all(12),
        .child = cx.make(kete.Padding{
            .padding = .all(16),
            .child = cx.make(kete.Column{ .fill = false, .cross_axis_alignment = .stretch, .spacing = 12, .children = rows[0..n] }),
        }),
    });
}

/// The width of the settings' fields and menus.
const field_width = 228;

/// A key for a field that starts again (showing what it is set to) when
/// `gen` changes.
fn fieldKey(field: u32, gen: u32) u64 {
    return @as(u64, field) << 32 | gen;
}

/// A setting: its name and what it is, and the control that sets it.
fn settingRow(cx: *BuildContext, title: []const u8, subtitle: []const u8, dimmed: bool, control: Widget) Widget {
    return cx.make(kete.Row{ .spacing = 16, .children = cx.makeAll(.{
        kete.Expanded{ .child = settingLabel(cx, title, subtitle, dimmed, false) },
        control,
    }) });
}

fn settingLabel(cx: *BuildContext, title: []const u8, subtitle: []const u8, dimmed: bool, warn: bool) Widget {
    const t = cx.theme();
    const a: f32 = if (dimmed) 0.42 else 1;
    return cx.make(kete.Column{ .fill = false, .cross_axis_alignment = .start, .spacing = 2, .children = cx.makeAll(.{
        kete.Text{ .text = title, .style = .{ .size = 14, .color = t.on_surface.withAlpha(a) } },
        kete.Text{ .text = subtitle, .style = .{ .size = 11.5, .color = if (warn) t.@"error" else t.on_surface_variant.withAlpha(a) } },
    }) });
}

/// The Manage SD Cards dialog: the card images (to pick, rename or delete),
/// or the form that makes one.
fn sdDialog(cx: *BuildContext, sh: *Shell, under: Widget) Widget {
    const b = sh.board;
    if (b.isSdCreateView()) {
        return cx.make(kete.Dialog{
            .title = "Create SD Card",
            .content = createCardForm(cx, sh),
            .confirm_label = if (b.isCreatingSdCard()) "Creating…" else "Create Card",
            .on_confirm = if (sh.canCreateCard()) .of(sh, Shell.createCard) else null,
            .dismiss_label = "Cancel",
            .on_dismiss = .of(sh, Shell.cancelCreateCard),
            .width = 480,
            .child = under,
        });
    }
    return cx.make(kete.Dialog{
        .title = "Manage SD Cards",
        .content = cardList(cx, sh),
        .confirm_label = "Done",
        .on_confirm = .of(sh, Shell.closeSdManager),
        .on_dismiss = .of(sh, Shell.closeSdManager),
        .width = 480,
        .child = under,
    });
}

fn cardList(cx: *BuildContext, sh: *Shell) Widget {
    const b = sh.board;
    const count = @min(b.sd_cards.items.len, Shell.max_cards);
    const rows = cx.arena.alloc(Widget, count + 1) catch return cx.make(kete.SizedBox{});
    for (b.sd_cards.items[0..count], 0..) |*card, i| {
        sh.card_actions[i] = .{ .shell = sh, .idx = i };
        const action = &sh.card_actions[i];
        if (b.renaming_sd_card_idx == i) {
            rows[i] = cx.make(kete.Row{ .spacing = 8, .children = cx.makeAll(.{
                kete.Expanded{ .child = cx.make(kete.TextField{
                    .initial = b.renameCardName(),
                    .max_len = 64,
                    .width = 360,
                    .autofocus = true,
                    .on_changed = .of(sh, Shell.setRenameName),
                    .on_submit = .of(sh, Shell.commitRename),
                }) },
                kete.IconButton{ .icon = .check, .on_press = .of(action, CardAction.rename) },
            }) }).withKey(i);
            continue;
        }
        var size_buf: [32]u8 = undefined;
        rows[i] = cx.make(kete.ListItem{
            .headline = card.name(),
            .supporting_text = cx.fmt("{s}  ·  {s} on disk", .{ card.size.label(), board_state.formatByteSize(&size_buf, card.disk.diskAllocatedBytes()) }),
            .selected = b.selected_sd_card_idx == i,
            .on_press = .of(action, CardAction.select),
            .trailing = cx.make(kete.Row{ .fill = false, .children = cx.makeAll(.{
                kete.IconButton{ .icon = .edit, .on_press = .of(action, CardAction.rename) },
                kete.IconButton{ .icon = .delete, .on_press = .of(action, CardAction.delete) },
            }) }),
        }).withKey(i);
    }
    rows[count] = cx.make(kete.Padding{ .padding = .{ .top = 8 }, .child = cx.make(kete.Align{
        .alignment = .center_left,
        .height_factor = 1,
        .child = cx.make(kete.OutlinedButton{ .label = "New Card…", .icon = .add, .on_press = .of(sh, Shell.showCreateCard) }),
    }) });
    return cx.make(kete.Column{ .fill = false, .cross_axis_alignment = .stretch, .spacing = 4, .children = rows });
}

fn createCardForm(cx: *BuildContext, sh: *Shell) Widget {
    const b = sh.board;
    const t = cx.theme();
    const creating = b.isCreatingSdCard();
    const label: kete.TextStyle = .{ .size = 12.5, .color = t.on_surface_variant };
    var rows: [9]Widget = undefined;
    var n: usize = 0;

    rows[n] = cx.make(kete.Text{ .text = "Card name", .style = label });
    n += 1;
    rows[n] = cx.make(kete.TextField{
        .initial = b.newCardName(),
        .max_len = 64,
        .width = 432,
        .enabled = !creating,
        .on_changed = .of(sh, Shell.setNewCardName),
    }).withKey(fieldKey(5, b.new_card_name_gen));
    n += 1;

    var size_options: [SdCardSize.all.len]kete.MenuItem = undefined;
    var size_idx: usize = 0;
    for (SdCardSize.all, 0..) |sz, i| {
        size_options[i] = .{ .label = sz.label() };
        if (sz == b.new_card_size) size_idx = i;
    }
    rows[n] = cx.make(kete.Text{ .text = "Card size", .style = label });
    n += 1;
    rows[n] = cx.make(kete.Align{ .alignment = .center_left, .height_factor = 1, .child = cx.make(kete.DropdownMenu{
        .options = &size_options,
        .selected = size_idx,
        .on_selected = if (creating) null else .of(sh, Shell.setNewCardSize),
        .width = 160,
    }) });
    n += 1;

    rows[n] = cx.make(kete.Text{ .text = "OS image file", .style = label });
    n += 1;
    const image: []const u8 = if (b.pending_sd_image_path_len > 0) blk: {
        var size_buf: [32]u8 = undefined;
        const base = std.fs.path.basename(b.pending_sd_image_path_buf[0..b.pending_sd_image_path_len]);
        break :blk cx.fmt("{s} ({s})", .{ base, board_state.formatByteSize(&size_buf, b.pending_sd_image_size) });
    } else "No image file chosen";
    rows[n] = cx.make(kete.Row{ .spacing = 8, .children = cx.makeAll(.{
        kete.Expanded{ .child = cx.make(kete.Text{
            .text = image,
            .style = .{ .size = 13.5, .color = if (b.pending_sd_image_path_len > 0) t.on_surface else t.on_surface_variant },
            .wrap = false,
            .ellipsis = true,
        }) },
        kete.OutlinedButton{ .label = "Choose Image…", .on_press = if (creating) null else .of(sh, Shell.chooseImage) },
    }) });
    n += 1;

    if (b.sd_error_len > 0) {
        rows[n] = cx.make(kete.Text{ .text = b.sdErrorMessage(), .style = .{ .size = 12, .color = t.@"error" } });
        n += 1;
    }
    if (b.sdCreationProgress()) |done| {
        rows[n] = cx.make(kete.ProgressBar{ .value = done });
        n += 1;
        rows[n] = cx.make(kete.Text{
            .text = cx.fmt("Creating SD card image… {d}%", .{@as(u32, @intFromFloat(done * 100))}),
            .style = label,
        });
        n += 1;
    }
    return cx.make(kete.Column{ .fill = false, .cross_axis_alignment = .stretch, .spacing = 6, .children = rows[0..n] });
}

/// Below the display, while the GPIO ribbon cable is in: an LED for each
/// header pin the guest drives, and a switch for each it reads.
const GpioPanel = struct {
    shell: *Shell,

    pub const State = struct {
        hovered: ?usize = null,
    };

    /// The header's pins set as outputs and as inputs, by their number on
    /// the header (1 to 40).
    const Pins = struct {
        outputs: [28]Pin = undefined,
        output_count: usize = 0,
        inputs: [28]Pin = undefined,
        input_count: usize = 0,
    };

    const Pin = struct {
        /// The pin's number on the 40-pin header.
        header_pin: u8,
        /// Its Broadcom GPIO line (0..27).
        bcm: u6,
    };

    fn pins(gpio: *const Gpio) Pins {
        var out: Pins = .{};
        for (gpio_model.header_40, 0..) |entry, idx| {
            switch (entry) {
                .gpio => |bcm| {
                    if (bcm >= 28) continue;
                    const pin: Pin = .{ .header_pin = @intCast(idx + 1), .bcm = @intCast(bcm) };
                    switch (gpio.getPinFunction(bcm)) {
                        .output => {
                            out.outputs[out.output_count] = pin;
                            out.output_count += 1;
                        },
                        .input => {
                            out.inputs[out.input_count] = pin;
                            out.input_count += 1;
                        },
                        else => {},
                    }
                },
                .power_3v3, .power_5v, .ground => {},
            }
        }
        return out;
    }

    /// Where item `idx` of a row of `count` is (the LEDs' row at the top,
    /// the switches' below), in a panel `w` wide.
    fn cell(w: f32, idx: usize, count: usize, y: f32, h: f32) Rect {
        const avail_w = @max(280.0, w - 112.0 - 20.0);
        const pitch: f32 = @min(40.0, @floor(avail_w / @as(f32, @floatFromInt(@max(count, 28)))));
        return .{ .x = 112.0 + @as(f32, @floatFromInt(idx)) * pitch, .y = y, .w = pitch - 2.0, .h = h };
    }

    fn ledCell(w: f32, idx: usize, count: usize) Rect {
        return cell(w, idx, count, 10.0, 46.0);
    }

    fn switchCell(w: f32, idx: usize, count: usize) Rect {
        return cell(w, idx, count, 68.0, 58.0);
    }

    fn switchAt(self: *const GpioPanel, n: *const WidgetNode, pos: Point) ?usize {
        const p = pins(self.shell.gpio);
        for (0..p.input_count) |i| {
            if (switchCell(n.size.w, i, p.input_count).contains(pos)) return i;
        }
        return null;
    }

    pub fn paint(self: *const GpioPanel, n: *WidgetNode, p: *kete.Painter) void {
        const sh = self.shell;
        const gpio = sh.gpio;
        const t = Theme.fromKete(n.theme());
        var c: Canvas = .{ .painter = p, .font = &sh.font };
        const w = n.size.w;
        const h = n.size.h;
        const hovered = n.state(State).hovered;
        const list = pins(gpio);

        c.fillRect(.{ .x = 0, .y = 0, .w = w, .h = h }, t.surface_container);
        c.fillRect(.{ .x = 0, .y = 0, .w = w, .h = 1.0 }, t.outline_variant);
        const card_r: Rect = .{ .x = 12.0, .y = 8.0, .w = w - 24.0, .h = h - 16.0 };
        c.fillRoundedRect(card_r, .all(10.0), t.surface);
        c.strokeRoundedRect(card_r, .all(10.0), 1.0, t.outline_variant);
        // Between the outputs and the inputs
        c.fillRect(.{ .x = card_r.x + 12.0, .y = 60.0, .w = card_r.w - 24.0, .h = 1.0 }, t.outline_variant.withAlpha(0.6));
        const num_st: canvas_mod.Style = .{ .font = &sh.font, .size = 11.0 };

        // The outputs: an LED for each, lit while the guest drives it high
        _ = c.drawText(13.0, 24.0, 32.0, "Outputs", t.on_surface);
        _ = c.drawText(11.0, 24.0, 47.0, "GPIO LEDs", t.on_surface_variant);
        if (list.output_count == 0) {
            _ = c.drawText(12.5, 116.0, 39.0, "No pins configured as outputs", t.on_surface_variant);
        }
        for (list.outputs[0..list.output_count], 0..) |pin, idx| {
            const r = ledCell(w, idx, list.output_count);
            const cx = @round(r.x + r.w * 0.5);
            const cy = @round(r.y + 15.0);
            const high = gpio.getPinLevel(pin.bcm);
            if (high) {
                const led: Color = .rgb(0x22E55E);
                c.fillCircle(.{ cx, cy }, 9.5, led.withAlpha(0.28));
                c.fillCircle(.{ cx, cy }, 6.5, led);
                c.fillCircle(.{ cx - 1.8, cy - 1.8 }, 2.0, Color.rgb(0xC8FFDA));
                c.strokeCircle(.{ cx, cy }, 6.5, 1.0, Color.rgb(0x16A34A));
            } else {
                c.fillCircle(.{ cx, cy }, 6.5, t.surface_container_highest);
                c.strokeCircle(.{ cx, cy }, 6.5, 1.2, t.outline);
            }
            var buf: [8]u8 = undefined;
            const label = std.fmt.bufPrint(&buf, "{d}", .{pin.header_pin}) catch "";
            _ = c.drawText(11.0, @round(cx - c.measureText(11.0, label) * 0.5), @round(r.y + 32.0 + num_st.ascent()), label, if (high) t.on_surface else t.on_surface_variant);
        }

        // The inputs: a switch for each, which sets the pin's level
        _ = c.drawText(13.0, 24.0, 93.0, "Inputs", t.on_surface);
        _ = c.drawText(11.0, 24.0, 108.0, "GPIO Switches", t.on_surface_variant);
        if (list.input_count == 0) {
            _ = c.drawText(12.5, 116.0, 100.0, "No pins configured as inputs", t.on_surface_variant);
        }
        for (list.inputs[0..list.input_count], 0..) |pin, idx| {
            const r = switchCell(w, idx, list.input_count);
            const cx = @round(r.x + r.w * 0.5);
            const high = gpio.getPinLevel(pin.bcm);
            const hov = hovered == idx;
            const sw: Rect = .{ .x = @round(cx - 8.0), .y = @round(r.y + 3.0), .w = 16.0, .h = 30.0 };
            c.fillRoundedRect(sw, .all(8.0), if (high) t.primary else t.surface_container_highest);
            c.strokeRoundedRect(sw, .all(8.0), if (hov) 1.5 else 1.1, if (hov) t.on_surface else if (high) t.primary else t.outline);
            c.fillCircle(.{ cx, if (high) sw.y + 8.0 else sw.y + sw.h - 8.0 }, 5.5, if (high) t.on_primary else t.on_surface_variant);
            var buf: [8]u8 = undefined;
            const label = std.fmt.bufPrint(&buf, "{d}", .{pin.header_pin}) catch "";
            _ = c.drawText(11.0, @round(cx - c.measureText(11.0, label) * 0.5), @round(r.y + 38.0 + num_st.ascent()), label, if (high or hov) t.on_surface else t.on_surface_variant);
        }
    }

    pub fn cursor(self: *const GpioPanel, n: *WidgetNode, pos: Point) ?kete.PointerCursor {
        return if (self.switchAt(n, pos) != null) .pointer else .default;
    }

    pub fn event(self: *const GpioPanel, n: *WidgetNode, e: kete.Event) bool {
        const st = n.state(State);
        switch (e) {
            .motion => |pos| {
                const at = self.switchAt(n, pos);
                if (at != st.hovered) {
                    st.hovered = at;
                    n.ui.needs_frame = true;
                }
            },
            .leave => if (st.hovered != null) {
                st.hovered = null;
                n.ui.needs_frame = true;
            },
            .press => |pr| return pr.button == .left and self.switchAt(n, pr.pos) != null,
            .release => |r| {
                if (r.button != .left or !r.inside) return true;
                const idx = self.switchAt(n, r.pos) orelse return true;
                const gpio = self.shell.gpio;
                const bcm = pins(gpio).inputs[idx].bcm;
                gpio.setExternalPin(bcm, !gpio.getPinLevel(bcm));
                n.ui.needs_frame = true;
            },
            else => return false,
        }
        return true;
    }
};

const testing = std.testing;

/// The window's widgets, in a UI of their own (drawn on the CPU), for tests.
const TestWindow = struct {
    board: BoardState,
    status: SystemStatus = .{ .board_model = .pi_zero },
    gpio: Gpio = .{},
    shell: Shell = undefined,
    ui: *kete.ui.WindowUi = undefined,
    width: u32 = 1280,
    height: u32 = 764,

    fn create(width: u32, height: u32) !*TestWindow {
        const tw = try testing.allocator.create(TestWindow);
        errdefer testing.allocator.destroy(tw);
        tw.* = .{ .board = try BoardState.init(testing.allocator), .width = width, .height = height };
        tw.shell = try .init(&tw.board, &tw.status, &tw.gpio, .{ .width = 1280, .height = 720 });
        tw.ui = try kete.ui.WindowUi.createDefault(testing.allocator, testing.io);
        tw.ui.attachRenderer(tw.ui.shared.software_renderer.renderer(), false);
        tw.frame();
        return tw;
    }

    fn destroy(tw: *TestWindow) void {
        tw.ui.destroy();
        tw.board.deinit();
        testing.allocator.destroy(tw);
    }

    /// Builds, lays out and paints the window (twice: what the first frame
    /// learns, such as whether the sheet stays above the display, the second
    /// shows).
    fn frame(tw: *TestWindow) void {
        for (0..2) |_| tw.ui.frame(tw.width, tw.height, 0, Root{ .shell = &tw.shell });
    }

    /// The window as drawn, `width` by `height` (to free).
    fn pixels(tw: *TestWindow) ![]u32 {
        const px = try testing.allocator.alloc(u32, tw.width * tw.height);
        @memset(px, 0xff000000);
        try tw.ui.preview(.{ .pixels = px, .width = tw.width, .height = tw.height });
        return px;
    }

    fn click(tw: *TestWindow, p: Point) void {
        tw.ui.pointerMotion(p);
        tw.ui.pointerButton(p, .left, true);
        tw.ui.pointerButton(p, .left, false);
        tw.frame();
    }

    /// The first node (depth first) of a `T`.
    fn find(tw: *TestWindow, comptime T: type) ?*WidgetNode {
        return findIn(tw.ui.root orelse return null, T);
    }

    fn findIn(n: *WidgetNode, comptime T: type) ?*WidgetNode {
        if (n.widget.is(T)) return n;
        for (n.children.items) |ch| if (findIn(ch, T)) |f| return f;
        return null;
    }

    /// The middle of node `n`, in the window.
    fn centre(n: *const WidgetNode) Point {
        const at = n.position();
        return .{ at[0] + n.size.w / 2, at[1] + n.size.h / 2 };
    }

    /// Where `target` is on the board's drawing, in the window.
    fn targetPoint(tw: *TestWindow, target: InteractiveTarget) ?Point {
        const n = tw.find(BoardDiagram) orelse return null;
        const at = n.position();
        var y: f32 = 0;
        while (y < n.size.h) : (y += 1) {
            var x: f32 = 0;
            while (x < n.size.w) : (x += 1) {
                const d: BoardDiagram = .{ .shell = &tw.shell };
                if (d.targetAt(n, .{ x, y }) == target) return .{ at[0] + x, at[1] + y };
            }
        }
        return null;
    }
};

fn findAll(n: *WidgetNode, comptime T: type, out: *std.ArrayList(*WidgetNode)) !void {
    if (n.widget.is(T)) try out.append(testing.allocator, n);
    for (n.children.items) |ch| try findAll(ch, T, out);
}

/// Types `text` into what has the keyboard.
fn typeText(tw: *TestWindow, text: []const u8) void {
    for (text) |ch| {
        tw.ui.key(.{ .key = .a, .pressed = true, .char = ch });
        tw.ui.key(.{ .key = .a, .pressed = false });
    }
    tw.frame();
}

fn pressKey(tw: *TestWindow, key: kete.KeyboardKey, times: usize) void {
    for (0..times) |_| {
        tw.ui.key(.{ .key = key, .pressed = true });
        tw.ui.key(.{ .key = key, .pressed = false });
    }
    tw.frame();
}

test "the sheet stays above the display when there is room, or else covers it until closed" {
    // Tall: the board above the display, with no button to hide it.
    const tall = try TestWindow.create(1280, 1100);
    defer tall.destroy();
    try testing.expect(tall.shell.sheet_docked);
    try testing.expect(!tall.shell.sheetCovers());
    try testing.expect(tall.find(kete.IconButton) == null);
    try testing.expect(tall.find(Scrim) == null);
    const sheet = tall.find(Sheet).?;
    const display = tall.find(DisplayArea).?;
    try testing.expect(display.position()[1] >= sheet.position()[1] + sheet.size.h);
    try testing.expectEqual(@as(f32, 720), tall.shell.display_rect.h);

    // As tall as the display: the sheet covers it, until the title bar's
    // button, or a press on the display beside it, closes it.
    const tw = try TestWindow.create(1280, 764);
    defer tw.destroy();
    try testing.expect(!tw.shell.sheet_docked);
    try testing.expect(tw.shell.sheetCovers());
    const button = tw.find(kete.IconButton).?;
    tw.click(TestWindow.centre(button));
    try testing.expect(!tw.shell.sheet_open);
    try testing.expect(tw.find(Sheet) == null);
    tw.click(TestWindow.centre(tw.find(kete.IconButton).?));
    try testing.expect(tw.shell.sheet_open);
    tw.click(.{ 20, 600 });
    try testing.expect(!tw.shell.sheet_open);

    // Escape closes it too, and keys don't reach the guest under it.
    tw.click(TestWindow.centre(tw.find(kete.IconButton).?));
    try testing.expect(tw.ui.focused == tw.find(Keyboard).?);
    pressKey(tw, .escape, 1);
    try testing.expect(!tw.shell.sheet_open);
}

test "pressing what is plugged into the board pulls it out, or plugs it in" {
    const tw = try TestWindow.create(1280, 1100);
    defer tw.destroy();
    const st = &tw.status;
    try testing.expect(st.hdmi_connected and st.usb_keyboard_connected and st.usb_mouse_connected and st.ethernet_connected);

    tw.click(tw.targetPoint(.hdmi).?);
    try testing.expect(!st.hdmi_connected);
    try testing.expect(tw.gpio.getPinLevel(46));
    tw.click(tw.targetPoint(.usb_keyboard).?);
    try testing.expect(!st.usb_keyboard_connected);
    tw.click(tw.targetPoint(.usb_mouse).?);
    try testing.expect(!st.usb_mouse_connected);
    tw.click(tw.targetPoint(.ethernet).?);
    try testing.expect(!st.ethernet_connected);
    tw.click(tw.targetPoint(.usb_hub).?);
    try testing.expect(!st.usb_hub_connected);
    try testing.expect(tw.shell.events.save);

    tw.click(tw.targetPoint(.power).?);
    try testing.expect(st.power_connected);
    try testing.expect(tw.shell.events.power_on);

    // The GPIO cable brings its panel, below the display.
    tw.click(tw.targetPoint(.gpio).?);
    try testing.expect(st.gpio_connected);
    try testing.expect(tw.shell.events.gpio_toggled);
    const panel = tw.find(GpioPanel).?;
    try testing.expectEqual(@as(f32, gpio_panel_height), panel.size.h);
    try testing.expectEqual(@as(f32, @floatFromInt(tw.height - gpio_panel_height)), panel.position()[1]);
}

test "the SD card slot offers to make a card, then the cards made" {
    const tw = try TestWindow.create(1280, 1100);
    defer tw.destroy();

    // With no card images, the card (or the slot) offers to make one.
    tw.click(tw.targetPoint(.sd_connector).?);
    try testing.expect(tw.board.sd_manage_open);
    try testing.expect(tw.board.isSdCreateView());
    try testing.expect(tw.find(kete.Dialog) != null);
    // Nothing to make it from yet.
    try testing.expect(!tw.shell.canCreateCard());

    // Choosing the image is the window's (a file chooser).
    var choose: std.ArrayList(*WidgetNode) = .empty;
    defer choose.deinit(testing.allocator);
    try findAll(tw.ui.root.?, kete.OutlinedButton, &choose);
    tw.click(TestWindow.centre(choose.items[choose.items.len - 1]));
    try testing.expect(tw.shell.events.pick_image);

    // An image in memory is made into a card at once.
    var img: [512]u8 = @splat(0);
    img[510] = 0x55;
    img[511] = 0xAA;
    tw.board.setPendingSdImageSlice("test.img", &img);
    tw.frame();
    try testing.expect(tw.shell.canCreateCard());
    tw.shell.createCard();
    tw.frame();
    try testing.expect(!tw.board.sd_manage_open);
    try testing.expectEqualStrings("Card 1", tw.board.activeSdCardName());
    try testing.expect(tw.shell.events.sd_chosen);

    // Now pressing the slot puts the card in, and the card takes it out.
    tw.click(tw.targetPoint(.sd_connector).?);
    try testing.expect(tw.status.sd_connected);
    try testing.expect(tw.shell.events.sd_in);
    tw.click(tw.targetPoint(.sd_card).?);
    try testing.expect(!tw.status.sd_connected);

    // Out of the slot, the card offers the cards in a menu.
    tw.click(tw.targetPoint(.sd_card).?);
    try testing.expect(tw.ui.menu != null);
    try testing.expect(tw.ui.menu.?.content == .items);
}

test "the settings set which board it is, its identity while it's off, and its network" {
    // Tall enough for all of them above the display.
    const tw = try TestWindow.create(1280, 1700);
    defer tw.destroy();
    tw.click(TestWindow.centre(tw.find(kete.OutlinedButton).?));
    try testing.expect(tw.shell.settings_open);

    // The serial number, typed (keeping only hex digits).
    var fields: std.ArrayList(*WidgetNode) = .empty;
    defer fields.deinit(testing.allocator);
    try findAll(tw.ui.root.?, kete.TextField, &fields);
    try testing.expectEqual(@as(usize, 2), fields.items.len);
    tw.click(TestWindow.centre(fields.items[0]));
    pressKey(tw, .end, 1);
    pressKey(tw, .backspace, 16);
    typeText(tw, "12x34");
    try testing.expectEqualStrings("1234", tw.board.serialText());
    try testing.expectEqual(@as(u64, 0x1234), tw.status.serial_u64);
    try testing.expect(tw.shell.events.save);

    // Another board: a new identity, and its own settings (Wi-Fi).
    const serial = tw.status.serial_u64;
    tw.shell.selectBoard(std.mem.indexOfScalar(BoardModel, &BoardModel.all, .pi_zero_w).?);
    tw.frame();
    try testing.expectEqual(BoardModel.pi_zero_w, tw.status.board_model);
    try testing.expect(tw.shell.events.board_changed);
    try testing.expect(tw.status.serial_u64 != serial);
    fields.clearRetainingCapacity();
    try findAll(tw.ui.root.?, kete.TextField, &fields);
    try testing.expectEqual(@as(usize, 4), fields.items.len);

    // While it runs, its identity can't change; the network's can.
    tw.status.power_connected = true;
    tw.frame();
    fields.clearRetainingCapacity();
    try findAll(tw.ui.root.?, kete.TextField, &fields);
    try testing.expect(!fields.items[0].widget.as(kete.TextField).?.enabled);
    const password = fields.items[3];
    try testing.expect(password.widget.as(kete.TextField).?.enabled);
    tw.click(TestWindow.centre(password));
    pressKey(tw, .end, 1);
    pressKey(tw, .backspace, 9);
    typeText(tw, "secret!!");
    try testing.expectEqualStrings("secret!!", tw.board.wifiPassword());

    // DHCP's switch.
    tw.click(TestWindow.centre(tw.find(kete.Switch).?));
    try testing.expect(!tw.status.dhcp_enabled);
}

test "the settings scroll in a sheet that doesn't fit" {
    const tw = try TestWindow.create(1280, 764);
    defer tw.destroy();
    tw.status.board_model = .pi_zero_w;
    tw.shell.settings_open = true;
    tw.frame();
    const sheet = tw.find(Sheet).?;
    const scroll = tw.find(kete.ScrollView).?;
    const st = scroll.state(kete.ScrollView.State);
    try testing.expect(st.content > st.viewport);
    try testing.expectEqual(@as(f32, @floatFromInt(tw.height - title_bar_height)), sheet.size.h);

    // The wheel over it scrolls it, down to the DHCP switch.
    tw.ui.pointerScroll(TestWindow.centre(sheet), 0, 2000);
    tw.frame();
    try testing.expectEqual(st.maxOffset(), st.offset);
    const sw = tw.find(kete.Switch).?;
    try testing.expect(sw.position()[1] + sw.size.h <= sheet.position()[1] + sheet.size.h);
}

test "the CPU's temperature is set in a popup" {
    const tw = try TestWindow.create(1280, 1100);
    defer tw.destroy();
    tw.click(tw.targetPoint(.cpu).?);
    try testing.expect(tw.ui.menu != null);
    try testing.expect(tw.ui.menu.?.content == .popup);
    tw.shell.setCpuTemperature(80.4);
    try testing.expectEqual(@as(u8, 80), tw.status.cpu_temperature_c);
    try testing.expectEqual(@as(u8, 80), tw.board.effectiveCpuTemperature(tw.status));
}

test "the GPIO panel lights the outputs, and its switches set the inputs" {
    const tw = try TestWindow.create(1280, 900);
    defer tw.destroy();
    tw.status.gpio_connected = true;
    // GPIO 5 (header pin 29) an output, driven high
    tw.gpio.write32(0x00, tw.gpio.read32(0x00) | (0b001 << 15));
    tw.gpio.write32(0x1C, 1 << 5);
    tw.frame();
    const panel = tw.find(GpioPanel).?;
    const pins = GpioPanel.pins(&tw.gpio);
    try testing.expectEqual(@as(usize, 1), pins.output_count);
    try testing.expectEqual(@as(u8, 29), pins.outputs[0].header_pin);
    try testing.expectEqual(@as(u8, 7), pins.inputs[2].header_pin);
    try testing.expectEqual(@as(u6, 4), pins.inputs[2].bcm);

    // Header pin 7's switch (GPIO 4) pulls it low.
    try testing.expect(tw.gpio.getPinLevel(4));
    const r = GpioPanel.switchCell(panel.size.w, 2, pins.input_count);
    const at = panel.position();
    tw.click(.{ at[0] + r.x + r.w / 2, at[1] + r.y + r.h / 2 });
    try testing.expect(!tw.gpio.getPinLevel(4));
}

test "a boot error shows at the bottom of the window until dismissed" {
    const tw = try TestWindow.create(1280, 764);
    defer tw.destroy();
    tw.board.showBootErrorSnackbar(error.KernelNotFound);
    tw.frame();
    const bar = tw.find(kete.Snackbar).?;
    _ = bar;
    var buttons: std.ArrayList(*WidgetNode) = .empty;
    defer buttons.deinit(testing.allocator);
    try findAll(tw.ui.root.?, kete.IconButton, &buttons);
    // The snackbar's dismiss button is the last.
    tw.click(TestWindow.centre(buttons.items[buttons.items.len - 1]));
    try testing.expect(!tw.board.hasSnackbar());
}

test "the window is drawn" {
    for ([_][2]u32{ .{ 1280, 1100 }, .{ 1280, 764 }, .{ 400, 300 } }) |size| {
        const tw = try TestWindow.create(size[0], size[1]);
        defer tw.destroy();
        tw.shell.settings_open = true;
        tw.status.gpio_connected = true;
        tw.status.board_model = .pi_3_b_plus;
        tw.board.showBootErrorSnackbar(error.KernelNotFound);
        tw.frame();
        const px = try tw.pixels();
        defer testing.allocator.free(px);
        // The title bar's colour, behind its title.
        const t = tw.ui.theme;
        try testing.expectEqual(Color.fromKete(t.surface_container).toArgb(), px[4 * size[0] + 4]);
    }
}
