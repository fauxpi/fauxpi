//! Board drawings for the emulated Raspberry Pi models: each board's outline,
//! its mounting holes, and its parts (chips, connectors, and LEDs), in
//! millimetres from the board's top left corner, seen from above with the
//! GPIO header along the top edge. Parts on the underside are drawn as
//! outlines.

const std = @import("std");
const BoardClocks = @import("../soc/mailbox.zig").BoardClocks;

pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

/// What a part is, which says how it is drawn and what it does.
pub const Kind = enum {
    /// The system on a chip: the processor and graphics.
    soc,
    /// The processor with its memory stacked on top.
    soc_with_ram,
    ram,
    /// USB hub and Ethernet adapter.
    usb_ethernet,
    /// Wi-Fi and Bluetooth (in a metal can, or bare).
    wireless,
    wireless_can,
    antenna,
    /// Power management.
    pmic,
    gpio,
    /// GPIO holes with no header fitted (the Zeros').
    gpio_holes,
    usb,
    usb_double,
    /// A micro USB port for data (the Zeros' USB On-The-Go).
    usb_otg,
    power,
    ethernet,
    hdmi,
    mini_hdmi,
    /// 3.5 mm jack: sound, and composite video on later boards.
    audio,
    camera,
    display,
    micro_sd,
    /// Green activity LED (blinks on SD card activity).
    act_led,
    /// Red 5V power LED.
    pwr_led,
};

pub const Part = struct {
    kind: Kind,
    rect: Rect,
    /// Under the board.
    underside: bool = false,
    /// A metal lid (the B0 chips' heat spreader).
    lidded: bool = false,
    /// Which edge its opening faces, for connectors: for drawing the
    /// opening.
    faces: ?Edge = null,
    /// A header's pins: columns and rows.
    pins: [2]u8 = .{ 0, 0 },
};

pub const Edge = enum { top, bottom, left, right };

pub const Board = struct {
    width: f32,
    height: f32,
    corner: f32 = 3,
    holes: []const [2]f32,
    hole_diameter: f32 = 2.75,
    parts: []const Part,

    /// The area drawn: the board, and what sticks out past its edges.
    pub fn bounds(b: *const Board) Rect {
        var x0: f32 = 0;
        var y0: f32 = 0;
        var x1: f32 = b.width;
        var y1: f32 = b.height;
        for (b.parts) |p| {
            x0 = @min(x0, p.rect.x);
            y0 = @min(y0, p.rect.y);
            x1 = @max(x1, p.rect.x + p.rect.w);
            y1 = @max(y1, p.rect.y + p.rect.h);
        }
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }
};

/// A part centred at (`cx`, `cy`).
fn at(kind: Kind, cx: f32, cy: f32, w: f32, h: f32) Part {
    return .{ .kind = kind, .rect = .{ .x = cx - w / 2, .y = cy - h / 2, .w = w, .h = h } };
}

fn chip(kind: Kind, cx: f32, cy: f32, size: f32) Part {
    return at(kind, cx, cy, size, size);
}

fn lidded(p: Part) Part {
    var q = p;
    q.lidded = true;
    return q;
}

fn under(p: Part) Part {
    var q = p;
    q.underside = true;
    return q;
}

fn facing(p: Part, e: Edge) Part {
    var q = p;
    q.faces = e;
    return q;
}

fn header(kind: Kind, cx: f32, cy: f32, cols: u8) Part {
    var p = at(kind, cx, cy, @as(f32, @floatFromInt(cols)) * 2.54, 5.08);
    p.pins = .{ cols, 2 };
    return p;
}

// --- The B+ layout (85 × 56): the 1 B+ and 3 B+ -------------------------------

const b_plus_holes = [_][2]f32{ .{ 3.5, 3.5 }, .{ 61.5, 3.5 }, .{ 3.5, 52.5 }, .{ 61.5, 52.5 } };

/// The connectors of the B+ layout and the A+ layout: GPIO, power, HDMI,
/// audio and video, camera, display, microSD card (underneath), and ACT/PWR LEDs.
fn plusConnectors() [9]Part {
    return .{
        header(.gpio, 32.5, 3.5, 20),
        facing(at(.power, 10.6, 54.1, 7.6, 5.6), .bottom),
        facing(at(.hdmi, 32, 51.75, 15.2, 11.5), .bottom),
        facing(at(.audio, 53.5, 50.5, 7, 14), .bottom),
        at(.camera, 45, 44.5, 4, 22),
        at(.display, 3.6, 28, 4, 22),
        under(facing(at(.micro_sd, 6.5, 28, 15, 12), .left)),
        at(.act_led, 2.0, 43.0, 1.8, 1.2),
        at(.pwr_led, 2.0, 46.2, 1.8, 1.2),
    };
}

fn bPlus(comptime extra: []const Part) [12 + extra.len]Part {
    return plusConnectors() ++ [_]Part{
        facing(at(.usb_double, 78.4, 9, 17.4, 13.1), .right),
        facing(at(.usb_double, 78.4, 27, 17.4, 13.1), .right),
        facing(at(.ethernet, 76.3, 45.75, 21.6, 15.9), .right),
    } ++ extra[0..extra.len].*;
}

pub const pi1_b_plus: Board = .{ .width = 85, .height = 56, .holes = &b_plus_holes, .parts = &bPlus(&.{
    chip(.soc_with_ram, 27, 24.6, 12),
    chip(.usb_ethernet, 60, 22.3, 9),
}) };

pub const pi3_b_plus: Board = .{ .width = 85, .height = 56, .holes = &b_plus_holes, .parts = &bPlus(&.{
    lidded(chip(.soc, 27, 24.6, 14)),
    under(chip(.ram, 27, 24.6, 12)),
    chip(.usb_ethernet, 60, 22.3, 9),
    at(.wireless_can, 13.5, 11.5, 12, 10),
    chip(.pmic, 15.5, 37, 5),
}) };

// --- The A+ layout (65 × 56): the 1 A+ and 3 A+ ---------------------------------

fn aPlus(comptime extra: []const Part) [10 + extra.len]Part {
    return plusConnectors() ++ [_]Part{
        facing(at(.usb, 60.2, 24.55, 14, 13.1), .right),
    } ++ extra[0..extra.len].*;
}

pub const pi1_a_plus: Board = .{ .width = 65, .height = 56, .holes = &b_plus_holes, .parts = &aPlus(&.{
    chip(.soc_with_ram, 27, 24.6, 12),
}) };

pub const pi3_a_plus: Board = .{ .width = 65, .height = 56, .holes = &b_plus_holes, .parts = &aPlus(&.{
    lidded(chip(.soc, 27, 24.6, 14)),
    under(chip(.ram, 27, 24.6, 12)),
    at(.wireless_can, 13.5, 11.5, 12, 10),
    chip(.pmic, 15.5, 37, 5),
}) };

// --- The Zero layout (65 × 30) ---------------------------------------------------

const zero_holes = [_][2]f32{ .{ 3.5, 3.5 }, .{ 61.5, 3.5 }, .{ 3.5, 26.5 }, .{ 61.5, 26.5 } };

fn zero(comptime extra: []const Part) [7 + extra.len]Part {
    return [_]Part{
        header(.gpio_holes, 32.5, 3.5, 20),
        facing(at(.mini_hdmi, 12.4, 26.9, 11.2, 7.5), .bottom),
        facing(at(.usb_otg, 41.4, 28.1, 7.6, 5.6), .bottom),
        facing(at(.power, 54, 28.1, 7.6, 5.6), .bottom),
        facing(at(.micro_sd, 6.75, 13.3, 13.5, 11.5), .left),
        at(.camera, 63.2, 15, 3.6, 17),
        at(.act_led, 59.2, 22.5, 1.8, 1.2),
    } ++ extra[0..extra.len].*;
}

pub const pi_zero: Board = .{ .width = 65, .height = 30, .holes = &zero_holes, .parts = &zero(&.{
    chip(.soc_with_ram, 25.5, 17, 12),
}) };

pub const pi_zero_w: Board = .{ .width = 65, .height = 30, .holes = &zero_holes, .parts = &zero(&.{
    chip(.soc_with_ram, 25.5, 17, 12),
    chip(.wireless, 40, 18, 5),
    at(.antenna, 26, 27.5, 9, 3),
}) };

pub const pi_zero_2_w: Board = .{ .width = 65, .height = 30, .holes = &zero_holes, .parts = &zero(&.{
    chip(.soc_with_ram, 27, 17, 14),
    at(.wireless_can, 42, 14.5, 11, 10),
}) };

pub const BoardModel = enum {
    pi_1_a_plus,
    pi_1_b_plus,
    pi_3_a_plus,
    pi_3_b_plus,
    pi_zero,
    pi_zero_w,
    pi_zero_2_w,

    pub const all = [_]BoardModel{
        .pi_1_a_plus,
        .pi_1_b_plus,
        .pi_3_a_plus,
        .pi_3_b_plus,
        .pi_zero,
        .pi_zero_w,
        .pi_zero_2_w,
    };

    pub fn windowTitle(self: BoardModel) []const u8 {
        return switch (self) {
            .pi_1_a_plus => "Raspberry Pi 1 Model A+",
            .pi_1_b_plus => "Raspberry Pi 1 Model B+",
            .pi_3_a_plus => "Raspberry Pi 3 Model A+",
            .pi_3_b_plus => "Raspberry Pi 3 Model B+",
            .pi_zero => "Raspberry Pi Zero",
            .pi_zero_w => "Raspberry Pi Zero W",
            .pi_zero_2_w => "Raspberry Pi Zero 2 W",
        };
    }

    pub fn dtModel(self: BoardModel) []const u8 {
        return switch (self) {
            .pi_1_a_plus => "Raspberry Pi Model A Plus Rev 1.1",
            .pi_1_b_plus => "Raspberry Pi Model B Plus Rev 1.2",
            .pi_3_a_plus => "Raspberry Pi 3 Model A Plus Rev 1.0",
            .pi_3_b_plus => "Raspberry Pi 3 Model B Plus Rev 1.3",
            .pi_zero => "Raspberry Pi Zero Rev 1.3",
            .pi_zero_w => "Raspberry Pi Zero W Rev 1.1",
            .pi_zero_2_w => "Raspberry Pi Zero 2 W Rev 1.0",
        };
    }

    pub fn boardRevision(self: BoardModel) u32 {
        return switch (self) {
            .pi_1_a_plus => 0x00900021,
            .pi_1_b_plus => 0x00900032,
            .pi_3_a_plus => 0x009020e0,
            .pi_3_b_plus => 0x00a020d3,
            .pi_zero => 0x00900093,
            .pi_zero_w => 0x009000c1,
            .pi_zero_2_w => 0x00902120,
        };
    }

    /// SDRAM size, as the board revision code's memory-size field says (256 MiB << n).
    pub fn ramBytes(self: BoardModel) u32 {
        return @as(u32, 256 * 1024 * 1024) << @intCast((self.boardRevision() >> 20) & 7);
    }

    /// The firmware's default clocks (`arm_freq`, `core_freq`, ... and their `_min`), in MHz.
    pub fn clocks(self: BoardModel) BoardClocks {
        return switch (self) {
            .pi_1_a_plus, .pi_1_b_plus => .{
                .arm = .mhz(700, 700),
                .core = .mhz(250, 250),
                .v3d = .mhz(250, 250),
                .h264 = .mhz(250, 250),
                .isp = .mhz(250, 250),
                .sdram = .mhz(400, 400),
            },
            .pi_zero, .pi_zero_w => .{
                .arm = .mhz(700, 1000),
                .core = .mhz(250, 400),
                .v3d = .mhz(250, 300),
                .h264 = .mhz(250, 300),
                .isp = .mhz(250, 300),
                .sdram = .mhz(400, 450),
            },
            .pi_zero_2_w => .{
                .arm = .mhz(600, 1000),
                .core = .mhz(250, 400),
                .v3d = .mhz(250, 300),
                .h264 = .mhz(250, 300),
                .isp = .mhz(250, 300),
                .sdram = .mhz(400, 450),
            },
            .pi_3_a_plus, .pi_3_b_plus => .{
                .arm = .mhz(600, 1400),
                .core = .mhz(250, 400),
                .v3d = .mhz(250, 400),
                .h264 = .mhz(250, 400),
                .isp = .mhz(250, 400),
                .sdram = .mhz(400, 500),
            },
        };
    }

    pub fn hasWireless(self: BoardModel) bool {
        return switch (self) {
            .pi_1_a_plus, .pi_1_b_plus, .pi_zero => false,
            .pi_3_a_plus, .pi_3_b_plus, .pi_zero_w, .pi_zero_2_w => true,
        };
    }

    pub fn hasHeadphoneJack(self: BoardModel) bool {
        return switch (self) {
            .pi_1_a_plus, .pi_1_b_plus, .pi_3_a_plus, .pi_3_b_plus => true,
            .pi_zero, .pi_zero_w, .pi_zero_2_w => false,
        };
    }

    pub fn hubKind(self: BoardModel) @import("../usb/hid.zig").HubKind {
        return switch (self) {
            .pi_1_b_plus => .lan9514,
            .pi_3_b_plus => .lan7515,
            .pi_1_a_plus, .pi_3_a_plus, .pi_zero, .pi_zero_w, .pi_zero_2_w => .external,
        };
    }

    pub fn usesExternalUsbHub(self: BoardModel) bool {
        return !self.hubKind().isBuiltIn();
    }

    pub fn isBcm2837(self: BoardModel) bool {
        return switch (self) {
            .pi_3_a_plus, .pi_3_b_plus, .pi_zero_2_w => true,
            .pi_1_a_plus, .pi_1_b_plus, .pi_zero, .pi_zero_w => false,
        };
    }

    pub fn drawing(self: BoardModel) *const Board {
        return forModel(self);
    }

    pub fn id(self: BoardModel) []const u8 {
        return switch (self) {
            .pi_1_a_plus => "pi_1_a_plus",
            .pi_1_b_plus => "pi_1_b_plus",
            .pi_3_a_plus => "pi_3_a_plus",
            .pi_3_b_plus => "pi_3_b_plus",
            .pi_zero => "pi_zero",
            .pi_zero_w => "pi_zero_w",
            .pi_zero_2_w => "pi_zero_2_w",
        };
    }

    pub fn fromId(s: []const u8) ?BoardModel {
        for (all) |bm| {
            if (std.mem.eql(u8, s, bm.id()) or std.mem.eql(u8, s, bm.windowTitle())) return bm;
        }
        return null;
    }
};

/// Returns the board drawing for `bm`.
pub fn forModel(bm: BoardModel) *const Board {
    return switch (bm) {
        .pi_1_a_plus => &pi1_a_plus,
        .pi_1_b_plus => &pi1_b_plus,
        .pi_3_a_plus => &pi3_a_plus,
        .pi_3_b_plus => &pi3_b_plus,
        .pi_zero => &pi_zero,
        .pi_zero_w => &pi_zero_w,
        .pi_zero_2_w => &pi_zero_2_w,
    };
}

const testing = std.testing;

test "boards by their model" {
    try testing.expect(forModel(.pi_3_b_plus) == &pi3_b_plus);
    try testing.expect(forModel(.pi_3_a_plus) == &pi3_a_plus);
    try testing.expect(forModel(.pi_1_b_plus) == &pi1_b_plus);
    try testing.expect(forModel(.pi_1_a_plus) == &pi1_a_plus);
    try testing.expect(forModel(.pi_zero) == &pi_zero);
    try testing.expect(forModel(.pi_zero_w) == &pi_zero_w);
    try testing.expect(forModel(.pi_zero_2_w) == &pi_zero_2_w);

    // USB and Ethernet stick out past the edge.
    const r = pi3_b_plus.bounds();
    try testing.expect(r.w > 85 and r.x < 0);
}

test "board RAM sizes" {
    try std.testing.expectEqual(@as(u32, 1024 * 1024 * 1024), BoardModel.pi_3_b_plus.ramBytes());
    for ([_]BoardModel{ .pi_1_a_plus, .pi_1_b_plus, .pi_3_a_plus, .pi_zero, .pi_zero_w, .pi_zero_2_w }) |bm| {
        try std.testing.expectEqual(@as(u32, 512 * 1024 * 1024), bm.ramBytes());
    }
}

test "board ARM clocks" {
    try std.testing.expectEqual(@as(u32, 700_000_000), BoardModel.pi_1_b_plus.clocks().arm.max_hz);
    try std.testing.expectEqual(@as(u32, 1_000_000_000), BoardModel.pi_zero_w.clocks().arm.max_hz);
    try std.testing.expectEqual(@as(u32, 1_400_000_000), BoardModel.pi_3_b_plus.clocks().arm.max_hz);
    try std.testing.expectEqual(@as(u32, 600_000_000), BoardModel.pi_zero_2_w.clocks().arm.min_hz);
}

test "every part is on or at the edge of its board" {
    for (BoardModel.all) |bm| {
        const b = forModel(bm);
        for (b.parts) |p| {
            try testing.expect(p.rect.x + p.rect.w > 0 and p.rect.x < b.width);
            try testing.expect(p.rect.y + p.rect.h > 0 and p.rect.y < b.height);
            try testing.expect(p.rect.x >= -18 and p.rect.x + p.rect.w <= b.width + 3);
        }
    }
}


