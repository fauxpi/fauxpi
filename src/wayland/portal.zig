//! Pure-Zig XDG Desktop Portal (`org.freedesktop.portal.FileChooser`) client over the
//! D-Bus session bus wire protocol.
//!
//! Used by `WaylandWindow` so file selection works seamlessly under strict Snap and
//! Flatpak confinement (via `xdg-desktop-portal` and `xdg-document-portal`) without
//! spawning external helper binaries such as `zenity` or `kdialog`.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const host_posix = @import("../host/posix.zig");
const window = @import("../app/window.zig");

const is_linux = (builtin.os.tag == .linux);

pub const Error = error{
    NoSessionBus,
    ConnectFailed,
    AuthFailed,
    ProtocolError,
    BufferFull,
    PortalError,
};

pub const MessageType = enum(u8) {
    method_call = 1,
    method_return = 2,
    error_reply = 3,
    signal = 4,
};

pub const HeaderField = enum(u8) {
    path = 1,
    interface = 2,
    member = 3,
    error_name = 4,
    reply_serial = 5,
    destination = 6,
    sender = 7,
    signature = 8,
    unix_fds = 9,
};

const hello_serial: u32 = 1;
const add_match_serial: u32 = 2;
const open_file_serial: u32 = 3;
const handle_token_str = "fauxpi_sd";

const match_rule =
    "type='signal',sender='org.freedesktop.portal.Desktop'," ++
    "interface='org.freedesktop.portal.Request',member='Response'";

/// Non-blocking XDG Desktop Portal FileChooser session polled by `WaylandWindow`.
pub const PortalFilePicker = struct {
    fd: host_posix.fd_t = -1,
    state: State = .idle,
    in_buf: [16384]u8 = undefined,
    in_len: usize = 0,

    pub const State = enum {
        idle,
        await_hello,
        await_response,
    };

    pub fn close(self: *PortalFilePicker) void {
        if (self.fd >= 0) {
            host_posix.close(self.fd);
            self.fd = -1;
        }
        self.state = .idle;
        self.in_len = 0;
    }

    pub fn open(self: *PortalFilePicker, environ: std.process.Environ) void {
        if (!is_linux) return;
        if (self.fd >= 0) return;

        const fd = connectSessionBus(environ) catch return;
        authenticateExternal(fd, linux.geteuid()) catch {
            host_posix.close(fd);
            return;
        };

        var msg_buf: [512]u8 = undefined;
        const hello_msg = buildHelloMessage(&msg_buf, hello_serial) catch {
            host_posix.close(fd);
            return;
        };
        writeAllBlocking(fd, hello_msg) catch {
            host_posix.close(fd);
            return;
        };

        self.fd = fd;
        self.state = .await_hello;
        self.in_len = 0;
    }

    pub fn poll(self: *PortalFilePicker, win: anytype) void {
        if (!is_linux) return;
        if (self.fd < 0) return;

        while (self.in_len < self.in_buf.len) {
            const rc = linux.recvfrom(
                self.fd,
                self.in_buf[self.in_len..].ptr,
                self.in_buf.len - self.in_len,
                linux.MSG.DONTWAIT,
                null,
                null,
            );
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) {
                        self.close();
                        return;
                    }
                    self.in_len += rc;
                },
                .INTR => continue,
                .AGAIN => break,
                else => {
                    self.close();
                    return;
                },
            }
        }

        while (true) {
            const outcome = self.processNextMessage(win) catch {
                self.close();
                return;
            };
            if (!outcome) break;
            if (self.fd < 0) return;
        }
    }

    fn processNextMessage(self: *PortalFilePicker, win: anytype) Error!bool {
        const parsed = (try parseMessage(self.in_buf[0..self.in_len])) orelse return false;
        const total_len = parsed.total_len;

        // Copy out any needed state before shifting the input buffer.
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        var selected_path: ?[]const u8 = null;
        var should_close = false;
        var send_open_file = false;

        switch (parsed.msg_type) {
            .method_return => {
                if (self.state == .await_hello and parsed.reply_serial == hello_serial) {
                    send_open_file = true;
                }
            },
            .error_reply => {
                if (parsed.reply_serial == hello_serial or parsed.reply_serial == open_file_serial) {
                    should_close = true;
                }
            },
            .signal => {
                if (std.mem.eql(u8, parsed.interface, "org.freedesktop.portal.Request") and
                    std.mem.eql(u8, parsed.member, "Response"))
                {
                    if (try parsePortalResponseBody(parsed.full_msg, parsed.body_start, &path_buf)) |decoded| {
                        selected_path = decoded;
                    }
                    should_close = true;
                }
            },
            .method_call => {},
        }

        // Shift remaining bytes in `in_buf`.
        const rem = self.in_len - total_len;
        if (rem > 0) {
            std.mem.copyForwards(u8, self.in_buf[0..rem], self.in_buf[total_len..self.in_len]);
        }
        self.in_len = rem;

        if (send_open_file) {
            var out_buf: [2048]u8 = undefined;
            const match_msg = try buildAddMatchMessage(&out_buf, add_match_serial);
            writeAllBlocking(self.fd, match_msg) catch return error.PortalError;

            const open_msg = try buildOpenFileMessage(&out_buf, open_file_serial);
            writeAllBlocking(self.fd, open_msg) catch return error.PortalError;
            self.state = .await_response;
        }

        if (selected_path) |p| {
            window.setChosenSdPath(win, p);
        }

        if (should_close) {
            self.close();
            return false;
        }
        return true;
    }
};

pub const BusAddress = union(enum) {
    path: []const u8,
    abstract: []const u8,
};

/// Parses `DBUS_SESSION_BUS_ADDRESS` (e.g. `unix:path=/run/user/1000/bus,guid=...` or
/// `unix:abstract=/tmp/dbus-1234`) or falls back to `$XDG_RUNTIME_DIR/bus`.
pub fn resolveSessionBusAddress(
    buf: []u8,
    dbus_addr_env: ?[]const u8,
    xdg_runtime_dir: ?[]const u8,
) Error!BusAddress {
    if (dbus_addr_env) |raw_env| {
        var entry_it = std.mem.splitScalar(u8, raw_env, ';');
        while (entry_it.next()) |entry| {
            if (!std.mem.startsWith(u8, entry, "unix:")) continue;
            const params = entry["unix:".len..];
            var param_it = std.mem.splitScalar(u8, params, ',');
            while (param_it.next()) |kv| {
                if (std.mem.startsWith(u8, kv, "path=")) {
                    const decoded = try percentDecode(buf, kv["path=".len..]);
                    if (decoded.len > 0) return .{ .path = decoded };
                } else if (std.mem.startsWith(u8, kv, "abstract=")) {
                    const decoded = try percentDecode(buf, kv["abstract=".len..]);
                    if (decoded.len > 0) return .{ .abstract = decoded };
                }
            }
        }
    }
    const rt = std.mem.trimEnd(u8, xdg_runtime_dir orelse return error.NoSessionBus, "/");
    if (rt.len == 0) return error.NoSessionBus;
    const p = std.fmt.bufPrint(buf, "{s}/bus", .{rt}) catch return error.NoSessionBus;
    return .{ .path = p };
}

fn connectSessionBus(environ: std.process.Environ) Error!linux.fd_t {
    const Environ = std.process.Environ;
    var path_buf: [256]u8 = undefined;
    const bus_addr = try resolveSessionBusAddress(
        &path_buf,
        Environ.getPosix(environ, "DBUS_SESSION_BUS_ADDRESS"),
        Environ.getPosix(environ, "XDG_RUNTIME_DIR"),
    );

    const sock_rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(sock_rc) != .SUCCESS) return error.ConnectFailed;
    const fd: linux.fd_t = @intCast(sock_rc);
    errdefer _ = linux.close(fd);

    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    var addr_len: u32 = @sizeOf(linux.sockaddr.un);

    switch (bus_addr) {
        .path => |p| {
            if (p.len >= addr.path.len) return error.ConnectFailed;
            @memcpy(addr.path[0..p.len], p);
        },
        .abstract => |a| {
            if (a.len + 1 > addr.path.len) return error.ConnectFailed;
            addr.path[0] = 0;
            @memcpy(addr.path[1 .. 1 + a.len], a);
            addr_len = @intCast(2 + 1 + a.len);
        },
    }

    if (linux.errno(linux.connect(fd, @ptrCast(&addr), addr_len)) != .SUCCESS) {
        return error.ConnectFailed;
    }
    return fd;
}

pub fn formatExternalAuthLine(buf: []u8, uid: u32) Error![]const u8 {
    var dec_buf: [16]u8 = undefined;
    const dec = std.fmt.bufPrint(&dec_buf, "{d}", .{uid}) catch return error.BufferFull;
    const prefix = "\x00AUTH EXTERNAL ";
    const suffix = "\r\n";
    const total = prefix.len + dec.len * 2 + suffix.len;
    if (total > buf.len) return error.BufferFull;

    @memcpy(buf[0..prefix.len], prefix);
    var pos: usize = prefix.len;
    const hex = "0123456789abcdef";
    for (dec) |c| {
        buf[pos] = hex[c >> 4];
        buf[pos + 1] = hex[c & 0x0f];
        pos += 2;
    }
    @memcpy(buf[pos .. pos + suffix.len], suffix);
    return buf[0..total];
}

fn authenticateExternal(fd: linux.fd_t, uid: u32) Error!void {
    var auth_buf: [64]u8 = undefined;
    const auth_line = try formatExternalAuthLine(&auth_buf, uid);
    try writeAllBlocking(fd, auth_line);

    var reply_buf: [256]u8 = undefined;
    var reply_len: usize = 0;
    while (reply_len < reply_buf.len) {
        var pfd = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
        const prc = linux.poll(&pfd, 1, 1000);
        if (linux.errno(prc) != .SUCCESS or prc == 0) return error.AuthFailed;

        const rrc = linux.read(fd, reply_buf[reply_len..].ptr, reply_buf.len - reply_len);
        if (linux.errno(rrc) != .SUCCESS or rrc == 0) return error.AuthFailed;
        reply_len += rrc;

        if (std.mem.indexOfScalar(u8, reply_buf[0..reply_len], '\n')) |nl| {
            const line = std.mem.trimEnd(u8, reply_buf[0..nl], "\r");
            if (!std.mem.startsWith(u8, line, "OK ")) return error.AuthFailed;
            try writeAllBlocking(fd, "BEGIN\r\n");
            return;
        }
    }
    return error.AuthFailed;
}

fn writeAllBlocking(fd: linux.fd_t, data: []const u8) Error!void {
    var sent: usize = 0;
    while (sent < data.len) {
        const rc = linux.sendto(fd, data[sent..].ptr, data.len - sent, linux.MSG.NOSIGNAL, null, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.ConnectFailed;
                sent += rc;
            },
            .INTR => continue,
            .AGAIN => {
                var pfd = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 }};
                _ = linux.poll(&pfd, 1, 1000);
                continue;
            },
            else => return error.ConnectFailed,
        }
    }
}

/// Decodes percent-encoded sequences (`%XX`) in `input` into `out`.
pub fn percentDecode(out: []u8, input: []const u8) Error![]const u8 {
    var r: usize = 0;
    var w: usize = 0;
    while (r < input.len) {
        if (w >= out.len) return error.BufferFull;
        if (input[r] == '%' and r + 2 < input.len) {
            if (hexNibble(input[r + 1])) |hi| {
                if (hexNibble(input[r + 2])) |lo| {
                    const byte = (hi << 4) | lo;
                    if (byte == 0) return error.ProtocolError;
                    out[w] = byte;
                    w += 1;
                    r += 3;
                    continue;
                }
            }
        }
        if (input[r] == 0) return error.ProtocolError;
        out[w] = input[r];
        w += 1;
        r += 1;
    }
    return out[0..w];
}

/// Converts a `file:///...` URI returned by `org.freedesktop.portal.FileChooser` into a
/// local POSIX filesystem path.
pub fn decodeFileUri(out: []u8, uri: []const u8) Error![]const u8 {
    const raw_path = if (std.mem.startsWith(u8, uri, "file://localhost/"))
        uri["file://localhost".len..]
    else if (std.mem.startsWith(u8, uri, "file:///"))
        uri["file://".len..]
    else if (uri.len > 0 and uri[0] == '/')
        uri
    else
        return error.ProtocolError;

    return percentDecode(out, raw_path);
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

pub const MessageBuilder = struct {
    buf: []u8,
    pos: usize = 0,
    body_start: usize = 0,

    pub const ArrayHandle = struct {
        len_pos: usize,
        data_start: usize,
    };

    pub fn begin(buf: []u8, msg_type: MessageType, flags: u8, serial: u32) Error!MessageBuilder {
        if (buf.len < 16) return error.BufferFull;
        @memset(buf[0..16], 0);
        buf[0] = 'l';
        buf[1] = @backingInt(msg_type);
        buf[2] = flags;
        buf[3] = 1;
        std.mem.writeInt(u32, buf[8..12], serial, .little);
        return .{ .buf = buf, .pos = 16 };
    }

    pub fn padTo(self: *MessageBuilder, alignment: usize) Error!void {
        const aligned = std.mem.alignForward(usize, self.pos, alignment);
        if (aligned > self.buf.len) return error.BufferFull;
        if (aligned > self.pos) {
            @memset(self.buf[self.pos..aligned], 0);
            self.pos = aligned;
        }
    }

    pub fn writeByte(self: *MessageBuilder, b: u8) Error!void {
        if (self.pos + 1 > self.buf.len) return error.BufferFull;
        self.buf[self.pos] = b;
        self.pos += 1;
    }

    pub fn writeU32(self: *MessageBuilder, v: u32) Error!void {
        try self.padTo(4);
        if (self.pos + 4 > self.buf.len) return error.BufferFull;
        std.mem.writeInt(u32, self.buf[self.pos..][0..4], v, .little);
        self.pos += 4;
    }

    pub fn writeString(self: *MessageBuilder, s: []const u8) Error!void {
        try self.writeU32(@intCast(s.len));
        if (self.pos + s.len + 1 > self.buf.len) return error.BufferFull;
        @memcpy(self.buf[self.pos .. self.pos + s.len], s);
        self.buf[self.pos + s.len] = 0;
        self.pos += s.len + 1;
    }

    pub fn writeSignature(self: *MessageBuilder, sig: []const u8) Error!void {
        if (sig.len > 255 or self.pos + 1 + sig.len + 1 > self.buf.len) return error.BufferFull;
        self.buf[self.pos] = @intCast(sig.len);
        @memcpy(self.buf[self.pos + 1 .. self.pos + 1 + sig.len], sig);
        self.buf[self.pos + 1 + sig.len] = 0;
        self.pos += 1 + sig.len + 1;
    }

    pub fn writeHeaderFieldString(self: *MessageBuilder, field: HeaderField, sig_char: u8, value: []const u8) Error!void {
        try self.padTo(8);
        try self.writeByte(@backingInt(field));
        const sig_slice = [1]u8{sig_char};
        try self.writeSignature(&sig_slice);
        if (sig_char == 'g') {
            try self.writeSignature(value);
        } else {
            try self.writeString(value);
        }
    }

    pub fn finishHeader(self: *MessageBuilder) Error!void {
        const fields_len: u32 = @intCast(self.pos - 16);
        std.mem.writeInt(u32, self.buf[12..16], fields_len, .little);
        try self.padTo(8);
        self.body_start = self.pos;
    }

    pub fn beginArray(self: *MessageBuilder, elem_align: usize) Error!ArrayHandle {
        try self.padTo(4);
        const len_pos = self.pos;
        try self.writeU32(0);
        try self.padTo(elem_align);
        return .{ .len_pos = len_pos, .data_start = self.pos };
    }

    pub fn endArray(self: *MessageBuilder, h: ArrayHandle) void {
        const byte_len: u32 = @intCast(self.pos - h.data_start);
        std.mem.writeInt(u32, self.buf[h.len_pos..][0..4], byte_len, .little);
    }

    pub fn finish(self: *MessageBuilder) []const u8 {
        const body_len: u32 = @intCast(self.pos - self.body_start);
        std.mem.writeInt(u32, self.buf[4..8], body_len, .little);
        return self.buf[0..self.pos];
    }
};

pub fn buildHelloMessage(buf: []u8, serial: u32) Error![]const u8 {
    var b = try MessageBuilder.begin(buf, .method_call, 0, serial);
    try b.writeHeaderFieldString(.path, 'o', "/org/freedesktop/DBus");
    try b.writeHeaderFieldString(.destination, 's', "org.freedesktop.DBus");
    try b.writeHeaderFieldString(.interface, 's', "org.freedesktop.DBus");
    try b.writeHeaderFieldString(.member, 's', "Hello");
    try b.finishHeader();
    return b.finish();
}

pub fn buildAddMatchMessage(buf: []u8, serial: u32) Error![]const u8 {
    var b = try MessageBuilder.begin(buf, .method_call, 0, serial);
    try b.writeHeaderFieldString(.path, 'o', "/org/freedesktop/DBus");
    try b.writeHeaderFieldString(.destination, 's', "org.freedesktop.DBus");
    try b.writeHeaderFieldString(.interface, 's', "org.freedesktop.DBus");
    try b.writeHeaderFieldString(.member, 's', "AddMatch");
    try b.writeHeaderFieldString(.signature, 'g', "s");
    try b.finishHeader();
    try b.writeString(match_rule);
    return b.finish();
}

pub fn buildOpenFileMessage(buf: []u8, serial: u32) Error![]const u8 {
    var b = try MessageBuilder.begin(buf, .method_call, 0, serial);
    try b.writeHeaderFieldString(.path, 'o', "/org/freedesktop/portal/desktop");
    try b.writeHeaderFieldString(.destination, 's', "org.freedesktop.portal.Desktop");
    try b.writeHeaderFieldString(.interface, 's', "org.freedesktop.portal.FileChooser");
    try b.writeHeaderFieldString(.member, 's', "OpenFile");
    try b.writeHeaderFieldString(.signature, 'g', "ssa{sv}");
    try b.finishHeader();

    // IN s parent_window, IN s title
    try b.writeString("");
    try b.writeString("Select SD Card Image");

    // IN a{sv} options
    const opts_arr = try b.beginArray(8);

    // 1. "handle_token": s = "fauxpi_sd"
    try b.padTo(8);
    try b.writeString("handle_token");
    try b.writeSignature("s");
    try b.writeString(handle_token_str);

    // 2. "modal": b = true
    try b.padTo(8);
    try b.writeString("modal");
    try b.writeSignature("b");
    try b.writeU32(1);

    // 3. "filters": a(sa(us))
    try b.padTo(8);
    try b.writeString("filters");
    try b.writeSignature("a(sa(us))");
    const filters_arr = try b.beginArray(8);

    // Filter 0: Disk Images
    try writeFileFilter(
        &b,
        "Disk Images (*.img, *.img.xz, *.iso, *.bin, *.raw)",
        &.{ "*.img", "*.img.xz", "*.xz", "*.iso", "*.bin", "*.raw" },
    );
    // Filter 1: All Files
    try writeFileFilter(&b, "All Files", &.{"*"});

    b.endArray(filters_arr);

    // 4. "current_filter": (sa(us))
    try b.padTo(8);
    try b.writeString("current_filter");
    try b.writeSignature("(sa(us))");
    try writeFileFilter(
        &b,
        "Disk Images (*.img, *.img.xz, *.iso, *.bin, *.raw)",
        &.{ "*.img", "*.img.xz", "*.xz", "*.iso", "*.bin", "*.raw" },
    );

    b.endArray(opts_arr);
    return b.finish();
}

fn writeFileFilter(b: *MessageBuilder, label: []const u8, globs: []const []const u8) Error!void {
    try b.padTo(8);
    try b.writeString(label);
    const pat_arr = try b.beginArray(8);
    for (globs) |glob| {
        try b.padTo(8);
        try b.writeU32(0); // 0 = glob pattern
        try b.writeString(glob);
    }
    b.endArray(pat_arr);
}

pub const ParsedMessage = struct {
    msg_type: MessageType,
    serial: u32,
    reply_serial: u32,
    path: []const u8,
    interface: []const u8,
    member: []const u8,
    signature: []const u8,
    body_start: usize,
    total_len: usize,
    full_msg: []const u8,
};

pub fn parseMessage(buf: []const u8) Error!?ParsedMessage {
    if (buf.len < 16) return null;
    if (buf[0] != 'l' or buf[3] != 1) return error.ProtocolError;
    const msg_type: MessageType = switch (buf[1]) {
        1 => .method_call,
        2 => .method_return,
        3 => .error_reply,
        4 => .signal,
        else => return error.ProtocolError,
    };
    const body_len = std.mem.readInt(u32, buf[4..8], .little);
    const serial = std.mem.readInt(u32, buf[8..12], .little);
    const fields_len = std.mem.readInt(u32, buf[12..16], .little);

    const fields_end: usize = 16 + @as(usize, fields_len);
    const body_start = std.mem.alignForward(usize, fields_end, 8);
    const total_len = body_start + @as(usize, body_len);
    if (total_len > 16384) return error.ProtocolError;
    if (buf.len < total_len) return null;

    var res: ParsedMessage = .{
        .msg_type = msg_type,
        .serial = serial,
        .reply_serial = 0,
        .path = "",
        .interface = "",
        .member = "",
        .signature = "",
        .body_start = body_start,
        .total_len = total_len,
        .full_msg = buf[0..total_len],
    };

    var pos: usize = 16;
    while (pos < fields_end) {
        pos = std.mem.alignForward(usize, pos, 8);
        if (pos >= fields_end) break;
        const code = buf[pos];
        pos += 1;
        const sig = try readSignature(buf, &pos, fields_end);
        if (code == @backingInt(HeaderField.path) and std.mem.eql(u8, sig, "o")) {
            res.path = try readString(buf, &pos, fields_end);
        } else if (code == @backingInt(HeaderField.interface) and std.mem.eql(u8, sig, "s")) {
            res.interface = try readString(buf, &pos, fields_end);
        } else if (code == @backingInt(HeaderField.member) and std.mem.eql(u8, sig, "s")) {
            res.member = try readString(buf, &pos, fields_end);
        } else if (code == @backingInt(HeaderField.reply_serial) and std.mem.eql(u8, sig, "u")) {
            res.reply_serial = try readU32(buf, &pos, fields_end);
        } else if (code == @backingInt(HeaderField.signature) and std.mem.eql(u8, sig, "g")) {
            res.signature = try readSignature(buf, &pos, fields_end);
        } else {
            var sig_idx: usize = 0;
            try skipOneType(sig, &sig_idx, &pos, fields_end, buf);
        }
    }

    return res;
}

/// Parses the `(ua{sv})` body of `org.freedesktop.portal.Request.Response` and decodes
/// the first selected `"file://..."` URI into `out_path`. Returns `null` if cancelled.
pub fn parsePortalResponseBody(
    full_msg: []const u8,
    body_start: usize,
    out_path: []u8,
) Error!?[]const u8 {
    const limit = full_msg.len;
    var pos = body_start;

    const response_code = try readU32(full_msg, &pos, limit);
    if (response_code != 0) return null;

    const dict_byte_len = try readU32(full_msg, &pos, limit);
    pos = std.mem.alignForward(usize, pos, 8);
    if (pos + dict_byte_len > limit) return error.ProtocolError;
    const dict_end = pos + dict_byte_len;

    while (pos < dict_end) {
        pos = std.mem.alignForward(usize, pos, 8);
        if (pos >= dict_end) break;
        const key = try readString(full_msg, &pos, dict_end);
        const val_sig = try readSignature(full_msg, &pos, dict_end);
        if (std.mem.eql(u8, key, "uris") and std.mem.eql(u8, val_sig, "as")) {
            const uris_byte_len = try readU32(full_msg, &pos, dict_end);
            if (pos + uris_byte_len > dict_end) return error.ProtocolError;
            const uris_end = pos + uris_byte_len;
            if (pos < uris_end) {
                const first_uri = try readString(full_msg, &pos, uris_end);
                return try decodeFileUri(out_path, first_uri);
            }
            pos = uris_end;
        } else {
            var sig_idx: usize = 0;
            try skipOneType(val_sig, &sig_idx, &pos, dict_end, full_msg);
        }
    }
    return null;
}

fn readU32(buf: []const u8, pos: *usize, limit: usize) Error!u32 {
    pos.* = std.mem.alignForward(usize, pos.*, 4);
    if (pos.* + 4 > limit) return error.ProtocolError;
    const v = std.mem.readInt(u32, buf[pos.*..][0..4], .little);
    pos.* += 4;
    return v;
}

fn readString(buf: []const u8, pos: *usize, limit: usize) Error![]const u8 {
    const slen = try readU32(buf, pos, limit);
    if (pos.* + slen + 1 > limit) return error.ProtocolError;
    const s = buf[pos.* .. pos.* + slen];
    if (buf[pos.* + slen] != 0) return error.ProtocolError;
    pos.* += slen + 1;
    return s;
}

fn readSignature(buf: []const u8, pos: *usize, limit: usize) Error![]const u8 {
    if (pos.* + 1 > limit) return error.ProtocolError;
    const glen = buf[pos.*];
    if (pos.* + 1 + glen + 1 > limit) return error.ProtocolError;
    const s = buf[pos.* + 1 .. pos.* + 1 + glen];
    if (buf[pos.* + 1 + glen] != 0) return error.ProtocolError;
    pos.* += 1 + glen + 1;
    return s;
}

fn typeAlignment(c: u8) Error!usize {
    return switch (c) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'b', 'i', 'u', 'h', 's', 'o', 'a' => 4,
        'x', 't', 'd', '(', '{' => 8,
        else => error.ProtocolError,
    };
}

fn advanceSigType(sig: []const u8, idx: *usize) Error!void {
    if (idx.* >= sig.len) return error.ProtocolError;
    const c = sig[idx.*];
    idx.* += 1;
    switch (c) {
        'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 'h', 's', 'o', 'g', 'v' => {},
        'a' => try advanceSigType(sig, idx),
        '(', '{' => {
            const close_ch: u8 = if (c == '(') ')' else '}';
            while (idx.* < sig.len and sig[idx.*] != close_ch) {
                try advanceSigType(sig, idx);
            }
            if (idx.* >= sig.len or sig[idx.*] != close_ch) return error.ProtocolError;
            idx.* += 1;
        },
        else => return error.ProtocolError,
    }
}

fn skipOneType(sig: []const u8, sig_idx: *usize, pos: *usize, limit: usize, buf: []const u8) Error!void {
    if (sig_idx.* >= sig.len) return error.ProtocolError;
    const c = sig[sig_idx.*];
    sig_idx.* += 1;
    switch (c) {
        'y' => {
            if (pos.* + 1 > limit) return error.ProtocolError;
            pos.* += 1;
        },
        'n', 'q' => {
            pos.* = std.mem.alignForward(usize, pos.*, 2);
            if (pos.* + 2 > limit) return error.ProtocolError;
            pos.* += 2;
        },
        'b', 'i', 'u', 'h' => {
            pos.* = std.mem.alignForward(usize, pos.*, 4);
            if (pos.* + 4 > limit) return error.ProtocolError;
            pos.* += 4;
        },
        'x', 't', 'd' => {
            pos.* = std.mem.alignForward(usize, pos.*, 8);
            if (pos.* + 8 > limit) return error.ProtocolError;
            pos.* += 8;
        },
        's', 'o' => {
            _ = try readString(buf, pos, limit);
        },
        'g' => {
            _ = try readSignature(buf, pos, limit);
        },
        'v' => {
            const inner_sig = try readSignature(buf, pos, limit);
            var inner_idx: usize = 0;
            try skipOneType(inner_sig, &inner_idx, pos, limit, buf);
        },
        'a' => {
            if (sig_idx.* >= sig.len) return error.ProtocolError;
            const elem_align = try typeAlignment(sig[sig_idx.*]);
            try advanceSigType(sig, sig_idx);
            const arr_len = try readU32(buf, pos, limit);
            pos.* = std.mem.alignForward(usize, pos.*, elem_align);
            if (pos.* + arr_len > limit) return error.ProtocolError;
            pos.* += arr_len;
        },
        '(', '{' => {
            const close_ch: u8 = if (c == '(') ')' else '}';
            pos.* = std.mem.alignForward(usize, pos.*, 8);
            while (sig_idx.* < sig.len and sig[sig_idx.*] != close_ch) {
                try skipOneType(sig, sig_idx, pos, limit, buf);
            }
            if (sig_idx.* >= sig.len or sig[sig_idx.*] != close_ch) return error.ProtocolError;
            sig_idx.* += 1;
        },
        else => return error.ProtocolError,
    }
}

test "resolveSessionBusAddress parses unix:path and unix:abstract and fallback" {
    var buf: [128]u8 = undefined;

    const p1 = try resolveSessionBusAddress(&buf, "unix:path=/run/user/1000/bus,guid=0123", "/run/user/1000");
    try std.testing.expectEqualStrings("/run/user/1000/bus", p1.path);

    const p2 = try resolveSessionBusAddress(&buf, "unix:abstract=/tmp/dbus-test,guid=abcd", null);
    try std.testing.expectEqualStrings("/tmp/dbus-test", p2.abstract);

    const p3 = try resolveSessionBusAddress(&buf, null, "/run/user/1000/");
    try std.testing.expectEqualStrings("/run/user/1000/bus", p3.path);
}

test "formatExternalAuthLine encodes UID in ASCII hex" {
    var buf: [64]u8 = undefined;
    const line = try formatExternalAuthLine(&buf, 1000);
    try std.testing.expectEqualStrings("\x00AUTH EXTERNAL 31303030\r\n", line);
}

test "decodeFileUri decodes percent-encoded file URIs" {
    var buf: [256]u8 = undefined;
    const p1 = try decodeFileUri(&buf, "file:///home/user/Downloads/Raspberry%20Pi%20OS.img.xz");
    try std.testing.expectEqualStrings("/home/user/Downloads/Raspberry Pi OS.img.xz", p1);

    const p2 = try decodeFileUri(&buf, "file://localhost/run/user/1000/doc/abc123/ubuntu.img");
    try std.testing.expectEqualStrings("/run/user/1000/doc/abc123/ubuntu.img", p2);
}

test "D-Bus OpenFile request and Response signal round-trip" {
    var req_buf: [2048]u8 = undefined;
    const open_msg = try buildOpenFileMessage(&req_buf, open_file_serial);
    const parsed_req = (try parseMessage(open_msg)).?;
    try std.testing.expectEqual(MessageType.method_call, parsed_req.msg_type);
    try std.testing.expectEqual(open_file_serial, parsed_req.serial);
    try std.testing.expectEqualStrings("/org/freedesktop/portal/desktop", parsed_req.path);
    try std.testing.expectEqualStrings("org.freedesktop.portal.FileChooser", parsed_req.interface);
    try std.testing.expectEqualStrings("OpenFile", parsed_req.member);
    try std.testing.expectEqualStrings("ssa{sv}", parsed_req.signature);

    // Construct a synthetic org.freedesktop.portal.Request.Response signal with
    // extra preceding vardict entries (e.g. "writable": b, "current_filter": (sa(us)))
    // followed by "uris": as.
    var sig_buf: [1024]u8 = undefined;
    var b = try MessageBuilder.begin(&sig_buf, .signal, 0, 42);
    try b.writeHeaderFieldString(.path, 'o', "/org/freedesktop/portal/desktop/request/1_99/fauxpi_sd");
    try b.writeHeaderFieldString(.interface, 's', "org.freedesktop.portal.Request");
    try b.writeHeaderFieldString(.member, 's', "Response");
    try b.writeHeaderFieldString(.signature, 'g', "ua{sv}");
    try b.finishHeader();

    // response = 0 (success)
    try b.writeU32(0);
    const dict = try b.beginArray(8);

    // Entry 1: "writable": b = true
    try b.padTo(8);
    try b.writeString("writable");
    try b.writeSignature("b");
    try b.writeU32(1);

    // Entry 2: "current_filter": (sa(us))
    try b.padTo(8);
    try b.writeString("current_filter");
    try b.writeSignature("(sa(us))");
    try writeFileFilter(&b, "Disk Images", &.{"*.img"});

    // Entry 3: "uris": as = ["file:///run/user/1000/doc/4f8a/raspios%20lite.img"]
    try b.padTo(8);
    try b.writeString("uris");
    try b.writeSignature("as");
    const uris_arr = try b.beginArray(4);
    try b.writeString("file:///run/user/1000/doc/4f8a/raspios%20lite.img");
    b.endArray(uris_arr);

    b.endArray(dict);
    const raw_signal = b.finish();

    const parsed_sig = (try parseMessage(raw_signal)).?;
    try std.testing.expectEqual(MessageType.signal, parsed_sig.msg_type);
    try std.testing.expectEqualStrings("org.freedesktop.portal.Request", parsed_sig.interface);
    try std.testing.expectEqualStrings("Response", parsed_sig.member);

    var out_path: [256]u8 = undefined;
    const chosen = (try parsePortalResponseBody(parsed_sig.full_msg, parsed_sig.body_start, &out_path)).?;
    try std.testing.expectEqualStrings("/run/user/1000/doc/4f8a/raspios lite.img", chosen);
}
