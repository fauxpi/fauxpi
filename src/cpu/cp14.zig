//! CP14 debug units reached through `MRC`/`MCR p14, 0` in AArch32: the ARM1176JZF-S's (ARMv6.1
//! debug) and the Cortex-A53's (ARMv8 debug).
//!
//! Each implements the Debug ID Register, the Debug Status and Control Register, the Data Transfer
//! Register, the Watchpoint Fault Address Register, the Vector Catch Register, and the breakpoint
//! and watchpoint value/control pairs; the Cortex-A53 adds the OS Lock and power-down registers.
//! Breakpoint and watchpoint matching is not modelled; the registers hold their values.

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

/// Cortex-A53 AArch32 debug registers (ARMv8 debug), as reached from EL1 and EL0.
pub const CortexA53Debug = struct {
    /// `DBGDIDR`: 4 watchpoints, 6 breakpoints (2 context-matching), ARMv8 debug, EL3 implemented, r0p4.
    pub const DIDR: u32 = 0x3516_d004;
    pub const DSCR_MDBGEN: u32 = 1 << 15;
    pub const DSCR_UDCCDIS: u32 = 1 << 12;
    /// `DBGDSCRext` bits software can write: INTdis, TDA, MDBGEN and UDCCdis.
    const DSCR_WRITABLE: u32 = (3 << 22) | (1 << 21) | DSCR_MDBGEN | DSCR_UDCCDIS;
    /// `DBGOSLSR.OSLM` = 0b10: the OS Lock is implemented (ARMv8)
    const OSLSR_OSLM: u32 = 1 << 3;
    const OSLSR_OSLK: u32 = 1 << 1;
    /// `DBGOSLAR` value that locks the OS Lock
    pub const OS_LOCK_KEY: u32 = 0xc5ac_ce55;
    pub const NUM_BRP = 6;
    pub const NUM_WRP = 4;

    dscr: u32 = 0,
    wfar: u32 = 0,
    vcr: u32 = 0,
    bvr: [NUM_BRP]u32 = @splat(0),
    bcr: [NUM_BRP]u32 = @splat(0),
    wvr: [NUM_WRP]u32 = @splat(0),
    wcr: [NUM_WRP]u32 = @splat(0),
    /// The OS Lock is set by a cold reset
    os_lock: bool = true,
    os_double_lock: bool = false,
    prcr: u32 = 0,

    /// Whether `MRC`/`MCR p14, opc1, crn, crm, opc2` names a register that may be accessed;
    /// at EL0 only `DBGDSCRint` reads and the internal DTR are allowed, while user DCC access is enabled.
    pub fn accessible(self: *const CortexA53Debug, opc1: u3, crn: u4, crm: u4, opc2: u3, privileged: bool, is_read: bool) bool {
        if (opc1 != 0) return false;
        const valid = switch (crn) {
            0 => switch (opc2) {
                0 => switch (crm) {
                    0, 1 => is_read, // DBGDIDR, DBGDSCRint
                    5, 6, 7 => true, // DBGDTR{RX,TX}int, DBGWFAR, DBGVCR
                    else => false,
                },
                2 => crm == 0 or crm == 2 or crm == 3, // DBGDTRRXext, DBGDSCRext, DBGDTRTXext
                4, 5 => crm < NUM_BRP,
                6, 7 => crm < NUM_WRP,
                else => false,
            },
            1 => switch (opc2) {
                0 => crm == 0 and is_read, // DBGDRAR
                4 => switch (crm) {
                    0 => !is_read, // DBGOSLAR
                    1 => is_read, // DBGOSLSR
                    3, 4 => true, // DBGOSDLR, DBGPRCR
                    else => false,
                },
                else => false,
            },
            2 => opc2 == 0 and crm == 0 and is_read, // DBGDSAR
            else => false,
        };
        if (!valid) return false;
        if (privileged) return true;
        if ((self.dscr & DSCR_UDCCDIS) != 0) return false;
        return crn == 0 and opc2 == 0 and ((crm == 1 and is_read) or crm == 5);
    }

    pub fn read(self: *const CortexA53Debug, crn: u4, crm: u4, opc2: u3) u32 {
        return switch (crn) {
            0 => switch (opc2) {
                0 => switch (crm) {
                    0 => DIDR,
                    1 => self.dscr,
                    6 => self.wfar,
                    7 => self.vcr,
                    else => 0, // DTR: no debugger is attached to send data
                },
                2 => if (crm == 2) self.dscr else 0,
                4 => self.bvr[crm],
                5 => self.bcr[crm],
                6 => self.wvr[crm],
                7 => self.wcr[crm],
                else => 0,
            },
            1 => switch (crm) {
                1 => OSLSR_OSLM | if (self.os_lock) OSLSR_OSLK else 0,
                3 => @intFromBool(self.os_double_lock),
                4 => self.prcr,
                else => 0, // DBGDRAR: no debug ROM table address is valid
            },
            else => 0, // DBGDSAR: no debug self address is valid
        };
    }

    pub fn write(self: *CortexA53Debug, crn: u4, crm: u4, opc2: u3, value: u32) void {
        switch (crn) {
            0 => switch (opc2) {
                0 => switch (crm) {
                    6 => self.wfar = value,
                    7 => self.vcr = value,
                    else => {}, // DTR writes go to a debugger, of which there is none
                },
                2 => if (crm == 2) {
                    self.dscr = (self.dscr & ~DSCR_WRITABLE) | (value & DSCR_WRITABLE);
                },
                4 => self.bvr[crm] = value,
                5 => self.bcr[crm] = value,
                6 => self.wvr[crm] = value,
                7 => self.wcr[crm] = value,
                else => {},
            },
            1 => switch (crm) {
                0 => self.os_lock = value == OS_LOCK_KEY,
                3 => self.os_double_lock = (value & 1) != 0,
                4 => self.prcr = value & 1, // CORENPDRQ
                else => {},
            },
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

test "Cortex-A53 AArch32 debug unit identifies ARMv8 debug, unlocks and enables monitor mode" {
    var dbg = CortexA53Debug{};
    const didr = dbg.read(0, 0, 0);
    try std.testing.expectEqual(@as(u32, 6), (didr >> 16) & 0xf);
    try std.testing.expectEqual(@as(u32, 6), ((didr >> 24) & 0xf) + 1);
    try std.testing.expectEqual(@as(u32, 4), ((didr >> 28) & 0xf) + 1);

    // The OS Lock is set out of reset; any value but the key clears it
    try std.testing.expectEqual(@as(u32, 0b1010), dbg.read(1, 1, 4));
    dbg.write(1, 0, 4, ~CortexA53Debug.OS_LOCK_KEY);
    try std.testing.expectEqual(@as(u32, 0b1000), dbg.read(1, 1, 4));

    // MDBGEN is written through DBGDSCRext and seen through DBGDSCRint
    try std.testing.expect(dbg.accessible(0, 0, 2, 2, true, false));
    try std.testing.expect(!dbg.accessible(0, 0, 1, 0, true, false));
    dbg.write(0, 2, 2, 0xffff_ffff);
    try std.testing.expect((dbg.read(0, 1, 0) & CortexA53Debug.DSCR_MDBGEN) != 0);
    try std.testing.expectEqual(@as(u32, 0), dbg.read(0, 1, 0) & (1 << 14)); // HDE is not software writable

    // Breakpoint and watchpoint pairs, and the ranges beyond them
    dbg.write(0, 3, 7, 0x1e7);
    try std.testing.expectEqual(@as(u32, 0x1e7), dbg.read(0, 3, 7));
    try std.testing.expect(dbg.accessible(0, 0, 5, 5, true, true));
    try std.testing.expect(!dbg.accessible(0, 0, 6, 5, true, true));
    try std.testing.expect(!dbg.accessible(0, 0, 4, 7, true, true));

    // EL0 may read DBGDSCRint only while user DCC access is enabled
    try std.testing.expect(!dbg.accessible(0, 0, 1, 0, false, true)); // UDCCdis was set above
    dbg.write(0, 2, 2, 0);
    try std.testing.expect(dbg.accessible(0, 0, 1, 0, false, true));
    try std.testing.expect(!dbg.accessible(0, 0, 0, 0, false, true));
    try std.testing.expect(!dbg.accessible(0, 1, 1, 4, false, true));
}
