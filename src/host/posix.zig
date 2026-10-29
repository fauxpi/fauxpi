//! Cross-platform host POSIX / Win32, clock, random, futex, and non-blocking socket helpers
//! supporting Linux, macOS (`darwin`), and Windows.

const std = @import("std");
const builtin = @import("builtin");

pub const is_linux = builtin.os.tag == .linux;
pub const is_macos = builtin.os.tag == .macos;
pub const is_windows = builtin.os.tag == .windows;

pub const fd_t = if (is_windows) c_int else std.c.fd_t;
pub const pid_t = if (is_windows) c_int else std.c.pid_t;
pub const pollfd = if (is_windows) extern struct {
    fd: fd_t,
    events: i16,
    revents: i16,
} else std.c.pollfd;

pub const sockaddr = if (is_windows) extern struct {
    family: u16,
    data: [14]u8,
    pub const in = extern struct {
        family: u16 = 2, // AF_INET
        port: u16,
        addr: u32,
        zero: [8]u8 = @splat(0),
    };
} else std.c.sockaddr;

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

// Windows CRT & Win32 declarations
const O_RDONLY_WIN: c_int = 0x0000;
const O_WRONLY_WIN: c_int = 0x0001;
const O_RDWR_WIN: c_int = 0x0002;
const O_TEMPORARY_WIN: c_int = 0x0040;
const O_NOINHERIT_WIN: c_int = 0x0080;
const O_CREAT_WIN: c_int = 0x0100;
const O_TRUNC_WIN: c_int = 0x0200;
const O_EXCL_WIN: c_int = 0x0400;
const O_BINARY_WIN: c_int = 0x8000;
const S_IREAD_IWRITE_WIN: c_int = 0x0180;

const OVERLAPPED_WIN = extern struct {
    Internal: usize = 0,
    InternalHigh: usize = 0,
    Offset: u32 = 0,
    OffsetHigh: u32 = 0,
    hEvent: ?*anyopaque = null,
};

const WIN32_FIND_DATAA = extern struct {
    dwFileAttributes: u32,
    ftCreationTime: [2]u32,
    ftLastAccessTime: [2]u32,
    ftLastWriteTime: [2]u32,
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
    dwReserved0: u32,
    dwReserved1: u32,
    cFileName: [260]u8,
    cAlternateFileName: [14]u8,
};

extern "c" fn _open(path: [*:0]const u8, oflag: c_int, pmode: c_int) c_int;
extern "c" fn _close(fd: c_int) c_int;
extern "c" fn _read(fd: c_int, buf: [*]u8, count: c_uint) c_int;
extern "c" fn _write(fd: c_int, buf: [*]const u8, count: c_uint) c_int;
extern "c" fn _lseeki64(fd: c_int, offset: i64, origin: c_int) i64;
extern "c" fn _chsize_s(fd: c_int, size: i64) c_int;
extern "c" fn _unlink(path: [*:0]const u8) c_int;
extern "c" fn _rmdir(path: [*:0]const u8) c_int;
extern "c" fn _mkdir(path: [*:0]const u8) c_int;
extern "c" fn _access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn _get_osfhandle(fd: c_int) isize;
extern "c" fn rename(old_path: [*:0]const u8, new_path: [*:0]const u8) c_int;

extern "kernel32" fn ReadFile(
    hFile: isize,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: u32,
    lpNumberOfBytesRead: *u32,
    lpOverlapped: ?*OVERLAPPED_WIN,
) i32;
extern "kernel32" fn WriteFile(
    hFile: isize,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: u32,
    lpNumberOfBytesWritten: *u32,
    lpOverlapped: ?*OVERLAPPED_WIN,
) i32;
extern "kernel32" fn GetTempPathA(nBufferLength: u32, lpBuffer: [*]u8) u32;
extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) i32;
extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) i32;
extern "kernel32" fn GetSystemTimeAsFileTime(lpSystemTimeAsFileTime: *u64) void;
extern "kernel32" fn GetEnvironmentVariableA(lpName: [*:0]const u8, lpBuffer: [*]u8, nSize: u32) u32;
extern "kernel32" fn FindFirstFileA(lpFileName: [*:0]const u8, lpFindFileData: *WIN32_FIND_DATAA) isize;
extern "kernel32" fn FindNextFileA(hFindFile: isize, lpFindFileData: *WIN32_FIND_DATAA) i32;
extern "kernel32" fn FindClose(hFindFile: isize) i32;
extern "kernel32" fn Sleep(dwMilliseconds: u32) void;
extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) ?*anyopaque;
extern "kernel32" fn GetProcAddress(hModule: *anyopaque, lpProcName: [*:0]const u8) ?*const anyopaque;
extern "kernel32" fn FreeLibrary(hLibModule: *anyopaque) i32;

pub const DynLib = if (is_windows) struct {
    handle: *anyopaque,

    pub fn open(path: []const u8) !DynLib {
        var buf: [512]u8 = undefined;
        if (path.len >= buf.len) return error.NameTooLong;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        const h = LoadLibraryA(buf[0..path.len :0]) orelse return error.FileNotFound;
        return .{ .handle = h };
    }

    pub fn close(self: *DynLib) void {
        _ = FreeLibrary(self.handle);
    }

    pub fn lookup(self: *DynLib, comptime T: type, name: [:0]const u8) ?T {
        const sym = GetProcAddress(self.handle, name.ptr) orelse return null;
        return @ptrCast(@alignCast(sym));
    }
} else std.DynLib;

pub fn close(fd: fd_t) void {
    if (fd < 0) return;
    if (is_linux) {
        _ = std.os.linux.close(fd);
    } else if (is_windows) {
        if (fd >= WIN_SOCK_FD_BASE) {
            closeWinSocket(fd);
        } else {
            _ = _close(fd);
        }
    } else {
        _ = std.c.close(fd);
    }
}

pub fn writeStdout(bytes: []const u8) void {
    if (bytes.len == 0) return;
    if (is_linux) {
        _ = std.os.linux.write(STDOUT_FILENO, bytes.ptr, bytes.len);
    } else if (is_windows) {
        _ = _write(STDOUT_FILENO, bytes.ptr, @intCast(@min(bytes.len, std.math.maxInt(c_uint))));
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
    } else if (is_windows) {
        const rc = _open(path_z[0..path.len :0], O_RDONLY_WIN | O_BINARY_WIN | O_NOINHERIT_WIN, 0);
        if (rc < 0) return error.FileOpenFailed;
        return rc;
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
    } else if (is_windows) {
        const rc = _open(path_z[0..path.len :0], O_RDWR_WIN | O_BINARY_WIN | O_NOINHERIT_WIN, 0);
        if (rc < 0) return error.FileOpenFailed;
        return rc;
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
    } else if (is_windows) {
        const acc: c_int = if (read_write) O_RDWR_WIN else O_WRONLY_WIN;
        const flags: c_int = acc | O_CREAT_WIN | O_TRUNC_WIN | O_BINARY_WIN | O_NOINHERIT_WIN;
        const rc = _open(path_z[0..path.len :0], flags, S_IREAD_IWRITE_WIN);
        if (rc < 0) return error.FileOpenFailed;
        return rc;
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
        const tmp_dirs = [_][:0]const u8{ "/tmp", "/var/tmp" };
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
    } else if (is_windows) {
        var tmp_dir: [260]u8 = undefined;
        const tlen = GetTempPathA(tmp_dir.len, &tmp_dir);
        const prefix = if (tlen > 0 and tlen < tmp_dir.len) tmp_dir[0..tlen] else ".\\";
        var rnd: [8]u8 = undefined;
        getRandomBytes(&rnd);
        var path_buf: [320]u8 = undefined;
        const path = std.fmt.bufPrint(
            &path_buf,
            "{s}fauxpi-sdcard-{x}.qcow2\x00",
            .{ prefix, std.mem.readInt(u64, &rnd, .little) },
        ) catch return error.FileOpenFailed;
        const path_z: [*:0]const u8 = @ptrCast(path.ptr);
        const flags: c_int = O_RDWR_WIN | O_CREAT_WIN | O_EXCL_WIN | O_TRUNC_WIN | O_TEMPORARY_WIN | O_BINARY_WIN | O_NOINHERIT_WIN;
        const fd = _open(path_z, flags, S_IREAD_IWRITE_WIN);
        if (fd < 0) return error.FileOpenFailed;
        return fd;
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
    } else if (is_windows) {
        const rc = _lseeki64(fd, 0, 2); // SEEK_END = 2
        if (rc < 0) return error.FileSeekFailed;
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
    } else if (is_windows) {
        _ = _lseeki64(fd, @intCast(offset), 0); // SEEK_SET = 0
    } else {
        _ = std.c.lseek(fd, @intCast(offset), 0); // SEEK_SET = 0
    }
}

pub fn ftruncate(fd: fd_t, length: u64) void {
    if (is_linux) {
        _ = std.os.linux.ftruncate(fd, @intCast(length));
    } else if (is_windows) {
        _ = _chsize_s(fd, @intCast(length));
    } else {
        _ = std.c.ftruncate(fd, @intCast(length));
    }
}

pub fn read(fd: fd_t, buf: []u8) !usize {
    if (is_linux) {
        const rc = std.os.linux.read(fd, buf.ptr, buf.len);
        if (std.os.linux.errno(rc) != .SUCCESS) return error.FileReadFailed;
        return rc;
    } else if (is_windows) {
        const chunk: c_uint = @intCast(@min(buf.len, 0x7fff_ffff));
        const rc = _read(fd, buf.ptr, chunk);
        if (rc < 0) return error.FileReadFailed;
        return @intCast(rc);
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
    } else if (is_windows) {
        const chunk: c_uint = @intCast(@min(buf.len, 0x7fff_ffff));
        const rc = _read(fd, buf.ptr, chunk);
        if (rc < 0) return .err;
        return .{ .bytes = @intCast(rc) };
    } else {
        const rc = std.c.read(fd, buf.ptr, buf.len);
        if (rc < 0) {
            const e = std.c._errno().*;
            if (e == @backingInt(std.c.E.AGAIN)) return .again;
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
        } else if (is_windows) {
            const chunk: c_uint = @intCast(@min(bytes.len - written, 0x7fff_ffff));
            const rc = _write(fd, bytes[written..].ptr, chunk);
            if (rc <= 0) return error.FileWriteFailed;
            written += @intCast(rc);
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
        } else if (is_windows) {
            const h = _get_osfhandle(fd);
            if (h == -1) return error.DiskReadFailed;
            const cur_off = offset + done;
            var ov: OVERLAPPED_WIN = .{
                .Offset = @truncate(cur_off),
                .OffsetHigh = @truncate(cur_off >> 32),
            };
            const to_read: u32 = @intCast(@min(buf.len - done, 0x7fff_ffff));
            var n_read: u32 = 0;
            const ok = ReadFile(h, buf[done..].ptr, to_read, &n_read, &ov);
            if (ok == 0 or n_read == 0) {
                @memset(buf[done..], 0);
                return;
            }
            done += n_read;
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
        } else if (is_windows) {
            const h = _get_osfhandle(fd);
            if (h == -1) return error.DiskWriteFailed;
            const cur_off = offset + done;
            var ov: OVERLAPPED_WIN = .{
                .Offset = @truncate(cur_off),
                .OffsetHigh = @truncate(cur_off >> 32),
            };
            const to_write: u32 = @intCast(@min(buf.len - done, 0x7fff_ffff));
            var n_written: u32 = 0;
            const ok = WriteFile(h, buf[done..].ptr, to_write, &n_written, &ov);
            if (ok == 0 or n_written == 0) return error.DiskWriteFailed;
            done += n_written;
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
    } else if (is_windows) {
        _ = _unlink(path_z[0..path.len :0]);
    } else {
        _ = std.c.unlink(path_z[0..path.len :0]);
    }
}

pub fn renameFile(old_path: []const u8, new_path: []const u8) bool {
    var old_z: [std.fs.max_path_bytes]u8 = undefined;
    var new_z: [std.fs.max_path_bytes]u8 = undefined;
    if (old_path.len == 0 or old_path.len >= old_z.len) return false;
    if (new_path.len == 0 or new_path.len >= new_z.len) return false;
    @memcpy(old_z[0..old_path.len], old_path);
    old_z[old_path.len] = 0;
    @memcpy(new_z[0..new_path.len], new_path);
    new_z[new_path.len] = 0;
    if (is_linux) {
        return std.os.linux.errno(std.os.linux.renameat(
            std.os.linux.AT.FDCWD,
            old_z[0..old_path.len :0],
            std.os.linux.AT.FDCWD,
            new_z[0..new_path.len :0],
        )) == .SUCCESS;
    } else {
        return rename(old_z[0..old_path.len :0], new_z[0..new_path.len :0]) == 0;
    }
}

pub fn removeDir(path: []const u8) void {
    var path_z: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= path_z.len) return;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    if (is_linux) {
        _ = std.os.linux.unlinkat(std.os.linux.AT.FDCWD, path_z[0..path.len :0], std.os.linux.AT.REMOVEDIR);
    } else if (is_windows) {
        _ = _rmdir(path_z[0..path.len :0]);
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
        if (i == path.len or buf[i] == '/' or (is_windows and buf[i] == '\\')) {
            // Skip Windows drive letter root like "C:"
            if (is_windows and i == 2 and buf[1] == ':') continue;
            const saved = if (i < path.len) buf[i] else 0;
            buf[i] = 0;
            if (is_linux) {
                _ = std.os.linux.mkdirat(std.os.linux.AT.FDCWD, buf[0..i :0], 0o755);
            } else if (is_windows) {
                _ = _mkdir(buf[0..i :0]);
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
    } else if (is_windows) {
        return _access(buf[0..path.len :0], 0) == 0;
    } else {
        return std.c.access(buf[0..path.len :0], 0) == 0;
    }
}

pub fn resolveAppDataDir(buf: []u8, environ: std.process.Environ) ?[]const u8 {
    if (is_windows) {
        var env_buf: [384]u8 = undefined;
        var n = GetEnvironmentVariableA("LOCALAPPDATA", &env_buf, env_buf.len);
        if (n == 0 or n >= env_buf.len) {
            n = GetEnvironmentVariableA("APPDATA", &env_buf, env_buf.len);
        }
        if (n > 0 and n < env_buf.len) {
            const trimmed = std.mem.trimEnd(u8, env_buf[0..n], "/\\");
            if (trimmed.len > 0) {
                return std.fmt.bufPrint(buf, "{s}/fauxpi", .{trimmed}) catch null;
            }
        }
        return null;
    } else {
        const Environ = std.process.Environ;
        if (Environ.getPosix(environ, "XDG_DATA_HOME")) |xdg| {
            const trimmed = std.mem.trimEnd(u8, xdg, "/");
            if (trimmed.len > 0) {
                return std.fmt.bufPrint(buf, "{s}/fauxpi", .{trimmed}) catch null;
            }
        }
        if (Environ.getPosix(environ, "HOME")) |home| {
            const trimmed = std.mem.trimEnd(u8, home, "/");
            if (trimmed.len > 0) {
                return std.fmt.bufPrint(buf, "{s}/.local/share/fauxpi", .{trimmed}) catch null;
            }
        }
        return null;
    }
}

pub fn forEachQcow2File(
    dir_path: []const u8,
    ctx: anytype,
    comptime callback: fn (@TypeOf(ctx), card_name: []const u8, full_path: []const u8) void,
) void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (dir_path.len >= path_buf.len) return;
    @memcpy(path_buf[0..dir_path.len], dir_path);
    path_buf[dir_path.len] = 0;

    if (is_linux) {
        const fd_rc = std.os.linux.openat(
            std.os.linux.AT.FDCWD,
            path_buf[0..dir_path.len :0],
            .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true },
            0,
        );
        if (std.os.linux.errno(fd_rc) != .SUCCESS) return;
        const dir_fd: std.os.linux.fd_t = @intCast(fd_rc);
        defer _ = std.os.linux.close(dir_fd);

        var dents_buf: [4096]u8 align(8) = undefined;
        while (true) {
            const n = std.os.linux.getdents64(dir_fd, &dents_buf, dents_buf.len);
            if (std.os.linux.errno(n) != .SUCCESS or n == 0) break;
            var at: usize = 0;
            while (at < n) {
                const reclen = std.mem.readInt(u16, dents_buf[at + 16 ..][0..2], .little);
                const d_name = std.mem.sliceTo(dents_buf[at + 19 .. at + reclen], 0);
                at += reclen;
                if (d_name.len <= ".qcow2".len or d_name[0] == '.') continue;
                if (!std.mem.endsWith(u8, d_name, ".qcow2")) continue;

                const card_name = d_name[0 .. d_name.len - ".qcow2".len];
                var full_buf: [std.fs.max_path_bytes]u8 = undefined;
                const full_path = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ dir_path, d_name }) catch continue;
                callback(ctx, card_name, full_path);
            }
        }
    } else if (is_windows) {
        var pattern_buf: [std.fs.max_path_bytes]u8 = undefined;
        const pat = std.fmt.bufPrint(&pattern_buf, "{s}\\*.qcow2\x00", .{dir_path}) catch return;
        var find_data: WIN32_FIND_DATAA = undefined;
        const h_find = FindFirstFileA(@ptrCast(pat.ptr), &find_data);
        if (h_find == -1) return;
        defer _ = FindClose(h_find);

        while (true) {
            const d_name = std.mem.sliceTo(&find_data.cFileName, 0);
            if (d_name.len > ".qcow2".len and d_name[0] != '.' and std.mem.endsWith(u8, d_name, ".qcow2")) {
                const card_name = d_name[0 .. d_name.len - ".qcow2".len];
                var full_buf: [std.fs.max_path_bytes]u8 = undefined;
                const full_path = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ dir_path, d_name }) catch "";
                if (full_path.len > 0) {
                    callback(ctx, card_name, full_path);
                }
            }
            if (FindNextFileA(h_find, &find_data) == 0) break;
        }
    } else {
        const dir_ptr = std.c.opendir(path_buf[0..dir_path.len :0]) orelse return;
        defer _ = std.c.closedir(dir_ptr);
        while (std.c.readdir(dir_ptr)) |ent| {
            const d_name = std.mem.sliceTo(&ent.name, 0);
            if (d_name.len <= ".qcow2".len or d_name[0] == '.') continue;
            if (!std.mem.endsWith(u8, d_name, ".qcow2")) continue;

            const card_name = d_name[0 .. d_name.len - ".qcow2".len];
            var full_buf: [std.fs.max_path_bytes]u8 = undefined;
            const full_path = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ dir_path, d_name }) catch continue;
            callback(ctx, card_name, full_path);
        }
    }
}

pub fn pipeNonBlockCloexec(fds: *[2]fd_t) bool {
    if (is_linux) {
        return std.os.linux.errno(std.os.linux.pipe2(fds, .{ .CLOEXEC = true, .NONBLOCK = true })) == .SUCCESS;
    } else if (is_windows) {
        return false;
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
    } else if (is_windows) {
        return null;
    } else {
        const rc = std.c.fork();
        if (rc < 0) return null;
        return rc;
    }
}

pub fn dup2Stdout(fd: fd_t) void {
    if (is_linux) {
        _ = std.os.linux.dup2(fd, STDOUT_FILENO);
    } else if (!is_windows) {
        _ = std.c.dup2(fd, STDOUT_FILENO);
    }
}

pub fn waitpidBlocking(pid: pid_t) void {
    if (pid <= 0) return;
    if (is_linux) {
        var wstatus: i32 = 0;
        _ = std.os.linux.waitpid(pid, &wstatus, 0);
    } else if (!is_windows) {
        var wstatus: c_int = 0;
        _ = std.c.waitpid(pid, &wstatus, 0);
    }
}

var qpc_freq: u64 = 0;

pub fn monotonicNs() u64 {
    if (is_linux) {
        var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        const sec: u64 = if (ts.sec > 0) @intCast(ts.sec) else 0;
        const nsec: u64 = if (ts.nsec > 0) @intCast(ts.nsec) else 0;
        return sec * std.time.ns_per_s + nsec;
    } else if (is_windows) {
        if (qpc_freq == 0) {
            var f: i64 = 0;
            _ = QueryPerformanceFrequency(&f);
            qpc_freq = if (f > 0) @intCast(f) else 10_000_000;
        }
        var c: i64 = 0;
        _ = QueryPerformanceCounter(&c);
        const count: u64 = if (c > 0) @intCast(c) else 0;
        return @intCast((@as(u128, count) * std.time.ns_per_s) / @as(u128, qpc_freq));
    } else {
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
        const sec: u64 = if (ts.sec > 0) @intCast(ts.sec) else 0;
        const nsec: u64 = if (ts.nsec > 0) @intCast(ts.nsec) else 0;
        return sec * std.time.ns_per_s + nsec;
    }
}

/// Sleeps the calling thread for about `us` microseconds (millisecond granularity on Windows).
pub fn sleepUs(us: u64) void {
    if (us == 0) return;
    if (is_linux) {
        var ts: std.os.linux.timespec = .{ .sec = @intCast(us / 1_000_000), .nsec = @intCast((us % 1_000_000) * 1000) };
        _ = std.os.linux.nanosleep(&ts, null);
    } else if (is_windows) {
        Sleep(@intCast(@min((us + 999) / 1000, std.math.maxInt(u32))));
    } else {
        var ts: std.c.timespec = .{ .sec = @intCast(us / 1_000_000), .nsec = @intCast((us % 1_000_000) * 1000) };
        _ = std.c.nanosleep(&ts, null);
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
    } else if (is_windows) {
        var ft: u64 = 0;
        GetSystemTimeAsFileTime(&ft);
        // Windows FILETIME is 100-ns intervals since 1601-01-01; Unix epoch is +11644473600s
        const EPOCH_DIFF_100NS: u64 = 116_444_736_000_000_000;
        const unix_100ns = ft -| EPOCH_DIFF_100NS;
        return .{
            .sec = unix_100ns / 10_000_000,
            .nsec = (unix_100ns % 10_000_000) * 100,
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

/// When set, `getRandomBytes` returns a fixed pseudo-random sequence, so that guest-visible
/// randomness (such as the device-tree `rng-seed`) is reproducible (`--clock instructions`).
pub var deterministic_random: bool = false;
var deterministic_random_state: u64 = 0x9E3779B97F4A7C15;

pub fn getRandomBytes(buf: []u8) void {
    if (buf.len == 0) return;
    if (deterministic_random) {
        for (buf) |*b| {
            deterministic_random_state +%= 0x9E3779B97F4A7C15;
            var z = deterministic_random_state;
            z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
            z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
            b.* = @truncate(z ^ (z >> 31));
        }
    } else if (is_linux) {
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    } else if (is_windows) {
        var seed: u64 = monotonicNs() ^ realtimeSecNsec().nsec ^ 0x9E3779B97F4A7C15;
        for (buf) |*b| {
            seed +%= 0x9E3779B97F4A7C15;
            var z = seed;
            z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
            z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
            z = z ^ (z >> 31);
            b.* = @truncate(z);
        }
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}

const UL_COMPARE_AND_WAIT_MACOS: u32 = 1 | 0x01000000; // UL_COMPARE_AND_WAIT | ULF_NO_ERRNO
extern "c" fn __ulock_wake(operation: u32, addr: *const anyopaque, wake_value: u64) c_int;
extern "c" fn __ulock_wait(operation: u32, addr: *const anyopaque, value: u64, timeout: u32) c_int;

const WinSynchApi = struct {
    wait_on_addr: ?*const fn (
        Address: *const volatile anyopaque,
        CompareAddress: *const anyopaque,
        AddressSize: usize,
        dwMilliseconds: u32,
    ) callconv(.c) i32 = null,
    wake_single: ?*const fn (Address: *const anyopaque) callconv(.c) void = null,
};

var win_synch_loaded: bool = false;
var win_synch: WinSynchApi = .{};

fn getWinSynch() *const WinSynchApi {
    if (!win_synch_loaded) {
        win_synch_loaded = true;
        var lib_opt: ?DynLib = DynLib.open("api-ms-win-core-synch-l1-2-0.dll") catch (DynLib.open("kernelbase.dll") catch null);
        if (lib_opt) |*lib| {
            win_synch.wait_on_addr = lib.lookup(
                *const fn (*const volatile anyopaque, *const anyopaque, usize, u32) callconv(.c) i32,
                "WaitOnAddress",
            );
            win_synch.wake_single = lib.lookup(
                *const fn (*const anyopaque) callconv(.c) void,
                "WakeByAddressSingle",
            );
        }
    }
    return &win_synch;
}

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
    } else if (is_windows) {
        if (getWinSynch().wake_single) |wake_fn| {
            wake_fn(ptr);
        }
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
    } else if (is_windows) {
        if (getWinSynch().wait_on_addr) |wait_fn| {
            var exp = expected;
            _ = wait_fn(ptr, &exp, @sizeOf(u32), 50);
        } else {
            Sleep(1);
        }
    }
}

// Winsock2 dynamic table for non-blocking sockets on Windows
const WIN_SOCK_FD_BASE: fd_t = 0x10000;
const INVALID_SOCKET_WIN: usize = std.math.maxInt(usize);
const FIONBIO_WIN: c_long = @bitCast(@as(c_ulong, 0x8004667E));
const WSAEWOULDBLOCK_WIN: c_int = 10035;
const WSAEINPROGRESS_WIN: c_int = 10036;
const POLLRDNORM_WIN: i16 = 0x0100;
const POLLWRNORM_WIN: i16 = 0x0010;
const POLLERR_WIN: i16 = 0x0001;
const POLLHUP_WIN: i16 = 0x0002;

const WSAPOLLFD_WIN = extern struct {
    fd: usize,
    events: i16,
    revents: i16,
};

const WinsockApi = struct {
    socket: *const fn (af: c_int, stype: c_int, protocol: c_int) callconv(.c) usize,
    closesocket: *const fn (s: usize) callconv(.c) c_int,
    ioctlsocket: *const fn (s: usize, cmd: c_long, argp: *c_ulong) callconv(.c) c_int,
    connect: *const fn (s: usize, name: *const sockaddr, namelen: c_int) callconv(.c) c_int,
    sendto: *const fn (s: usize, buf: [*]const u8, len: c_int, flags: c_int, to: ?*const sockaddr, tolen: c_int) callconv(.c) c_int,
    recvfrom: *const fn (s: usize, buf: [*]u8, len: c_int, flags: c_int, from: ?*sockaddr, fromlen: ?*c_int) callconv(.c) c_int,
    shutdown: *const fn (s: usize, how: c_int) callconv(.c) c_int,
    WSAGetLastError: *const fn () callconv(.c) c_int,
    WSAPoll: *const fn (fdArray: [*]WSAPOLLFD_WIN, fds: c_ulong, timeout: c_int) callconv(.c) c_int,
};

var winsock_init_attempted: bool = false;
var winsock_api: ?WinsockApi = null;
var win_sock_table: [64]usize = @splat(INVALID_SOCKET_WIN);

fn ensureWinsock() ?*const WinsockApi {
    if (winsock_init_attempted) return if (winsock_api) |*a| a else null;
    winsock_init_attempted = true;

    var lib = DynLib.open("ws2_32.dll") catch return null;
    const WSAStartup = lib.lookup(*const fn (u16, [*]u8) callconv(.c) c_int, "WSAStartup") orelse return null;
    var wsa_data: [512]u8 align(8) = @splat(0);
    if (WSAStartup(0x0202, &wsa_data) != 0) return null;

    winsock_api = .{
        .socket = lib.lookup(*const fn (c_int, c_int, c_int) callconv(.c) usize, "socket") orelse return null,
        .closesocket = lib.lookup(*const fn (usize) callconv(.c) c_int, "closesocket") orelse return null,
        .ioctlsocket = lib.lookup(*const fn (usize, c_long, *c_ulong) callconv(.c) c_int, "ioctlsocket") orelse return null,
        .connect = lib.lookup(*const fn (usize, *const sockaddr, c_int) callconv(.c) c_int, "connect") orelse return null,
        .sendto = lib.lookup(*const fn (usize, [*]const u8, c_int, c_int, ?*const sockaddr, c_int) callconv(.c) c_int, "sendto") orelse return null,
        .recvfrom = lib.lookup(*const fn (usize, [*]u8, c_int, c_int, ?*sockaddr, ?*c_int) callconv(.c) c_int, "recvfrom") orelse return null,
        .shutdown = lib.lookup(*const fn (usize, c_int) callconv(.c) c_int, "shutdown") orelse return null,
        .WSAGetLastError = lib.lookup(*const fn () callconv(.c) c_int, "WSAGetLastError") orelse return null,
        .WSAPoll = lib.lookup(*const fn ([*]WSAPOLLFD_WIN, c_ulong, c_int) callconv(.c) c_int, "WSAPoll") orelse return null,
    };
    return &winsock_api.?;
}

fn allocWinSockFd(s: usize) ?fd_t {
    for (&win_sock_table, 0..) |*slot, i| {
        if (slot.* == INVALID_SOCKET_WIN) {
            slot.* = s;
            return WIN_SOCK_FD_BASE + @as(fd_t, @intCast(i));
        }
    }
    return null;
}

fn lookupWinSock(fd: fd_t) ?usize {
    if (fd < WIN_SOCK_FD_BASE) return null;
    const idx: usize = @intCast(fd - WIN_SOCK_FD_BASE);
    if (idx >= win_sock_table.len) return null;
    const s = win_sock_table[idx];
    return if (s != INVALID_SOCKET_WIN) s else null;
}

fn closeWinSocket(fd: fd_t) void {
    if (fd < WIN_SOCK_FD_BASE) return;
    const idx: usize = @intCast(fd - WIN_SOCK_FD_BASE);
    if (idx >= win_sock_table.len) return;
    const s = win_sock_table[idx];
    win_sock_table[idx] = INVALID_SOCKET_WIN;
    if (s != INVALID_SOCKET_WIN) {
        if (ensureWinsock()) |wsa| {
            _ = wsa.closesocket(s);
        }
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
    } else if (is_windows) {
        const wsa = ensureWinsock() orelse return error.SocketFailed;
        const stype: c_int = if (is_tcp) 1 else 2; // SOCK_STREAM = 1, SOCK_DGRAM = 2
        const s = wsa.socket(2, stype, 0); // AF_INET = 2
        if (s == INVALID_SOCKET_WIN) return error.SocketFailed;
        var nonblock: c_ulong = 1;
        _ = wsa.ioctlsocket(s, FIONBIO_WIN, &nonblock);
        return allocWinSockFd(s) orelse {
            _ = wsa.closesocket(s);
            return error.SocketFailed;
        };
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
    } else if (is_windows) {
        const wsa = ensureWinsock() orelse return .failed;
        const s = lookupWinSock(fd) orelse return .failed;
        const rc = wsa.connect(s, @ptrCast(&addr), @sizeOf(sockaddr.in));
        if (rc == 0) return .connected_or_in_progress;
        const e = wsa.WSAGetLastError();
        if (e == WSAEWOULDBLOCK_WIN or e == WSAEINPROGRESS_WIN) return .connected_or_in_progress;
        return .failed;
    } else {
        const rc = std.c.connect(fd, @ptrCast(&addr), @sizeOf(sockaddr.in));
        if (rc == 0) return .connected_or_in_progress;
        const e = std.c._errno().*;
        if (e == @backingInt(std.c.E.INPROGRESS) or e == @backingInt(std.c.E.AGAIN)) {
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
    } else if (is_windows) {
        const wsa = ensureWinsock() orelse return 0;
        const s = lookupWinSock(fd) orelse return 0;
        const rc = wsa.sendto(s, data.ptr, @intCast(data.len), 0, addr_ptr, @intCast(addr_len));
        if (rc > 0) return @intCast(rc);
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
    } else if (is_windows) {
        const wsa = ensureWinsock() orelse return .err;
        const s = lookupWinSock(fd) orelse return .err;
        const rc = wsa.recvfrom(s, buf.ptr, @intCast(buf.len), 0, null, null);
        if (rc > 0) return .{ .data = @intCast(rc) };
        if (rc == 0) return .eof;
        const e = wsa.WSAGetLastError();
        if (e == WSAEWOULDBLOCK_WIN or e == WSAEINPROGRESS_WIN) return .again;
        return .err;
    } else {
        const rc = std.c.recvfrom(fd, buf.ptr, buf.len, MSG_DONTWAIT_MACOS, null, null);
        if (rc > 0) return .{ .data = @intCast(rc) };
        if (rc == 0) return .eof;
        const e = std.c._errno().*;
        if (e == @backingInt(std.c.E.AGAIN) or e == @backingInt(std.c.E.INPROGRESS)) return .again;
        return .err;
    }
}

pub fn shutdownWrite(fd: fd_t) void {
    if (is_linux) {
        _ = std.os.linux.shutdown(fd, std.os.linux.SHUT.WR);
    } else if (is_windows) {
        if (ensureWinsock()) |wsa| {
            if (lookupWinSock(fd)) |s| {
                _ = wsa.shutdown(s, 1); // SD_SEND = 1
            }
        }
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
    } else if (is_windows) {
        const wsa = ensureWinsock() orelse return 0;
        var wsa_fds: [64]WSAPOLLFD_WIN = undefined;
        const count = @min(fds.len, wsa_fds.len);
        for (0..count) |i| {
            const s = lookupWinSock(fds[i].fd) orelse INVALID_SOCKET_WIN;
            var ev: i16 = 0;
            if ((fds[i].events & POLL.IN) != 0) ev |= POLLRDNORM_WIN;
            if ((fds[i].events & POLL.OUT) != 0) ev |= POLLWRNORM_WIN;
            wsa_fds[i] = .{ .fd = s, .events = ev, .revents = 0 };
            fds[i].revents = 0;
        }
        const rc = wsa.WSAPoll(&wsa_fds, @intCast(count), timeout_ms);
        if (rc <= 0) return 0;
        for (0..count) |i| {
            var rev: i16 = 0;
            if ((wsa_fds[i].revents & (POLLRDNORM_WIN | POLLHUP_WIN | POLLERR_WIN)) != 0) rev |= POLL.IN;
            if ((wsa_fds[i].revents & POLLWRNORM_WIN) != 0) rev |= POLL.OUT;
            fds[i].revents = rev;
        }
        return @intCast(rc);
    } else {
        const rc = std.c.poll(fds.ptr, @intCast(fds.len), timeout_ms);
        if (rc > 0) return @intCast(rc);
        return 0;
    }
}
