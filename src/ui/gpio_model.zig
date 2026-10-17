//! The 40-pin GPIO header layout: which physical pin on the Raspberry Pi
//! header corresponds to power, ground, or a Broadcom GPIO line (`0..27`).

const std = @import("std");

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

const testing = std.testing;

test "40-pin GPIO header covers all 28 BCM GPIO lines" {
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


