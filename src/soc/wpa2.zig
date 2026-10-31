//! WPA2-Personal (IEEE 802.11i RSNA with a pre-shared key) for the emulated Wi-Fi access point:
//! the authenticator side of the 4-way handshake, which brings a station from associated to
//! authorized. The station is the guest's own supplicant (wpa_supplicant), so this checks its
//! frames the way a real access point would; a wrong passphrase fails the handshake.
//!
//! - PMK = PBKDF2-HMAC-SHA1(passphrase, SSID, 4096 iterations, 32 bytes)
//! - PTK = PRF-384(PMK, "Pairwise key expansion", AA/SPA and ANonce/SNonce, each lower first):
//!   KCK (MICs), KEK (wraps the group key), TK
//! - EAPOL-Key frames use descriptor version 2: HMAC-SHA1-128 MICs, AES key wrap (RFC 3394)
//!
//! The frames that follow are not encrypted: the emulated radio link is never observed, so the
//! temporal keys the guest installs are only accepted.

const std = @import("std");
const HmacSha1 = std.crypto.auth.hmac.HmacSha1;
const Aes128 = std.crypto.core.aes.Aes128;

/// RSN IE for WPA2-PSK with CCMP: version 1, group cipher CCMP, one pairwise cipher (CCMP),
/// one AKM (PSK), no capabilities (no management frame protection)
pub const rsn_ie = [_]u8{
    0x30, 0x14, 0x01, 0x00,
    0x00, 0x0f, 0xac, 0x04,
    0x01, 0x00, 0x00, 0x0f,
    0xac, 0x04, 0x01, 0x00,
    0x00, 0x0f, 0xac, 0x02,
    0x00, 0x00,
};

pub fn pmkFromPassphrase(passphrase: []const u8, ssid: []const u8) [32]u8 {
    var pmk: [32]u8 = undefined;
    std.crypto.pwhash.pbkdf2(&pmk, passphrase, ssid, 4096, HmacSha1) catch unreachable;
    return pmk;
}

/// IEEE 802.11 PRF: HMAC-SHA1(key, label || 0 || data || i) for i = 0, 1, ... into `out`
pub fn prf(key: []const u8, label: []const u8, data: []const u8, out: []u8) void {
    var i: u8 = 0;
    var off: usize = 0;
    while (off < out.len) : (i += 1) {
        var h = HmacSha1.init(key);
        h.update(label);
        h.update(&.{0});
        h.update(data);
        h.update(&.{i});
        var block: [HmacSha1.mac_length]u8 = undefined;
        h.final(&block);
        const n = @min(block.len, out.len - off);
        @memcpy(out[off..][0..n], block[0..n]);
        off += n;
    }
}

pub const Ptk = struct {
    kck: [16]u8,
    kek: [16]u8,
    tk: [16]u8,
};

/// The pairwise transient key for authenticator address `aa` and supplicant address `spa`
pub fn derivePtk(pmk: [32]u8, aa: [6]u8, spa: [6]u8, anonce: [32]u8, snonce: [32]u8) Ptk {
    var data: [6 + 6 + 32 + 32]u8 = undefined;
    const aa_low = std.mem.order(u8, &aa, &spa) == .lt;
    @memcpy(data[0..6], if (aa_low) &aa else &spa);
    @memcpy(data[6..12], if (aa_low) &spa else &aa);
    const a_low = std.mem.order(u8, &anonce, &snonce) == .lt;
    @memcpy(data[12..44], if (a_low) &anonce else &snonce);
    @memcpy(data[44..76], if (a_low) &snonce else &anonce);
    var out: [48]u8 = undefined;
    prf(&pmk, "Pairwise key expansion", &data, &out);
    return .{ .kck = out[0..16].*, .kek = out[16..32].*, .tk = out[32..48].* };
}

/// AES key wrap (RFC 3394) of `plain` (a multiple of 8 bytes) into `out` (8 bytes longer)
pub fn aesKeyWrap(kek: [16]u8, plain: []const u8, out: []u8) void {
    std.debug.assert(plain.len % 8 == 0 and out.len == plain.len + 8);
    const ctx = Aes128.initEnc(kek);
    const n = plain.len / 8;
    var a: [8]u8 = @splat(0xa6);
    @memcpy(out[8..], plain);
    for (0..6) |j| {
        for (1..n + 1) |i| {
            var b: [16]u8 = undefined;
            @memcpy(b[0..8], &a);
            @memcpy(b[8..16], out[i * 8 ..][0..8]);
            ctx.encrypt(&b, &b);
            const t: u64 = @intCast(n * j + i);
            const msb = std.mem.readInt(u64, b[0..8], .big) ^ t;
            std.mem.writeInt(u64, &a, msb, .big);
            @memcpy(out[i * 8 ..][0..8], b[8..16]);
        }
    }
    @memcpy(out[0..8], &a);
}

/// HMAC-SHA1-128 MIC of an EAPOL frame (with its MIC field zeroed)
pub fn eapolMic(kck: [16]u8, frame: []const u8) [16]u8 {
    var full: [HmacSha1.mac_length]u8 = undefined;
    HmacSha1.create(&full, frame, &kck);
    return full[0..16].*;
}

// EAPOL-Key frame (802.1X header, then the key descriptor) offsets
pub const KEY_INFO = 5;
pub const KEY_LENGTH = 7;
pub const REPLAY = 9;
pub const NONCE = 17;
pub const MIC = 81;
pub const KEY_DATA_LEN = 97;
pub const KEY_DATA = 99;

// Key Information bits (descriptor version 2: HMAC-SHA1 MIC, AES key wrap)
pub const KI_VERSION_2: u16 = 2;
pub const KI_PAIRWISE: u16 = 1 << 3;
pub const KI_INSTALL: u16 = 1 << 6;
pub const KI_ACK: u16 = 1 << 7;
pub const KI_MIC: u16 = 1 << 8;
pub const KI_SECURE: u16 = 1 << 9;
pub const KI_ENCRYPTED: u16 = 1 << 12;

pub const MAX_FRAME = KEY_DATA + 64;

/// The access point's side of the 4-way handshake with one station
pub const Authenticator = struct {
    pmk: [32]u8,
    aa: [6]u8,
    spa: [6]u8,
    anonce: [32]u8,
    gtk: [16]u8,
    ptk: ?Ptk = null,
    replay: u64 = 0,
    state: State = .wait_m2,

    pub const State = enum { wait_m2, wait_m4, done };

    pub const Result = union(enum) {
        /// Not a handshake frame for this state: ignored, as an access point drops it
        ignore,
        /// Send this EAPOL frame (message 3) to the station
        send: []const u8,
        /// Handshake complete: the station is authorized
        done,
        /// The station's MIC is wrong (another passphrase): the handshake fails
        failed,
    };

    /// Message 1: the ANonce, asking the station for its SNonce
    pub fn message1(self: *Authenticator, out: *[MAX_FRAME]u8) []const u8 {
        self.replay = 1;
        self.state = .wait_m2;
        return buildKey(out, KI_VERSION_2 | KI_PAIRWISE | KI_ACK, self.replay, self.anonce, &.{}, null);
    }

    /// Handles the station's EAPOL frame `frame` (802.1X header onwards)
    pub fn receive(self: *Authenticator, frame: []const u8, out: *[MAX_FRAME]u8) Result {
        if (frame.len < KEY_DATA or frame[1] != 3 or frame[4] != 2) return .ignore;
        const body_len = std.mem.readInt(u16, frame[2..4], .big);
        if (4 + @as(usize, body_len) > frame.len) return .ignore;
        const msg = frame[0 .. 4 + body_len];
        const info = std.mem.readInt(u16, msg[KEY_INFO..][0..2], .big);
        if ((info & (KI_PAIRWISE | KI_MIC | KI_ACK)) != (KI_PAIRWISE | KI_MIC)) return .ignore;
        if (std.mem.readInt(u64, msg[REPLAY..][0..8], .big) != self.replay) return .ignore;

        switch (self.state) {
            .wait_m2 => {
                if ((info & KI_SECURE) != 0) return .ignore;
                const ptk = derivePtk(self.pmk, self.aa, self.spa, self.anonce, msg[NONCE..][0..32].*);
                if (!micMatches(ptk.kck, msg)) return .failed;
                self.ptk = ptk;
                // Message 3: install the pairwise key, with the RSN IE and the group key
                // (a GTK KDE, key ID 1) wrapped with the KEK
                var key_data: [48]u8 = @splat(0);
                @memcpy(key_data[0..rsn_ie.len], &rsn_ie);
                const kde = key_data[rsn_ie.len..];
                kde[0..8].* = .{ 0xdd, 6 + 16, 0x00, 0x0f, 0xac, 0x01, 0x01, 0x00 };
                @memcpy(kde[8..24], &self.gtk);
                key_data[rsn_ie.len + 24] = 0xdd; // padding to a multiple of 8
                var wrapped: [56]u8 = undefined;
                aesKeyWrap(ptk.kek, &key_data, &wrapped);
                self.replay += 1;
                self.state = .wait_m4;
                const info3 = KI_VERSION_2 | KI_PAIRWISE | KI_INSTALL | KI_ACK | KI_MIC | KI_SECURE | KI_ENCRYPTED;
                return .{ .send = buildKey(out, info3, self.replay, self.anonce, &wrapped, ptk.kck) };
            },
            .wait_m4 => {
                if ((info & KI_SECURE) == 0) return .ignore;
                if (!micMatches(self.ptk.?.kck, msg)) return .failed;
                self.state = .done;
                return .done;
            },
            .done => return .ignore,
        }
    }

    fn micMatches(kck: [16]u8, msg: []const u8) bool {
        var copy: [512]u8 = undefined;
        if (msg.len > copy.len) return false;
        @memcpy(copy[0..msg.len], msg);
        @memset(copy[MIC..][0..16], 0);
        const want = eapolMic(kck, copy[0..msg.len]);
        return std.crypto.timing_safe.eql([16]u8, want, msg[MIC..][0..16].*);
    }
};

/// An EAPOL-Key frame (802.1X version 2, RSN key descriptor, CCMP key length), with a MIC
/// under `kck` if given
pub fn buildKey(out: *[MAX_FRAME]u8, info: u16, replay: u64, nonce: [32]u8, key_data: []const u8, kck: ?[16]u8) []const u8 {
    const len = KEY_DATA + key_data.len;
    @memset(out[0..len], 0);
    out[0] = 2; // 802.1X-2004
    out[1] = 3; // EAPOL-Key
    std.mem.writeInt(u16, out[2..4], @intCast(len - 4), .big);
    out[4] = 2; // RSN key descriptor
    std.mem.writeInt(u16, out[KEY_INFO..][0..2], info, .big);
    std.mem.writeInt(u16, out[KEY_LENGTH..][0..2], 16, .big);
    std.mem.writeInt(u64, out[REPLAY..][0..8], replay, .big);
    @memcpy(out[NONCE..][0..32], &nonce);
    std.mem.writeInt(u16, out[KEY_DATA_LEN..][0..2], @intCast(key_data.len), .big);
    @memcpy(out[KEY_DATA..][0..key_data.len], key_data);
    if (kck) |k| out[MIC..][0..16].* = eapolMic(k, out[0..len]);
    return out[0..len];
}

test "WPA2 PMK, PRF and AES key wrap match the IEEE 802.11 and RFC 3394 vectors" {
    var want: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want, "f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e");
    try std.testing.expectEqualSlices(u8, &want, &pmkFromPassphrase("password", "IEEE"));

    var out: [64]u8 = undefined;
    prf("Jefe", "prefix", "what do ya want for nothing?", &out);
    var want_prf: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want_prf, "51f4de5b33f249adf81aeb713a3c20f4fe631446fabdfa58244759ae58ef9009a99abf4eac2ca5fa87e692c440eb40023e7babb206d61de7b92f41529092b8fc");
    try std.testing.expectEqualSlices(u8, &want_prf, &out);

    var kek: [16]u8 = undefined;
    for (&kek, 0..) |*b, i| b.* = @intCast(i);
    var wrapped: [24]u8 = undefined;
    var plain: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&plain, "00112233445566778899aabbccddeeff");
    aesKeyWrap(kek, &plain, &wrapped);
    var want_wrap: [24]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want_wrap, "1fa68b0a8112b447aef34bd8fb5a7b829d3e862371d2cfe5");
    try std.testing.expectEqualSlices(u8, &want_wrap, &wrapped);

    var plain48: [48]u8 = undefined;
    for (&plain48, 0..) |*b, i| b.* = @intCast(i);
    var wrapped56: [56]u8 = undefined;
    aesKeyWrap(kek, &plain48, &wrapped56);
    var want56: [56]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want56, "b37c378ecb4211ec022189d70b826a5bb1c4118933a12da21e76fbd45fac173f5f00b01ca7d63b5cd9af141c04374604e461886cabcbccbc");
    try std.testing.expectEqualSlices(u8, &want56, &wrapped56);
}

/// A station's reply to `m` (message 1 or 3) with key information `info`, as a supplicant
/// sends it: its SNonce (message 2) and MIC under `kck`
fn testStationReply(m: []const u8, info: u16, snonce: [32]u8, key_data: []const u8, kck: [16]u8, out: *[MAX_FRAME]u8) []const u8 {
    const replay = std.mem.readInt(u64, m[REPLAY..][0..8], .big);
    return buildKey(out, info, replay, snonce, key_data, kck);
}

test "WPA2 4-way handshake authorizes a station with the passphrase and fails one without" {
    const pmk = pmkFromPassphrase("correct horse", "tokamak");
    const aa = [6]u8{ 0x1e, 0x8b, 0xaa, 0xda, 0x27, 0x96 };
    const spa = [6]u8{ 0xb8, 0x27, 0xeb, 0x01, 0x02, 0x03 };
    const snonce: [32]u8 = @splat(0x5a);

    for ([_][]const u8{ "correct horse", "wrong horse" }) |passphrase| {
        var auth = Authenticator{ .pmk = pmk, .aa = aa, .spa = spa, .anonce = @splat(0xa5), .gtk = @splat(0x47) };
        var m1_buf: [MAX_FRAME]u8 = undefined;
        const m1 = auth.message1(&m1_buf);
        try std.testing.expectEqual(KI_VERSION_2 | KI_PAIRWISE | KI_ACK, std.mem.readInt(u16, m1[KEY_INFO..][0..2], .big));

        // The station derives the PTK from its own passphrase and the ANonce
        const sta_ptk = derivePtk(pmkFromPassphrase(passphrase, "tokamak"), aa, spa, m1[NONCE..][0..32].*, snonce);
        var m2_buf: [MAX_FRAME]u8 = undefined;
        const m2 = testStationReply(m1, KI_VERSION_2 | KI_PAIRWISE | KI_MIC, snonce, &rsn_ie, sta_ptk.kck, &m2_buf);
        var out: [MAX_FRAME]u8 = undefined;
        const r3 = auth.receive(m2, &out);
        if (std.mem.eql(u8, passphrase, "wrong horse")) {
            try std.testing.expectEqual(Authenticator.Result.failed, r3);
            continue;
        }
        const m3 = r3.send;
        // Message 3 verifies under the station's KCK and carries the wrapped RSN IE and GTK
        var check: [MAX_FRAME]u8 = undefined;
        @memcpy(check[0..m3.len], m3);
        @memset(check[MIC..][0..16], 0);
        try std.testing.expectEqualSlices(u8, &eapolMic(sta_ptk.kck, check[0..m3.len]), m3[MIC..][0..16]);
        try std.testing.expectEqual(@as(u16, 56), std.mem.readInt(u16, m3[KEY_DATA_LEN..][0..2], .big));

        var m4_buf: [MAX_FRAME]u8 = undefined;
        const m4 = testStationReply(m3, KI_VERSION_2 | KI_PAIRWISE | KI_MIC | KI_SECURE, @splat(0), &.{}, sta_ptk.kck, &m4_buf);
        try std.testing.expectEqual(Authenticator.Result.done, auth.receive(m4, &out));
    }
}
