//! Cross-platform host POSIX, clock, random, futex, and non-blocking BSD socket helpers
//! supporting both Linux and macOS (`darwin`).

const std = @import("std");
const builtin = @import("builtin");

pub const is_linux = builtin.os.tag == .linux;
pub const is_macos = builtin.os.tag == .macos;

pub const fd_t = std.c.fd_t;
pub const pid_t = std.c.pid_t;
pub const pollfd = std.c.pollfd;
pub const sockaddr = std.c.sockaddr;
pub const timespec = std.c.timespec;

pub const STDOUT_FILENO: fd_t = 1;

pub const POLL = struct {
    pub const IN: i16 = 0x0001;
    pub const OUT: i16 = 0x0004;
};

// Darwin / POSIX fcntl and socket constants
const F_GETFD: c_int = 1;
const F_SETFD: c_int = 2;
const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const FD_CLOEXEC: c_int = 1;

const O_NONBLOCK_MACOS: c_int = 0x0004;
const O_CREAT_MACOS: c_int = 0x0200;
const O_TRUNC_MACOS: c_int = 0x0400;
const O_EXCL_MACOS: c_int = 0x0800;
const O_CLOEXEC_MACOS: c_int = 0x01000000;

const SOL_SOCKET_MACOS: i32 = 0xffff;
const SO_NOSIGPIPE_MACOS: u32 = 0x1022;
const MSG_DONTWAIT_MACOS: u32 = 0x80;

pub fn close(fd: fd_t) void {
    if (fd < 0) return;
    if (is_linux) {
        _ = std.os.linux.close(fd);
    } else {
        _ = std.c.close(fd);
    }
}

pub fn writeStdout(bytes: []const u8) void {
    if (bytes.len == 0) return;
    if (is_linux) {
        _ = std.os.linux.write(STDOUT_FILENO, bytes.ptr, bytes.len);
    } else {
        _ = std.c.write(STDOUT_FILENO, bytes.ptr, bytes.len);
    }
}

pub fn openRead(path: []const u8) !fd_t {
    var path_z: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= path_z.len) return error.NameTooLong;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    if (is_linux) {
        const rc = std.os.linux.openat(
            std.os.linux.AT.FDCWD,
            path_z[0..path.len :0],
            .{ .ACCMODE = .RDONLY, .CLOEXEC = true },
            0,
        );
        if (std.os.linux.errno(rc) != .SUCCESS) return error.FileOpenFailed;
        return @intCast(rc);
    } else {
        const rc = std.c.open(
            path_z[0..path.len :0],
            @bitCast(@as(c_int, 0) | O_CLOEXEC_MACOS),
            @as(c_uint, 0),
        );
        if (rc < 0) return error.FileOpenFailed;
        return rc;
    }
}

pub fn openReadWrite(path: []const u8) !fd_t {
    var path_z: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= path_z.len) return error.NameTooLong;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    if (is_linux) {
        const rc = std.os.linux.openat(
            std.os.linux.AT.FDCWD,
            path_z[0..path.len :0],
            .{ .ACCMODE = .RDWR, .CLOEXEC = true },
            0,
        );
        if (std.os.linux.errno(rc) != .SUCCESS) return error.FileOpenFailed;
        return @intCast(rc);
    } else {
        const rc = std.c.open(
            path_z[0..path.len :0],
            @bitCast(@as(c_int, 2) | O_CLOEXEC_MACOS),
            @as(c_uint, 0),
        );
        if (rc < 0) return error.FileOpenFailed;
        return rc;
    }
}

pub fn openCreateTruncWrite(path: []const u8, read_write: bool) !fd_t {
    var path_z: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= path_z.len) return error.NameTooLong;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    if (is_linux) {
        const rc = std.os.linux.openat(
            std.os.linux.AT.FDCWD,
            path_z[0..path.len :0],
            .{
                .ACCMODE = if (read_write) .RDWR else .WRONLY,
                .CREAT = true,
                .TRUNC = true,
                .CLOEXEC = true,
            },
            0o644,
        );
        if (std.os.linux.errno(rc) != .SUCCESS) return error.FileOpenFailed;
        return @intCast(rc);
    } else {
        const acc: c_int = if (read_write) 2 else 1;
        const flags: c_int = acc | O_CREAT_MACOS | O_TRUNC_MACOS | O_CLOEXEC_MACOS;
        const rc = std.c.open(path_z[0..path.len :0], @bitCast(flags), @as(c_uint, 0o644));
        if (rc < 0) return error.FileOpenFailed;
        return rc;
    }
}

pub fn createTempBackingFd() !fd_t {
    if (is_linux) {
        const tmp_dirs = [_][:0]const u8{ "/var/tmp", "/tmp" };
        for (tmp_dirs) |dir| {
            const rc = std.os.linux.openat(
                std.os.linux.AT.FDCWD,
                dir,
                .{
                    .ACCMODE = .RDWR,
                    .TMPFILE = true,
                    .CLOEXEC = true,
                },
                0o600,
            );
            if (std.os.linux.errno(rc) == .SUCCESS) {
                return @intCast(rc);
            }
        }
        const mfd_rc = std.os.linux.memfd_create("fauxpi-sdcard-qcow2", std.os.linux.MFD.CLOEXEC);
        if (std.os.linux.errno(mfd_rc) != .SUCCESS) return error.FileOpenFailed;
        return @intCast(mfd_rc);
    } else {
        var rnd: [8]u8 = undefined;
        getRandomBytes(&rnd);
        var path_buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(
            &path_buf,
            "/tmp/fauxpi-sdcard-{x}.qcow2\x00",
            .{std.mem.readInt(u64, &rnd, .little)},
        ) catch return error.FileOpenFailed;
        const path_z: [*:0]const u8 = @ptrCast(path.ptr);
        const flags: c_int = 2 | O_CREAT_MACOS | O_EXCL_MACOS | O_TRUNC_MACOS | O_CLOEXEC_MACOS;
        const fd = std.c.open(path_z, @bitCast(flags), @as(c_uint, 0o600));
        if (fd < 0) return error.FileOpenFailed;
        _ = std.c.unlink(path_z);
        return fd;
    }
}

pub fn lseekEnd(fd: fd_t) !u64 {
    if (is_linux) {
        const rc = std.os.linux.lseek(fd, 0, std.os.linux.SEEK.END);
        if (std.os.linux.errno(rc) != .SUCCESS) return error.FileSeekFailed;
        return @intCast(rc);
    } else {
        const rc = std.c.lseek(fd, 0, 2); // SEEK_END = 2
        if (rc < 0) return error.FileSeekFailed;
        return @intCast(rc);
    }
}

pub fn lseekSet(fd: fd_t, offset: u64) void {
    if (is_linux) {
        _ = std.os.linux.lseek(fd, @intCast(offset), std.os.linux.SEEK.SET);
    } else {
        _ = std.c.lseek(fd, @intCast(offset), 0); // SEEK_SET = 0
    }
}

pub fn ftruncate(fd: fd_t, length: u64) void {
    if (is_linux) {
        _ = std.os.linux.ftruncate(fd, @intCast(length));
    } else {
        _ = std.c.ftruncate(fd, @intCast(length));
    }
}

pub fn read(fd: fd_t, buf: []u8) !usize {
    if (is_linux) {
        const rc = std.os.linux.read(fd, buf.ptr, buf.len);
        if (std.os.linux.errno(rc) != .SUCCESS) return error.FileReadFailed;
        return rc;
    } else {
        const rc = std.c.read(fd, buf.ptr, buf.len);
        if (rc < 0) return error.FileReadFailed;
        return @intCast(rc);
    }
}

pub fn readNonBlock(fd: fd_t, buf: []u8) union(enum) { bytes: usize, again, err } {
    if (is_linux) {
        const rc = std.os.linux.read(fd, buf.ptr, buf.len);
        const e = std.os.linux.errno(rc);
        if (e == .AGAIN) return .again;
        if (e != .SUCCESS) return .err;
        return .{ .bytes = rc };
    } else {
        const rc = std.c.read(fd, buf.ptr, buf.len);
        if (rc < 0) {
            const e = std.c._errno().*;
            if (e == @intFromEnum(std.c.E.AGAIN)) return .again;
            return .err;
        }
        return .{ .bytes = @intCast(rc) };
    }
}

pub fn writeAll(fd: fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        if (is_linux) {
            const rc = std.os.linux.write(fd, bytes[written..].ptr, bytes.len - written);
            if (std.os.linux.errno(rc) != .SUCCESS) return error.FileWriteFailed;
            written += rc;
        } else {
            const rc = std.c.write(fd, bytes[written..].ptr, bytes.len - written);
            if (rc <= 0) return error.FileWriteFailed;
            written += @intCast(rc);
        }
    }
}

pub fn preadAll(fd: fd_t, buf: []u8, offset: u64) !void {
    var done: usize = 0;
    while (done < buf.len) {
        if (is_linux) {
            const rc = std.os.linux.pread(fd, buf[done..].ptr, buf.len - done, @intCast(offset + done));
            if (std.os.linux.errno(rc) != .SUCCESS) return error.DiskReadFailed;
            if (rc == 0) {
                @memset(buf[done..], 0);
                return;
            }
            done += rc;
        } else {
            const rc = std.c.pread(fd, buf[done..].ptr, buf.len - done, @intCast(offset + done));
            if (rc < 0) return error.DiskReadFailed;
            if (rc == 0) {
                @memset(buf[done..], 0);
                return;
            }
            done += @intCast(rc);
        }
    }
}

pub fn pwriteAll(fd: fd_t, buf: []const u8, offset: u64) !void {
    var done: usize = 0;
    while (done < buf.len) {
        if (is_linux) {
            const rc = std.os.linux.pwrite(fd, buf[done..].ptr, buf.len - done, @intCast(offset + done));
            if (std.os.linux.errno(rc) != .SUCCESS) return error.DiskWriteFailed;
            done += rc;
        } else {
            const rc = std.c.pwrite(fd, buf[done..].ptr, buf.len - done, @intCast(offset + done));
            if (rc <= 0) return error.DiskWriteFailed;
            done += @intCast(rc);
        }
    }
}

pub fn unlinkFile(path: []const u8) void {
    var path_z: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= path_z.len) return;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    if (is_linux) {
        _ = std.os.linux.unlinkat(std.os.linux.AT.FDCWD, path_z[0..path.len :0], 0);
    } else {
        _ = std.c.unlink(path_z[0..path.len :0]);
    }
}

pub fn removeDir(path: []const u8) void {
    var path_z: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= path_z.len) return;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    if (is_linux) {
        _ = std.os.linux.unlinkat(std.os.linux.AT.FDCWD, path_z[0..path.len :0], std.os.linux.AT.REMOVEDIR);
    } else {
        _ = std.c.rmdir(path_z[0..path.len :0]);
    }
}

pub fn ensureDirPath(path: []const u8) void {
    if (path.len == 0 or path.len >= std.fs.max_path_bytes) return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(buf[0..path.len], path);

    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or buf[i] == '/') {
            const saved = if (i < path.len) buf[i] else 0;
            buf[i] = 0;
            if (is_linux) {
                _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, buf[0..i :0], 0o755);
            } else {
                _ = std.c.mkdir(buf[0..i :0], 0o755);
            }
            if (i < path.len) buf[i] = saved;
        }
    }
}

pub fn fileExists(path: []const u8) bool {
    if (path.len == 0 or path.len >= std.fs.max_path_bytes) return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    if (is_linux) {
        return std.os.linux.errno(std.os.linux.faccessat(std.os.linux.AT.FDCWD, buf[0..path.len :0], std.os.linux.F_OK, 0)) == .SUCCESS;
    } else {
        return std.c.access(buf[0..path.len :0], 0) == 0;
    }
}

pub fn pipeNonBlockCloexec(fds: *[2]fd_t) bool {
    if (is_linux) {
        return std.os.linux.errno(std.os.linux.pipe2(fds, .{ .CLOEXEC = true, .NONBLOCK = true })) == .SUCCESS;
    } else {
        if (std.c.pipe(fds) != 0) return false;
        for (fds) |fd| {
            _ = std.c.fcntl(fd, F_SETFD, FD_CLOEXEC);
        }
        const fl = std.c.fcntl(fds[0], F_GETFL, @as(c_int, 0));
        if (fl >= 0) {
            _ = std.c.fcntl(fds[0], F_SETFL, fl | O_NONBLOCK_MACOS);
        }
        return true;
    }
}

pub fn forkProcess() ?pid_t {
    if (is_linux) {
        const rc = std.os.linux.fork();
        if (std.os.linux.errno(rc) != .SUCCESS) return null;
        return @intCast(rc);
    } else {
        const rc = std.c.fork();
        if (rc < 0) return null;
        return rc;
    }
}

pub fn dup2Stdout(fd: fd_t) void {
    if (is_linux) {
        _ = std.os.linux.dup2(fd, STDOUT_FILENO);
    } else {
        _ = std.c.dup2(fd, STDOUT_FILENO);
    }
}

pub fn waitpidBlocking(pid: pid_t) void {
    if (pid <= 0) return;
    if (is_linux) {
        var wstatus: u32 = 0;
        _ = std.os.linux.waitpid(pid, &wstatus, 0);
    } else {
        var wstatus: c_int = 0;
        _ = std.c.waitpid(pid, &wstatus, 0);
    }
}

pub fn monotonicNs() u64 {
    if (is_linux) {
        var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        const sec: u64 = if (ts.sec > 0) @intCast(ts.sec) else 0;
        const nsec: u64 = if (ts.nsec > 0) @intCast(ts.nsec) else 0;
        return sec * std.time.ns_per_s + nsec;
    } else {
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
        const sec: u64 = if (ts.sec > 0) @intCast(ts.sec) else 0;
        const nsec: u64 = if (ts.nsec > 0) @intCast(ts.nsec) else 0;
        return sec * std.time.ns_per_s + nsec;
    }
}

pub fn realtimeSecNsec() struct { sec: u64, nsec: u64 } {
    if (is_linux) {
        var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
        return .{
            .sec = if (ts.sec > 0) @intCast(ts.sec) else 0,
            .nsec = if (ts.nsec > 0) @intCast(ts.nsec) else 0,
        };
    } else {
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        return .{
            .sec = if (ts.sec > 0) @intCast(ts.sec) else 0,
            .nsec = if (ts.nsec > 0) @intCast(ts.nsec) else 0,
        };
    }
}

pub fn getRandomBytes(buf: []u8) void {
    if (buf.len == 0) return;
    if (is_linux) {
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}

const UL_COMPARE_AND_WAIT_MACOS: u32 = 1 | 0x01000000; // UL_COMPARE_AND_WAIT | ULF_NO_ERRNO
extern "c" fn __ulock_wake(operation: u32, addr: *const anyopaque, wake_value: u64) c_int;
extern "c" fn __ulock_wait(operation: u32, addr: *const anyopaque, value: u64, timeout: u32) c_int;

pub fn futexWake(ptr: *const u32) void {
    if (is_linux) {
        _ = std.os.linux.futex_4arg(
            @ptrCast(ptr),
            .{ .cmd = .WAKE, .private = true },
            1,
            null,
        );
    } else if (is_macos) {
        _ = __ulock_wake(UL_COMPARE_AND_WAIT_MACOS, ptr, 0);
    }
}

pub fn futexWait(ptr: *const u32, expected: u32) void {
    if (is_linux) {
        _ = std.os.linux.futex_4arg(
            @ptrCast(ptr),
            .{ .cmd = .WAIT, .private = true },
            expected,
            null,
        );
    } else if (is_macos) {
        _ = __ulock_wait(UL_COMPARE_AND_WAIT_MACOS, ptr, expected, 0);
    }
}

pub fn socketNonBlock(is_tcp: bool) !fd_t {
    if (is_linux) {
        const stype: u32 = (if (is_tcp) @as(u32, std.os.linux.SOCK.STREAM) else @as(u32, std.os.linux.SOCK.DGRAM)) |
            std.os.linux.SOCK.NONBLOCK |
            std.os.linux.SOCK.CLOEXEC;
        const rc = std.os.linux.socket(std.os.linux.AF.INET, stype, 0);
        if (std.os.linux.errno(rc) != .SUCCESS) return error.SocketFailed;
        return @intCast(rc);
    } else {
        const stype: c_uint = if (is_tcp) std.c.SOCK.STREAM else std.c.SOCK.DGRAM;
        const fd = std.c.socket(std.c.AF.INET, stype, 0);
        if (fd < 0) return error.SocketFailed;
        _ = std.c.fcntl(fd, F_SETFD, FD_CLOEXEC);
        const fl = std.c.fcntl(fd, F_GETFL, @as(c_int, 0));
        if (fl >= 0) {
            _ = std.c.fcntl(fd, F_SETFL, fl | O_NONBLOCK_MACOS);
        }
        var one: c_int = 1;
        _ = std.c.setsockopt(fd, SOL_SOCKET_MACOS, SO_NOSIGPIPE_MACOS, &one, @sizeOf(c_int));
        return fd;
    }
}

pub const ConnectStatus = enum {
    connected_or_in_progress,
    failed,
};

pub fn connectIpv4NonBlock(fd: fd_t, ip: [4]u8, port: u16) ConnectStatus {
    var addr: sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(ip),
    };
    if (is_linux) {
        const rc = std.os.linux.connect(fd, @ptrCast(&addr), @sizeOf(sockaddr.in));
        const err = std.os.linux.errno(rc);
        if (err == .SUCCESS or err == .INPROGRESS or err == .AGAIN) return .connected_or_in_progress;
        return .failed;
    } else {
        const rc = std.c.connect(fd, @ptrCast(&addr), @sizeOf(sockaddr.in));
        if (rc == 0) return .connected_or_in_progress;
        const e = std.c._errno().*;
        if (e == @intFromEnum(std.c.E.INPROGRESS) or e == @intFromEnum(std.c.E.AGAIN)) {
            return .connected_or_in_progress;
        }
        return .failed;
    }
}

pub fn sendtoIpv4NonBlock(fd: fd_t, data: []const u8, ip: ?[4]u8, port: u16) usize {
    if (data.len == 0) return 0;
    var addr: sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = if (ip) |v| @bitCast(v) else 0,
    };
    const addr_ptr: ?*const sockaddr = if (ip != null) @ptrCast(&addr) else null;
    const addr_len: u32 = if (ip != null) @sizeOf(sockaddr.in) else 0;

    if (is_linux) {
        const flags = std.os.linux.MSG.DONTWAIT | std.os.linux.MSG.NOSIGNAL;
        const rc = std.os.linux.sendto(fd, data.ptr, data.len, flags, addr_ptr, addr_len);
        if (std.os.linux.errno(rc) == .SUCCESS and rc > 0) return rc;
        return 0;
    } else {
        const rc = std.c.sendto(fd, data.ptr, data.len, MSG_DONTWAIT_MACOS, addr_ptr, addr_len);
        if (rc > 0) return @intCast(rc);
        return 0;
    }
}

pub const RecvResult = union(enum) {
    data: usize,
    eof,
    again,
    err,
};

pub fn recvNonBlock(fd: fd_t, buf: []u8) RecvResult {
    if (is_linux) {
        const rc = std.os.linux.recvfrom(fd, buf.ptr, buf.len, std.os.linux.MSG.DONTWAIT, null, null);
        const e = std.os.linux.errno(rc);
        if (e == .SUCCESS) {
            if (rc == 0) return .eof;
            return .{ .data = rc };
        }
        if (e == .AGAIN or e == .INPROGRESS) return .again;
        return .err;
    } else {
        const rc = std.c.recvfrom(fd, buf.ptr, buf.len, MSG_DONTWAIT_MACOS, null, null);
        if (rc > 0) return .{ .data = @intCast(rc) };
        if (rc == 0) return .eof;
        const e = std.c._errno().*;
        if (e == @intFromEnum(std.c.E.AGAIN) or e == @intFromEnum(std.c.E.INPROGRESS)) return .again;
        return .err;
    }
}

pub fn shutdownWrite(fd: fd_t) void {
    if (is_linux) {
        _ = std.os.linux.shutdown(fd, std.os.linux.SHUT.WR);
    } else {
        _ = std.c.shutdown(fd, 1); // SHUT_WR = 1
    }
}

pub fn pollFds(fds: []pollfd, timeout_ms: i32) usize {
    if (fds.len == 0) return 0;
    if (is_linux) {
        const rc = std.os.linux.poll(fds.ptr, @intCast(fds.len), timeout_ms);
        if (std.os.linux.errno(rc) == .SUCCESS and rc > 0) return rc;
        return 0;
    } else {
        const rc = std.c.poll(fds.ptr, @intCast(fds.len), timeout_ms);
        if (rc > 0) return @intCast(rc);
        return 0;
    }
}
