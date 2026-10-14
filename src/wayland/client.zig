//! Pure-Zig Wayland wire protocol and client library over a Unix domain socket.

const std = @import("std");
const linux = std.os.linux;
const protocol = @import("protocol.zig");

pub const Error = error{
    Closed,
    WouldBlock,
    ProtocolError,
    BufferFull,
    TooManyFds,
    SystemError,
    ConnectFailed,
    NoRuntimeDir,
    ServerError,
    OutOfMemory,
};

pub const max_message_size = 4096;
const max_fds_per_message = 28;

pub const Message = struct {
    object: u32,
    opcode: u16,
    data: []const u8,
};

pub const Connection = struct {
    fd: linux.fd_t,
    in: [4 * max_message_size]u8 = undefined,
    in_start: usize = 0,
    in_end: usize = 0,
    in_fds: [64]linux.fd_t = undefined,
    in_fds_start: usize = 0,
    in_fds_end: usize = 0,
    out: [4 * max_message_size]u8 = undefined,
    out_len: usize = 0,
    out_fds: [max_fds_per_message]linux.fd_t = undefined,
    out_fds_len: usize = 0,

    pub fn init(fd: linux.fd_t) Connection {
        return .{ .fd = fd };
    }

    pub fn deinit(c: *Connection) void {
        while (c.takeFd()) |fd| _ = linux.close(fd);
        for (c.out_fds[0..c.out_fds_len]) |fd| _ = linux.close(fd);
        _ = linux.close(c.fd);
    }

    pub fn read(c: *Connection) Error!usize {
        if (c.in_start > 0) {
            std.mem.copyForwards(u8, &c.in, c.in[c.in_start..c.in_end]);
            c.in_end -= c.in_start;
            c.in_start = 0;
        }
        if (c.in_fds_start > 0) {
            std.mem.copyForwards(linux.fd_t, &c.in_fds, c.in_fds[c.in_fds_start..c.in_fds_end]);
            c.in_fds_end -= c.in_fds_start;
            c.in_fds_start = 0;
        }
        if (c.in_end == c.in.len) return error.BufferFull;
        var iov = [_]std.posix.iovec{.{ .base = c.in[c.in_end..].ptr, .len = c.in.len - c.in_end }};
        var control: [cmsgSpace(max_fds_per_message)]u8 align(@alignOf(linux.cmsghdr)) = undefined;
        var msg: linux.msghdr = .{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = &control,
            .controllen = control.len,
            .flags = 0,
        };
        const rc = linux.recvmsg(c.fd, &msg, linux.MSG.DONTWAIT | linux.MSG.CMSG_CLOEXEC);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => return error.WouldBlock,
            .INTR => return 0,
            .CONNRESET, .PIPE => return error.Closed,
            else => return error.SystemError,
        }
        var at: usize = 0;
        while (at + @sizeOf(linux.cmsghdr) <= msg.controllen) {
            const hdr: *const linux.cmsghdr = @ptrCast(@alignCast(&control[at]));
            if (hdr.len < @sizeOf(linux.cmsghdr)) break;
            if (hdr.level == linux.SOL.SOCKET and hdr.type == linux.SCM.RIGHTS) {
                const data = control[at + cmsgAlign(@sizeOf(linux.cmsghdr)) .. at + hdr.len];
                var i: usize = 0;
                while (i + 4 <= data.len) : (i += 4) {
                    const fd = std.mem.readInt(i32, data[i..][0..4], .little);
                    if (c.in_fds_end == c.in_fds.len) {
                        _ = linux.close(fd);
                        continue;
                    }
                    c.in_fds[c.in_fds_end] = fd;
                    c.in_fds_end += 1;
                }
            }
            at += cmsgAlign(hdr.len);
        }
        if (rc == 0) return error.Closed;
        c.in_end += rc;
        return rc;
    }

    pub fn next(c: *Connection) Error!?Message {
        const avail = c.in[c.in_start..c.in_end];
        if (avail.len < 8) return null;
        const object = std.mem.readInt(u32, avail[0..4], .little);
        const word = std.mem.readInt(u32, avail[4..8], .little);
        const size: usize = word >> 16;
        if (size < 8 or size % 4 != 0) return error.ProtocolError;
        if (avail.len < size) {
            if (size > c.in.len) return error.ProtocolError;
            return null;
        }
        c.in_start += size;
        return .{ .object = object, .opcode = @truncate(word), .data = avail[8..size] };
    }

    pub fn takeFd(c: *Connection) ?linux.fd_t {
        if (c.in_fds_start == c.in_fds_end) return null;
        const fd = c.in_fds[c.in_fds_start];
        c.in_fds_start += 1;
        return fd;
    }

    pub fn begin(c: *Connection, object: u32, opcode: u16) Error!Builder {
        if (c.out.len - c.out_len < max_message_size or c.out_fds_len + 4 > c.out_fds.len) try c.flush();
        if (c.out.len - c.out_len < max_message_size) return error.BufferFull;
        const start = c.out_len;
        c.out_len += 8;
        std.mem.writeInt(u32, c.out[start..][0..4], object, .little);
        return .{ .c = c, .start = start, .opcode = opcode };
    }

    pub fn flush(c: *Connection) Error!void {
        while (c.out_len > 0 or c.out_fds_len > 0) {
            const iov = [_]std.posix.iovec_const{.{ .base = &c.out, .len = c.out_len }};
            var control: [cmsgSpace(max_fds_per_message)]u8 align(@alignOf(linux.cmsghdr)) = undefined;
            var control_len: usize = 0;
            if (c.out_fds_len > 0) {
                const hdr: *linux.cmsghdr = @ptrCast(&control);
                hdr.* = .{ .len = cmsgAlign(@sizeOf(linux.cmsghdr)) + c.out_fds_len * 4, .level = linux.SOL.SOCKET, .type = linux.SCM.RIGHTS };
                for (c.out_fds[0..c.out_fds_len], 0..) |fd, i|
                    std.mem.writeInt(i32, control[cmsgAlign(@sizeOf(linux.cmsghdr)) + i * 4 ..][0..4], fd, .little);
                control_len = cmsgSpace(c.out_fds_len);
            }
            const msg: linux.msghdr_const = .{
                .name = null,
                .namelen = 0,
                .iov = &iov,
                .iovlen = 1,
                .control = if (control_len > 0) &control else null,
                .controllen = control_len,
                .flags = 0,
            };
            const rc = linux.sendmsg(c.fd, &msg, linux.MSG.NOSIGNAL);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                .AGAIN => {
                    var fds = [_]linux.pollfd{.{ .fd = c.fd, .events = linux.POLL.OUT, .revents = 0 }};
                    _ = linux.poll(&fds, 1, 1000);
                    continue;
                },
                .PIPE, .CONNRESET => return error.Closed,
                else => return error.SystemError,
            }
            for (c.out_fds[0..c.out_fds_len]) |fd| _ = linux.close(fd);
            c.out_fds_len = 0;
            std.mem.copyForwards(u8, &c.out, c.out[rc..c.out_len]);
            c.out_len -= rc;
        }
    }
};

fn cmsgAlign(n: usize) usize {
    return std.mem.alignForward(usize, n, @sizeOf(usize));
}

fn cmsgSpace(fds: usize) usize {
    return cmsgAlign(@sizeOf(linux.cmsghdr)) + cmsgAlign(fds * 4);
}

pub const Builder = struct {
    c: *Connection,
    start: usize,
    opcode: u16,

    fn word(b: *Builder, v: u32) void {
        std.mem.writeInt(u32, b.c.out[b.c.out_len..][0..4], v, .little);
        b.c.out_len += 4;
    }

    pub fn uint(b: *Builder, v: u32) *Builder {
        b.word(v);
        return b;
    }

    pub fn int(b: *Builder, v: i32) *Builder {
        b.word(@bitCast(v));
        return b;
    }

    pub fn fixed(b: *Builder, v: f64) *Builder {
        b.word(@bitCast(@as(i32, @intFromFloat(v * 256))));
        return b;
    }

    pub fn string(b: *Builder, s: ?[]const u8) *Builder {
        const str = s orelse {
            b.word(0);
            return b;
        };
        b.word(@intCast(str.len + 1));
        @memcpy(b.c.out[b.c.out_len..][0..str.len], str);
        const padded = std.mem.alignForward(usize, str.len + 1, 4);
        @memset(b.c.out[b.c.out_len + str.len ..][0 .. padded - str.len], 0);
        b.c.out_len += padded;
        return b;
    }

    pub fn array(b: *Builder, bytes: []const u8) *Builder {
        b.word(@intCast(bytes.len));
        @memcpy(b.c.out[b.c.out_len..][0..bytes.len], bytes);
        const padded = std.mem.alignForward(usize, bytes.len, 4);
        @memset(b.c.out[b.c.out_len + bytes.len ..][0 .. padded - bytes.len], 0);
        b.c.out_len += padded;
        return b;
    }

    pub fn fd(b: *Builder, f: linux.fd_t) *Builder {
        b.c.out_fds[b.c.out_fds_len] = f;
        b.c.out_fds_len += 1;
        return b;
    }

    pub fn end(b: *Builder) void {
        const size: u32 = @intCast(b.c.out_len - b.start);
        std.mem.writeInt(u32, b.c.out[b.start + 4 ..][0..4], size << 16 | b.opcode, .little);
    }
};

pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,
    c: *Connection,

    pub fn init(c: *Connection, m: Message) Reader {
        return .{ .data = m.data, .c = c };
    }

    pub fn uint(r: *Reader) Error!u32 {
        if (r.pos + 4 > r.data.len) return error.ProtocolError;
        const v = std.mem.readInt(u32, r.data[r.pos..][0..4], .little);
        r.pos += 4;
        return v;
    }

    pub fn int(r: *Reader) Error!i32 {
        return @bitCast(try r.uint());
    }

    pub fn fixed(r: *Reader) Error!f64 {
        return @as(f64, @floatFromInt(try r.int())) / 256;
    }

    pub fn string(r: *Reader) Error!?[]const u8 {
        const len = try r.uint();
        if (len == 0) return null;
        const padded = std.mem.alignForward(usize, len, 4);
        if (r.pos + padded > r.data.len) return error.ProtocolError;
        const s = r.data[r.pos..][0 .. len - 1];
        if (r.data[r.pos + len - 1] != 0) return error.ProtocolError;
        r.pos += padded;
        return s;
    }

    pub fn array(r: *Reader) Error![]const u8 {
        const len = try r.uint();
        const padded = std.mem.alignForward(usize, len, 4);
        if (r.pos + padded > r.data.len) return error.ProtocolError;
        const a = r.data[r.pos..][0..len];
        r.pos += padded;
        return a;
    }

    pub fn fd(r: *Reader) Error!linux.fd_t {
        return r.c.takeFd() orelse error.ProtocolError;
    }
};

pub const Listener = struct {
    ptr: ?*anyopaque,
    handler: *const fn (ptr: ?*anyopaque, d: *Display, object: u32, opcode: u16, r: *Reader) void,
};

pub const Proxy = struct {
    display: *Display,
    id: u32,

    pub fn request(p: Proxy, opcode: u16) Error!Builder {
        return p.display.conn.begin(p.id, opcode);
    }
};

pub const Display = struct {
    gpa: std.mem.Allocator,
    conn: Connection,
    next_id: u32 = 2,
    listeners: std.AutoHashMapUnmanaged(u32, Listener) = .empty,
    failed: bool = false,
    error_object: u32 = 0,
    error_code: u32 = 0,
    error_buf: [128]u8 = undefined,
    error_len: usize = 0,

    pub fn connect(gpa: std.mem.Allocator, path: []const u8) Error!*Display {
        const fd: linux.fd_t = @intCast(sysCheck(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)) catch return error.ConnectFailed);
        var addr: linux.sockaddr.un = .{ .path = @splat(0) };
        if (path.len >= addr.path.len) return error.ConnectFailed;
        @memcpy(addr.path[0..path.len], path);
        if (linux.errno(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un))) != .SUCCESS) {
            _ = linux.close(fd);
            return error.ConnectFailed;
        }
        return fromFd(gpa, fd);
    }

    pub fn connectEnviron(gpa: std.mem.Allocator, environ: std.process.Environ) Error!*Display {
        var buf: [128]u8 = undefined;
        return connect(gpa, try environSocketPath(&buf, environ));
    }

    pub fn fromFd(gpa: std.mem.Allocator, fd: linux.fd_t) Error!*Display {
        const d = try gpa.create(Display);
        d.* = .{ .gpa = gpa, .conn = .init(fd) };
        try d.listeners.put(gpa, protocol.wl_display.id, .{ .ptr = null, .handler = displayEvent });
        return d;
    }

    pub fn disconnect(d: *Display) void {
        d.conn.deinit();
        d.listeners.deinit(d.gpa);
        d.gpa.destroy(d);
    }

    pub fn proxy(d: *Display) Proxy {
        return .{ .display = d, .id = protocol.wl_display.id };
    }

    pub fn newObject(d: *Display, listener: ?Listener) Error!Proxy {
        const id = d.next_id;
        d.next_id += 1;
        if (listener) |l| try d.listeners.put(d.gpa, id, l);
        return .{ .display = d, .id = id };
    }

    pub fn forget(d: *Display, id: u32) void {
        _ = d.listeners.remove(id);
    }

    pub fn flush(d: *Display) Error!void {
        return d.conn.flush();
    }

    pub fn dispatchPending(d: *Display) Error!usize {
        var n: usize = 0;
        while (true) {
            while (try d.conn.next()) |m| {
                var r = Reader.init(&d.conn, m);
                if (d.listeners.get(m.object)) |l| l.handler(l.ptr, d, m.object, m.opcode, &r);
                n += 1;
                if (d.failed) return error.ServerError;
            }
            _ = d.conn.read() catch |e| switch (e) {
                error.WouldBlock => return n,
                else => return e,
            };
        }
    }

    pub fn dispatch(d: *Display) Error!void {
        try d.flush();
        while (true) {
            if (try d.dispatchPending() > 0) return;
            var fds = [_]linux.pollfd{.{ .fd = d.conn.fd, .events = linux.POLL.IN, .revents = 0 }};
            _ = linux.poll(&fds, 1, -1);
        }
    }

    pub fn pollAndDispatch(d: *Display) Error!void {
        try d.flush();
        _ = try d.dispatchPending();
    }

    pub fn roundtrip(d: *Display) Error!void {
        var done = false;
        const cb = try d.newObject(.{ .ptr = &done, .handler = setFlag });
        var m = try d.proxy().request(protocol.wl_display.request.sync);
        m.uint(cb.id).end();
        while (!done) try d.dispatch();
        d.forget(cb.id);
    }

    fn setFlag(ptr: ?*anyopaque, _: *Display, _: u32, _: u16, _: *Reader) void {
        const flag: *bool = @ptrCast(ptr.?);
        flag.* = true;
    }

    fn displayEvent(_: ?*anyopaque, d: *Display, _: u32, opcode: u16, r: *Reader) void {
        switch (opcode) {
            protocol.wl_display.event.@"error" => {
                d.error_object = r.uint() catch 0;
                d.error_code = r.uint() catch 0;
                const message = (r.string() catch null) orelse "";
                d.error_len = @min(message.len, d.error_buf.len);
                @memcpy(d.error_buf[0..d.error_len], message[0..d.error_len]);
                d.failed = true;
            },
            protocol.wl_display.event.delete_id => {
                const id = r.uint() catch return;
                d.forget(id);
            },
            else => {},
        }
    }
};

fn sysCheck(rc: usize) !usize {
    return if (linux.errno(rc) == .SUCCESS) rc else error.SystemError;
}

pub fn socketPath(buf: []u8, runtime_dir: ?[]const u8, wayland_display: ?[]const u8) Error![]const u8 {
    const name = wayland_display orelse "wayland-0";
    if (name.len > 0 and name[0] == '/') return name;
    const dir = runtime_dir orelse return error.NoRuntimeDir;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, name }) catch error.NoRuntimeDir;
}

pub fn environSocketPath(buf: []u8, environ: std.process.Environ) Error![]const u8 {
    const Environ = std.process.Environ;
    return socketPath(buf, Environ.getPosix(environ, "XDG_RUNTIME_DIR"), Environ.getPosix(environ, "WAYLAND_DISPLAY"));
}

pub const Globals = struct {
    pub const Global = struct { name: u32, interface: [64]u8, interface_len: usize, version: u32 };
    list: [64]Global = undefined,
    len: usize = 0,

    pub fn find(g: *const Globals, interface: []const u8) ?Global {
        for (g.list[0..g.len]) |gl| if (std.mem.eql(u8, gl.interface[0..gl.interface_len], interface)) return gl;
        return null;
    }

    fn event(ptr: ?*anyopaque, _: *Display, _: u32, opcode: u16, r: *Reader) void {
        const g: *Globals = @ptrCast(@alignCast(ptr.?));
        if (opcode != protocol.wl_registry.event.global or g.len == g.list.len) return;
        const name = r.uint() catch return;
        const interface = (r.string() catch return) orelse return;
        const version = r.uint() catch return;
        if (interface.len > 64) return;
        var entry: Global = .{ .name = name, .interface = undefined, .interface_len = interface.len, .version = version };
        @memcpy(entry.interface[0..interface.len], interface);
        g.list[g.len] = entry;
        g.len += 1;
    }

    pub fn fetch(g: *Globals, d: *Display) Error!Proxy {
        const registry = try d.newObject(.{ .ptr = g, .handler = event });
        var m = try d.proxy().request(protocol.wl_display.request.get_registry);
        m.uint(registry.id).end();
        try d.roundtrip();
        return registry;
    }

    pub fn bind(g: *const Globals, registry: Proxy, interface: []const u8, version: u32, listener: ?Listener) Error!?Proxy {
        const gl = g.find(interface) orelse return null;
        const p = try registry.display.newObject(listener);
        var m = try registry.request(protocol.wl_registry.request.bind);
        m.uint(gl.name).string(interface).uint(@min(version, gl.version)).uint(p.id).end();
        return p;
    }
};

test "Wayland wire messages round trip" {
    var fds: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds)));
    var a = Connection.init(fds[0]);
    defer a.deinit();
    var b = Connection.init(fds[1]);
    defer b.deinit();

    var m = try a.begin(7, 3);
    m.uint(42).int(-5).string("fauxpi").end();
    try a.flush();

    _ = try b.read();
    const msg = (try b.next()).?;
    var r = Reader.init(&b, msg);
    try std.testing.expectEqual(@as(u32, 42), try r.uint());
    try std.testing.expectEqual(@as(i32, -5), try r.int());
    try std.testing.expectEqualStrings("fauxpi", (try r.string()).?);
}
