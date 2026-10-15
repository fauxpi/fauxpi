//! Native macOS Cocoa (`AppKit`) + `CoreGraphics` window backend for `fauxpi`.
//!
//! Uses `NSWindowStyleMaskFullSizeContentView` with a transparent system titlebar
//! so `BoardUi`'s 44px TitleBar (centered board title and `.developer_board` Board toggle button)
//! integrates natively with macOS's left-side red/yellow/green traffic light controls.

const std = @import("std");
const builtin = @import("builtin");
const host_posix = @import("../host/posix.zig");
const UsbHidComposite = @import("../usb/hid.zig").UsbHidComposite;
const Gpio = @import("../soc/gpio.zig").Gpio;
const board_sheet = @import("../ui/board_sheet.zig");

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn _exit(status: c_int) noreturn;

// Objective-C runtime & CoreGraphics C ABI loaded from macOS system frameworks
const Id = ?*anyopaque;
const Sel = ?*anyopaque;
const Class = ?*anyopaque;

const CocoaApi = struct {
    objc_lib: std.DynLib,
    cg_lib: std.DynLib,
    appkit_lib: std.DynLib,
    quartz_lib: ?std.DynLib,

    objc_getClass: *const fn (name: [*:0]const u8) callconv(.c) Class,
    sel_registerName: *const fn (str: [*:0]const u8) callconv(.c) Sel,
    objc_msgSend_ptr: *const anyopaque,
    objc_allocateClassPair: *const fn (superclass: Class, name: [*:0]const u8, extraBytes: usize) callconv(.c) Class,
    class_addMethod: *const fn (cls: Class, name: Sel, imp: *const anyopaque, types: [*:0]const u8) callconv(.c) bool,
    objc_registerClassPair: *const fn (cls: Class) callconv(.c) void,

    CGColorSpaceCreateDeviceRGB: *const fn () callconv(.c) ?*anyopaque,
    CGColorSpaceRelease: *const fn (cs: ?*anyopaque) callconv(.c) void,
    CGDataProviderCreateWithData: *const fn (
        info: ?*anyopaque,
        data: *const anyopaque,
        size: usize,
        releaseData: ?*const anyopaque,
    ) callconv(.c) ?*anyopaque,
    CGDataProviderRelease: *const fn (provider: ?*anyopaque) callconv(.c) void,
    CGImageCreate: *const fn (
        width: usize,
        height: usize,
        bitsPerComponent: usize,
        bitsPerPixel: usize,
        bytesPerRow: usize,
        space: ?*anyopaque,
        bitmapInfo: u32,
        provider: ?*anyopaque,
        decode: ?*const f64,
        shouldInterpolate: bool,
        intent: i32,
    ) callconv(.c) ?*anyopaque,
    CGImageRelease: *const fn (image: ?*anyopaque) callconv(.c) void,
};

var cocoa_api: ?CocoaApi = null;

fn ensureCocoaLoaded() !*const CocoaApi {
    if (cocoa_api) |*api| return api;

    var objc_lib = try std.DynLib.open("/usr/lib/libobjc.A.dylib");
    errdefer objc_lib.close();

    var cg_lib = try std.DynLib.open("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics");
    errdefer cg_lib.close();

    var appkit_lib = try std.DynLib.open("/System/Library/Frameworks/AppKit.framework/AppKit");
    errdefer appkit_lib.close();

    const quartz_lib = std.DynLib.open("/System/Library/Frameworks/QuartzCore.framework/QuartzCore") catch null;

    cocoa_api = .{
        .objc_lib = objc_lib,
        .cg_lib = cg_lib,
        .appkit_lib = appkit_lib,
        .quartz_lib = quartz_lib,
        .objc_getClass = objc_lib.lookup(*const fn ([*:0]const u8) callconv(.c) Class, "objc_getClass") orelse return error.SymbolNotFound,
        .sel_registerName = objc_lib.lookup(*const fn ([*:0]const u8) callconv(.c) Sel, "sel_registerName") orelse return error.SymbolNotFound,
        .objc_msgSend_ptr = objc_lib.lookup(*const anyopaque, "objc_msgSend") orelse return error.SymbolNotFound,
        .objc_allocateClassPair = objc_lib.lookup(*const fn (Class, [*:0]const u8, usize) callconv(.c) Class, "objc_allocateClassPair") orelse return error.SymbolNotFound,
        .class_addMethod = objc_lib.lookup(*const fn (Class, Sel, *const anyopaque, [*:0]const u8) callconv(.c) bool, "class_addMethod") orelse return error.SymbolNotFound,
        .objc_registerClassPair = objc_lib.lookup(*const fn (Class) callconv(.c) void, "objc_registerClassPair") orelse return error.SymbolNotFound,
        .CGColorSpaceCreateDeviceRGB = cg_lib.lookup(*const fn () callconv(.c) ?*anyopaque, "CGColorSpaceCreateDeviceRGB") orelse return error.SymbolNotFound,
        .CGColorSpaceRelease = cg_lib.lookup(*const fn (?*anyopaque) callconv(.c) void, "CGColorSpaceRelease") orelse return error.SymbolNotFound,
        .CGDataProviderCreateWithData = cg_lib.lookup(
            *const fn (?*anyopaque, *const anyopaque, usize, ?*const anyopaque) callconv(.c) ?*anyopaque,
            "CGDataProviderCreateWithData",
        ) orelse return error.SymbolNotFound,
        .CGDataProviderRelease = cg_lib.lookup(*const fn (?*anyopaque) callconv(.c) void, "CGDataProviderRelease") orelse return error.SymbolNotFound,
        .CGImageCreate = cg_lib.lookup(
            *const fn (usize, usize, usize, usize, usize, ?*anyopaque, u32, ?*anyopaque, ?*const f64, bool, i32) callconv(.c) ?*anyopaque,
            "CGImageCreate",
        ) orelse return error.SymbolNotFound,
        .CGImageRelease = cg_lib.lookup(*const fn (?*anyopaque) callconv(.c) void, "CGImageRelease") orelse return error.SymbolNotFound,
    };
    return &cocoa_api.?;
}

fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extraBytes: usize) Class {
    return cocoa_api.?.objc_allocateClassPair(superclass, name, extraBytes);
}

fn class_addMethod(c: Class, name: Sel, imp: *const anyopaque, types: [*:0]const u8) bool {
    return cocoa_api.?.class_addMethod(c, name, imp, types);
}

fn objc_registerClassPair(c: Class) void {
    cocoa_api.?.objc_registerClassPair(c);
}

fn CGColorSpaceCreateDeviceRGB() ?*anyopaque {
    return cocoa_api.?.CGColorSpaceCreateDeviceRGB();
}

fn CGColorSpaceRelease(cs: ?*anyopaque) void {
    cocoa_api.?.CGColorSpaceRelease(cs);
}

fn CGDataProviderCreateWithData(
    info: ?*anyopaque,
    data: *const anyopaque,
    size: usize,
    releaseData: ?*const anyopaque,
) ?*anyopaque {
    return cocoa_api.?.CGDataProviderCreateWithData(info, data, size, releaseData);
}

fn CGDataProviderRelease(provider: ?*anyopaque) void {
    cocoa_api.?.CGDataProviderRelease(provider);
}

fn CGImageCreate(
    width: usize,
    height: usize,
    bitsPerComponent: usize,
    bitsPerPixel: usize,
    bytesPerRow: usize,
    space: ?*anyopaque,
    bitmapInfo: u32,
    provider: ?*anyopaque,
    decode: ?*const f64,
    shouldInterpolate: bool,
    intent: i32,
) ?*anyopaque {
    return cocoa_api.?.CGImageCreate(
        width,
        height,
        bitsPerComponent,
        bitsPerPixel,
        bytesPerRow,
        space,
        bitmapInfo,
        provider,
        decode,
        shouldInterpolate,
        intent,
    );
}

fn CGImageRelease(image: ?*anyopaque) void {
    cocoa_api.?.CGImageRelease(image);
}

const NSPoint = extern struct {
    x: f64,
    y: f64,
};

const NSSize = extern struct {
    width: f64,
    height: f64,
};

const NSRect = extern struct {
    origin: NSPoint,
    size: NSSize,
};

// AppKit constants
const NSApplicationActivationPolicyRegular: isize = 0;
const NSWindowStyleMaskTitled: usize = 1 << 0;
const NSWindowStyleMaskClosable: usize = 1 << 1;
const NSWindowStyleMaskMiniaturizable: usize = 1 << 2;
const NSWindowStyleMaskFullSizeContentView: usize = 1 << 15;
const NSBackingStoreBuffered: usize = 2;
const NSWindowTitleHidden: isize = 1;
const NSEventMaskAny: u64 = std.math.maxInt(u64);

const NSEventTypeLeftMouseDown: usize = 1;
const NSEventTypeLeftMouseUp: usize = 2;
const NSEventTypeRightMouseDown: usize = 3;
const NSEventTypeRightMouseUp: usize = 4;
const NSEventTypeMouseMoved: usize = 5;
const NSEventTypeLeftMouseDragged: usize = 6;
const NSEventTypeRightMouseDragged: usize = 7;
const NSEventTypeKeyDown: usize = 10;
const NSEventTypeKeyUp: usize = 11;
const NSEventTypeFlagsChanged: usize = 12;
const NSEventTypeScrollWheel: usize = 22;
const NSEventTypeOtherMouseDown: usize = 25;
const NSEventTypeOtherMouseUp: usize = 26;
const NSEventTypeOtherMouseDragged: usize = 27;

const NSEventModifierFlagCapsLock: usize = 1 << 16;
const NSEventModifierFlagShift: usize = 1 << 17;
const NSEventModifierFlagControl: usize = 1 << 18;
const NSEventModifierFlagOption: usize = 1 << 19;
const NSEventModifierFlagCommand: usize = 1 << 20;

// kCGBitmapByteOrder32Little (2 << 12) | kCGImageAlphaNoneSkipFirst (6)
const kCGBitmapByteOrder32Little_NoneSkipFirst: u32 = (2 << 12) | 6;
// kCGBitmapByteOrder32Little (2 << 12) | kCGImageAlphaPremultipliedFirst (2)
const kCGBitmapByteOrder32Little_PremulFirst: u32 = (2 << 12) | 2;

var active_macos_window: ?*MacosWindow = null;
var delegate_class_registered: bool = false;
var delegate_class: Class = null;

fn windowShouldCloseImp(_: Id, _: Sel, _: Id) callconv(.c) bool {
    if (active_macos_window) |w| {
        w.closed = true;
        w.ui_dirty = true;
    }
    return false;
}

inline fn sel(name: [*:0]const u8) Sel {
    return cocoa_api.?.sel_registerName(name);
}

inline fn cls(name: [*:0]const u8) Class {
    return cocoa_api.?.objc_getClass(name);
}

fn msgSend0(comptime Ret: type, recv: Id, s: Sel) Ret {
    const Fn = *const fn (Id, Sel) callconv(.c) Ret;
    const f: Fn = @ptrCast(@alignCast(cocoa_api.?.objc_msgSend_ptr));
    return f(recv, s);
}

fn msgSend1(comptime Ret: type, comptime A1: type, recv: Id, s: Sel, a1: A1) Ret {
    const Fn = *const fn (Id, Sel, A1) callconv(.c) Ret;
    const f: Fn = @ptrCast(@alignCast(cocoa_api.?.objc_msgSend_ptr));
    return f(recv, s, a1);
}

fn msgSend2(comptime Ret: type, comptime A1: type, comptime A2: type, recv: Id, s: Sel, a1: A1, a2: A2) Ret {
    const Fn = *const fn (Id, Sel, A1, A2) callconv(.c) Ret;
    const f: Fn = @ptrCast(@alignCast(cocoa_api.?.objc_msgSend_ptr));
    return f(recv, s, a1, a2);
}

fn msgSend4(
    comptime Ret: type,
    comptime A1: type,
    comptime A2: type,
    comptime A3: type,
    comptime A4: type,
    recv: Id,
    s: Sel,
    a1: A1,
    a2: A2,
    a3: A3,
    a4: A4,
) Ret {
    const Fn = *const fn (Id, Sel, A1, A2, A3, A4) callconv(.c) Ret;
    const f: Fn = @ptrCast(@alignCast(cocoa_api.?.objc_msgSend_ptr));
    return f(recv, s, a1, a2, a3, a4);
}

pub const MacosWindow = struct {
    gpa: std.mem.Allocator,
    ns_app: Id = null,
    ns_window: Id = null,
    ns_view: Id = null,
    ns_delegate: Id = null,
    default_run_loop_mode: Id = null,
    color_space: ?*anyopaque = null,
    crosshair_cursor: Id = null,

    /// Logical HDMI display size (e.g. 1280 x 720)
    display_width: u32,
    display_height: u32,
    /// Logical window size (`display_width` x `display_height + 44 [+ gpio_panel_height]`)
    width: u32,
    height: u32,
    /// HiDPI / Retina buffer scale factor (`1` on standard displays, `2` on Retina displays)
    scale: u32 = 1,
    pending_scale: u32 = 1,

    /// 1x simulated HDMI framebuffer (`display_width * display_height`)
    hdmi_fb: []u32,
    /// Physical window backbuffer (`(width * scale) * (height * scale)`)
    backbuffer: []u32 = &.{},

    closed: bool = false,
    ui_dirty: bool = true,
    power_reconnected: bool = false,
    sd_disconnected: bool = false,
    sd_reconnected: bool = false,
    sd_image_chosen: bool = false,
    chosen_sd_path_buf: [std.fs.max_path_bytes]u8 = undefined,
    chosen_sd_path_len: usize = 0,

    picker_fd: host_posix.fd_t = -1,
    picker_pid: host_posix.pid_t = -1,
    picker_buf: [std.fs.max_path_bytes]u8 = undefined,
    picker_len: usize = 0,

    last_mouse_x: ?f64 = null,
    last_mouse_y: ?f64 = null,
    last_mouse_down_event: Id = null,
    was_key_window: bool = true,
    cursor_mode: enum { unknown, ui_arrow, hdmi_crosshair } = .unknown,

    /// Client-side keyboard repeat state
    repeat_rate: u32 = 25,
    repeat_delay_ms: u32 = 500,
    repeat: ?struct { key: u32, next_ns: u64 } = null,
    keys_down: std.StaticBitSet(256) = .initEmpty(),

    hid: ?*UsbHidComposite = null,
    gpio: *Gpio,
    ui: board_sheet.BoardUi,
    status: board_sheet.SystemStatus = .{},

    pub fn create(
        gpa: std.mem.Allocator,
        environ: std.process.Environ,
        display_width: u32,
        display_height: u32,
        hid: *UsbHidComposite,
        gpio: *Gpio,
    ) !*MacosWindow {
        var ui = try board_sheet.BoardUi.init(gpa);
        errdefer ui.deinit();

        const hdmi_fb = try gpa.alloc(u32, @as(usize, display_width) * @as(usize, display_height));
        errdefer gpa.free(hdmi_fb);
        @memset(hdmi_fb, 0xFF101418);

        var status: board_sheet.SystemStatus = .{
            .serial_u64 = ui.parsedSerial(),
            .mac_address = ui.parsedMac(),
            .wifi_mac_address = ui.parsedWifiMac(),
            .hdmi_width = @intCast(display_width),
            .hdmi_height = @intCast(display_height),
        };
        ui.configureXdgStorage(environ, &status);

        const total_width = display_width;
        const total_height = display_height + board_sheet.BoardUi.title_bar_height +
            (if (status.gpio_connected) board_sheet.BoardUi.gpio_panel_height else 0);

        const win = try gpa.create(MacosWindow);
        errdefer gpa.destroy(win);

        win.* = .{
            .gpa = gpa,
            .display_width = display_width,
            .display_height = display_height,
            .width = total_width,
            .height = total_height,
            .hdmi_fb = hdmi_fb,
            .hid = hid,
            .gpio = gpio,
            .ui = ui,
            .status = status,
        };

        gpio.setExternalPin(46, !win.status.hdmi_connected);
        hid.setHubKind(@import("../usb/hid.zig").HubKind.fromModel(win.status.model));
        hid.hub_connected = win.status.usb_hub_connected;
        hid.keyboard_connected = win.status.usb_keyboard_connected;
        hid.mouse_connected = win.status.usb_mouse_connected;
        hid.ethernet_connected = win.status.ethernet_connected;
        hid.net.dhcp_enabled = win.status.dhcp_enabled;

        try win.initCocoaWindow();
        try win.initBackbuffer();
        active_macos_window = win;
        return win;
    }

    pub fn destroy(self: *MacosWindow) void {
        if (active_macos_window == self) {
            active_macos_window = null;
        }
        if (self.picker_fd >= 0) {
            host_posix.close(self.picker_fd);
            self.picker_fd = -1;
        }
        self.ui.saveSettings(self.status) catch {};
        self.ui.deinit();
        if (self.backbuffer.len > 0) {
            self.gpa.free(self.backbuffer);
        }
        self.gpa.free(self.hdmi_fb);
        if (self.color_space) |cs| {
            CGColorSpaceRelease(cs);
            self.color_space = null;
        }
        if (self.ns_window) |w| {
            msgSend0(void, w, sel("close"));
        }
        self.gpa.destroy(self);
    }

    fn initCocoaWindow(self: *MacosWindow) !void {
        _ = try ensureCocoaLoaded();
        const pool = msgSend0(Id, msgSend0(Id, cls("NSAutoreleasePool"), sel("alloc")), sel("init"));
        defer msgSend0(void, pool, sel("drain"));

        const app = msgSend0(Id, cls("NSApplication"), sel("sharedApplication")) orelse return error.CocoaInitFailed;
        self.ns_app = app;
        _ = msgSend1(bool, isize, app, sel("setActivationPolicy:"), NSApplicationActivationPolicyRegular);
        msgSend0(void, app, sel("finishLaunching"));

        self.default_run_loop_mode = makeNSString("kCFRunLoopDefaultMode");

        const content_rect = NSRect{
            .origin = .{ .x = 120.0, .y = 120.0 },
            .size = .{ .width = @floatFromInt(self.width), .height = @floatFromInt(self.height) },
        };
        const style_mask = NSWindowStyleMaskTitled |
            NSWindowStyleMaskClosable |
            NSWindowStyleMaskMiniaturizable |
            NSWindowStyleMaskFullSizeContentView;

        const raw_win = msgSend0(Id, cls("NSWindow"), sel("alloc")) orelse return error.CocoaInitFailed;
        const ns_win = msgSend4(
            Id,
            NSRect,
            usize,
            usize,
            bool,
            raw_win,
            sel("initWithContentRect:styleMask:backing:defer:"),
            content_rect,
            style_mask,
            NSBackingStoreBuffered,
            false,
        ) orelse return error.CocoaInitFailed;
        self.ns_window = ns_win;

        msgSend1(void, bool, ns_win, sel("setReleasedWhenClosed:"), false);
        msgSend1(void, bool, ns_win, sel("setTitlebarAppearsTransparent:"), true);
        msgSend1(void, isize, ns_win, sel("setTitleVisibility:"), NSWindowTitleHidden);
        msgSend1(void, bool, ns_win, sel("setMovableByWindowBackground:"), false);
        msgSend1(void, bool, ns_win, sel("setAcceptsMouseMovedEvents:"), true);

        if (makeNSStringSlice(self.ui.title)) |title_str| {
            msgSend1(void, Id, ns_win, sel("setTitle:"), title_str);
        }

        // Register window delegate to intercept the native red traffic-light close button
        if (!delegate_class_registered) {
            delegate_class_registered = true;
            if (objc_allocateClassPair(cls("NSObject"), "FauxPiWindowDelegate", 0)) |dcls| {
                _ = class_addMethod(dcls, sel("windowShouldClose:"), @ptrCast(&windowShouldCloseImp), "c@:@");
                objc_registerClassPair(dcls);
                delegate_class = dcls;
            }
        }
        if (delegate_class) |dcls| {
            const del = msgSend0(Id, msgSend0(Id, dcls, sel("alloc")), sel("init"));
            self.ns_delegate = del;
            msgSend1(void, Id, ns_win, sel("setDelegate:"), del);
        }

        const view = msgSend0(Id, ns_win, sel("contentView")) orelse return error.CocoaInitFailed;
        self.ns_view = view;
        msgSend1(void, bool, view, sel("setWantsLayer:"), true);

        msgSend0(void, ns_win, sel("center"));
        msgSend1(void, Id, ns_win, sel("makeKeyAndOrderFront:"), null);
        msgSend1(void, bool, app, sel("activateIgnoringOtherApps:"), true);

        self.color_space = CGColorSpaceCreateDeviceRGB();
        self.crosshair_cursor = self.createCrosshairCursor();
        self.queryBackingScale();
        self.scale = @max(self.pending_scale, 1);
    }

    fn queryBackingScale(self: *MacosWindow) void {
        const w = self.ns_window orelse return;
        const factor = msgSend0(f64, w, sel("backingScaleFactor"));
        if (factor >= 1.0 and factor <= 4.0) {
            const new_scale: u32 = @intFromFloat(@round(factor));
            if (new_scale >= 1 and self.pending_scale != new_scale) {
                self.pending_scale = new_scale;
                self.ui_dirty = true;
            }
        }
    }

    fn createCrosshairCursor(self: *MacosWindow) Id {
        const cs = self.color_space orelse return null;
        const dim: usize = 24;
        var pixels: [dim * dim]u32 = undefined;
        @import("window.zig").paintFaintCrosshairCursor(&pixels, 1);

        const provider = CGDataProviderCreateWithData(null, @ptrCast(&pixels), dim * dim * 4, null) orelse return null;
        defer CGDataProviderRelease(provider);

        const cg_img = CGImageCreate(
            dim,
            dim,
            8,
            32,
            dim * 4,
            cs,
            kCGBitmapByteOrder32Little_PremulFirst,
            provider,
            null,
            false,
            0,
        ) orelse return null;
        defer CGImageRelease(cg_img);

        const raw_ns_img = msgSend0(Id, cls("NSImage"), sel("alloc")) orelse return null;
        const ns_img = msgSend2(
            Id,
            ?*anyopaque,
            NSSize,
            raw_ns_img,
            sel("initWithCGImage:size:"),
            cg_img,
            .{ .width = 24.0, .height = 24.0 },
        ) orelse return null;

        const raw_cur = msgSend0(Id, cls("NSCursor"), sel("alloc")) orelse return null;
        return msgSend2(
            Id,
            Id,
            NSPoint,
            raw_cur,
            sel("initWithImage:hotSpot:"),
            ns_img,
            .{ .x = 12.0, .y = 12.0 },
        );
    }

    fn initBackbuffer(self: *MacosWindow) !void {
        if (self.backbuffer.len > 0) {
            self.gpa.free(self.backbuffer);
            self.backbuffer = &.{};
        }
        const sc = @max(self.scale, 1);
        const count = @as(usize, self.width * sc) * @as(usize, self.height * sc);
        self.backbuffer = try self.gpa.alloc(u32, count);
        @memset(self.backbuffer, 0xFF101418);
        self.cursor_mode = .unknown;
        self.ui_dirty = true;
    }

    pub fn backbufferPixels(self: *MacosWindow) []u32 {
        return self.backbuffer;
    }

    pub fn displayPixels(self: *MacosWindow) []u32 {
        return self.hdmi_fb;
    }

    pub fn chosenSdPath(self: *const MacosWindow) []const u8 {
        return self.chosen_sd_path_buf[0..self.chosen_sd_path_len];
    }

    pub fn compositeUi(self: *MacosWindow) void {
        self.ui_dirty = false;
        self.queryBackingScale();

        const desired_h = self.display_height + board_sheet.BoardUi.title_bar_height +
            (if (self.status.gpio_connected) board_sheet.BoardUi.gpio_panel_height else 0);
        if ((self.pending_scale != self.scale and self.pending_scale >= 1) or self.height != desired_h) {
            if (self.pending_scale >= 1) self.scale = self.pending_scale;
            const height_changed = (self.height != desired_h);
            self.height = desired_h;
            self.initBackbuffer() catch {};
            if (height_changed) {
                if (self.ns_window) |w| {
                    msgSend1(
                        void,
                        NSSize,
                        w,
                        sel("setContentSize:"),
                        .{ .width = @floatFromInt(self.width), .height = @floatFromInt(self.height) },
                    );
                }
            }
            self.ui_dirty = false;
        }

        const sc = @max(self.scale, 1);
        const full = self.backbufferPixels();
        const buf_w: usize = @as(usize, self.width) * @as(usize, sc);
        const top_phys_rows: usize = @as(usize, board_sheet.BoardUi.title_bar_height) * @as(usize, sc);
        const dw: usize = self.display_width;
        const dh: usize = self.display_height;

        if (self.status.hdmi_connected and self.status.hdmi_active) {
            if (sc == 1) {
                const dst = full[top_phys_rows * buf_w ..][0 .. dw * dh];
                @memcpy(dst, self.hdmi_fb[0 .. dw * dh]);
            } else if (sc == 2) {
                for (0..dh) |sy| {
                    const src_row = self.hdmi_fb[sy * dw ..][0..dw];
                    const dst_y0 = top_phys_rows + sy * 2;
                    const first_dst_row = full[dst_y0 * buf_w ..][0 .. dw * 2];
                    const dst_u64: [*]align(4) u64 = @ptrCast(first_dst_row.ptr);
                    for (src_row, 0..) |px, sx| {
                        dst_u64[sx] = (@as(u64, px) << 32) | px;
                    }
                    const dup_dst_row = full[(dst_y0 + 1) * buf_w ..][0 .. dw * 2];
                    @memcpy(dup_dst_row, first_dst_row);
                }
            } else {
                for (0..dh) |sy| {
                    const src_row = self.hdmi_fb[sy * dw ..][0..dw];
                    const dst_y0 = top_phys_rows + sy * sc;
                    const first_dst_row = full[dst_y0 * buf_w ..][0 .. dw * sc];
                    for (src_row, 0..) |px, sx| {
                        @memset(first_dst_row[sx * sc ..][0..sc], px);
                    }
                    for (1..sc) |ry| {
                        const dup_dst_row = full[(dst_y0 + ry) * buf_w ..][0 .. dw * sc];
                        @memcpy(dup_dst_row, first_dst_row);
                    }
                }
            }
        }

        self.ui.paint(full, self.width, self.height, sc, self.status, self.gpio);
    }

    pub fn present(self: *MacosWindow) !void {
        const view = self.ns_view orelse return;
        const cs = self.color_space orelse return;
        const sc = @max(self.scale, 1);
        const buf_w: usize = @as(usize, self.width) * @as(usize, sc);
        const buf_h: usize = @as(usize, self.height) * @as(usize, sc);
        const byte_len = buf_w * buf_h * 4;
        if (self.backbuffer.len * 4 < byte_len) return;

        const pool = msgSend0(Id, msgSend0(Id, cls("NSAutoreleasePool"), sel("alloc")), sel("init"));
        defer msgSend0(void, pool, sel("drain"));

        if (msgSend0(Id, view, sel("layer"))) |layer| {
            msgSend1(void, f64, layer, sel("setContentsScale:"), @floatFromInt(sc));
            if (CGDataProviderCreateWithData(null, @ptrCast(self.backbuffer.ptr), byte_len, null)) |provider| {
                defer CGDataProviderRelease(provider);
                if (CGImageCreate(
                    buf_w,
                    buf_h,
                    8,
                    32,
                    buf_w * 4,
                    cs,
                    kCGBitmapByteOrder32Little_NoneSkipFirst,
                    provider,
                    null,
                    false,
                    0,
                )) |cg_img| {
                    defer CGImageRelease(cg_img);
                    msgSend1(void, ?*anyopaque, layer, sel("setContents:"), cg_img);
                }
            }
            if (cls("CATransaction")) |ca_tx| {
                msgSend0(void, ca_tx, sel("flush"));
            }
        }

        try self.pollEvents();
    }

    pub fn pollEvents(self: *MacosWindow) !void {
        self.pumpCocoaEvents(0.0);
        self.pollSdImagePicker();
        self.serviceRepeat(host_posix.monotonicNs());
    }

    pub fn waitEvents(self: *MacosWindow, timeout_ms: i32) !void {
        const timeout_us: ?u64 = if (timeout_ms < 0) null else @as(u64, @intCast(timeout_ms)) * 1000;
        return self.waitEventsUs(timeout_us);
    }

    pub fn waitEventsUs(self: *MacosWindow, timeout_us: ?u64) !void {
        const was_dirty = self.ui_dirty;
        self.pumpCocoaEvents(0.0);
        self.pollSdImagePicker();
        const now_ns = host_posix.monotonicNs();
        self.serviceRepeat(now_ns);
        if (self.closed or (!was_dirty and self.ui_dirty)) return;
        if (self.hid) |h| {
            if (h.hasPendingInterruptIn()) return;
        }

        var eff_timeout_us: u64 = timeout_us orelse 16_000;
        if (self.repeatTimeoutMs(now_ns)) |rep_ms| {
            eff_timeout_us = @min(eff_timeout_us, @as(u64, @intCast(@max(rep_ms, 0))) * 1000);
        }
        if (self.picker_fd >= 0) {
            eff_timeout_us = @min(eff_timeout_us, 10_000);
        }
        if (self.hid) |h| {
            if (h.isEthernetLinkUp()) {
                var net_fds: [32]host_posix.pollfd = undefined;
                const n = h.net.fillPollFds(&net_fds);
                if (n > 0) {
                    eff_timeout_us = @min(eff_timeout_us, 2_000);
                }
            }
        }

        if (eff_timeout_us > 0) {
            const wait_secs: f64 = @as(f64, @floatFromInt(eff_timeout_us)) / 1_000_000.0;
            self.pumpCocoaEvents(wait_secs);
        }
        self.pollSdImagePicker();
        self.serviceRepeat(host_posix.monotonicNs());
    }

    fn pumpCocoaEvents(self: *MacosWindow, wait_seconds: f64) void {
        const app = self.ns_app orelse return;
        const pool = msgSend0(Id, msgSend0(Id, cls("NSAutoreleasePool"), sel("alloc")), sel("init"));
        defer msgSend0(void, pool, sel("drain"));

        var first_wait = wait_seconds;
        while (true) {
            const until_date: Id = if (first_wait > 0.0)
                msgSend1(Id, f64, cls("NSDate"), sel("dateWithTimeIntervalSinceNow:"), first_wait)
            else
                msgSend0(Id, cls("NSDate"), sel("distantPast"));
            first_wait = 0.0;

            const ev = msgSend4(
                Id,
                u64,
                Id,
                Id,
                bool,
                app,
                sel("nextEventMatchingMask:untilDate:inMode:dequeue:"),
                NSEventMaskAny,
                until_date,
                self.default_run_loop_mode,
                true,
            ) orelse break;

            const handled = self.handleCocoaEvent(ev);
            if (!handled) {
                msgSend1(void, Id, app, sel("sendEvent:"), ev);
            }
        }

        if (self.ns_window) |w| {
            const is_key = msgSend0(bool, w, sel("isKeyWindow"));
            if (self.was_key_window and !is_key) {
                self.repeat = null;
                self.keys_down = .initEmpty();
                self.ui.clearModifiers();
                if (self.hid) |h| {
                    h.releaseAllKeys();
                }
            }
            self.was_key_window = is_key;
        }
    }

    fn handleCocoaEvent(self: *MacosWindow, ev: Id) bool {
        const ev_type = msgSend0(usize, ev, sel("type"));
        switch (ev_type) {
            NSEventTypeMouseMoved,
            NSEventTypeLeftMouseDragged,
            NSEventTypeRightMouseDragged,
            NSEventTypeOtherMouseDragged,
            => {
                const pt = self.eventWindowCoords(ev);
                if (pt.x >= 0.0 and pt.x < @as(f64, @floatFromInt(self.width)) and
                    pt.y >= 0.0 and pt.y < @as(f64, @floatFromInt(self.height)))
                {
                    const in_ui = self.ui.pointerMotion(@floatCast(pt.x), @floatCast(pt.y), self.status, self.gpio);
                    self.updateCursorShape(in_ui);
                    if (!in_ui) {
                        self.updateGuestMouseTarget(pt.x, pt.y);
                    }
                    self.last_mouse_x = pt.x;
                    self.last_mouse_y = pt.y;
                    self.ui_dirty = true;
                }
                return false;
            },
            NSEventTypeLeftMouseDown, NSEventTypeLeftMouseUp => {
                const pressed = (ev_type == NSEventTypeLeftMouseDown);
                if (pressed) self.last_mouse_down_event = ev;
                const pt = self.eventWindowCoords(ev);
                self.last_mouse_x = pt.x;
                self.last_mouse_y = pt.y;

                // Allow native macOS traffic lights in the top-left (x < 78, y < 44) to receive clicks directly
                if (pt.y < @as(f64, @floatFromInt(board_sheet.BoardUi.title_bar_height)) and pt.x < 78.0) {
                    return false;
                }
                if (pt.x < 0.0 or pt.x >= @as(f64, @floatFromInt(self.width)) or
                    pt.y < 0.0 or pt.y >= @as(f64, @floatFromInt(self.height)))
                {
                    return false;
                }
                self.handleMouseButton(1 << 0, pressed, pt.x, pt.y);
                return false;
            },
            NSEventTypeRightMouseDown, NSEventTypeRightMouseUp => {
                const pressed = (ev_type == NSEventTypeRightMouseDown);
                const pt = self.eventWindowCoords(ev);
                self.last_mouse_x = pt.x;
                self.last_mouse_y = pt.y;
                self.handleMouseButton(1 << 1, pressed, pt.x, pt.y);
                return false;
            },
            NSEventTypeOtherMouseDown, NSEventTypeOtherMouseUp => {
                const pressed = (ev_type == NSEventTypeOtherMouseDown);
                const pt = self.eventWindowCoords(ev);
                self.last_mouse_x = pt.x;
                self.last_mouse_y = pt.y;
                self.handleMouseButton(1 << 2, pressed, pt.x, pt.y);
                return false;
            },
            NSEventTypeScrollWheel => {
                const dy = msgSend0(f64, ev, sel("scrollingDeltaY"));
                const sx: f32 = @floatCast(self.last_mouse_x orelse 0.0);
                const sy: f32 = @floatCast(self.last_mouse_y orelse 0.0);
                if (!self.ui.isPointInUi(sx, sy, self.status) and dy != 0.0) {
                    if (self.hid) |h| {
                        const wheel: i8 = if (dy > 0.0) 1 else -1;
                        h.handleMouseMotion(0, 0, wheel);
                    }
                }
                return false;
            },
            NSEventTypeKeyDown, NSEventTypeKeyUp => {
                const pressed = (ev_type == NSEventTypeKeyDown);
                const mods = msgSend0(usize, ev, sel("modifierFlags"));
                // Allow Command+Q / Command+W / Command+M to pass through to AppKit when Command is held and BoardSheet is open
                if ((mods & NSEventModifierFlagCommand) != 0 and pressed) {
                    const chars_ign = extractEventAsciiChar(ev, "charactersIgnoringModifiers");
                    if (chars_ign == 'q') {
                        self.closed = true;
                        self.ui_dirty = true;
                        return true;
                    }
                }
                const mac_kc = msgSend0(u16, ev, sel("keyCode"));
                const is_repeat = if (pressed) msgSend0(bool, ev, sel("isARepeat")) else false;
                if (macosKeycodeToEvdev(mac_kc)) |evdev_key| {
                    if (pressed) {
                        self.updateKeymapFromCocoaEvent(ev, evdev_key);
                    }
                    if (evdev_key < 256) {
                        if (pressed) self.keys_down.set(evdev_key) else self.keys_down.unset(evdev_key);
                    }
                    if (pressed) {
                        if (!isModifierKey(evdev_key) and self.repeat_rate > 0 and !is_repeat) {
                            const delay_ns = @as(u64, self.repeat_delay_ms) * std.time.ns_per_ms;
                            self.repeat = .{ .key = evdev_key, .next_ns = host_posix.monotonicNs() + delay_ns };
                        }
                    } else {
                        if (self.repeat) |rep| {
                            if (rep.key == evdev_key) self.repeat = null;
                        }
                    }
                    self.dispatchKey(evdev_key, pressed, is_repeat);
                }
                // Consume key events so macOS does not play the system alert beep
                return true;
            },
            NSEventTypeFlagsChanged => {
                const mods = msgSend0(usize, ev, sel("modifierFlags"));
                const mac_kc = msgSend0(u16, ev, sel("keyCode"));
                self.ui.shift_held = (mods & NSEventModifierFlagShift) != 0;
                self.ui.caps_lock = (mods & NSEventModifierFlagCapsLock) != 0;
                if (macosKeycodeToEvdev(mac_kc)) |evdev_key| {
                    const pressed = switch (mac_kc) {
                        0x38, 0x3C => (mods & NSEventModifierFlagShift) != 0,
                        0x3B, 0x3E => (mods & NSEventModifierFlagControl) != 0,
                        0x3A, 0x3D => (mods & NSEventModifierFlagOption) != 0,
                        0x37, 0x36 => (mods & NSEventModifierFlagCommand) != 0,
                        0x39 => (mods & NSEventModifierFlagCapsLock) != 0,
                        else => false,
                    };
                    self.dispatchKey(evdev_key, pressed, false);
                }
                return false;
            },
            else => return false,
        }
    }

    fn eventWindowCoords(self: *const MacosWindow, ev: Id) NSPoint {
        const loc = msgSend0(NSPoint, ev, sel("locationInWindow"));
        return .{
            .x = loc.x,
            .y = @as(f64, @floatFromInt(self.height)) - loc.y,
        };
    }

    fn updateKeymapFromCocoaEvent(self: *MacosWindow, ev: Id, evdev_key: u32) void {
        if (evdev_key >= 128) return;
        if (extractEventAsciiChar(ev, "charactersIgnoringModifiers")) |base_ch| {
            self.ui.keymap.entries[evdev_key][0] = base_ch;
        }
        if (extractEventAsciiChar(ev, "characters")) |ch| {
            if (self.ui.shift_held or self.ui.xkb_shift) {
                self.ui.keymap.entries[evdev_key][1] = ch;
            } else {
                self.ui.keymap.entries[evdev_key][0] = ch;
            }
        }
    }

    fn extractEventAsciiChar(ev: Id, selector_name: [*:0]const u8) ?u8 {
        const ns_str = msgSend0(Id, ev, sel(selector_name)) orelse return null;
        const c_str = msgSend0(?[*:0]const u8, ns_str, sel("UTF8String")) orelse return null;
        const ch = c_str[0];
        if (ch >= 0x20 and ch < 0x7f and c_str[1] == 0) {
            return ch;
        }
        return null;
    }

    fn updateCursorShape(self: *MacosWindow, over_ui: bool) void {
        const target: @TypeOf(self.cursor_mode) = if (over_ui) .ui_arrow else .hdmi_crosshair;
        if (self.cursor_mode == target) return;
        self.cursor_mode = target;

        if (over_ui) {
            if (msgSend0(Id, cls("NSCursor"), sel("arrowCursor"))) |cur| {
                msgSend0(void, cur, sel("set"));
            }
        } else {
            const cur = self.crosshair_cursor orelse msgSend0(Id, cls("NSCursor"), sel("crosshairCursor"));
            if (cur) |c| {
                msgSend0(void, c, sel("set"));
            }
        }
    }

    fn updateGuestMouseTarget(self: *MacosWindow, sx: f64, sy: f64) void {
        const hid = self.hid orelse return;
        const max_x = @max(@as(i32, @intCast(self.display_width)) - 1, 0);
        const max_y = @max(@as(i32, @intCast(self.display_height)) - 1, 0);
        const hdmi_x = std.math.clamp(@as(i32, @intFromFloat(@floor(sx))), 0, max_x);
        const hdmi_y = std.math.clamp(
            @as(i32, @intFromFloat(@floor(sy))) - @as(i32, board_sheet.BoardUi.title_bar_height),
            0,
            max_y,
        );
        hid.setMouseTarget(hdmi_x, hdmi_y);
    }

    fn handleMouseButton(self: *MacosWindow, button_bit: u8, pressed: bool, sx_f64: f64, sy_f64: f64) void {
        const hid = self.hid orelse return;
        self.ui_dirty = true;
        const sx: f32 = @floatCast(sx_f64);
        const sy: f32 = @floatCast(sy_f64);

        if (button_bit == (1 << 0)) {
            const prev_sheet = self.ui.sheet_open;
            const action = self.ui.pointerButton(sx, sy, pressed, self.status, self.gpio);
            if (!prev_sheet and self.ui.sheet_open) {
                hid.releaseAllKeys();
            }
            const over_ui = self.ui.isPointInUi(sx, sy, self.status);
            self.updateCursorShape(over_ui);
            switch (action) {
                .start_drag => {
                    if (self.ns_window) |w| {
                        if (self.last_mouse_down_event) |ev| {
                            msgSend1(void, Id, w, sel("performWindowDragWithEvent:"), ev);
                        }
                    }
                    return;
                },
                .toggle_maximize => {
                    self.ui.maximized = !self.ui.maximized;
                    if (self.ns_window) |w| {
                        msgSend1(void, Id, w, sel("zoom:"), null);
                    }
                    return;
                },
                .toggle_hdmi => {
                    self.status.hdmi_connected = !self.status.hdmi_connected;
                    if (!self.status.hdmi_connected) {
                        self.status.hdmi_active = false;
                    }
                    self.gpio.setExternalPin(46, !self.status.hdmi_connected);
                    self.ui.saveSettings(self.status) catch {};
                    return;
                },
                .toggle_audio => {
                    self.status.audio_connected = !self.status.audio_connected;
                    self.ui.saveSettings(self.status) catch {};
                    return;
                },
                .toggle_power => {
                    self.status.power_connected = !self.status.power_connected;
                    if (self.status.power_connected) {
                        self.power_reconnected = true;
                    } else {
                        self.status.hdmi_active = false;
                        self.status.cpu_busy_percent = 0.0;
                        self.gpio.resetSocState();
                    }
                    return;
                },
                .toggle_sd => {
                    self.status.sd_connected = !self.status.sd_connected;
                    if (self.status.sd_connected) {
                        self.sd_reconnected = true;
                    } else {
                        self.sd_disconnected = true;
                    }
                    self.ui.saveSettings(self.status) catch {};
                    return;
                },
                .select_sd_image => {
                    self.openSdImagePicker();
                    return;
                },
                .select_sd_card => {
                    self.sd_image_chosen = true;
                    self.ui.saveSettings(self.status) catch {};
                    return;
                },
                .toggle_usb_hub => {
                    self.status.usb_hub_connected = !self.status.usb_hub_connected;
                    hid.hub_connected = self.status.usb_hub_connected;
                    self.ui.saveSettings(self.status) catch {};
                    return;
                },
                .toggle_usb_keyboard => {
                    self.status.usb_keyboard_connected = !self.status.usb_keyboard_connected;
                    hid.keyboard_connected = self.status.usb_keyboard_connected;
                    self.ui.saveSettings(self.status) catch {};
                    return;
                },
                .toggle_usb_mouse => {
                    self.status.usb_mouse_connected = !self.status.usb_mouse_connected;
                    hid.mouse_connected = self.status.usb_mouse_connected;
                    self.ui.saveSettings(self.status) catch {};
                    return;
                },
                .toggle_ethernet => {
                    self.status.ethernet_connected = !self.status.ethernet_connected;
                    hid.ethernet_connected = self.status.ethernet_connected;
                    self.ui.saveSettings(self.status) catch {};
                    return;
                },
                .toggle_gpio => {
                    self.status.gpio_connected = !self.status.gpio_connected;
                    if (!self.status.gpio_connected) {
                        self.gpio.clearHeaderExternalPins();
                    }
                    self.ui.saveSettings(self.status) catch {};
                    return;
                },
                .select_board => {
                    self.setBoardModel(self.ui.selected_board_model);
                    return;
                },
                .toggle_dhcp => {
                    self.status.dhcp_enabled = !self.status.dhcp_enabled;
                    hid.net.dhcp_enabled = self.status.dhcp_enabled;
                    self.ui.saveSettings(self.status) catch {};
                    return;
                },
                .close => {
                    self.closed = true;
                    return;
                },
                .consumed => {
                    self.status.serial_u64 = self.ui.parsedSerial();
                    self.status.mac_address = self.ui.parsedMac();
                    self.status.wifi_mac_address = self.ui.parsedWifiMac();
                    self.ui.saveSettings(self.status) catch {};
                    return;
                },
                .none => {},
            }
        } else if (self.ui.isPointInUi(sx, sy, self.status)) {
            return;
        }

        self.updateGuestMouseTarget(sx_f64, sy_f64);
        hid.handleMouseButton(button_bit, pressed);
    }

    pub fn setBoardModel(self: *MacosWindow, bm: board_sheet.BoardModel) void {
        self.status.board_model = bm;
        self.status.model = bm.dtModel();
        self.status.serial_u64 = self.ui.parsedSerial();
        self.status.mac_address = self.ui.parsedMac();
        self.status.wifi_mac_address = self.ui.parsedWifiMac();
        self.ui.title = bm.windowTitle();
        if (!bm.usesExternalUsbHub()) {
            self.status.usb_hub_connected = true;
        }
        if (self.hid) |h| {
            h.setHubKind(@import("../usb/hid.zig").HubKind.fromModel(self.status.model));
            h.hub_connected = self.status.usb_hub_connected;
        }
        self.ui_dirty = true;
        self.ui.saveSettings(self.status) catch {};
        if (self.ns_window) |w| {
            if (makeNSStringSlice(self.ui.title)) |title_str| {
                msgSend1(void, Id, w, sel("setTitle:"), title_str);
            }
        }
    }

    fn openSdImagePicker(self: *MacosWindow) void {
        if (self.picker_fd >= 0) return;

        var fds: [2]host_posix.fd_t = undefined;
        if (!host_posix.pipeNonBlockCloexec(&fds)) return;

        const pid = host_posix.forkProcess() orelse {
            host_posix.close(fds[0]);
            host_posix.close(fds[1]);
            return;
        };

        if (pid == 0) {
            host_posix.dup2Stdout(fds[1]);
            host_posix.close(fds[0]);
            host_posix.close(fds[1]);

            const osascript_argv = [_:null]?[*:0]const u8{
                "osascript",
                "-e",
                "POSIX path of (choose file with prompt \"Select SD Card Image\")",
            };
            _ = execvp("osascript", &osascript_argv);
            _exit(127);
        }

        host_posix.close(fds[1]);
        self.picker_fd = fds[0];
        self.picker_pid = pid;
        self.picker_len = 0;
    }

    fn pollSdImagePicker(self: *MacosWindow) void {
        if (self.picker_fd < 0) return;

        while (self.picker_len < self.picker_buf.len) {
            switch (host_posix.readNonBlock(self.picker_fd, self.picker_buf[self.picker_len..])) {
                .again => return,
                .err => break,
                .bytes => |rc| {
                    if (rc == 0) {
                        host_posix.waitpidBlocking(self.picker_pid);
                        host_posix.close(self.picker_fd);
                        self.picker_fd = -1;
                        self.picker_pid = -1;

                        const trimmed = std.mem.trim(u8, self.picker_buf[0..self.picker_len], " \t\r\n");
                        if (trimmed.len > 0 and trimmed.len <= self.chosen_sd_path_buf.len) {
                            @memcpy(self.chosen_sd_path_buf[0..trimmed.len], trimmed);
                            self.chosen_sd_path_len = trimmed.len;
                            const fsize = board_sheet.Qcow2Disk.getFileSizeLinux(trimmed) catch 0;
                            self.ui.setPendingSdImageFile(trimmed, fsize);
                        }
                        self.picker_len = 0;
                        self.ui_dirty = true;
                        return;
                    }
                    self.picker_len += rc;
                },
            }
        }
    }

    fn isModifierKey(evdev_key: u32) bool {
        return switch (evdev_key) {
            29, 97, 42, 54, 56, 100, 125, 126, 58, 69, 70 => true,
            else => false,
        };
    }

    pub fn repeatTimeoutMs(self: *const MacosWindow, now_ns: u64) ?i32 {
        const rep = self.repeat orelse return null;
        if (self.repeat_rate == 0 or !self.ui.sheet_open) return null;
        if (now_ns >= rep.next_ns) return 0;
        const rem_ms = std.math.divCeil(u64, rep.next_ns - now_ns, std.time.ns_per_ms) catch 0;
        return @intCast(@min(rem_ms, @as(u64, std.math.maxInt(i32))));
    }

    pub fn serviceRepeat(self: *MacosWindow, now_ns: u64) void {
        const rep = &(self.repeat orelse return);
        if (self.repeat_rate == 0) {
            self.repeat = null;
            return;
        }
        if (now_ns < rep.next_ns) return;
        const step = std.time.ns_per_s / @as(u64, self.repeat_rate);
        rep.next_ns = if (now_ns - rep.next_ns < step) rep.next_ns + step else now_ns + step;
        if (self.ui.sheet_open) {
            self.dispatchKey(rep.key, true, true);
        }
    }

    pub fn dispatchKey(self: *MacosWindow, key: u32, pressed: bool, is_repeat: bool) void {
        self.ui.updateModifierKey(key, pressed);
        if (self.ui.sheet_open) {
            self.ui_dirty = true;
            if (pressed and self.ui.handleKey(key)) {
                self.status.serial_u64 = self.ui.parsedSerial();
                self.status.mac_address = self.ui.parsedMac();
                self.status.wifi_mac_address = self.ui.parsedWifiMac();
                self.ui.saveSettings(self.status) catch {};
                return;
            }
            if (key == 1 and pressed and !is_repeat) {
                if (self.ui.sd_manage_open) {
                    self.ui.sd_manage_open = false;
                    return;
                }
                if (self.ui.sd_card_menu_open) {
                    self.ui.sd_card_menu_open = false;
                    return;
                }
                self.ui.sheet_open = false;
                const sx: f32 = @floatCast(self.last_mouse_x orelse 0.0);
                const sy: f32 = @floatCast(self.last_mouse_y orelse 0.0);
                self.updateCursorShape(self.ui.isPointInUi(sx, sy, self.status));
            }
            return;
        }
        if (self.hid) |hid| {
            hid.handleEvdevKey(key, pressed);
        }
    }
};

fn makeNSString(cstr: [*:0]const u8) Id {
    return msgSend1(Id, [*:0]const u8, cls("NSString"), sel("stringWithUTF8String:"), cstr);
}

fn makeNSStringSlice(s: []const u8) Id {
    var buf: [256]u8 = undefined;
    const len = @min(s.len, buf.len - 1);
    @memcpy(buf[0..len], s[0..len]);
    buf[len] = 0;
    return makeNSString(buf[0..len :0]);
}

/// Translates macOS Carbon/Cocoa virtual keycode (`NSEvent.keyCode`, `kVK_*`) to Linux `evdev` keycode.
pub fn macosKeycodeToEvdev(mac_kc: u16) ?u32 {
    return switch (mac_kc) {
        0x00 => 30, // kVK_ANSI_A -> KEY_A
        0x01 => 31, // kVK_ANSI_S -> KEY_S
        0x02 => 32, // kVK_ANSI_D -> KEY_D
        0x03 => 33, // kVK_ANSI_F -> KEY_F
        0x04 => 35, // kVK_ANSI_H -> KEY_H
        0x05 => 34, // kVK_ANSI_G -> KEY_G
        0x06 => 44, // kVK_ANSI_Z -> KEY_Z
        0x07 => 45, // kVK_ANSI_X -> KEY_X
        0x08 => 46, // kVK_ANSI_C -> KEY_C
        0x09 => 47, // kVK_ANSI_V -> KEY_V
        0x0A => 86, // kVK_ISO_Section -> KEY_102ND
        0x0B => 48, // kVK_ANSI_B -> KEY_B
        0x0C => 16, // kVK_ANSI_Q -> KEY_Q
        0x0D => 17, // kVK_ANSI_W -> KEY_W
        0x0E => 18, // kVK_ANSI_E -> KEY_E
        0x0F => 19, // kVK_ANSI_R -> KEY_R
        0x10 => 21, // kVK_ANSI_Y -> KEY_Y
        0x11 => 20, // kVK_ANSI_T -> KEY_T
        0x12 => 2, // kVK_ANSI_1 -> KEY_1
        0x13 => 3, // kVK_ANSI_2 -> KEY_2
        0x14 => 4, // kVK_ANSI_3 -> KEY_3
        0x15 => 5, // kVK_ANSI_4 -> KEY_4
        0x16 => 7, // kVK_ANSI_6 -> KEY_6
        0x17 => 6, // kVK_ANSI_5 -> KEY_5
        0x18 => 13, // kVK_ANSI_Equal -> KEY_EQUAL
        0x19 => 10, // kVK_ANSI_9 -> KEY_9
        0x1A => 8, // kVK_ANSI_7 -> KEY_7
        0x1B => 12, // kVK_ANSI_Minus -> KEY_MINUS
        0x1C => 9, // kVK_ANSI_8 -> KEY_8
        0x1D => 11, // kVK_ANSI_0 -> KEY_0
        0x1E => 27, // kVK_ANSI_RightBracket -> KEY_RIGHTBRACE
        0x1F => 24, // kVK_ANSI_O -> KEY_O
        0x20 => 22, // kVK_ANSI_U -> KEY_U
        0x21 => 26, // kVK_ANSI_LeftBracket -> KEY_LEFTBRACE
        0x22 => 23, // kVK_ANSI_I -> KEY_I
        0x23 => 25, // kVK_ANSI_P -> KEY_P
        0x24 => 28, // kVK_Return -> KEY_ENTER
        0x25 => 38, // kVK_ANSI_L -> KEY_L
        0x26 => 36, // kVK_ANSI_J -> KEY_J
        0x27 => 40, // kVK_ANSI_Quote -> KEY_APOSTROPHE
        0x28 => 37, // kVK_ANSI_K -> KEY_K
        0x29 => 39, // kVK_ANSI_Semicolon -> KEY_SEMICOLON
        0x2A => 43, // kVK_ANSI_Backslash -> KEY_BACKSLASH
        0x2B => 51, // kVK_ANSI_Comma -> KEY_COMMA
        0x2C => 53, // kVK_ANSI_Slash -> KEY_SLASH
        0x2D => 49, // kVK_ANSI_N -> KEY_N
        0x2E => 50, // kVK_ANSI_M -> KEY_M
        0x2F => 52, // kVK_ANSI_Period -> KEY_DOT
        0x30 => 15, // kVK_Tab -> KEY_TAB
        0x31 => 57, // kVK_Space -> KEY_SPACE
        0x32 => 41, // kVK_ANSI_Grave -> KEY_GRAVE
        0x33 => 14, // kVK_Delete -> KEY_BACKSPACE
        0x35 => 1, // kVK_Escape -> KEY_ESC
        0x36 => 126, // kVK_RightCommand -> KEY_RIGHTMETA
        0x37 => 125, // kVK_Command -> KEY_LEFTMETA
        0x38 => 42, // kVK_Shift -> KEY_LEFTSHIFT
        0x39 => 58, // kVK_CapsLock -> KEY_CAPSLOCK
        0x3A => 56, // kVK_Option -> KEY_LEFTALT
        0x3B => 29, // kVK_Control -> KEY_LEFTCTRL
        0x3C => 54, // kVK_RightShift -> KEY_RIGHTSHIFT
        0x3D => 100, // kVK_RightOption -> KEY_RIGHTALT
        0x3E => 97, // kVK_RightControl -> KEY_RIGHTCTRL
        0x41 => 83, // kVK_ANSI_KeypadDecimal -> KEY_KPDOT
        0x43 => 55, // kVK_ANSI_KeypadMultiply -> KEY_KPASTERISK
        0x45 => 78, // kVK_ANSI_KeypadPlus -> KEY_KPPLUS
        0x47 => 69, // kVK_ANSI_KeypadClear -> KEY_NUMLOCK
        0x4B => 98, // kVK_ANSI_KeypadDivide -> KEY_KPSLASH
        0x4C => 96, // kVK_ANSI_KeypadEnter -> KEY_KPENTER
        0x4E => 74, // kVK_ANSI_KeypadMinus -> KEY_KPMINUS
        0x51 => 117, // kVK_ANSI_KeypadEquals -> KEY_KPEQUAL
        0x52 => 82, // kVK_ANSI_Keypad0 -> KEY_KP0
        0x53 => 79, // kVK_ANSI_Keypad1 -> KEY_KP1
        0x54 => 80, // kVK_ANSI_Keypad2 -> KEY_KP2
        0x55 => 81, // kVK_ANSI_Keypad3 -> KEY_KP3
        0x56 => 75, // kVK_ANSI_Keypad4 -> KEY_KP4
        0x57 => 76, // kVK_ANSI_Keypad5 -> KEY_KP5
        0x58 => 77, // kVK_ANSI_Keypad6 -> KEY_KP6
        0x59 => 71, // kVK_ANSI_Keypad7 -> KEY_KP7
        0x5B => 72, // kVK_ANSI_Keypad8 -> KEY_KP8
        0x5C => 73, // kVK_ANSI_Keypad9 -> KEY_KP9
        0x60 => 63, // kVK_F5 -> KEY_F5
        0x61 => 64, // kVK_F6 -> KEY_F6
        0x62 => 65, // kVK_F7 -> KEY_F7
        0x63 => 61, // kVK_F3 -> KEY_F3
        0x64 => 66, // kVK_F8 -> KEY_F8
        0x65 => 67, // kVK_F9 -> KEY_F9
        0x67 => 87, // kVK_F11 -> KEY_F11
        0x69 => 99, // kVK_F13 -> KEY_SYSRQ
        0x6D => 68, // kVK_F10 -> KEY_F10
        0x6F => 88, // kVK_F12 -> KEY_F12
        0x72 => 110, // kVK_Help / Insert -> KEY_INSERT
        0x73 => 102, // kVK_Home -> KEY_HOME
        0x74 => 104, // kVK_PageUp -> KEY_PAGEUP
        0x75 => 111, // kVK_ForwardDelete -> KEY_DELETE
        0x76 => 62, // kVK_F4 -> KEY_F4
        0x77 => 107, // kVK_End -> KEY_END
        0x78 => 60, // kVK_F2 -> KEY_F2
        0x79 => 109, // kVK_PageDown -> KEY_PAGEDOWN
        0x7A => 59, // kVK_F1 -> KEY_F1
        0x7B => 105, // kVK_LeftArrow -> KEY_LEFT
        0x7C => 106, // kVK_RightArrow -> KEY_RIGHT
        0x7D => 108, // kVK_DownArrow -> KEY_DOWN
        0x7E => 103, // kVK_UpArrow -> KEY_UP
        else => null,
    };
}

test "macosKeycodeToEvdev maps macOS virtual keycodes to Linux evdev keycodes" {
    const testing = std.testing;
    try testing.expectEqual(@as(?u32, 30), macosKeycodeToEvdev(0x00)); // A
    try testing.expectEqual(@as(?u32, 44), macosKeycodeToEvdev(0x06)); // Z
    try testing.expectEqual(@as(?u32, 2), macosKeycodeToEvdev(0x12)); // 1
    try testing.expectEqual(@as(?u32, 11), macosKeycodeToEvdev(0x1D)); // 0
    try testing.expectEqual(@as(?u32, 28), macosKeycodeToEvdev(0x24)); // Return
    try testing.expectEqual(@as(?u32, 14), macosKeycodeToEvdev(0x33)); // Backspace
    try testing.expectEqual(@as(?u32, 1), macosKeycodeToEvdev(0x35)); // Escape
    try testing.expectEqual(@as(?u32, 42), macosKeycodeToEvdev(0x38)); // Left Shift
    try testing.expectEqual(@as(?u32, 105), macosKeycodeToEvdev(0x7B)); // Left Arrow
    try testing.expectEqual(@as(?u32, 106), macosKeycodeToEvdev(0x7C)); // Right Arrow
    try testing.expectEqual(@as(?u32, null), macosKeycodeToEvdev(0xFFFF));
    if (builtin.os.tag == .macos) {
        _ = MacosWindow;
    }
}
