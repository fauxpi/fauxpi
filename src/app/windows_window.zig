//! Native Windows (`Win32` + `GDI`) desktop window backend for `fauxpi`.
//!
//! Uses a Per-Monitor DPI v2 client-side-decorated window (`WS_POPUP | WS_MINIMIZEBOX | WS_SYSMENU`)
//! so `BoardUi`'s 44px TitleBar (Board toggle button, centered title, and Maximize/Close buttons)
//! renders at crisp native resolution alongside the HDMI display and GPIO status panel.

const std = @import("std");
const builtin = @import("builtin");
const host_posix = @import("../host/posix.zig");
const UsbHidComposite = @import("../usb/hid.zig").UsbHidComposite;
const Gpio = @import("../soc/gpio.zig").Gpio;
const board_sheet = @import("../ui/board_sheet.zig");

const HWND = ?*anyopaque;
const HINSTANCE = ?*anyopaque;
const HICON = ?*anyopaque;
const HCURSOR = ?*anyopaque;
const HBRUSH = ?*anyopaque;
const HMENU = ?*anyopaque;
const HDC = ?*anyopaque;
const HBITMAP = ?*anyopaque;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;

const WNDPROC = *const fn (HWND, u32, WPARAM, LPARAM) callconv(.c) LRESULT;

const WNDCLASSEXA = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXA),
    style: u32 = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: HINSTANCE = null,
    hIcon: HICON = null,
    hCursor: HCURSOR = null,
    hbrBackground: HBRUSH = null,
    lpszMenuName: ?[*:0]const u8 = null,
    lpszClassName: [*:0]const u8,
    hIconSm: HICON = null,
};

const POINT = extern struct {
    x: i32,
    y: i32,
};

const MSG = extern struct {
    hwnd: HWND,
    message: u32,
    wParam: WPARAM,
    lParam: LPARAM,
    time: u32,
    pt: POINT,
    lPrivate: u32 = 0,
};

const BITMAPINFOHEADER = extern struct {
    biSize: u32 = @sizeOf(BITMAPINFOHEADER),
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16 = 1,
    biBitCount: u16 = 32,
    biCompression: u32 = 0, // BI_RGB
    biSizeImage: u32 = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: u32 = 0,
    biClrImportant: u32 = 0,
};

const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER,
    bmiColors: [1]u32 = .{0},
};

const ICONINFO = extern struct {
    fIcon: i32,
    xHotspot: u32,
    yHotspot: u32,
    hbmMask: HBITMAP,
    hbmColor: HBITMAP,
};

const OPENFILENAMEA = extern struct {
    lStructSize: u32 = @sizeOf(OPENFILENAMEA),
    hwndOwner: HWND = null,
    hInstance: HINSTANCE = null,
    lpstrFilter: ?[*:0]const u8 = null,
    lpstrCustomFilter: ?[*]u8 = null,
    nMaxCustFilter: u32 = 0,
    nFilterIndex: u32 = 1,
    lpstrFile: [*]u8,
    nMaxFile: u32,
    lpstrFileTitle: ?[*]u8 = null,
    nMaxFileTitle: u32 = 0,
    lpstrInitialDir: ?[*:0]const u8 = null,
    lpstrTitle: ?[*:0]const u8 = null,
    Flags: u32 = 0,
    nFileOffset: u16 = 0,
    nFileExtension: u16 = 0,
    lpstrDefExt: ?[*:0]const u8 = null,
    lCustData: isize = 0,
    lpfnHook: ?*const anyopaque = null,
    lpTemplateName: ?[*:0]const u8 = null,
    pvReserved: ?*anyopaque = null,
    dwReserved: u32 = 0,
    FlagsEx: u32 = 0,
};

// Win32 Window Styles & Messages
const WS_POPUP: u32 = 0x80000000;
const WS_VISIBLE: u32 = 0x10000000;
const WS_CLIPSIBLINGS: u32 = 0x04000000;
const WS_CLIPCHILDREN: u32 = 0x02000000;
const WS_SYSMENU: u32 = 0x00080000;
const WS_MINIMIZEBOX: u32 = 0x00020000;
const WS_MAXIMIZEBOX: u32 = 0x00010000;

const SW_SHOW: i32 = 5;
const SW_MAXIMIZE: i32 = 3;
const SW_RESTORE: i32 = 9;
const PM_REMOVE: u32 = 0x0001;
const QS_ALLINPUT: u32 = 0x04FF;

const SM_CXSCREEN: i32 = 0;
const SM_CYSCREEN: i32 = 1;
const HWND_TOP: HWND = null;
const SWP_NOMOVE: u32 = 0x0002;
const SWP_NOZORDER: u32 = 0x0004;
const SWP_NOACTIVATE: u32 = 0x0010;

const WM_DESTROY: u32 = 0x0002;
const WM_ACTIVATE: u32 = 0x0006;
const WM_KILLFOCUS: u32 = 0x0008;
const WM_PAINT: u32 = 0x000F;
const WM_CLOSE: u32 = 0x0010;
const WM_Quit: u32 = 0x0012;
const WM_ERASEBKGND: u32 = 0x0014;
const WM_SETCURSOR: u32 = 0x0020;
const WM_NCLBUTTONDOWN: u32 = 0x00A1;
const WM_KEYDOWN: u32 = 0x0100;
const WM_KEYUP: u32 = 0x0101;
const WM_SYSKEYDOWN: u32 = 0x0104;
const WM_SYSKEYUP: u32 = 0x0105;
const WM_MOUSEMOVE: u32 = 0x0200;
const WM_LBUTTONDOWN: u32 = 0x0201;
const WM_LBUTTONUP: u32 = 0x0202;
const WM_RBUTTONDOWN: u32 = 0x0204;
const WM_RBUTTONUP: u32 = 0x0205;
const WM_MBUTTONDOWN: u32 = 0x0207;
const WM_MBUTTONUP: u32 = 0x0208;
const WM_MOUSEWHEEL: u32 = 0x020A;
const WM_DPICHANGED: u32 = 0x02E0;

const HTCLIENT: usize = 1;
const HTCAPTION: WPARAM = 2;
const WA_INACTIVE: usize = 0;

const OFN_PATHMUSTEXIST: u32 = 0x00000800;
const OFN_FILEMUSTEXIST: u32 = 0x00001000;
const OFN_NOCHANGEDIR: u32 = 0x00000008;

extern "kernel32" fn GetModuleHandleA(lpModuleName: ?[*:0]const u8) HINSTANCE;

const Win32Api = struct {
    user32: host_posix.DynLib,
    gdi32: host_posix.DynLib,

    RegisterClassExA: *const fn (*const WNDCLASSEXA) callconv(.c) u16,
    CreateWindowExA: *const fn (
        u32,
        [*:0]const u8,
        [*:0]const u8,
        u32,
        i32,
        i32,
        i32,
        i32,
        HWND,
        HMENU,
        HINSTANCE,
        ?*anyopaque,
    ) callconv(.c) HWND,
    DestroyWindow: *const fn (HWND) callconv(.c) i32,
    ShowWindow: *const fn (HWND, i32) callconv(.c) i32,
    SetWindowPos: *const fn (HWND, HWND, i32, i32, i32, i32, u32) callconv(.c) i32,
    SetWindowTextA: *const fn (HWND, [*:0]const u8) callconv(.c) i32,
    DefWindowProcA: *const fn (HWND, u32, WPARAM, LPARAM) callconv(.c) LRESULT,
    PeekMessageA: *const fn (*MSG, HWND, u32, u32, u32) callconv(.c) i32,
    TranslateMessage: *const fn (*const MSG) callconv(.c) i32,
    DispatchMessageA: *const fn (*const MSG) callconv(.c) LRESULT,
    MsgWaitForMultipleObjects: *const fn (u32, ?*const anyopaque, i32, u32, u32) callconv(.c) u32,
    GetDC: *const fn (HWND) callconv(.c) HDC,
    ReleaseDC: *const fn (HWND, HDC) callconv(.c) i32,
    ValidateRect: *const fn (HWND, ?*const anyopaque) callconv(.c) i32,
    GetSystemMetrics: *const fn (i32) callconv(.c) i32,
    LoadCursorA: *const fn (HINSTANCE, usize) callconv(.c) HCURSOR,
    SetCursor: *const fn (HCURSOR) callconv(.c) HCURSOR,
    CreateIconIndirect: *const fn (*const ICONINFO) callconv(.c) HICON,
    DestroyIcon: *const fn (HICON) callconv(.c) i32,
    ReleaseCapture: *const fn () callconv(.c) i32,
    SendMessageA: *const fn (HWND, u32, WPARAM, LPARAM) callconv(.c) LRESULT,
    GetKeyboardState: *const fn (*[256]u8) callconv(.c) i32,
    ToUnicode: *const fn (u32, u32, *const [256]u8, [*]u16, i32, u32) callconv(.c) i32,
    SetProcessDpiAwarenessContext: ?*const fn (isize) callconv(.c) i32,
    GetDpiForWindow: ?*const fn (HWND) callconv(.c) u32,

    SetDIBitsToDevice: *const fn (
        HDC,
        i32,
        i32,
        u32,
        u32,
        i32,
        i32,
        u32,
        u32,
        *const anyopaque,
        *const BITMAPINFO,
        u32,
    ) callconv(.c) i32,
    CreateDIBSection: *const fn (
        HDC,
        *const BITMAPINFO,
        u32,
        *?*anyopaque,
        ?*anyopaque,
        u32,
    ) callconv(.c) HBITMAP,
    CreateBitmap: *const fn (i32, i32, u32, u32, ?*const anyopaque) callconv(.c) HBITMAP,
    DeleteObject: *const fn (?*anyopaque) callconv(.c) i32,
};

var win32_api: ?Win32Api = null;
var active_windows_window: ?*WindowsWindow = null;
var window_class_registered: bool = false;

fn ensureWin32Loaded() !*const Win32Api {
    if (win32_api) |*api| return api;

    var user32 = try host_posix.DynLib.open("user32.dll");
    errdefer user32.close();

    var gdi32 = try host_posix.DynLib.open("gdi32.dll");
    errdefer gdi32.close();

    win32_api = .{
        .user32 = user32,
        .gdi32 = gdi32,
        .RegisterClassExA = user32.lookup(*const fn (*const WNDCLASSEXA) callconv(.c) u16, "RegisterClassExA") orelse return error.SymbolNotFound,
        .CreateWindowExA = user32.lookup(
            *const fn (u32, [*:0]const u8, [*:0]const u8, u32, i32, i32, i32, i32, HWND, HMENU, HINSTANCE, ?*anyopaque) callconv(.c) HWND,
            "CreateWindowExA",
        ) orelse return error.SymbolNotFound,
        .DestroyWindow = user32.lookup(*const fn (HWND) callconv(.c) i32, "DestroyWindow") orelse return error.SymbolNotFound,
        .ShowWindow = user32.lookup(*const fn (HWND, i32) callconv(.c) i32, "ShowWindow") orelse return error.SymbolNotFound,
        .SetWindowPos = user32.lookup(*const fn (HWND, HWND, i32, i32, i32, i32, u32) callconv(.c) i32, "SetWindowPos") orelse return error.SymbolNotFound,
        .SetWindowTextA = user32.lookup(*const fn (HWND, [*:0]const u8) callconv(.c) i32, "SetWindowTextA") orelse return error.SymbolNotFound,
        .DefWindowProcA = user32.lookup(*const fn (HWND, u32, WPARAM, LPARAM) callconv(.c) LRESULT, "DefWindowProcA") orelse return error.SymbolNotFound,
        .PeekMessageA = user32.lookup(*const fn (*MSG, HWND, u32, u32, u32) callconv(.c) i32, "PeekMessageA") orelse return error.SymbolNotFound,
        .TranslateMessage = user32.lookup(*const fn (*const MSG) callconv(.c) i32, "TranslateMessage") orelse return error.SymbolNotFound,
        .DispatchMessageA = user32.lookup(*const fn (*const MSG) callconv(.c) LRESULT, "DispatchMessageA") orelse return error.SymbolNotFound,
        .MsgWaitForMultipleObjects = user32.lookup(*const fn (u32, ?*const anyopaque, i32, u32, u32) callconv(.c) u32, "MsgWaitForMultipleObjects") orelse return error.SymbolNotFound,
        .GetDC = user32.lookup(*const fn (HWND) callconv(.c) HDC, "GetDC") orelse return error.SymbolNotFound,
        .ReleaseDC = user32.lookup(*const fn (HWND, HDC) callconv(.c) i32, "ReleaseDC") orelse return error.SymbolNotFound,
        .ValidateRect = user32.lookup(*const fn (HWND, ?*const anyopaque) callconv(.c) i32, "ValidateRect") orelse return error.SymbolNotFound,
        .GetSystemMetrics = user32.lookup(*const fn (i32) callconv(.c) i32, "GetSystemMetrics") orelse return error.SymbolNotFound,
        .LoadCursorA = user32.lookup(*const fn (HINSTANCE, usize) callconv(.c) HCURSOR, "LoadCursorA") orelse return error.SymbolNotFound,
        .SetCursor = user32.lookup(*const fn (HCURSOR) callconv(.c) HCURSOR, "SetCursor") orelse return error.SymbolNotFound,
        .CreateIconIndirect = user32.lookup(*const fn (*const ICONINFO) callconv(.c) HICON, "CreateIconIndirect") orelse return error.SymbolNotFound,
        .DestroyIcon = user32.lookup(*const fn (HICON) callconv(.c) i32, "DestroyIcon") orelse return error.SymbolNotFound,
        .ReleaseCapture = user32.lookup(*const fn () callconv(.c) i32, "ReleaseCapture") orelse return error.SymbolNotFound,
        .SendMessageA = user32.lookup(*const fn (HWND, u32, WPARAM, LPARAM) callconv(.c) LRESULT, "SendMessageA") orelse return error.SymbolNotFound,
        .GetKeyboardState = user32.lookup(*const fn (*[256]u8) callconv(.c) i32, "GetKeyboardState") orelse return error.SymbolNotFound,
        .ToUnicode = user32.lookup(*const fn (u32, u32, *const [256]u8, [*]u16, i32, u32) callconv(.c) i32, "ToUnicode") orelse return error.SymbolNotFound,
        .SetProcessDpiAwarenessContext = user32.lookup(*const fn (isize) callconv(.c) i32, "SetProcessDpiAwarenessContext"),
        .GetDpiForWindow = user32.lookup(*const fn (HWND) callconv(.c) u32, "GetDpiForWindow"),
        .SetDIBitsToDevice = gdi32.lookup(
            *const fn (HDC, i32, i32, u32, u32, i32, i32, u32, u32, *const anyopaque, *const BITMAPINFO, u32) callconv(.c) i32,
            "SetDIBitsToDevice",
        ) orelse return error.SymbolNotFound,
        .CreateDIBSection = gdi32.lookup(
            *const fn (HDC, *const BITMAPINFO, u32, *?*anyopaque, ?*anyopaque, u32) callconv(.c) HBITMAP,
            "CreateDIBSection",
        ) orelse return error.SymbolNotFound,
        .CreateBitmap = gdi32.lookup(*const fn (i32, i32, u32, u32, ?*const anyopaque) callconv(.c) HBITMAP, "CreateBitmap") orelse return error.SymbolNotFound,
        .DeleteObject = gdi32.lookup(*const fn (?*anyopaque) callconv(.c) i32, "DeleteObject") orelse return error.SymbolNotFound,
    };
    return &win32_api.?;
}

fn windowProc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) callconv(.c) LRESULT {
    const api = &(win32_api orelse return 0);
    if (active_windows_window) |w| {
        if (w.handleWndProc(hwnd, msg, wparam, lparam)) |res| {
            return res;
        }
    }
    return api.DefWindowProcA(hwnd, msg, wparam, lparam);
}

pub const WindowsWindow = struct {
    gpa: std.mem.Allocator,
    hwnd: HWND = null,
    arrow_cursor: HCURSOR = null,
    crosshair_cursor: HCURSOR = null,

    /// Logical HDMI display size (e.g. 1280 x 720)
    display_width: u32,
    display_height: u32,
    /// Logical window size (`display_width` x `display_height + 44 [+ gpio_panel_height]`)
    width: u32,
    height: u32,
    /// HiDPI buffer scale factor (`1` at 96 DPI, `2` at 192 DPI, etc.)
    scale: u32 = 1,
    pending_scale: u32 = 1,

    /// 1x simulated HDMI framebuffer (`display_width * display_height`)
    hdmi_fb: []u32,
    /// Physical window backbuffer (`(width * scale) * (height * scale)`)
    backbuffer: []u32 = &.{},
    hdmi_gen: u64 = 1,
    backbuf_hdmi_gen: u64 = 0,
    backbuf_had_sheet: bool = false,
    backbuf_hdmi_state: u2 = 0,
    backbuf_sheet_rect: board_sheet.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    closed: bool = false,
    ui_dirty: bool = true,
    power_reconnected: bool = false,
    sd_disconnected: bool = false,
    sd_reconnected: bool = false,
    sd_image_chosen: bool = false,
    chosen_sd_path_buf: [std.fs.max_path_bytes]u8 = undefined,
    chosen_sd_path_len: usize = 0,

    last_mouse_x: ?f64 = null,
    last_mouse_y: ?f64 = null,
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
    ) !*WindowsWindow {
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

        const win = try gpa.create(WindowsWindow);
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

        active_windows_window = win;
        try win.initWin32Window();
        try win.initBackbuffer();
        return win;
    }

    pub fn destroy(self: *WindowsWindow) void {
        if (active_windows_window == self) {
            active_windows_window = null;
        }
        self.ui.saveSettings(self.status) catch {};
        self.ui.deinit();
        if (self.backbuffer.len > 0) {
            self.gpa.free(self.backbuffer);
        }
        self.gpa.free(self.hdmi_fb);
        if (win32_api) |*api| {
            if (self.crosshair_cursor) |cur| {
                _ = api.DestroyIcon(cur);
                self.crosshair_cursor = null;
            }
            if (self.hwnd) |h| {
                _ = api.DestroyWindow(h);
                self.hwnd = null;
            }
        }
        self.gpa.destroy(self);
    }

    fn initWin32Window(self: *WindowsWindow) !void {
        const api = try ensureWin32Loaded();

        if (api.SetProcessDpiAwarenessContext) |set_dpi| {
            // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4
            _ = set_dpi(-4);
        }

        const hinst = GetModuleHandleA(null);
        self.arrow_cursor = api.LoadCursorA(null, 32512); // IDC_ARROW = 32512
        self.crosshair_cursor = self.createCrosshairCursor(api);

        const class_name = "FauxPiWindowClass";
        if (!window_class_registered) {
            const wc: WNDCLASSEXA = .{
                .lpfnWndProc = windowProc,
                .hInstance = hinst,
                .hCursor = self.arrow_cursor,
                .lpszClassName = class_name,
            };
            _ = api.RegisterClassExA(&wc);
            window_class_registered = true;
        }

        var title_z: [128]u8 = undefined;
        const tlen = @min(self.ui.title.len, title_z.len - 1);
        @memcpy(title_z[0..tlen], self.ui.title[0..tlen]);
        title_z[tlen] = 0;

        const screen_w = api.GetSystemMetrics(SM_CXSCREEN);
        const screen_h = api.GetSystemMetrics(SM_CYSCREEN);
        const init_w: i32 = @intCast(self.width);
        const init_h: i32 = @intCast(self.height);
        const pos_x: i32 = @max(0, @divTrunc(screen_w - init_w, 2));
        const pos_y: i32 = @max(0, @divTrunc(screen_h - init_h, 2));

        const style = WS_POPUP | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU | WS_CLIPCHILDREN | WS_CLIPSIBLINGS | WS_VISIBLE;
        const hwnd = api.CreateWindowExA(
            0,
            class_name,
            title_z[0..tlen :0],
            style,
            pos_x,
            pos_y,
            init_w,
            init_h,
            null,
            null,
            hinst,
            null,
        ) orelse return error.Win32WindowCreateFailed;
        self.hwnd = hwnd;

        self.queryWindowDpiScale(api);
        if (self.pending_scale > 1) {
            self.scale = self.pending_scale;
            const phys_w: i32 = @intCast(self.width * self.scale);
            const phys_h: i32 = @intCast(self.height * self.scale);
            const cx: i32 = @max(0, @divTrunc(screen_w - phys_w, 2));
            const cy: i32 = @max(0, @divTrunc(screen_h - phys_h, 2));
            _ = api.SetWindowPos(hwnd, HWND_TOP, cx, cy, phys_w, phys_h, SWP_NOZORDER | SWP_NOACTIVATE);
        }
        _ = api.ShowWindow(hwnd, SW_SHOW);
    }

    fn queryWindowDpiScale(self: *WindowsWindow, api: *const Win32Api) void {
        const hwnd = self.hwnd orelse return;
        if (api.GetDpiForWindow) |get_dpi| {
            const dpi = get_dpi(hwnd);
            if (dpi >= 96 and dpi <= 384) {
                const new_scale: u32 = @max(@as(u32, @intCast((dpi + 48) / 96)), 1);
                if (self.pending_scale != new_scale) {
                    self.pending_scale = new_scale;
                    self.ui_dirty = true;
                }
            }
        }
    }

    fn createCrosshairCursor(_: *WindowsWindow, api: *const Win32Api) HCURSOR {
        const dim: usize = 24;
        const bmi: BITMAPINFO = .{
            .bmiHeader = .{
                .biWidth = @intCast(dim),
                .biHeight = -@as(i32, @intCast(dim)), // top-down
                .biBitCount = 32,
            },
        };
        var bits_ptr: ?*anyopaque = null;
        const hbm_color = api.CreateDIBSection(null, &bmi, 0, &bits_ptr, null, 0) orelse return null;
        defer _ = api.DeleteObject(hbm_color);
        const bits = bits_ptr orelse return null;
        const pixels: []u32 = @as([*]u32, @ptrCast(@alignCast(bits)))[0 .. dim * dim];
        @import("window.zig").paintFaintCrosshairCursor(pixels, 1);

        var mask_bytes: [dim * 4]u8 = @splat(0);
        const hbm_mask = api.CreateBitmap(@intCast(dim), @intCast(dim), 1, 1, &mask_bytes) orelse return null;
        defer _ = api.DeleteObject(hbm_mask);

        const ii: ICONINFO = .{
            .fIcon = 0, // FALSE = cursor
            .xHotspot = 12,
            .yHotspot = 12,
            .hbmMask = hbm_mask,
            .hbmColor = hbm_color,
        };
        return api.CreateIconIndirect(&ii);
    }

    fn initBackbuffer(self: *WindowsWindow) !void {
        if (self.backbuffer.len > 0) {
            self.gpa.free(self.backbuffer);
            self.backbuffer = &.{};
        }
        const sc = @max(self.scale, 1);
        const count = @as(usize, self.width * sc) * @as(usize, self.height * sc);
        self.backbuffer = try self.gpa.alloc(u32, count);
        @memset(self.backbuffer, 0xFF101418);
        self.backbuf_hdmi_gen = 0;
        self.backbuf_had_sheet = false;
        self.backbuf_hdmi_state = 0;
        self.backbuf_sheet_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        self.cursor_mode = .unknown;
        self.ui_dirty = true;
    }

    pub fn backbufferPixels(self: *WindowsWindow) []u32 {
        return self.backbuffer;
    }

    pub fn displayPixels(self: *WindowsWindow) []u32 {
        return self.hdmi_fb;
    }

    pub fn notifyHdmiUpdated(self: *WindowsWindow) void {
        self.hdmi_gen +%= 1;
        if (self.hdmi_gen == 0) self.hdmi_gen = 1;
    }

    pub fn chosenSdPath(self: *const WindowsWindow) []const u8 {
        return self.chosen_sd_path_buf[0..self.chosen_sd_path_len];
    }

    pub fn compositeUi(self: *WindowsWindow) void {
        self.ui_dirty = false;
        if (win32_api) |*api| {
            self.queryWindowDpiScale(api);
        }

        const desired_h = self.display_height + board_sheet.BoardUi.title_bar_height +
            (if (self.status.gpio_connected) board_sheet.BoardUi.gpio_panel_height else 0);
        if ((self.pending_scale != self.scale and self.pending_scale >= 1) or self.height != desired_h) {
            if (self.pending_scale >= 1) self.scale = self.pending_scale;
            self.height = desired_h;
            self.initBackbuffer() catch {};
            if (win32_api) |*api| {
                if (self.hwnd) |hwnd| {
                    const sc = @max(self.scale, 1);
                    _ = api.SetWindowPos(
                        hwnd,
                        HWND_TOP,
                        0,
                        0,
                        @intCast(self.width * sc),
                        @intCast(self.height * sc),
                        SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE,
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

        self.ui.updateLayout(self.width, self.height, self.status, self.gpio);
        const has_overlay = self.ui.sheet_open or self.ui.hasSnackbar();
        const hdmi_state: u2 = (@as(u2, @intFromBool(self.status.hdmi_connected)) |
            (@as(u2, @intFromBool(self.status.hdmi_active)) << 1));
        const same_sheet_backdrop = self.ui.sheet_open and !self.ui.hasSnackbar() and
            self.backbuf_had_sheet and
            self.backbuf_hdmi_state == hdmi_state and
            std.meta.eql(self.backbuf_sheet_rect, self.ui.sheet_rect);

        var reuse_dimmed_backdrop = false;
        if (self.status.hdmi_connected and self.status.hdmi_active) {
            if (same_sheet_backdrop and self.backbuf_hdmi_gen == self.hdmi_gen) {
                reuse_dimmed_backdrop = true;
            } else {
                const need_hdmi_blit = (self.backbuf_hdmi_gen != self.hdmi_gen) or
                    has_overlay or
                    self.backbuf_had_sheet or
                    (self.backbuf_hdmi_state != hdmi_state);
                if (need_hdmi_blit) {
                    board_sheet.BoardUi.blitHdmiToBackbuffer(full, buf_w, top_phys_rows, self.hdmi_fb, dw, dh, sc);
                    self.backbuf_hdmi_gen = self.hdmi_gen;
                }
            }
        } else {
            self.backbuf_hdmi_gen = 0;
            if (same_sheet_backdrop) {
                reuse_dimmed_backdrop = true;
            }
        }
        self.backbuf_had_sheet = has_overlay;
        self.backbuf_hdmi_state = hdmi_state;
        self.backbuf_sheet_rect = if (self.ui.sheet_open and !self.ui.hasSnackbar())
            self.ui.sheet_rect
        else
            .{ .x = 0, .y = 0, .w = 0, .h = 0 };

        self.ui.paintWithBackdrop(full, self.width, self.height, sc, self.status, self.gpio, reuse_dimmed_backdrop);
    }

    pub fn present(self: *WindowsWindow) !void {
        self.blitBackbufferToWindow();
        try self.pollEvents();
    }

    fn blitBackbufferToWindow(self: *WindowsWindow) void {
        const api = &(win32_api orelse return);
        const hwnd = self.hwnd orelse return;
        const sc = @max(self.scale, 1);
        const buf_w: u32 = self.width * sc;
        const buf_h: u32 = self.height * sc;
        if (self.backbuffer.len < @as(usize, buf_w) * @as(usize, buf_h)) return;

        const hdc = api.GetDC(hwnd) orelse return;
        defer _ = api.ReleaseDC(hwnd, hdc);

        const bmi: BITMAPINFO = .{
            .bmiHeader = .{
                .biWidth = @intCast(buf_w),
                .biHeight = -@as(i32, @intCast(buf_h)), // top-down
                .biBitCount = 32,
            },
        };
        _ = api.SetDIBitsToDevice(
            hdc,
            0,
            0,
            buf_w,
            buf_h,
            0,
            0,
            0,
            buf_h,
            self.backbuffer.ptr,
            &bmi,
            0,
        );
    }

    pub fn pollEvents(self: *WindowsWindow) !void {
        self.pumpWin32Messages();
        self.pollAsyncSdCreation();
        self.serviceRepeat(host_posix.monotonicNs());
    }

    fn pollAsyncSdCreation(self: *WindowsWindow) void {
        switch (self.ui.pollAsyncSdCreation(host_posix.monotonicNs())) {
            .idle => {},
            .in_progress => {
                self.ui_dirty = true;
            },
            .completed_ok => {
                self.sd_image_chosen = true;
                self.ui_dirty = true;
                self.ui.saveSettings(self.status) catch {};
            },
            .completed_err => {
                self.ui_dirty = true;
            },
        }
    }

    pub fn waitEvents(self: *WindowsWindow, timeout_ms: i32) !void {
        const timeout_us: ?u64 = if (timeout_ms < 0) null else @as(u64, @intCast(timeout_ms)) * 1000;
        return self.waitEventsUs(timeout_us);
    }

    pub fn waitEventsUs(self: *WindowsWindow, timeout_us: ?u64) !void {
        const was_dirty = self.ui_dirty;
        self.pumpWin32Messages();
        self.pollAsyncSdCreation();
        const now_ns = host_posix.monotonicNs();
        self.serviceRepeat(now_ns);
        if (self.closed or (!was_dirty and self.ui_dirty)) return;
        if (self.hid) |h| {
            if (h.hasPendingInterruptIn()) return;
        }

        var eff_timeout_ms: u32 = if (timeout_us) |us|
            @intCast(@min((us + 999) / 1000, @as(u64, 16)))
        else
            16;
        if (self.repeatTimeoutMs(now_ns)) |rep_ms| {
            eff_timeout_ms = @min(eff_timeout_ms, @as(u32, @intCast(@max(rep_ms, 0))));
        }
        if (self.hid) |h| {
            if (h.isEthernetLinkUp()) {
                var net_fds: [32]host_posix.pollfd = undefined;
                const n = h.net.fillPollFds(&net_fds);
                if (n > 0) {
                    eff_timeout_ms = @min(eff_timeout_ms, 2);
                }
            }
        }

        if (eff_timeout_ms > 0) {
            if (win32_api) |*api| {
                _ = api.MsgWaitForMultipleObjects(0, null, 0, eff_timeout_ms, QS_ALLINPUT);
            }
        }
        self.pumpWin32Messages();
        self.pollAsyncSdCreation();
        self.serviceRepeat(host_posix.monotonicNs());
    }

    fn pumpWin32Messages(self: *WindowsWindow) void {
        const api = &(win32_api orelse return);
        var msg: MSG = undefined;
        while (api.PeekMessageA(&msg, null, 0, 0, PM_REMOVE) != 0) {
            if (msg.message == WM_Quit) {
                self.closed = true;
                self.ui_dirty = true;
                return;
            }
            _ = api.TranslateMessage(&msg);
            _ = api.DispatchMessageA(&msg);
        }
    }

    fn handleWndProc(self: *WindowsWindow, hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT {
        const api = &(win32_api orelse return null);
        switch (msg) {
            WM_CLOSE, WM_DESTROY => {
                self.closed = true;
                self.ui_dirty = true;
                return 0;
            },
            WM_ERASEBKGND => return 1,
            WM_PAINT => {
                self.blitBackbufferToWindow();
                _ = api.ValidateRect(hwnd, null);
                return 0;
            },
            WM_SETCURSOR => {
                const hit: usize = @as(usize, @bitCast(lparam)) & 0xFFFF;
                if (hit == HTCLIENT) {
                    const cur = switch (self.cursor_mode) {
                        .hdmi_crosshair => self.crosshair_cursor orelse self.arrow_cursor,
                        else => self.arrow_cursor,
                    };
                    _ = api.SetCursor(cur);
                    return 1;
                }
                return null;
            },
            WM_DPICHANGED => {
                const new_dpi: u32 = @truncate(wparam & 0xFFFF);
                if (new_dpi >= 96 and new_dpi <= 384) {
                    self.pending_scale = @max(@as(u32, @intCast((new_dpi + 48) / 96)), 1);
                    self.ui_dirty = true;
                }
                return 0;
            },
            WM_KILLFOCUS => {
                self.releaseAllHeldKeys();
                return 0;
            },
            WM_ACTIVATE => {
                if ((wparam & 0xFFFF) == WA_INACTIVE) {
                    self.releaseAllHeldKeys();
                }
                return 0;
            },
            WM_MOUSEMOVE => {
                const pt = self.clientCoordsToLogical(lparam);
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
                    if (self.ui.takeHoverDirty()) {
                        self.ui_dirty = true;
                    }
                }
                return 0;
            },
            WM_LBUTTONDOWN, WM_LBUTTONUP => {
                const pressed = (msg == WM_LBUTTONDOWN);
                const pt = self.clientCoordsToLogical(lparam);
                self.last_mouse_x = pt.x;
                self.last_mouse_y = pt.y;
                self.handleMouseButton(1 << 0, pressed, pt.x, pt.y);
                return 0;
            },
            WM_RBUTTONDOWN, WM_RBUTTONUP => {
                const pressed = (msg == WM_RBUTTONDOWN);
                const pt = self.clientCoordsToLogical(lparam);
                self.last_mouse_x = pt.x;
                self.last_mouse_y = pt.y;
                self.handleMouseButton(1 << 1, pressed, pt.x, pt.y);
                return 0;
            },
            WM_MBUTTONDOWN, WM_MBUTTONUP => {
                const pressed = (msg == WM_MBUTTONDOWN);
                const pt = self.clientCoordsToLogical(lparam);
                self.last_mouse_x = pt.x;
                self.last_mouse_y = pt.y;
                self.handleMouseButton(1 << 2, pressed, pt.x, pt.y);
                return 0;
            },
            WM_MOUSEWHEEL => {
                const delta_raw: i16 = @bitCast(@as(u16, @truncate((wparam >> 16) & 0xFFFF)));
                const sx: f32 = @floatCast(self.last_mouse_x orelse 0.0);
                const sy: f32 = @floatCast(self.last_mouse_y orelse 0.0);
                if (!self.ui.isPointInUi(sx, sy, self.status) and delta_raw != 0) {
                    if (self.hid) |h| {
                        const wheel: i8 = if (delta_raw > 0) 1 else -1;
                        h.handleMouseMotion(0, 0, wheel);
                    }
                }
                return 0;
            },
            WM_KEYDOWN, WM_SYSKEYDOWN, WM_KEYUP, WM_SYSKEYUP => {
                const pressed = (msg == WM_KEYDOWN or msg == WM_SYSKEYDOWN);
                const lp_u: usize = @bitCast(lparam);
                const scancode: u8 = @truncate((lp_u >> 16) & 0xFF);
                const extended: bool = ((lp_u >> 24) & 1) != 0;
                const is_repeat: bool = pressed and (((lp_u >> 30) & 1) != 0);
                const vk: u32 = @truncate(wparam & 0xFFFF);

                if (winScancodeToEvdev(scancode, extended, vk)) |evdev_key| {
                    if (pressed) {
                        self.updateKeymapFromWin32Key(api, vk, scancode, evdev_key);
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
                return 0;
            },
            else => return null,
        }
    }

    fn releaseAllHeldKeys(self: *WindowsWindow) void {
        self.repeat = null;
        self.keys_down = .initEmpty();
        self.ui.clearModifiers();
        if (self.hid) |h| {
            h.releaseAllKeys();
        }
    }

    fn clientCoordsToLogical(self: *const WindowsWindow, lparam: LPARAM) struct { x: f64, y: f64 } {
        const lp_u: usize = @bitCast(lparam);
        const px: i16 = @bitCast(@as(u16, @truncate(lp_u & 0xFFFF)));
        const py: i16 = @bitCast(@as(u16, @truncate((lp_u >> 16) & 0xFFFF)));
        const sc: f64 = @floatFromInt(@max(self.scale, 1));
        return .{
            .x = @as(f64, @floatFromInt(px)) / sc,
            .y = @as(f64, @floatFromInt(py)) / sc,
        };
    }

    fn updateKeymapFromWin32Key(self: *WindowsWindow, api: *const Win32Api, vk: u32, scancode: u8, evdev_key: u32) void {
        if (evdev_key >= 128) return;
        var kbd_state: [256]u8 = @splat(0);
        if (api.GetKeyboardState(&kbd_state) == 0) return;

        var utf16_buf: [4]u16 = @splat(0);
        const n = api.ToUnicode(vk, scancode, &kbd_state, &utf16_buf, 4, 0);
        if (n == 1 and utf16_buf[0] >= 0x20 and utf16_buf[0] < 0x7f) {
            const ch: u8 = @truncate(utf16_buf[0]);
            if (self.ui.shift_held or self.ui.xkb_shift) {
                self.ui.keymap.entries[evdev_key][1] = ch;
            } else {
                self.ui.keymap.entries[evdev_key][0] = ch;
            }
        }
    }

    fn updateCursorShape(self: *WindowsWindow, over_ui: bool) void {
        const target: @TypeOf(self.cursor_mode) = if (over_ui) .ui_arrow else .hdmi_crosshair;
        if (self.cursor_mode == target) return;
        self.cursor_mode = target;
        if (win32_api) |*api| {
            const cur = if (over_ui) self.arrow_cursor else (self.crosshair_cursor orelse self.arrow_cursor);
            _ = api.SetCursor(cur);
        }
    }

    fn updateGuestMouseTarget(self: *WindowsWindow, sx: f64, sy: f64) void {
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

    fn handleMouseButton(self: *WindowsWindow, button_bit: u8, pressed: bool, sx_f64: f64, sy_f64: f64) void {
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
                    if (win32_api) |*api| {
                        if (self.hwnd) |hwnd| {
                            _ = api.ReleaseCapture();
                            _ = api.SendMessageA(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
                        }
                    }
                    return;
                },
                .toggle_maximize => {
                    self.toggleMaximized();
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

    fn toggleMaximized(self: *WindowsWindow) void {
        self.ui.maximized = !self.ui.maximized;
        self.ui_dirty = true;
        if (win32_api) |*api| {
            if (self.hwnd) |hwnd| {
                _ = api.ShowWindow(hwnd, if (self.ui.maximized) SW_MAXIMIZE else SW_RESTORE);
            }
        }
    }

    fn openSdImagePicker(self: *WindowsWindow) void {
        var comdlg = host_posix.DynLib.open("comdlg32.dll") catch return;
        defer comdlg.close();
        const get_open_file = comdlg.lookup(
            *const fn (*OPENFILENAMEA) callconv(.c) i32,
            "GetOpenFileNameA",
        ) orelse return;

        var file_buf: [std.fs.max_path_bytes]u8 = @splat(0);
        const filter = "Disk Images (*.img;*.img.xz;*.iso;*.bin;*.raw)\x00*.img;*.img.xz;*.xz;*.iso;*.bin;*.raw\x00All Files (*.*)\x00*.*\x00";
        var ofn: OPENFILENAMEA = .{
            .hwndOwner = self.hwnd,
            .lpstrFilter = filter,
            .lpstrFile = &file_buf,
            .nMaxFile = file_buf.len,
            .lpstrTitle = "Select SD Card Image",
            .Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR,
        };
        if (get_open_file(&ofn) != 0) {
            const chosen = std.mem.sliceTo(&file_buf, 0);
            if (chosen.len > 0 and chosen.len <= self.chosen_sd_path_buf.len) {
                @memcpy(self.chosen_sd_path_buf[0..chosen.len], chosen);
                self.chosen_sd_path_len = chosen.len;
                const fsize = board_sheet.Qcow2Disk.getFileSizeLinux(chosen) catch 0;
                self.ui.setPendingSdImageFile(chosen, fsize);
                self.ui_dirty = true;
            }
        }
    }

    pub fn repeatTimeoutMs(self: *const WindowsWindow, now_ns: u64) ?i32 {
        const rep = self.repeat orelse return null;
        if (self.repeat_rate == 0 or !self.ui.sheet_open) return null;
        if (now_ns >= rep.next_ns) return 0;
        const rem_ms = std.math.divCeil(u64, rep.next_ns - now_ns, std.time.ns_per_ms) catch 0;
        return @intCast(@min(rem_ms, @as(u64, std.math.maxInt(i32))));
    }

    pub fn serviceRepeat(self: *WindowsWindow, now_ns: u64) void {
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

    fn isModifierKey(evdev_key: u32) bool {
        return switch (evdev_key) {
            29, 97, 42, 54, 56, 100, 125, 126, 58, 69, 70 => true,
            else => false,
        };
    }

    pub fn dispatchKey(self: *WindowsWindow, key: u32, pressed: bool, is_repeat: bool) void {
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
        if (self.hid) |h| {
            h.handleEvdevKey(key, pressed);
        }
    }

    pub fn setBoardModel(self: *WindowsWindow, bm: board_sheet.BoardModel) void {
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
        if (win32_api) |*api| {
            if (self.hwnd) |hwnd| {
                var title_z: [128]u8 = undefined;
                const tlen = @min(self.ui.title.len, title_z.len - 1);
                @memcpy(title_z[0..tlen], self.ui.title[0..tlen]);
                title_z[tlen] = 0;
                _ = api.SetWindowTextA(hwnd, title_z[0..tlen :0]);
            }
        }
    }
};

/// Maps a Windows PS/2 Set 1 hardware scancode (`(lParam >> 16) & 0xFF`) and extended bit
/// (`(lParam >> 24) & 1`) to a Linux `evdev` keycode (`KEY_*`).
pub fn winScancodeToEvdev(scancode: u8, extended: bool, vk: u32) ?u32 {
    if (!extended) {
        if (scancode == 0x45) {
            // VK_NUMLOCK = 0x90 -> KEY_NUMLOCK (69), otherwise KEY_PAUSE (119)
            return if (vk == 0x90) 69 else 119;
        }
        return switch (scancode) {
            0x01...0x53 => scancode,
            0x56 => 86, // KEY_102ND (ISO backslash)
            0x57 => 87, // KEY_F11
            0x58 => 88, // KEY_F12
            else => null,
        };
    } else {
        return switch (scancode) {
            0x1C => 96, // KEY_KPENTER
            0x1D => 97, // KEY_RIGHTCTRL
            0x35 => 98, // KEY_KPSLASH
            0x37 => 99, // KEY_SYSRQ
            0x38 => 100, // KEY_RIGHTALT
            0x45 => 69, // KEY_NUMLOCK
            0x47 => 102, // KEY_HOME
            0x48 => 103, // KEY_UP
            0x49 => 104, // KEY_PAGEUP
            0x4B => 105, // KEY_LEFT
            0x4D => 106, // KEY_RIGHT
            0x4F => 107, // KEY_END
            0x50 => 108, // KEY_DOWN
            0x51 => 109, // KEY_PAGEDOWN
            0x52 => 110, // KEY_INSERT
            0x53 => 111, // KEY_DELETE
            0x5B => 125, // KEY_LEFTMETA (Left Windows)
            0x5C => 126, // KEY_RIGHTMETA (Right Windows)
            0x5D => 127, // KEY_COMPOSE (Application/Menu)
            else => null,
        };
    }
}

test "winScancodeToEvdev maps Windows PS/2 Set 1 scancodes to Linux evdev keycodes" {
    const testing = std.testing;
    try testing.expectEqual(@as(?u32, 1), winScancodeToEvdev(0x01, false, 0x1B)); // Escape
    try testing.expectEqual(@as(?u32, 16), winScancodeToEvdev(0x10, false, 'Q')); // Q
    try testing.expectEqual(@as(?u32, 30), winScancodeToEvdev(0x1E, false, 'A')); // A
    try testing.expectEqual(@as(?u32, 28), winScancodeToEvdev(0x1C, false, 0x0D)); // Enter
    try testing.expectEqual(@as(?u32, 96), winScancodeToEvdev(0x1C, true, 0x0D)); // Keypad Enter
    try testing.expectEqual(@as(?u32, 105), winScancodeToEvdev(0x4B, true, 0x25)); // Left Arrow
    try testing.expectEqual(@as(?u32, 106), winScancodeToEvdev(0x4D, true, 0x27)); // Right Arrow
    try testing.expectEqual(@as(?u32, 111), winScancodeToEvdev(0x53, true, 0x2E)); // Delete
    try testing.expectEqual(@as(?u32, 125), winScancodeToEvdev(0x5B, true, 0x5B)); // Left Win
    if (builtin.os.tag == .windows) {
        _ = WindowsWindow;
    }
}
