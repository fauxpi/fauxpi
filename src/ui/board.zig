//! The boards Dazzle runs on, as drawings: each board's outline, its
//! mounting holes, and its parts (chips, connectors and the like), in
//! millimetres from the board's top left corner, seen from above with the
//! GPIO header along the top edge. Parts on the underside are drawn as
//! outlines.
//!
//! The outlines, holes and connectors are where Raspberry Pi's mechanical
//! drawings put them; the chips are where photos of the boards show them,
//! to a millimetre or two. Boards that share a layout (the B+, 2 B, 3 B and
//! 3 B+, say) share their connectors, and differ in their chips.

const std = @import("std");

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
    /// USB 3.0 host controller (the Pi 4's VL805).
    usb_controller,
    /// The Pi 5's RP1 I/O controller (southbridge).
    southbridge,
    /// Gigabit Ethernet transceiver (the Pi 4 and 5's BCM54213PE).
    ethernet_phy,
    /// Wi-Fi and Bluetooth (in a metal can, or bare).
    wireless,
    wireless_can,
    antenna,
    /// Power management.
    pmic,
    /// Flash storage (the Compute Modules').
    emmc,
    gpio,
    /// GPIO holes with no header fitted (the Zeros').
    gpio_holes,
    usb,
    usb_double,
    /// A micro USB port for data (the Zeros' USB On-The-Go).
    usb_otg,
    power,
    usb_c_power,
    power_button,
    ethernet,
    hdmi,
    mini_hdmi,
    micro_hdmi,
    /// 3.5 mm jack: sound, and composite video on later boards.
    audio,
    /// Composite video (RCA), on the first boards.
    composite,
    camera,
    display,
    camera_display,
    pcie,
    micro_sd,
    sd,
    /// The Compute Modules' edge connector.
    edge,
    /// Green activity LED (blinks on SD card activity).
    act_led,
    /// Red 5V power LED.
    pwr_led,
};

pub const Part = struct {
    kind: Kind,
    rect: Rect,
    /// The chip's name ("BCM2837B0"), if it is a chip.
    chip: []const u8 = "",
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

pub const Notch = struct { x: f32, y: f32, r: f32 };

pub const Board = struct {
    width: f32,
    height: f32,
    corner: f32 = 3,
    holes: []const [2]f32,
    hole_diameter: f32 = 2.75,
    /// Half-round notches cut into the edge (a Compute Module's).
    notches: []const Notch = &.{},
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

    /// The part at `p` (in millimetres), if any: those on top first, and
    /// later ones (drawn over earlier ones) before earlier ones.
    pub fn partAt(b: *const Board, p: [2]f32) ?usize {
        for ([_]bool{ false, true }) |underside| {
            var i = b.parts.len;
            while (i > 0) {
                i -= 1;
                const r = b.parts[i].rect;
                if (b.parts[i].underside != underside) continue;
                if (p[0] >= r.x and p[0] < r.x + r.w and p[1] >= r.y and p[1] < r.y + r.h) return i;
            }
        }
        return null;
    }
};

/// A part centred at (`cx`, `cy`).
fn at(kind: Kind, cx: f32, cy: f32, w: f32, h: f32) Part {
    return .{ .kind = kind, .rect = .{ .x = cx - w / 2, .y = cy - h / 2, .w = w, .h = h } };
}

fn chip(kind: Kind, name: []const u8, cx: f32, cy: f32, size: f32) Part {
    var p = at(kind, cx, cy, size, size);
    p.chip = name;
    return p;
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

// --- The B+ layout (85 × 56): the 1 B+, 2 B, 3 B and 3 B+ -------------------

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
    chip(.soc_with_ram, "BCM2835", 27, 24.6, 12),
    chip(.usb_ethernet, "LAN9514", 60, 22.3, 9),
}) };

const pi2_b: Board = .{ .width = 85, .height = 56, .holes = &b_plus_holes, .parts = &bPlus(&.{
    chip(.soc, "BCM2836", 27, 24.6, 12),
    under(chip(.ram, "1 GB LPDDR2", 27, 24.6, 12)),
    chip(.usb_ethernet, "LAN9514", 60, 22.3, 9),
}) };

const pi2_b_v12: Board = .{ .width = 85, .height = 56, .holes = &b_plus_holes, .parts = &bPlus(&.{
    chip(.soc, "BCM2837", 27, 24.6, 12),
    under(chip(.ram, "1 GB LPDDR2", 27, 24.6, 12)),
    chip(.usb_ethernet, "LAN9514", 60, 22.3, 9),
}) };

const pi3_b: Board = .{ .width = 85, .height = 56, .holes = &b_plus_holes, .parts = &bPlus(&.{
    chip(.soc, "BCM2837", 27, 24.6, 12),
    under(chip(.ram, "1 GB LPDDR2", 27, 24.6, 12)),
    chip(.usb_ethernet, "LAN9514", 60, 22.3, 9),
    chip(.wireless, "BCM43438", 11.5, 12.5, 4.5),
    at(.antenna, 1.6, 9.5, 2, 7),
}) };

pub const pi3_b_plus: Board = .{ .width = 85, .height = 56, .holes = &b_plus_holes, .parts = &bPlus(&.{
    lidded(chip(.soc, "BCM2837B0", 27, 24.6, 14)),
    under(chip(.ram, "1 GB LPDDR2", 27, 24.6, 12)),
    chip(.usb_ethernet, "LAN7515", 60, 22.3, 9),
    at(.wireless_can, 13.5, 11.5, 12, 10),
    chip(.pmic, "MxL7704", 15.5, 37, 5),
}) };

const pi4_b: Board = .{ .width = 85, .height = 56, .holes = &b_plus_holes, .parts = &.{
    header(.gpio, 32.5, 3.5, 20),
    facing(at(.usb_c_power, 11.2, 53.5, 9, 7.4), .bottom),
    facing(at(.micro_hdmi, 26, 53, 6.8, 7.8), .bottom),
    facing(at(.micro_hdmi, 39.5, 53, 6.8, 7.8), .bottom),
    at(.camera, 45.75, 44.5, 4, 22),
    facing(at(.audio, 54, 50.5, 7, 14), .bottom),
    at(.display, 3.9, 28, 4, 22),
    under(facing(at(.micro_sd, 6.5, 28, 15, 12), .left)),
    facing(at(.ethernet, 76.3, 10.25, 21.6, 15.9), .right),
    facing(at(.usb_double, 78.4, 29, 17.4, 13.1), .right),
    facing(at(.usb_double, 78.4, 47, 17.4, 13.1), .right),
    lidded(chip(.soc, "BCM2711", 30.5, 23.5, 15)),
    chip(.ram, "LPDDR4", 46, 23.5, 10),
    chip(.usb_controller, "VL805", 62, 31.5, 9),
    chip(.ethernet_phy, "BCM54213PE", 61, 16, 6.5),
    at(.wireless_can, 13.5, 12.5, 12, 10.5),
    chip(.pmic, "MxL7704", 15, 38.5, 5),
} };

const pi5_b: Board = .{ .width = 85, .height = 56, .holes = &b_plus_holes, .parts = &.{
    header(.gpio, 32.5, 3.5, 20),
    facing(at(.usb_c_power, 11.2, 53.5, 9, 7.4), .bottom),
    facing(at(.micro_hdmi, 25.8, 53, 6.8, 7.8), .bottom),
    facing(at(.micro_hdmi, 39.2, 53, 6.8, 7.8), .bottom),
    at(.camera_display, 47.5, 44, 3.2, 16),
    at(.camera_display, 52.5, 44, 3.2, 16),
    at(.pcie, 3.6, 28, 3.2, 14),
    facing(at(.power_button, 1.8, 17.5, 3.6, 4.5), .left),
    under(facing(at(.micro_sd, 6.5, 28, 15, 12), .left)),
    facing(at(.usb_double, 78.4, 9, 17.4, 13.1), .right),
    facing(at(.usb_double, 78.4, 27, 17.4, 13.1), .right),
    facing(at(.ethernet, 76.3, 45.75, 21.6, 15.9), .right),
    lidded(chip(.soc, "BCM2712", 29.5, 29, 17)),
    chip(.ram, "LPDDR4X", 29.5, 15, 10),
    chip(.southbridge, "RP1", 59.5, 23, 12),
    chip(.ethernet_phy, "BCM54213PE", 60, 39, 6.5),
    at(.wireless_can, 13.5, 11.5, 12, 10.5),
    chip(.pmic, "DA9091", 14.5, 40.5, 7),
} };

// --- The A+ layout (65 × 56): the 1 A+ and 3 A+ ---------------------------------

fn aPlus(comptime extra: []const Part) [10 + extra.len]Part {
    return plusConnectors() ++ [_]Part{
        facing(at(.usb, 60.2, 24.55, 14, 13.1), .right),
    } ++ extra[0..extra.len].*;
}

pub const pi1_a_plus: Board = .{ .width = 65, .height = 56, .holes = &b_plus_holes, .parts = &aPlus(&.{
    chip(.soc_with_ram, "BCM2835", 27, 24.6, 12),
}) };

pub const pi3_a_plus: Board = .{ .width = 65, .height = 56, .holes = &b_plus_holes, .parts = &aPlus(&.{
    lidded(chip(.soc, "BCM2837B0", 27, 24.6, 14)),
    under(chip(.ram, "512 MB LPDDR2", 27, 24.6, 12)),
    at(.wireless_can, 13.5, 11.5, 12, 10),
    chip(.pmic, "MxL7704", 15.5, 37, 5),
}) };

// --- The first boards (85 × 56): the 1 A and 1 B --------------------------------

const pi1_holes = [_][2]f32{ .{ 25.5, 38 }, .{ 80.1, 12.4 } };

fn pi1(comptime extra: []const Part) [9 + extra.len]Part {
    return [_]Part{
        header(.gpio, 17.5, 3.5, 13),
        facing(at(.composite, 41.4, 2, 10, 16), .top),
        facing(at(.audio, 58.2, 5, 7, 12), .top),
        facing(at(.hdmi, 37.1, 51.75, 15.2, 11.5), .bottom),
        facing(at(.power, 1.8, 48, 5.6, 7.6), .left),
        at(.camera, 51.5, 45, 4, 20),
        at(.display, 10, 21, 4, 22),
        under(facing(at(.sd, 1, 28, 34, 26), .left)),
        chip(.soc_with_ram, "BCM2835", 39, 27, 12),
    } ++ extra[0..extra.len].*;
}

const pi1_b: Board = .{ .width = 85, .height = 56, .corner = 0.5, .holes = &pi1_holes, .hole_diameter = 2.9, .parts = &pi1(&.{
    facing(at(.usb_double, 77.7, 25.5, 17.4, 13.1), .right),
    facing(at(.ethernet, 75.5, 46, 21.6, 15.9), .right),
    chip(.usb_ethernet, "LAN9512", 60, 30, 8),
}) };

const pi1_a: Board = .{ .width = 85, .height = 56, .corner = 0.5, .holes = &pi1_holes, .hole_diameter = 2.9, .parts = &pi1(&.{
    facing(at(.usb, 78.6, 25.5, 14, 13.1), .right),
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
    chip(.soc_with_ram, "BCM2835", 25.5, 17, 12),
}) };

pub const pi_zero_w: Board = .{ .width = 65, .height = 30, .holes = &zero_holes, .parts = &zero(&.{
    chip(.soc_with_ram, "BCM2835", 25.5, 17, 12),
    chip(.wireless, "BCM43438", 40, 18, 5),
    at(.antenna, 26, 27.5, 9, 3),
}) };

pub const pi_zero_2_w: Board = .{ .width = 65, .height = 30, .holes = &zero_holes, .parts = &zero(&.{
    chip(.soc_with_ram, "RP3A0", 27, 17, 14),
    at(.wireless_can, 42, 14.5, 11, 10),
}) };

// --- The Compute Modules (67.6 × 31, a SODIMM) -----------------------------------

const cm_holes = [_][2]f32{ .{ 3.5, 19 }, .{ 64.1, 3.5 } };
const cm_notches = [_]Notch{ .{ .x = 0, .y = 24, .r = 1.5 }, .{ .x = 67.6, .y = 24, .r = 1.5 } };

fn cm(comptime extra: []const Part) [2 + extra.len]Part {
    return [_]Part{
        facing(at(.edge, 8, 29.3, 12, 3.4), .bottom),
        facing(at(.edge, 41.3, 29.3, 52, 3.4), .bottom),
    } ++ extra[0..extra.len].*;
}

const cm1: Board = .{ .width = 67.6, .height = 31, .corner = 1, .holes = &cm_holes, .hole_diameter = 2.5, .notches = &cm_notches, .parts = &cm(&.{
    chip(.soc_with_ram, "BCM2835", 38, 13, 12),
    under(at(.emmc, 38, 13, 12, 16)),
}) };

const cm3: Board = .{ .width = 67.6, .height = 31, .corner = 1, .holes = &cm_holes, .hole_diameter = 2.5, .notches = &cm_notches, .parts = &cm(&.{
    chip(.soc, "BCM2837", 38, 13, 12),
    under(at(.ram, 30, 13, 12, 12)),
    under(at(.emmc, 50, 13, 11.5, 13)),
}) };

const cm3_plus: Board = .{ .width = 67.6, .height = 31, .corner = 1, .holes = &cm_holes, .hole_diameter = 2.5, .notches = &cm_notches, .parts = &cm(&.{
    lidded(chip(.soc, "BCM2837B0", 38, 13, 14)),
    under(at(.ram, 30, 13, 12, 12)),
    under(at(.emmc, 50, 13, 11.5, 13)),
}) };

const cm4_holes = [_][2]f32{ .{ 2.5, 2.5 }, .{ 52.5, 2.5 }, .{ 2.5, 37.5 }, .{ 52.5, 37.5 } };

const cm4: Board = .{ .width = 55, .height = 40, .corner = 1.5, .holes = &cm4_holes, .hole_diameter = 2.5, .parts = &.{
    lidded(chip(.soc, "BCM2711", 31, 20, 15)),
    chip(.ram, "LPDDR4", 46, 15, 10),
    at(.emmc, 46, 28.5, 11.5, 13),
    at(.wireless_can, 11, 14, 12, 10.5),
    chip(.ethernet_phy, "BCM54210PE", 15.5, 31, 6.5),
    chip(.pmic, "DA9090", 28, 34, 5),
} };

const cm5: Board = .{ .width = 55, .height = 40, .corner = 1.5, .holes = &cm4_holes, .hole_diameter = 2.5, .parts = &.{
    lidded(chip(.soc, "BCM2712", 29.5, 20, 17)),
    chip(.ram, "LPDDR4X", 45.5, 13, 10),
    chip(.southbridge, "RP1", 45.5, 29, 12),
    under(at(.emmc, 45.5, 28.5, 11.5, 13)),
    at(.wireless_can, 11, 13, 12, 10.5),
    chip(.ethernet_phy, "BCM54210PE", 11, 29, 6.5),
    chip(.pmic, "DA9091", 21, 32, 7),
} };

/// The board's drawing, from its model (as the device tree gives it:
/// "Raspberry Pi 3 Model B Plus Rev 1.3"); null for a board not known.
pub fn forModel(model: []const u8) ?*const Board {
    const has = struct {
        fn f(m: []const u8, s: []const u8) bool {
            return std.mem.indexOf(u8, m, s) != null;
        }
    }.f;
    if (!std.mem.startsWith(u8, model, "Raspberry Pi")) return null;
    // Most particular first.
    if (has(model, "Compute Module 5")) return &cm5;
    if (has(model, "Compute Module 4")) return &cm4;
    if (has(model, "Compute Module 3 Plus")) return &cm3_plus;
    if (has(model, "Compute Module 3")) return &cm3;
    if (has(model, "Compute Module")) return &cm1;
    if (has(model, "Zero 2 W")) return &pi_zero_2_w;
    if (has(model, "Zero W")) return &pi_zero_w;
    if (has(model, "Zero")) return &pi_zero;
    if (has(model, "5 Model B")) return &pi5_b;
    if (has(model, "4 Model B")) return &pi4_b;
    if (has(model, "3 Model B Plus") or has(model, "3 Model B+")) return &pi3_b_plus;
    if (has(model, "3 Model A Plus") or has(model, "3 Model A+")) return &pi3_a_plus;
    if (has(model, "3 Model B")) return &pi3_b;
    // The 2 B v1.2 has the Pi 3's chip.
    if (has(model, "2 Model B")) return if (has(model, "Rev 1.2")) &pi2_b_v12 else &pi2_b;
    if (has(model, "Model B Plus") or has(model, "Model B+")) return &pi1_b_plus;
    if (has(model, "Model A Plus") or has(model, "Model A+")) return &pi1_a_plus;
    if (has(model, "Model B")) return &pi1_b;
    if (has(model, "Model A")) return &pi1_a;
    return null;
}

/// What a part is, for people: its name, and a line about what it does.
pub fn describe(p: *const Part) struct { title: []const u8, about: []const u8 } {
    return switch (p.kind) {
        .soc => .{
            .title = "Processor and graphics",
            .about = if (std.mem.eql(u8, p.chip, "BCM2712"))
                "The system on a chip: the processor that runs Dazzle and its apps, and the VideoCore VII graphics processor Dazzle draws everything with"
            else if (std.mem.eql(u8, p.chip, "BCM2711"))
                "The system on a chip: the processor that runs Dazzle and its apps, and the VideoCore VI graphics processor Dazzle draws everything with"
            else
                "The system on a chip: the processor that runs Dazzle and its apps, and the VideoCore IV graphics processor Dazzle draws everything with",
        },
        .soc_with_ram => .{ .title = "Processor, graphics and memory", .about = "The system on a chip (the processor that runs Dazzle, and the VideoCore IV graphics processor Dazzle draws with), with the memory stacked on top of it" },
        .ram => .{ .title = "Memory", .about = if (p.underside) "The memory the processor and graphics share, underneath the board" else "The memory the processor and graphics share" },
        .usb_ethernet => .{ .title = "USB and Ethernet", .about = "A USB hub, for the USB ports, with the wired network adapter on it" },
        .usb_controller => .{ .title = "USB controller", .about = "For the USB ports, connected to the processor by PCI Express" },
        .southbridge => .{ .title = "I/O controller", .about = "The RP1 southbridge: runs the GPIO header, USB ports, Ethernet, cameras and displays, connected to the processor by PCI Express" },
        .ethernet_phy => .{ .title = "Ethernet transceiver", .about = "For the Gigabit Ethernet port" },
        .wireless, .wireless_can => .{ .title = "Wi-Fi and Bluetooth", .about = "The wireless network adapter (Dazzle uses its Wi-Fi)" },
        .antenna => .{ .title = "Antenna", .about = "For Wi-Fi and Bluetooth" },
        .pmic => .{ .title = "Power", .about = "Makes the voltages the chips need from the 5 V supply" },
        .emmc => .{ .title = "Flash storage", .about = "Storage on the module itself, underneath (Lite modules have none, and use an SD card instead)" },
        .gpio => .{ .title = "GPIO header", .about = "General-purpose pins for electronics: sensors, lights, buttons and add-on boards (HATs)" },
        .gpio_holes => .{ .title = "GPIO", .about = "General-purpose pins for electronics, for a header to be soldered in" },
        .usb, .usb_double => .{ .title = "USB", .about = "For keyboards, mice, USB drives and network adapters" },
        .usb_otg => .{ .title = "USB", .about = "A micro USB port: for a keyboard, mouse or USB drive (through an adapter or hub)" },
        .power => .{ .title = "Power", .about = "5 V in, through a micro USB cable" },
        .usb_c_power => .{ .title = "Power", .about = "5 V in, through a USB-C cable" },
        .power_button => .{ .title = "Power button", .about = "Turns the Raspberry Pi on and off" },
        .ethernet => .{ .title = "Ethernet", .about = "The wired network" },
        .hdmi => .{ .title = "HDMI", .about = "The screen, and its sound" },
        .mini_hdmi => .{ .title = "Mini HDMI", .about = "The screen, and its sound (through a mini HDMI cable or adapter)" },
        .micro_hdmi => .{ .title = "Micro HDMI", .about = "The screen, and its sound (through a micro HDMI cable or adapter)" },
        .audio => .{ .title = "Audio and video", .about = "A 3.5 mm jack: headphones or speakers, and composite video for an old television" },
        .composite => .{ .title = "Composite video", .about = "For an old television" },
        .camera => .{ .title = "Camera", .about = "For a Raspberry Pi camera module, by its ribbon cable" },
        .display => .{ .title = "Display", .about = "For the Raspberry Pi touch display, by its ribbon cable" },
        .camera_display => .{ .title = "Camera or display", .about = "For a Raspberry Pi camera module or touch display, by its ribbon cable" },
        .pcie => .{ .title = "PCI Express", .about = "For an NVMe SSD or other PCI Express add-on board, by its ribbon cable" },
        .micro_sd => .{ .title = "microSD card", .about = "Where Dazzle and your files are kept" },
        .sd => .{ .title = "SD card", .about = "Where Dazzle and your files are kept" },
        .edge => .{ .title = "Edge connector", .about = "Plugs into a carrier board, which has the connectors" },
        .act_led => .{ .title = "Activity LED", .about = "Blinks green when the SD card is being read or written" },
        .pwr_led => .{ .title = "Power LED", .about = "Glows red when the board has 5 V power" },
    };
}

const testing = std.testing;

test "boards by their model" {
    try testing.expect(forModel("Raspberry Pi 5 Model B Rev 1.0").? == &pi5_b);
    try testing.expect(forModel("Raspberry Pi 4 Model B Rev 1.4").? == &pi4_b);
    try testing.expect(forModel("Raspberry Pi 3 Model B Plus Rev 1.3").? == &pi3_b_plus);
    try testing.expect(forModel("Raspberry Pi 3 Model B Rev 1.2").? == &pi3_b);
    try testing.expect(forModel("Raspberry Pi 3 Model A Plus Rev 1.0").? == &pi3_a_plus);
    try testing.expect(forModel("Raspberry Pi 2 Model B Rev 1.1").? == &pi2_b);
    try testing.expect(forModel("Raspberry Pi 2 Model B Rev 1.2").? == &pi2_b_v12);
    try testing.expect(forModel("Raspberry Pi Model B Plus Rev 1.2").? == &pi1_b_plus);
    try testing.expect(forModel("Raspberry Pi Model A Plus Rev 1.1").? == &pi1_a_plus);
    try testing.expect(forModel("Raspberry Pi Model B Rev 2").? == &pi1_b);
    try testing.expect(forModel("Raspberry Pi Model A Rev 2").? == &pi1_a);
    try testing.expect(forModel("Raspberry Pi Zero Rev 1.3").? == &pi_zero);
    try testing.expect(forModel("Raspberry Pi Zero W Rev 1.1").? == &pi_zero_w);
    try testing.expect(forModel("Raspberry Pi Zero 2 W Rev 1.0").? == &pi_zero_2_w);
    try testing.expect(forModel("Raspberry Pi Compute Module Rev 1.0").? == &cm1);
    try testing.expect(forModel("Raspberry Pi Compute Module 3 Rev 1.0").? == &cm3);
    try testing.expect(forModel("Raspberry Pi Compute Module 3 Plus Rev 1.0").? == &cm3_plus);
    try testing.expect(forModel("Raspberry Pi Compute Module 4 Rev 1.0").? == &cm4);
    try testing.expect(forModel("Raspberry Pi Compute Module 5 Rev 1.0").? == &cm5);
    try testing.expect(forModel("QEMU") == null);
}

test "parts are found where they are, those on top first" {
    const b = forModel("Raspberry Pi 3 Model B Plus Rev 1.3").?;
    // The SoC (over the memory underneath it).
    try testing.expectEqual(Kind.soc, b.parts[b.partAt(.{ 27, 24.6 }).?].kind);
    try testing.expectEqual(Kind.gpio, b.parts[b.partAt(.{ 10, 3 }).?].kind);
    try testing.expectEqual(Kind.micro_sd, b.parts[b.partAt(.{ 1, 28 }).?].kind);
    try testing.expect(b.partAt(.{ 50, 30 }) == null);
    // USB and Ethernet stick out past the edge.
    const r = b.bounds();
    try testing.expect(r.w > 85 and r.x < 0);
}

test "every part is on or at the edge of its board" {
    const all = [_]*const Board{ &pi1_a, &pi1_b, &pi1_a_plus, &pi1_b_plus, &pi2_b, &pi2_b_v12, &pi3_b, &pi3_b_plus, &pi3_a_plus, &pi4_b, &pi5_b, &pi_zero, &pi_zero_w, &pi_zero_2_w, &cm1, &cm3, &cm3_plus, &cm4, &cm5 };
    for (all) |b| for (b.parts) |p| {
        try testing.expect(p.rect.x + p.rect.w > 0 and p.rect.x < b.width);
        try testing.expect(p.rect.y + p.rect.h > 0 and p.rect.y < b.height);
        try testing.expect(p.rect.x >= -18 and p.rect.x + p.rect.w <= b.width + 3);
    };
}
