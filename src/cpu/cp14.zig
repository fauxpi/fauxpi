//! ARM1176JZF-S CP14 debug unit (ARMv6.1 debug architecture).
//!
//! Implements the registers software reaches through `MRC`/`MCR p14, 0`: the Debug ID Register,
//! the Debug Status and Control Register, the Data Transfer Register, the Watchpoint Fault Address
//! Register, the Vector Catch Register, and the six breakpoint and two watchpoint value/control
//! pairs. Breakpoint and watchpoint matching is not modelled; the registers hold their values.

const std = @import("std");

pub const Arm1176Debug = struct {
    /// `DIDR`: 2 watchpoints, 6 breakpoints (2 context-ID capable), v6.1 debug, r0p7.
    pub const DIDR: u32 = 0x1512_0007;
    pub const DSCR_MDBGEN: u32 = 1 << 15;
    pub const DSCR_UDCCDIS: u32 = 1 << 12;
    /// DSCR bits software can write over CP14 (halting debug is only enabled from JTAG).
    const DSCR_WRITABLE: u32 = DSCR_MDBGEN | DSCR_UDCCDIS;
    pub const NUM_BRP = 6;
    pub const NUM_WRP = 2;

    dscr: u32 = 0,
    wfar: u32 = 0,
    vcr: u32 = 0,
    bvr: [NUM_BRP]u32 = @splat(0),
    bcr: [NUM_BRP]u32 = @splat(0),
    wvr: [NUM_WRP]u32 = @splat(0),
    wcr: [NUM_WRP]u32 = @splat(0),

    /// Whether `MRC`/`MCR p14, opc1, crn, crm, opc2` names a register; unprivileged software may
    /// only read DSCR and use the DTR while user DCC access is enabled.
    pub fn accessible(self: *const Arm1176Debug, opc1: u3, crn: u4, crm: u4, opc2: u3, privileged: bool, is_read: bool) bool {
        if (opc1 != 0 or crn != 0) return false;
        const valid = switch (opc2) {
            0 => switch (crm) {
                0 => is_read,
                1 => true,
                5, 6, 7 => true,
                else => false,
            },
            4, 5 => crm < NUM_BRP,
            6, 7 => crm < NUM_WRP,
            else => false,
        };
        if (!valid) return false;
        if (privileged) return true;
        if ((self.dscr & DSCR_UDCCDIS) != 0) return false;
        return opc2 == 0 and ((crm == 1 and is_read) or crm == 5);
    }

    pub fn read(self: *const Arm1176Debug, crm: u4, opc2: u3) u32 {
        return switch (opc2) {
            0 => switch (crm) {
                0 => DIDR,
                1 => self.dscr,
                6 => self.wfar,
                7 => self.vcr,
                else => 0, // DTR: no debugger is attached to send data
            },
            4 => self.bvr[crm],
            5 => self.bcr[crm],
            6 => self.wvr[crm],
            7 => self.wcr[crm],
            else => 0,
        };
    }

    pub fn write(self: *Arm1176Debug, crm: u4, opc2: u3, value: u32) void {
        switch (opc2) {
            0 => switch (crm) {
                1 => self.dscr = (self.dscr & ~DSCR_WRITABLE) | (value & DSCR_WRITABLE),
                6 => self.wfar = value,
                7 => self.vcr = value,
                else => {}, // DTR writes go to a debugger, of which there is none
            },
            4 => self.bvr[crm] = value,
            5 => self.bcr[crm] = value,
            6 => self.wvr[crm] = value,
            7 => self.wcr[crm] = value,
            else => {},
        }
    }
};

test "ARM1176 debug unit identifies v6.1 debug and enables monitor mode" {
    var dbg = Arm1176Debug{};
    try std.testing.expect(dbg.accessible(0, 0, 0, 0, true, true));
    try std.testing.expectEqual(@as(u32, 2), (dbg.read(0, 0) >> 16) & 0xf);
    try std.testing.expectEqual(@as(u32, 6), ((dbg.read(0, 0) >> 24) & 0xf) + 1);
    try std.testing.expectEqual(@as(u32, 2), ((dbg.read(0, 0) >> 28) & 0xf) + 1);

    dbg.write(1, 0, 0xffff_ffff);
    try std.testing.expectEqual(Arm1176Debug.DSCR_MDBGEN | Arm1176Debug.DSCR_UDCCDIS, dbg.read(1, 0));
    dbg.write(5, 5, 0x1e7);
    try std.testing.expectEqual(@as(u32, 0x1e7), dbg.read(5, 5));

    try std.testing.expect(dbg.accessible(0, 0, 1, 0, true, false));

    // DIDR is read-only, nonexistent pairs and other opc1 are undefined, user access is limited
    try std.testing.expect(!dbg.accessible(0, 0, 0, 0, true, false));
    try std.testing.expect(!dbg.accessible(0, 0, 6, 4, true, true));
    try std.testing.expect(!dbg.accessible(7, 0, 0, 0, true, true));
    try std.testing.expect(!dbg.accessible(0, 0, 1, 0, false, true));
    dbg.write(1, 0, 0);
    try std.testing.expect(dbg.accessible(0, 0, 1, 0, false, true));
    try std.testing.expect(!dbg.accessible(0, 0, 0, 0, false, true));
}
