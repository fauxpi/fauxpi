//! The GPIO header model: which pin is which on the board's header, and
//! what each GPIO pin on the simulated BCM2835 GPIO controller is doing.
//! Ported from dazzle's `src/apps/settings/gpio.zig`.

const std = @import("std");
const soc_gpio = @import("../soc/gpio.zig");

pub const Gpio = soc_gpio.Gpio;
pub const Mode = Gpio.Mode;
pub const Function = Gpio.Function;

/// A pin of the header.
pub const Pin = union(enum) {
    power_5v,
    power_3v3,
    ground,
    gpio: u6,
};

/// The 40-pin header (every board since the B+), pin 1 first.
pub const header_40 = [40]Pin{
    .power_3v3,      .power_5v,
    .{ .gpio = 2 },  .power_5v,
    .{ .gpio = 3 },  .ground,
    .{ .gpio = 4 },  .{ .gpio = 14 },
    .ground,         .{ .gpio = 15 },
    .{ .gpio = 17 }, .{ .gpio = 18 },
    .{ .gpio = 27 }, .ground,
    .{ .gpio = 22 }, .{ .gpio = 23 },
    .power_3v3,      .{ .gpio = 24 },
    .{ .gpio = 10 }, .ground,
    .{ .gpio = 9 },  .{ .gpio = 25 },
    .{ .gpio = 11 }, .{ .gpio = 8 },
    .ground,         .{ .gpio = 7 },
    .{ .gpio = 0 },  .{ .gpio = 1 },
    .{ .gpio = 5 },  .ground,
    .{ .gpio = 6 },  .{ .gpio = 12 },
    .{ .gpio = 13 }, .ground,
    .{ .gpio = 19 }, .{ .gpio = 16 },
    .{ .gpio = 26 }, .{ .gpio = 20 },
    .ground,         .{ .gpio = 21 },
};

/// The 26-pin header of the first Model A and B (revision 2): the first 26
/// pins of the 40.
pub const header_26 = header_40[0..26].*;

/// The very first Model B's (revision 1): pins 3, 5 and 13 are GPIO 0, 1
/// and 21.
pub const header_26_rev1 = blk: {
    var h = header_26;
    h[2] = .{ .gpio = 0 };
    h[4] = .{ .gpio = 1 };
    h[12] = .{ .gpio = 21 };
    break :blk h;
};

/// The header of the board whose model this is (as the device tree says);
/// null for the Compute Modules, which have none.
pub fn headerFor(model: []const u8) ?[]const Pin {
    const has = struct {
        fn f(m: []const u8, s: []const u8) bool {
            return std.mem.indexOf(u8, m, s) != null;
        }
    }.f;
    if (has(model, "Compute Module")) return null;
    const first = !has(model, "Plus") and
        (std.mem.startsWith(u8, model, "Raspberry Pi Model A") or std.mem.startsWith(u8, model, "Raspberry Pi Model B"));
    if (first) return if (has(model, "Rev 1")) &header_26_rev1 else &header_26;
    return &header_40;
}

/// What an alternate function of a BCM283x pin is for, where it is one people
/// use (null otherwise).
pub fn altName(pin: u6, alt: u4) ?[]const u8 {
    const table = [_]struct { u6, u4, []const u8 }{
        .{ 0, 0, "I2C 0 data (HAT EEPROM)" }, .{ 1, 0, "I2C 0 clock (HAT EEPROM)" },
        .{ 0, 4, "UART 2 transmit" },         .{ 1, 4, "UART 2 receive" },
        .{ 2, 0, "I2C 1 data" },              .{ 3, 0, "I2C 1 clock" },
        .{ 2, 5, "I2C 3 data" },              .{ 3, 5, "I2C 3 clock" },
        .{ 4, 0, "General clock 0" },         .{ 5, 0, "General clock 1" },
        .{ 4, 4, "UART 3 transmit" },         .{ 5, 4, "UART 3 receive" },
        .{ 6, 0, "General clock 2" },         .{ 7, 0, "SPI 0 chip select 1" },
        .{ 6, 5, "I2C 4 data" },              .{ 7, 5, "I2C 4 clock" },
        .{ 8, 0, "SPI 0 chip select 0" },     .{ 9, 0, "SPI 0 MISO" },
        .{ 8, 4, "UART 4 transmit" },         .{ 9, 4, "UART 4 receive" },
        .{ 10, 0, "SPI 0 MOSI" },             .{ 11, 0, "SPI 0 clock" },
        .{ 10, 5, "I2C 5 data" },             .{ 11, 5, "I2C 5 clock" },
        .{ 12, 0, "PWM 0" },                  .{ 13, 0, "PWM 1" },
        .{ 12, 4, "UART 5 transmit" },        .{ 13, 4, "UART 5 receive" },
        .{ 14, 0, "UART 0 transmit" },        .{ 15, 0, "UART 0 receive" },
        .{ 14, 5, "UART 1 transmit" },        .{ 15, 5, "UART 1 receive" },
        .{ 16, 4, "SPI 1 chip select 2" },    .{ 17, 4, "SPI 1 chip select 1" },
        .{ 18, 4, "SPI 1 chip select 0" },    .{ 18, 0, "PCM clock" },
        .{ 18, 5, "PWM 0" },                  .{ 19, 0, "PCM frame" },
        .{ 19, 4, "SPI 1 MISO" },             .{ 19, 5, "PWM 1" },
        .{ 20, 0, "PCM in" },                 .{ 20, 4, "SPI 1 MOSI" },
        .{ 21, 0, "PCM out" },                .{ 21, 4, "SPI 1 clock" },
        .{ 22, 4, "JTAG reset" },             .{ 23, 4, "JTAG return clock" },
        .{ 22, 5, "I2C 6 data" },             .{ 23, 5, "I2C 6 clock" },
        .{ 24, 4, "JTAG data out" },          .{ 25, 4, "JTAG clock" },
        .{ 26, 4, "JTAG data in" },           .{ 27, 4, "JTAG mode" },
    };
    for (table) |e| if (e[0] == pin and e[1] == alt) return e[2];
    return null;
}

/// What a pin is usually for, besides GPIO, to label it on the header.
pub fn usualName(pin: u6) ?[]const u8 {
    return switch (pin) {
        0 => "ID SD",
        1 => "ID SC",
        2 => "SDA",
        3 => "SCL",
        4 => "GPCLK0",
        7 => "CE1",
        8 => "CE0",
        9 => "MISO",
        10 => "MOSI",
        11 => "SCLK",
        12 => "PWM0",
        13 => "PWM1",
        14 => "TXD",
        15 => "RXD",
        18 => "PCM CLK",
        else => null,
    };
}

/// What pull a pin has when the chip starts (from the BCM283x datasheet):
/// pins 0–8, 34–36 and 46–53 are pulled up; 28–29 and 44–45 have no pull;
/// the rest are pulled down.
pub fn defaultInputMode(pin: u6) Mode {
    return switch (pin) {
        0...8, 34...36, 46...53 => .input_pull_up,
        28...29, 44...45 => .input,
        else => .input_pull_down,
    };
}

/// Formats what a GPIO pin is doing now ("Output, high", "Input, low", or its
/// alternate function description).
pub fn gpioDoing(buf: []u8, gpio_hw: *const Gpio, g: u6) []const u8 {
    const func = gpio_hw.getPinFunction(g);
    const high = gpio_hw.getPinLevel(g);
    const level = if (high) "high" else "low";
    return switch (func) {
        .output => std.fmt.bufPrint(buf, "Output, {s}", .{level}) catch "Output",
        .input => std.fmt.bufPrint(buf, "Input, {s}", .{level}) catch "Input",
        else => |f| if (altName(g, f.alt().?)) |n| n else std.fmt.bufPrint(buf, "Alternate function {d}", .{f.alt().?}) catch "Alternate function",
    };
}

const testing = std.testing;

test "headers by board" {
    try testing.expectEqual(@as(usize, 40), headerFor("Raspberry Pi Zero Rev 1.3").?.len);
    try testing.expectEqual(@as(usize, 40), headerFor("Raspberry Pi Zero W Rev 1.1").?.len);
    try testing.expectEqual(@as(usize, 40), headerFor("Raspberry Pi 3 Model B Plus Rev 1.3").?.len);
    const b2 = headerFor("Raspberry Pi Model B Rev 2").?;
    try testing.expectEqual(@as(usize, 26), b2.len);
    try testing.expectEqual(Pin{ .gpio = 2 }, b2[2]);
    const b1 = headerFor("Raspberry Pi Model B Rev 1").?;
    try testing.expectEqual(Pin{ .gpio = 0 }, b1[2]);
    try testing.expectEqual(Pin{ .gpio = 21 }, b1[12]);
    try testing.expect(headerFor("Raspberry Pi Compute Module 3 Rev 1.0") == null);

    var seen: [28]bool = @splat(false);
    for (header_40) |pin| switch (pin) {
        .gpio => |g| {
            try testing.expect(!seen[g]);
            seen[g] = true;
        },
        else => {},
    };
    for (seen) |s| try testing.expect(s);
}

test "what a pin is set up as on BCM2835 Gpio" {
    var hw: Gpio = .{};
    // Pin 4 defaults to input pulled up -> high
    try testing.expectEqual(@as(?Mode, .input_pull_up), hw.getPinMode(4));
    try testing.expect(hw.getPinLevel(4));

    // Pin 17 defaults to input pulled down -> low
    try testing.expectEqual(@as(?Mode, .input_pull_down), hw.getPinMode(17));
    try testing.expect(!hw.getPinLevel(17));

    // Set pin 17 to output high
    hw.setPinMode(17, .output_high);
    try testing.expectEqual(@as(?Mode, .output_high), hw.getPinMode(17));
    try testing.expect(hw.getPinLevel(17));

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Output, high", gpioDoing(&buf, &hw, 17));

    hw.setPinFunction(14, .alt0);
    try testing.expectEqualStrings("UART 0 transmit", gpioDoing(&buf, &hw, 14));
}
