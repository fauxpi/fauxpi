const std = @import("std");
const linux = std.os.linux;

/// User-mode NAT / SLIRP virtual network stack for CDC-ECM USB Ethernet.
/// Provides virtual gateway `10.0.2.2` (`52:55:0a:00:02:02`), DHCP server (`10.0.2.15/24`),
/// ARP responder, ICMP Echo responder, built-in SNTP server (UDP 123), and non-blocking
/// UDP/TCP NAT forwarding via unprivileged host sockets.
pub const VirtualNetwork = struct {
    pub const GATEWAY_MAC = [6]u8{ 0x52, 0x55, 0x0a, 0x00, 0x02, 0x02 };
    pub const DEFAULT_GUEST_MAC = [6]u8{ 0xb8, 0x27, 0xeb, 0x12, 0x34, 0x56 };
    pub const GATEWAY_IP = [4]u8{ 10, 0, 2, 2 };
    pub const DEFAULT_GUEST_IP = [4]u8{ 10, 0, 2, 15 };
    pub const NETMASK = [4]u8{ 255, 255, 255, 0 };
    pub const BROADCAST_IP = [4]u8{ 10, 0, 2, 255 };

    pub const MAX_FRAME_LEN = 1536;
    pub const RX_QUEUE_CAP = 32;
    pub const MAX_UDP_SESSIONS = 16;
    pub const MAX_TCP_CONNS = 16;

    pub const UdpSession = struct {
        active: bool = false,
        fd: linux.fd_t = -1,
        guest_mac: [6]u8 = DEFAULT_GUEST_MAC,
        guest_ip: [4]u8 = DEFAULT_GUEST_IP,
        guest_port: u16 = 0,
        dst_ip: [4]u8 = .{ 0, 0, 0, 0 },
        dst_port: u16 = 0,
        last_tick: u64 = 0,
    };

    pub const TcpState = enum(u8) {
        unused,
        established,
        fin_sent,
    };

    pub const TcpConn = struct {
        state: TcpState = .unused,
        fd: linux.fd_t = -1,
        guest_mac: [6]u8 = DEFAULT_GUEST_MAC,
        guest_ip: [4]u8 = DEFAULT_GUEST_IP,
        guest_port: u16 = 0,
        dst_ip: [4]u8 = .{ 0, 0, 0, 0 },
        dst_port: u16 = 0,
        my_seq: u32 = 0,
        guest_seq: u32 = 0,
        tx_buf: [4096]u8 = undefined,
        tx_len: usize = 0,
        last_tick: u64 = 0,
    };

    guest_mac: [6]u8 = DEFAULT_GUEST_MAC,
    guest_ip: [4]u8 = DEFAULT_GUEST_IP,
    ip_id: u16 = 1,
    tick_count: u64 = 0,
    dns_resolved: bool = false,
    host_dns_ip: [4]u8 = .{ 1, 1, 1, 1 },

    rx_frames: [RX_QUEUE_CAP][MAX_FRAME_LEN]u8 = undefined,
    rx_lens: [RX_QUEUE_CAP]u16 = [_]u16{0} ** RX_QUEUE_CAP,
    rx_head: u5 = 0,
    rx_tail: u5 = 0,
    rx_count: u6 = 0,

    udp_sessions: [MAX_UDP_SESSIONS]UdpSession = [_]UdpSession{.{}} ** MAX_UDP_SESSIONS,
    tcp_conns: [MAX_TCP_CONNS]TcpConn = [_]TcpConn{.{}} ** MAX_TCP_CONNS,

    pub fn deinit(self: *VirtualNetwork) void {
        for (&self.udp_sessions) |*s| {
            if (s.active and s.fd >= 0) {
                _ = linux.close(s.fd);
            }
            s.* = .{};
        }
        for (&self.tcp_conns) |*c| {
            if (c.state != .unused and c.fd >= 0) {
                _ = linux.close(c.fd);
            }
            c.* = .{};
        }
    }

    pub fn hasRxFrame(self: *const VirtualNetwork) bool {
        return self.rx_count > 0;
    }

    pub fn enqueueRxFrame(self: *VirtualNetwork, frame: []const u8) void {
        if (frame.len == 0 or frame.len > MAX_FRAME_LEN) return;
        if (self.rx_count >= RX_QUEUE_CAP) return;
        @memcpy(self.rx_frames[self.rx_tail][0..frame.len], frame);
        self.rx_lens[self.rx_tail] = @intCast(frame.len);
        self.rx_tail +%= 1;
        self.rx_count += 1;
    }

    pub fn popRxFrame(self: *VirtualNetwork, dest: []u8) ?usize {
        if (self.rx_count == 0) return null;
        const frame_len: usize = self.rx_lens[self.rx_head];
        const copy_len = @min(dest.len, frame_len);
        @memcpy(dest[0..copy_len], self.rx_frames[self.rx_head][0..copy_len]);
        self.rx_head +%= 1;
        self.rx_count -= 1;
        return copy_len;
    }

    /// Processes a complete Ethernet frame transmitted by the guest over USB Bulk OUT.
    pub fn handleTxFrame(self: *VirtualNetwork, frame: []const u8) void {
        if (frame.len < 14) return;
        const src_mac = frame[6..12];
        if ((src_mac[0] & 1) == 0) {
            @memcpy(&self.guest_mac, src_mac);
        }
        const ethertype = std.mem.readInt(u16, frame[12..14], .big);
        switch (ethertype) {
            0x0806 => self.handleArp(frame[14..]),
            0x0800 => self.handleIpv4(frame[14..]),
            else => {},
        }
    }

    fn handleArp(self: *VirtualNetwork, pkt: []const u8) void {
        if (pkt.len < 28) return;
        const htype = std.mem.readInt(u16, pkt[0..2], .big);
        const ptype = std.mem.readInt(u16, pkt[2..4], .big);
        const hlen = pkt[4];
        const plen = pkt[5];
        const oper = std.mem.readInt(u16, pkt[6..8], .big);
        if (htype != 1 or ptype != 0x0800 or hlen != 6 or plen != 4 or oper != 1) return;

        const sha = pkt[8..14];
        const spa = pkt[14..18];
        const tpa = pkt[24..28];

        if (!std.mem.eql(u8, spa, &[4]u8{ 0, 0, 0, 0 })) {
            @memcpy(&self.guest_ip, spa);
        }

        // Do not reply to ARP DAD probes for the guest's own IP address
        if (std.mem.eql(u8, tpa, &self.guest_ip) or std.mem.eql(u8, tpa, &DEFAULT_GUEST_IP)) {
            if (!std.mem.eql(u8, tpa, &GATEWAY_IP)) return;
        }

        var reply: [42]u8 = [_]u8{0} ** 42;
        @memcpy(reply[0..6], sha);
        @memcpy(reply[6..12], &GATEWAY_MAC);
        std.mem.writeInt(u16, reply[12..14], 0x0806, .big);

        std.mem.writeInt(u16, reply[14..16], 1, .big); // Ethernet
        std.mem.writeInt(u16, reply[16..18], 0x0800, .big); // IPv4
        reply[18] = 6;
        reply[19] = 4;
        std.mem.writeInt(u16, reply[20..22], 2, .big); // ARP Reply
        @memcpy(reply[22..28], &GATEWAY_MAC);
        @memcpy(reply[28..32], tpa);
        @memcpy(reply[32..38], sha);
        @memcpy(reply[38..42], spa);

        self.enqueueRxFrame(&reply);
    }

    fn handleIpv4(self: *VirtualNetwork, pkt: []const u8) void {
        if (pkt.len < 20) return;
        const version = pkt[0] >> 4;
        const ihl: usize = @as(usize, pkt[0] & 0x0f) * 4;
        if (version != 4 or ihl < 20 or pkt.len < ihl) return;

        const total_len: usize = std.mem.readInt(u16, pkt[2..4], .big);
        if (total_len < ihl or total_len > pkt.len) return;

        const proto = pkt[9];
        var src_ip: [4]u8 = undefined;
        var dst_ip: [4]u8 = undefined;
        @memcpy(&src_ip, pkt[12..16]);
        @memcpy(&dst_ip, pkt[16..20]);

        if (!std.mem.eql(u8, &src_ip, &[4]u8{ 0, 0, 0, 0 })) {
            self.guest_ip = src_ip;
        }

        const payload = pkt[ihl..total_len];
        switch (proto) {
            1 => self.handleIcmp(src_ip, dst_ip, payload),
            6 => self.handleTcp(src_ip, dst_ip, payload),
            17 => self.handleUdp(src_ip, dst_ip, payload),
            else => {},
        }
    }

    fn handleIcmp(self: *VirtualNetwork, src_ip: [4]u8, dst_ip: [4]u8, payload: []const u8) void {
        if (payload.len < 8 or payload.len > 1480) return;
        const icmp_type = payload[0];
        const icmp_code = payload[1];
        if (icmp_type != 8 or icmp_code != 0) return; // Only Echo Request

        var reply_icmp: [1480]u8 = undefined;
        @memcpy(reply_icmp[0..payload.len], payload);
        reply_icmp[0] = 0; // Echo Reply
        reply_icmp[2] = 0;
        reply_icmp[3] = 0;
        const csum = internetChecksum(reply_icmp[0..payload.len]);
        std.mem.writeInt(u16, reply_icmp[2..4], csum, .big);

        self.sendIpv4Packet(dst_ip, src_ip, 1, reply_icmp[0..payload.len]);
    }

    fn handleUdp(self: *VirtualNetwork, src_ip: [4]u8, dst_ip: [4]u8, payload: []const u8) void {
        if (payload.len < 8) return;
        const src_port = std.mem.readInt(u16, payload[0..2], .big);
        const dst_port = std.mem.readInt(u16, payload[2..4], .big);
        const udp_len: usize = std.mem.readInt(u16, payload[4..6], .big);
        if (udp_len < 8 or udp_len > payload.len) return;
        const data = payload[8..udp_len];

        // DHCP (client port 68 -> server port 67)
        if (src_port == 68 and dst_port == 67) {
            self.handleDhcp(data);
            return;
        }

        // Built-in SNTP responder on UDP port 123
        if (dst_port == 123 and data.len >= 48) {
            self.handleSntp(src_ip, src_port, dst_ip, data);
            return;
        }

        // General UDP NAT forwarding (including DNS port 53)
        self.forwardUdp(src_ip, src_port, dst_ip, dst_port, data);
    }

    fn handleDhcp(self: *VirtualNetwork, data: []const u8) void {
        if (data.len < 240) return;
        if (data[0] != 1) return; // BOOTREQUEST
        if (!std.mem.eql(u8, data[236..240], &[4]u8{ 99, 130, 83, 99 })) return;

        // Parse DHCP options to find Option 53 (DHCP Message Type)
        var msg_type: u8 = 0;
        var idx: usize = 240;
        while (idx < data.len) {
            const opt = data[idx];
            idx += 1;
            if (opt == 255) break;
            if (opt == 0) continue;
            if (idx >= data.len) break;
            const olen = data[idx];
            idx += 1;
            if (idx + olen > data.len) break;
            if (opt == 53 and olen >= 1) {
                msg_type = data[idx];
            }
            idx += olen;
        }

        const reply_type: u8 = switch (msg_type) {
            1 => 2, // DISCOVER -> OFFER
            3 => 5, // REQUEST -> ACK
            else => return,
        };

        self.guest_ip = DEFAULT_GUEST_IP;

        var bootp: [300]u8 = [_]u8{0} ** 300;
        bootp[0] = 2; // BOOTREPLY
        bootp[1] = 1; // Ethernet
        bootp[2] = 6; // hlen
        bootp[3] = 0;
        @memcpy(bootp[4..8], data[4..8]); // xid
        @memcpy(bootp[10..12], data[10..12]); // flags
        @memcpy(bootp[16..20], &DEFAULT_GUEST_IP); // yiaddr
        @memcpy(bootp[20..24], &GATEWAY_IP); // siaddr
        @memcpy(bootp[28..44], data[28..44]); // chaddr
        @memcpy(bootp[236..240], &[4]u8{ 99, 130, 83, 99 }); // magic cookie

        var o: usize = 240;
        // Option 53: DHCP Message Type
        bootp[o + 0] = 53;
        bootp[o + 1] = 1;
        bootp[o + 2] = reply_type;
        o += 3;

        // Option 54: Server Identifier (10.0.2.2)
        bootp[o + 0] = 54;
        bootp[o + 1] = 4;
        @memcpy(bootp[o + 2 .. o + 6], &GATEWAY_IP);
        o += 6;

        // Option 51: IP Address Lease Time (86400s)
        bootp[o + 0] = 51;
        bootp[o + 1] = 4;
        std.mem.writeInt(u32, bootp[o + 2 .. o + 6][0..4], 86400, .big);
        o += 6;

        // Option 1: Subnet Mask (255.255.255.0)
        bootp[o + 0] = 1;
        bootp[o + 1] = 4;
        @memcpy(bootp[o + 2 .. o + 6], &NETMASK);
        o += 6;

        // Option 28: Broadcast Address (10.0.2.255)
        bootp[o + 0] = 28;
        bootp[o + 1] = 4;
        @memcpy(bootp[o + 2 .. o + 6], &BROADCAST_IP);
        o += 6;

        // Option 3: Router (10.0.2.2)
        bootp[o + 0] = 3;
        bootp[o + 1] = 4;
        @memcpy(bootp[o + 2 .. o + 6], &GATEWAY_IP);
        o += 6;

        // Option 6: DNS Server (10.0.2.2)
        bootp[o + 0] = 6;
        bootp[o + 1] = 4;
        @memcpy(bootp[o + 2 .. o + 6], &GATEWAY_IP);
        o += 6;

        // Option 42: NTP Server (10.0.2.2)
        bootp[o + 0] = 42;
        bootp[o + 1] = 4;
        @memcpy(bootp[o + 2 .. o + 6], &GATEWAY_IP);
        o += 6;

        // Option 255: End
        bootp[o] = 255;
        o += 1;

        const dst_ip = if ((data[10] & 0x80) != 0) [4]u8{ 255, 255, 255, 255 } else DEFAULT_GUEST_IP;
        self.sendUdpPacket(GATEWAY_IP, 67, dst_ip, 68, bootp[0..o]);
    }

    fn handleSntp(self: *VirtualNetwork, src_ip: [4]u8, src_port: u16, dst_ip: [4]u8, req: []const u8) void {
        var rep: [48]u8 = [_]u8{0} ** 48;
        const vn = (req[0] >> 3) & 0x7;
        rep[0] = ((if (vn == 0) @as(u8, 4) else vn) << 3) | 4; // LI=0, VN, Mode=4 (Server)
        rep[1] = 2; // Stratum 2
        rep[2] = 6; // Poll interval
        rep[3] = 0xec; // Precision (-20)
        @memcpy(rep[12..16], "LOCL");

        var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
        _ = linux.clock_gettime(.REALTIME, &ts);
        const ntp_sec: u32 = @truncate(@as(u64, @intCast(@max(ts.sec, 0))) + 2_208_988_800);
        const ntp_frac: u32 = @truncate((@as(u64, @intCast(@max(ts.nsec, 0))) << 32) / 1_000_000_000);

        // Reference Timestamp (16..24)
        std.mem.writeInt(u32, rep[16..20], ntp_sec, .big);
        std.mem.writeInt(u32, rep[20..24], ntp_frac, .big);
        // Originate Timestamp (24..32) = Client Transmit Timestamp (40..48)
        @memcpy(rep[24..32], req[40..48]);
        // Receive Timestamp (32..40)
        std.mem.writeInt(u32, rep[32..36], ntp_sec, .big);
        std.mem.writeInt(u32, rep[36..40], ntp_frac, .big);
        // Transmit Timestamp (40..48)
        std.mem.writeInt(u32, rep[40..44], ntp_sec, .big);
        std.mem.writeInt(u32, rep[44..48], ntp_frac, .big);

        const reply_src = if (std.mem.eql(u8, &dst_ip, &[4]u8{ 255, 255, 255, 255 })) GATEWAY_IP else dst_ip;
        self.sendUdpPacket(reply_src, 123, src_ip, src_port, &rep);
    }

    fn resolveHostDns(self: *VirtualNetwork) [4]u8 {
        if (self.dns_resolved) return self.host_dns_ip;
        self.dns_resolved = true;

        const fd_rc = linux.openat(linux.AT.FDCWD, "/etc/resolv.conf", .{ .ACCMODE = .RDONLY }, 0);
        if (linux.errno(fd_rc) != .SUCCESS) return self.host_dns_ip;
        const fd: linux.fd_t = @intCast(fd_rc);
        defer _ = linux.close(fd);

        var buf: [2048]u8 = undefined;
        const n_rc = linux.read(fd, &buf, buf.len);
        if (linux.errno(n_rc) != .SUCCESS or n_rc == 0) return self.host_dns_ip;

        var lines = std.mem.splitScalar(u8, buf[0..n_rc], '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, trimmed, "nameserver")) {
                const rest = std.mem.trim(u8, trimmed["nameserver".len..], " \t");
                if (parseIpv4(rest)) |ip| {
                    self.host_dns_ip = ip;
                    return ip;
                }
            }
        }
        return self.host_dns_ip;
    }

    fn mapTargetIp(self: *VirtualNetwork, dst_ip: [4]u8, dst_port: u16) [4]u8 {
        if (std.mem.eql(u8, &dst_ip, &GATEWAY_IP)) {
            if (dst_port == 53) {
                return self.resolveHostDns();
            }
            return .{ 127, 0, 0, 1 };
        }
        return dst_ip;
    }

    fn forwardUdp(self: *VirtualNetwork, src_ip: [4]u8, src_port: u16, dst_ip: [4]u8, dst_port: u16, data: []const u8) void {
        var session_idx: ?usize = null;
        var oldest_idx: usize = 0;
        var oldest_tick: u64 = std.math.maxInt(u64);

        for (&self.udp_sessions, 0..) |*s, i| {
            if (s.active and s.guest_port == src_port and std.mem.eql(u8, &s.dst_ip, &dst_ip) and s.dst_port == dst_port) {
                session_idx = i;
                break;
            }
            if (!s.active) {
                if (oldest_tick != 0) {
                    oldest_idx = i;
                    oldest_tick = 0;
                }
            } else if (s.last_tick < oldest_tick) {
                oldest_idx = i;
                oldest_tick = s.last_tick;
            }
        }

        if (session_idx == null) {
            const s = &self.udp_sessions[oldest_idx];
            if (s.active and s.fd >= 0) {
                _ = linux.close(s.fd);
            }
            const sock_rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
            if (linux.errno(sock_rc) != .SUCCESS) return;
            s.* = .{
                .active = true,
                .fd = @intCast(sock_rc),
                .guest_mac = self.guest_mac,
                .guest_ip = src_ip,
                .guest_port = src_port,
                .dst_ip = dst_ip,
                .dst_port = dst_port,
                .last_tick = self.tick_count,
            };
            session_idx = oldest_idx;
        }

        const s = &self.udp_sessions[session_idx.?];
        s.last_tick = self.tick_count;
        s.guest_ip = src_ip;
        s.guest_mac = self.guest_mac;

        const real_ip = self.mapTargetIp(dst_ip, dst_port);
        var addr: linux.sockaddr.in = .{
            .port = std.mem.nativeToBig(u16, dst_port),
            .addr = @bitCast(real_ip),
        };
        _ = linux.sendto(s.fd, data.ptr, data.len, linux.MSG.DONTWAIT | linux.MSG.NOSIGNAL, @ptrCast(&addr), @sizeOf(linux.sockaddr.in));
    }

    fn handleTcp(self: *VirtualNetwork, src_ip: [4]u8, dst_ip: [4]u8, payload: []const u8) void {
        if (payload.len < 20) return;
        const src_port = std.mem.readInt(u16, payload[0..2], .big);
        const dst_port = std.mem.readInt(u16, payload[2..4], .big);
        const seq = std.mem.readInt(u32, payload[4..8], .big);
        const data_off: usize = @as(usize, payload[12] >> 4) * 4;
        const flags = payload[13];
        if (data_off < 20 or data_off > payload.len) return;
        const tcp_data = payload[data_off..];

        const flag_fin = (flags & 0x01) != 0;
        const flag_syn = (flags & 0x02) != 0;
        const flag_rst = (flags & 0x04) != 0;

        // Look up existing connection
        var conn_idx: ?usize = null;
        for (&self.tcp_conns, 0..) |*c, i| {
            if (c.state != .unused and c.guest_port == src_port and c.dst_port == dst_port and std.mem.eql(u8, &c.dst_ip, &dst_ip)) {
                conn_idx = i;
                break;
            }
        }

        if (flag_rst) {
            if (conn_idx) |idx| {
                self.closeTcpConn(idx);
            }
            return;
        }

        if (flag_syn and !((flags & 0x10) != 0)) {
            const idx = conn_idx orelse self.allocTcpConn();
            self.closeTcpConn(idx);

            const sock_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
            if (linux.errno(sock_rc) != .SUCCESS) {
                self.sendTcpSegment(dst_ip, dst_port, src_ip, src_port, 0, seq +% 1, 0x14, &.{}); // RST|ACK
                return;
            }
            const fd: linux.fd_t = @intCast(sock_rc);
            const real_ip = self.mapTargetIp(dst_ip, dst_port);
            var addr: linux.sockaddr.in = .{
                .port = std.mem.nativeToBig(u16, dst_port),
                .addr = @bitCast(real_ip),
            };
            const conn_rc = linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in));
            const err = linux.errno(conn_rc);
            if (err != .SUCCESS and err != .INPROGRESS and err != .AGAIN) {
                _ = linux.close(fd);
                self.sendTcpSegment(dst_ip, dst_port, src_ip, src_port, 0, seq +% 1, 0x14, &.{}); // RST|ACK
                return;
            }

            const init_seq: u32 = 0x1000_0000 +% (@as(u32, @truncate(self.tick_count)) *% 65537);
            self.tcp_conns[idx] = .{
                .state = .established,
                .fd = fd,
                .guest_mac = self.guest_mac,
                .guest_ip = src_ip,
                .guest_port = src_port,
                .dst_ip = dst_ip,
                .dst_port = dst_port,
                .my_seq = init_seq +% 1,
                .guest_seq = seq +% 1,
                .tx_len = 0,
                .last_tick = self.tick_count,
            };

            // Send SYN|ACK
            self.sendTcpSegment(dst_ip, dst_port, src_ip, src_port, init_seq, seq +% 1, 0x12, &.{});
            return;
        }

        const idx = conn_idx orelse {
            self.sendTcpSegment(dst_ip, dst_port, src_ip, src_port, 0, seq +% @as(u32, @intCast(@max(tcp_data.len, 1))), 0x14, &.{});
            return;
        };
        const c = &self.tcp_conns[idx];
        c.last_tick = self.tick_count;

        if (tcp_data.len > 0) {
            if (seq == c.guest_seq) {
                const space = c.tx_buf.len - c.tx_len;
                const copy_n = @min(space, tcp_data.len);
                if (copy_n > 0) {
                    @memcpy(c.tx_buf[c.tx_len .. c.tx_len + copy_n], tcp_data[0..copy_n]);
                    c.tx_len += copy_n;
                    c.guest_seq +%= @intCast(copy_n);
                }
                self.flushTcpTx(idx);
            }
            // Acknowledge current expected guest_seq
            self.sendTcpSegment(dst_ip, dst_port, src_ip, src_port, c.my_seq, c.guest_seq, 0x10, &.{});
        }

        if (flag_fin) {
            if (seq +% @as(u32, @intCast(tcp_data.len)) == c.guest_seq) {
                c.guest_seq +%= 1;
            }
            self.flushTcpTx(idx);
            if (c.fd >= 0) {
                _ = linux.shutdown(c.fd, linux.SHUT.WR);
            }
            self.sendTcpSegment(dst_ip, dst_port, src_ip, src_port, c.my_seq, c.guest_seq, 0x10, &.{});
        }
    }

    fn allocTcpConn(self: *VirtualNetwork) usize {
        var oldest_idx: usize = 0;
        var oldest_tick: u64 = std.math.maxInt(u64);
        for (&self.tcp_conns, 0..) |*c, i| {
            if (c.state == .unused) return i;
            if (c.last_tick < oldest_tick) {
                oldest_tick = c.last_tick;
                oldest_idx = i;
            }
        }
        return oldest_idx;
    }

    fn closeTcpConn(self: *VirtualNetwork, idx: usize) void {
        const c = &self.tcp_conns[idx];
        if (c.state != .unused and c.fd >= 0) {
            _ = linux.close(c.fd);
        }
        c.* = .{};
    }

    fn flushTcpTx(self: *VirtualNetwork, idx: usize) void {
        const c = &self.tcp_conns[idx];
        if (c.state == .unused or c.fd < 0 or c.tx_len == 0) return;
        const rc = linux.sendto(c.fd, &c.tx_buf, c.tx_len, linux.MSG.DONTWAIT | linux.MSG.NOSIGNAL, null, 0);
        const err = linux.errno(rc);
        if (err == .SUCCESS and rc > 0) {
            const sent: usize = @intCast(rc);
            if (sent < c.tx_len) {
                std.mem.copyForwards(u8, &c.tx_buf, c.tx_buf[sent..c.tx_len]);
            }
            c.tx_len -= sent;
        }
    }

    /// Polls non-blocking host UDP and TCP sockets and enqueues any incoming Ethernet frames.
    pub fn poll(self: *VirtualNetwork) void {
        self.tick_count +%= 1;

        // Poll UDP NAT sockets
        for (&self.udp_sessions) |*s| {
            if (!s.active or s.fd < 0) continue;
            if (self.rx_count >= RX_QUEUE_CAP - 2) break;

            var buf: [1472]u8 = undefined;
            const rc = linux.recvfrom(s.fd, &buf, buf.len, linux.MSG.DONTWAIT, null, null);
            if (linux.errno(rc) == .SUCCESS and rc > 0) {
                s.last_tick = self.tick_count;
                self.sendUdpPacket(s.dst_ip, s.dst_port, s.guest_ip, s.guest_port, buf[0..rc]);
            }
        }

        // Poll TCP NAT connections
        for (0..MAX_TCP_CONNS) |idx| {
            const c = &self.tcp_conns[idx];
            if (c.state == .unused or c.fd < 0) continue;
            if (self.rx_count >= RX_QUEUE_CAP - 2) break;

            if (c.tx_len > 0) {
                self.flushTcpTx(idx);
            }

            var buf: [1400]u8 = undefined;
            const rc = linux.recvfrom(c.fd, &buf, buf.len, linux.MSG.DONTWAIT, null, null);
            const err = linux.errno(rc);
            if (err == .SUCCESS) {
                if (rc > 0) {
                    c.last_tick = self.tick_count;
                    const seq = c.my_seq;
                    c.my_seq +%= @intCast(rc);
                    self.sendTcpSegment(c.dst_ip, c.dst_port, c.guest_ip, c.guest_port, seq, c.guest_seq, 0x18, buf[0..rc]); // PSH|ACK
                } else {
                    // EOF from remote host -> send FIN|ACK and close
                    const seq = c.my_seq;
                    c.my_seq +%= 1;
                    self.sendTcpSegment(c.dst_ip, c.dst_port, c.guest_ip, c.guest_port, seq, c.guest_seq, 0x11, &.{}); // FIN|ACK
                    self.closeTcpConn(idx);
                }
            } else if (err == .AGAIN or err == .INPROGRESS) {
                // Still waiting
            } else {
                // Connection refused / reset
                self.sendTcpSegment(c.dst_ip, c.dst_port, c.guest_ip, c.guest_port, c.my_seq, c.guest_seq, 0x14, &.{}); // RST|ACK
                self.closeTcpConn(idx);
            }
        }
    }

    pub fn sendUdpPacket(self: *VirtualNetwork, src_ip: [4]u8, src_port: u16, dst_ip: [4]u8, dst_port: u16, data: []const u8) void {
        if (8 + data.len > 1480) return;
        var udp: [1480]u8 = undefined;
        const udp_len: u16 = @intCast(8 + data.len);
        std.mem.writeInt(u16, udp[0..2], src_port, .big);
        std.mem.writeInt(u16, udp[2..4], dst_port, .big);
        std.mem.writeInt(u16, udp[4..6], udp_len, .big);
        std.mem.writeInt(u16, udp[6..8], 0, .big);
        @memcpy(udp[8 .. 8 + data.len], data);

        const csum = tcpUdpChecksum(src_ip, dst_ip, 17, udp[0..udp_len]);
        std.mem.writeInt(u16, udp[6..8], if (csum == 0) 0xffff else csum, .big);

        self.sendIpv4Packet(src_ip, dst_ip, 17, udp[0..udp_len]);
    }

    pub fn sendTcpSegment(
        self: *VirtualNetwork,
        src_ip: [4]u8,
        src_port: u16,
        dst_ip: [4]u8,
        dst_port: u16,
        seq: u32,
        ack: u32,
        flags: u8,
        data: []const u8,
    ) void {
        if (20 + data.len > 1480) return;
        var tcp: [1480]u8 = [_]u8{0} ** 1480;
        const tcp_len: usize = 20 + data.len;
        std.mem.writeInt(u16, tcp[0..2], src_port, .big);
        std.mem.writeInt(u16, tcp[2..4], dst_port, .big);
        std.mem.writeInt(u32, tcp[4..8], seq, .big);
        std.mem.writeInt(u32, tcp[8..12], ack, .big);
        tcp[12] = 5 << 4; // 20-byte header
        tcp[13] = flags;
        std.mem.writeInt(u16, tcp[14..16], 32768, .big); // Window size
        std.mem.writeInt(u16, tcp[16..18], 0, .big); // Checksum
        std.mem.writeInt(u16, tcp[18..20], 0, .big); // Urgent pointer
        if (data.len > 0) {
            @memcpy(tcp[20..tcp_len], data);
        }

        const csum = tcpUdpChecksum(src_ip, dst_ip, 6, tcp[0..tcp_len]);
        std.mem.writeInt(u16, tcp[16..18], csum, .big);

        self.sendIpv4Packet(src_ip, dst_ip, 6, tcp[0..tcp_len]);
    }

    pub fn sendIpv4Packet(self: *VirtualNetwork, src_ip: [4]u8, dst_ip: [4]u8, proto: u8, payload: []const u8) void {
        if (14 + 20 + payload.len > MAX_FRAME_LEN) return;
        var frame: [MAX_FRAME_LEN]u8 = undefined;

        const is_bcast = std.mem.eql(u8, &dst_ip, &[4]u8{ 255, 255, 255, 255 });
        const dst_mac = if (is_bcast) [6]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff } else self.guest_mac;

        @memcpy(frame[0..6], &dst_mac);
        @memcpy(frame[6..12], &GATEWAY_MAC);
        std.mem.writeInt(u16, frame[12..14], 0x0800, .big);

        const ip = frame[14..34];
        @memset(ip, 0);
        ip[0] = 0x45;
        const total_len: u16 = @intCast(20 + payload.len);
        std.mem.writeInt(u16, ip[2..4], total_len, .big);
        std.mem.writeInt(u16, ip[4..6], self.ip_id, .big);
        self.ip_id +%= 1;
        std.mem.writeInt(u16, ip[6..8], 0x4000, .big); // Don't Fragment
        ip[8] = 64; // TTL
        ip[9] = proto;
        @memcpy(ip[12..16], &src_ip);
        @memcpy(ip[16..20], &dst_ip);
        const ip_csum = internetChecksum(ip);
        std.mem.writeInt(u16, ip[10..12], ip_csum, .big);

        @memcpy(frame[34 .. 34 + payload.len], payload);
        const raw_len = 34 + payload.len;
        const wire_len = @max(raw_len, 60);
        if (wire_len > raw_len) {
            @memset(frame[raw_len..wire_len], 0);
        }
        self.enqueueRxFrame(frame[0..wire_len]);
    }

    pub fn parseIpv4(s: []const u8) ?[4]u8 {
        var out: [4]u8 = undefined;
        var it = std.mem.splitScalar(u8, s, '.');
        for (0..4) |i| {
            const part = it.next() orelse return null;
            out[i] = std.fmt.parseInt(u8, part, 10) catch return null;
        }
        if (it.next() != null) return null;
        return out;
    }

    pub fn internetChecksum(data: []const u8) u16 {
        var sum: u32 = 0;
        var i: usize = 0;
        while (i + 1 < data.len) : (i += 2) {
            sum += std.mem.readInt(u16, data[i..][0..2], .big);
        }
        if (i < data.len) {
            sum += @as(u32, data[i]) << 8;
        }
        while ((sum >> 16) != 0) {
            sum = (sum & 0xffff) + (sum >> 16);
        }
        return ~@as(u16, @truncate(sum));
    }

    pub fn tcpUdpChecksum(src_ip: [4]u8, dst_ip: [4]u8, proto: u8, segment: []const u8) u16 {
        var sum: u32 = 0;
        sum += std.mem.readInt(u16, src_ip[0..2], .big);
        sum += std.mem.readInt(u16, src_ip[2..4], .big);
        sum += std.mem.readInt(u16, dst_ip[0..2], .big);
        sum += std.mem.readInt(u16, dst_ip[2..4], .big);
        sum += proto;
        sum += @as(u32, @intCast(segment.len));

        var i: usize = 0;
        while (i + 1 < segment.len) : (i += 2) {
            sum += std.mem.readInt(u16, segment[i..][0..2], .big);
        }
        if (i < segment.len) {
            sum += @as(u32, segment[i]) << 8;
        }
        while ((sum >> 16) != 0) {
            sum = (sum & 0xffff) + (sum >> 16);
        }
        return ~@as(u16, @truncate(sum));
    }
};

test "VirtualNetwork ARP, DHCP, ICMP Echo, and SNTP" {
    var net = VirtualNetwork{};
    defer net.deinit();

    // 1. Test ARP request for 10.0.2.2
    var arp_req: [42]u8 = [_]u8{0} ** 42;
    @memset(arp_req[0..6], 0xff);
    @memcpy(arp_req[6..12], &VirtualNetwork.DEFAULT_GUEST_MAC);
    std.mem.writeInt(u16, arp_req[12..14], 0x0806, .big);
    std.mem.writeInt(u16, arp_req[14..16], 1, .big);
    std.mem.writeInt(u16, arp_req[16..18], 0x0800, .big);
    arp_req[18] = 6;
    arp_req[19] = 4;
    std.mem.writeInt(u16, arp_req[20..22], 1, .big); // Request
    @memcpy(arp_req[22..28], &VirtualNetwork.DEFAULT_GUEST_MAC);
    @memcpy(arp_req[28..32], &VirtualNetwork.DEFAULT_GUEST_IP);
    @memcpy(arp_req[38..42], &VirtualNetwork.GATEWAY_IP);

    net.handleTxFrame(&arp_req);
    try std.testing.expect(net.hasRxFrame());

    var rx_buf: [1536]u8 = undefined;
    const arp_len = net.popRxFrame(&rx_buf).?;
    try std.testing.expectEqual(@as(usize, 42), arp_len);
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, rx_buf[20..22], .big));
    try std.testing.expectEqualSlices(u8, &VirtualNetwork.GATEWAY_MAC, rx_buf[22..28]);

    // 2. Test DHCP DISCOVER -> OFFER
    var dhcp_disc: [34 + 8 + 244]u8 = [_]u8{0} ** (34 + 8 + 244);
    @memset(dhcp_disc[0..6], 0xff);
    @memcpy(dhcp_disc[6..12], &VirtualNetwork.DEFAULT_GUEST_MAC);
    std.mem.writeInt(u16, dhcp_disc[12..14], 0x0800, .big);
    dhcp_disc[14] = 0x45;
    std.mem.writeInt(u16, dhcp_disc[16..18], 20 + 8 + 244, .big);
    dhcp_disc[23] = 17; // UDP
    std.mem.writeInt(u16, dhcp_disc[34..36], 68, .big);
    std.mem.writeInt(u16, dhcp_disc[36..38], 67, .big);
    std.mem.writeInt(u16, dhcp_disc[38..40], 8 + 244, .big);
    const bootp = dhcp_disc[42..];
    bootp[0] = 1; // BOOTREQUEST
    bootp[1] = 1;
    bootp[2] = 6;
    std.mem.writeInt(u32, bootp[4..8], 0x12345678, .big);
    @memcpy(bootp[28..34], &VirtualNetwork.DEFAULT_GUEST_MAC);
    @memcpy(bootp[236..240], &[4]u8{ 99, 130, 83, 99 });
    bootp[240] = 53;
    bootp[241] = 1;
    bootp[242] = 1; // DHCPDISCOVER
    bootp[243] = 255;

    net.handleTxFrame(&dhcp_disc);
    const offer_len = net.popRxFrame(&rx_buf).?;
    try std.testing.expect(offer_len > 280);
    // yiaddr at offset 42 + 16 = 58
    try std.testing.expectEqualSlices(u8, &VirtualNetwork.DEFAULT_GUEST_IP, rx_buf[58..62]);

    // 3. Test SNTP request on UDP port 123
    var sntp_pkt: [34 + 8 + 48]u8 = [_]u8{0} ** (34 + 8 + 48);
    @memcpy(sntp_pkt[0..6], &VirtualNetwork.GATEWAY_MAC);
    @memcpy(sntp_pkt[6..12], &VirtualNetwork.DEFAULT_GUEST_MAC);
    std.mem.writeInt(u16, sntp_pkt[12..14], 0x0800, .big);
    sntp_pkt[14] = 0x45;
    std.mem.writeInt(u16, sntp_pkt[16..18], 20 + 8 + 48, .big);
    sntp_pkt[23] = 17;
    @memcpy(sntp_pkt[26..30], &VirtualNetwork.DEFAULT_GUEST_IP);
    @memcpy(sntp_pkt[30..34], &VirtualNetwork.GATEWAY_IP);
    std.mem.writeInt(u16, sntp_pkt[34..36], 40000, .big);
    std.mem.writeInt(u16, sntp_pkt[36..38], 123, .big);
    std.mem.writeInt(u16, sntp_pkt[38..40], 8 + 48, .big);
    sntp_pkt[42] = 0x23; // VN=4, Mode=3 (Client)

    net.handleTxFrame(&sntp_pkt);
    const sntp_len = net.popRxFrame(&rx_buf).?;
    try std.testing.expectEqual(@as(usize, 34 + 8 + 48), sntp_len);
    try std.testing.expectEqual(@as(u8, 0x24), rx_buf[42]); // VN=4, Mode=4 (Server)
}
