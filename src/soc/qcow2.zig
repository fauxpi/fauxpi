//! QCOW2 v3 (`QFI\xfb`) sparse virtual disk image implementation for SD cards.
//!
//! Uses 64 KiB clusters (`cluster_bits = 16`) allocated on demand so that large
//! SD cards (1 GB, 4 GB, 16 GB, 32 GB, etc.) consume minimal space on disk and
//! in memory, storing only non-zero 64 KiB clusters.

const std = @import("std");
const host_posix = @import("../host/posix.zig");

pub const QCOW2_MAGIC: u32 = 0x514649fb; // "QFI\xfb"
pub const QCOW2_VERSION: u32 = 3;
pub const CLUSTER_BITS: u5 = 16;
pub const CLUSTER_SIZE: usize = @as(usize, 1) << CLUSTER_BITS; // 65536 bytes (64 KiB)
pub const CLUSTER_MASK: u64 = CLUSTER_SIZE - 1;
pub const L2_BITS: u5 = CLUSTER_BITS - 3; // 13 bits = 8192 entries per L2 table
pub const L2_ENTRIES: usize = @as(usize, 1) << L2_BITS; // 8192 entries (512 MiB per L2 table)
pub const L2_MASK: u64 = L2_ENTRIES - 1;
pub const OFLAG_COPIED: u64 = @as(u64, 1) << 63;
pub const OFFSET_MASK: u64 = 0x00ff_ffff_ffff_fe00;

/// Standard SD / SDHC card capacities selectable when creating a virtual SD card.
pub const SdCardSize = enum(u8) {
    mb_256,
    mb_512,
    gb_1,
    gb_2,
    gb_4,
    gb_8,
    gb_16,
    gb_32,

    pub const all = [_]SdCardSize{
        .mb_256,
        .mb_512,
        .gb_1,
        .gb_2,
        .gb_4,
        .gb_8,
        .gb_16,
        .gb_32,
    };

    pub fn bytes(self: SdCardSize) u64 {
        return switch (self) {
            .mb_256 => 256 * 1024 * 1024,
            .mb_512 => 512 * 1024 * 1024,
            .gb_1 => 1 * 1024 * 1024 * 1024,
            .gb_2 => 2 * 1024 * 1024 * 1024,
            .gb_4 => 4 * 1024 * 1024 * 1024,
            .gb_8 => 8 * 1024 * 1024 * 1024,
            .gb_16 => 16 * 1024 * 1024 * 1024,
            .gb_32 => 32 * 1024 * 1024 * 1024,
        };
    }

    pub fn label(self: SdCardSize) []const u8 {
        return switch (self) {
            .mb_256 => "256 MB",
            .mb_512 => "512 MB",
            .gb_1 => "1 GB",
            .gb_2 => "2 GB",
            .gb_4 => "4 GB",
            .gb_8 => "8 GB",
            .gb_16 => "16 GB",
            .gb_32 => "32 GB",
        };
    }

    pub fn smallestFitting(image_len: u64) ?SdCardSize {
        for (all) |sz| {
            if (image_len <= sz.bytes()) return sz;
        }
        return null;
    }
};

pub const Qcow2Disk = struct {
    allocator: std.mem.Allocator,
    fd: host_posix.fd_t,
    virtual_size: u64,
    next_cluster: u64 = 4,
    allocated_data_clusters: u64 = 0,

    // In-memory L1 table (each entry holds host byte offset of L2 cluster, or 0)
    l1_table: []u64,

    // Cached L2 table
    cached_l1_idx: usize = std.math.maxInt(usize),
    l2_cache: [L2_ENTRIES]u64 = @splat(0),
    l2_dirty: bool = false,

    // Cached 64 KiB data cluster for fast byte/word SDHost reads and writes
    cached_vcluster: u64 = std.math.maxInt(u64),
    cluster_cache: *[CLUSTER_SIZE]u8,
    cluster_dirty: bool = false,

    /// XZ stream header magic bytes (`\xFD7zXZ\x00`).
    pub const XZ_HEADER_MAGIC = [6]u8{ 0xFD, '7', 'z', 'X', 'Z', 0x00 };

    pub fn isXzMagic(bytes: []const u8) bool {
        return bytes.len >= 6 and std.mem.eql(u8, bytes[0..6], &XZ_HEADER_MAGIC);
    }

    pub fn isXzPath(path: []const u8) bool {
        return std.ascii.endsWithIgnoreCase(path, ".xz");
    }

    /// Returns the logical (uncompressed) byte size of an in-memory disk image slice.
    /// For XZ-compressed slices (`.img.xz`), parses the XZ Stream Footer and Index at the end of the slice.
    pub fn getSliceLogicalSize(data: []const u8) !u64 {
        if (isXzMagic(data)) {
            return try readXzUncompressedSizeFromSlice(data);
        }
        return data.len;
    }

    /// Creates a new QCOW2 v3 disk of `virtual_size` bytes and populates it with `initial_image`
    /// (raw `.img` bytes or XZ-compressed `.img.xz` bytes).
    /// Returns `error.ImageTooLarge` if the logical uncompressed size exceeds `virtual_size`.
    pub fn createFromSlice(
        allocator: std.mem.Allocator,
        virtual_size: u64,
        initial_image: []const u8,
    ) !Qcow2Disk {
        return createFromSliceAtPath(allocator, virtual_size, initial_image, null);
    }

    /// Creates a new QCOW2 v3 disk of `virtual_size` bytes backed by `backing_path` (or a temporary
    /// unlinked file if `backing_path` is null) and populates it with `initial_image` (raw or `.xz`).
    pub fn createFromSliceAtPath(
        allocator: std.mem.Allocator,
        virtual_size: u64,
        initial_image: []const u8,
        backing_path: ?[]const u8,
    ) !Qcow2Disk {
        const logical_size = try getSliceLogicalSize(initial_image);
        if (logical_size > virtual_size) return error.ImageTooLarge;

        var disk = try initEmptyAtPath(allocator, virtual_size, backing_path);
        errdefer {
            disk.deinit();
            if (backing_path) |bp| unlinkFileLinux(bp);
        }

        if (isXzMagic(initial_image)) {
            var reader: std.Io.Reader = .fixed(initial_image);
            try streamXzToQcow2(allocator, &reader, &disk);
        } else {
            var off: usize = 0;
            while (off < initial_image.len) : (off += CLUSTER_SIZE) {
                const rem = @min(CLUSTER_SIZE, initial_image.len - off);
                const chunk = initial_image[off .. off + rem];
                if (!isAllZero(chunk)) {
                    const vcluster: u64 = @intCast(off / CLUSTER_SIZE);
                    try disk.writeClusterSlice(vcluster, chunk);
                }
            }
        }
        try disk.flush();
        return disk;
    }

    /// Queries the logical (uncompressed) size in bytes of an image file on disk without decompressing it.
    /// For `.xz` / `.img.xz` files, reads the XZ Stream Footer and Index at the end of the file.
    pub fn getFileSizeLinux(path: []const u8) !u64 {
        const fd = try host_posix.openRead(path);
        defer host_posix.close(fd);
        const raw_size = try host_posix.lseekEnd(fd);
        if (raw_size >= 24) {
            var magic: [6]u8 = undefined;
            if (preadAll(fd, &magic, 0)) |_| {
                if (isXzMagic(&magic)) {
                    if (readXzUncompressedSizeFromFd(fd, raw_size)) |uncomp_size| {
                        return uncomp_size;
                    } else |_| {}
                }
            } else |_| {}
        }
        return raw_size;
    }

    /// Creates a new QCOW2 v3 disk of `virtual_size` bytes by streaming `image_path` (raw `.img` or
    /// XZ-compressed `.img.xz`) in 64 KiB clusters.
    /// Returns `error.ImageTooLarge` if the uncompressed image size of `image_path` exceeds `virtual_size`.
    pub fn createFromImageFile(
        allocator: std.mem.Allocator,
        virtual_size: u64,
        image_path: []const u8,
    ) !Qcow2Disk {
        return createFromImageFileAtPath(allocator, virtual_size, image_path, null);
    }

    /// Creates a new QCOW2 v3 disk of `virtual_size` bytes backed by `backing_path` (or a temporary
    /// unlinked file if `backing_path` is null) by streaming `image_path` (raw `.img` or `.img.xz`)
    /// in 64 KiB clusters.
    pub fn createFromImageFileAtPath(
        allocator: std.mem.Allocator,
        virtual_size: u64,
        image_path: []const u8,
        backing_path: ?[]const u8,
    ) !Qcow2Disk {
        return createFromImageFileAtPathWithProgress(allocator, virtual_size, image_path, backing_path, null);
    }

    /// Creates a new QCOW2 v3 disk of `virtual_size` bytes backed by `backing_path` by streaming
    /// `image_path` (raw `.img` or `.img.xz`) in 64 KiB clusters while updating `progress_bytes_opt`
    /// with the number of uncompressed image bytes processed so far.
    pub fn createFromImageFileAtPathWithProgress(
        allocator: std.mem.Allocator,
        virtual_size: u64,
        image_path: []const u8,
        backing_path: ?[]const u8,
        progress_bytes_opt: ?*std.atomic.Value(u64),
    ) !Qcow2Disk {
        const src_fd = try host_posix.openRead(image_path);
        defer host_posix.close(src_fd);

        const raw_file_size = try host_posix.lseekEnd(src_fd);
        var header_magic: [6]u8 = @splat(0);
        if (raw_file_size >= 6) {
            preadAll(src_fd, &header_magic, 0) catch {};
        }
        const is_xz = isXzMagic(&header_magic);

        if (is_xz) {
            const uncomp_size = try readXzUncompressedSizeFromFd(src_fd, raw_file_size);
            if (uncomp_size > virtual_size) return error.ImageTooLarge;
        } else {
            if (raw_file_size > virtual_size) return error.ImageTooLarge;
        }

        host_posix.lseekSet(src_fd, 0);

        var disk = try initEmptyAtPath(allocator, virtual_size, backing_path);
        errdefer {
            disk.deinit();
            if (backing_path) |bp| unlinkFileLinux(bp);
        }

        const io_buf = try allocator.alloc(u8, CLUSTER_SIZE);
        defer allocator.free(io_buf);

        if (is_xz) {
            var fd_reader = PosixFdReader.init(src_fd, io_buf);
            try streamXzToQcow2WithProgress(allocator, &fd_reader.reader, &disk, progress_bytes_opt);
        } else {
            var off: u64 = 0;
            while (off < raw_file_size) {
                const want: usize = @intCast(@min(@as(u64, CLUSTER_SIZE), raw_file_size - off));
                var got: usize = 0;
                while (got < want) {
                    const rc = try host_posix.read(src_fd, io_buf[got..want]);
                    if (rc == 0) break;
                    got += rc;
                }
                if (got == 0) break;
                if (!isAllZero(io_buf[0..got])) {
                    try disk.writeClusterSlice(off / CLUSTER_SIZE, io_buf[0..got]);
                }
                off += got;
                if (progress_bytes_opt) |p| p.store(off, .monotonic);
            }
        }

        try disk.flush();
        return disk;
    }

    pub fn initEmpty(allocator: std.mem.Allocator, virtual_size: u64) !Qcow2Disk {
        return initEmptyAtPath(allocator, virtual_size, null);
    }

    pub fn initEmptyAtPath(
        allocator: std.mem.Allocator,
        virtual_size: u64,
        backing_path: ?[]const u8,
    ) !Qcow2Disk {
        if (virtual_size == 0) return error.InvalidSize;
        const fd = if (backing_path) |bp| try createFileFd(bp) else try createBackingFd();
        errdefer {
            host_posix.close(fd);
            if (backing_path) |bp| unlinkFileLinux(bp);
        }

        const l2_span: u64 = @as(u64, L2_ENTRIES) * CLUSTER_SIZE; // 512 MiB
        const l1_count: usize = @intCast((virtual_size + l2_span - 1) / l2_span);
        const l1_table = try allocator.alloc(u64, l1_count);
        errdefer allocator.free(l1_table);
        @memset(l1_table, 0);

        const cluster_cache = try allocator.create([CLUSTER_SIZE]u8);
        errdefer allocator.destroy(cluster_cache);
        @memset(cluster_cache, 0);

        var disk: Qcow2Disk = .{
            .allocator = allocator,
            .fd = fd,
            .virtual_size = virtual_size,
            .l1_table = l1_table,
            .cluster_cache = cluster_cache,
        };
        try disk.writeInitialHeaders();
        return disk;
    }

    /// Opens an existing QCOW2 v3 image file from disk for read/write persistence.
    pub fn openExistingFile(allocator: std.mem.Allocator, backing_path: []const u8) !Qcow2Disk {
        const fd = try host_posix.openReadWrite(backing_path);
        errdefer host_posix.close(fd);

        var hdr: [104]u8 = undefined;
        try preadAll(fd, &hdr, 0);

        const magic = std.mem.readInt(u32, hdr[0..4], .big);
        if (magic != QCOW2_MAGIC) return error.InvalidQcow2Header;
        const version = std.mem.readInt(u32, hdr[4..8], .big);
        if (version != 2 and version != QCOW2_VERSION) return error.UnsupportedQcow2Version;
        const cluster_bits = std.mem.readInt(u32, hdr[20..24], .big);
        if (cluster_bits != CLUSTER_BITS) return error.UnsupportedClusterSize;

        const virtual_size = std.mem.readInt(u64, hdr[24..32], .big);
        if (virtual_size == 0) return error.InvalidSize;
        const hdr_l1_size = std.mem.readInt(u32, hdr[36..40], .big);
        const l1_table_offset = std.mem.readInt(u64, hdr[40..48], .big);

        const l2_span: u64 = @as(u64, L2_ENTRIES) * CLUSTER_SIZE; // 512 MiB
        const l1_count: usize = @intCast((virtual_size + l2_span - 1) / l2_span);
        const alloc_l1_count = @max(l1_count, @as(usize, hdr_l1_size));
        const l1_table = try allocator.alloc(u64, alloc_l1_count);
        errdefer allocator.free(l1_table);
        @memset(l1_table, 0);

        const read_l1_count: usize = @min(alloc_l1_count, @as(usize, hdr_l1_size));
        if (read_l1_count > 0 and l1_table_offset != 0) {
            const raw_l1 = std.mem.sliceAsBytes(l1_table[0..read_l1_count]);
            try preadAll(fd, raw_l1, l1_table_offset);
            for (l1_table[0..read_l1_count]) |*entry| {
                entry.* = std.mem.bigToNative(u64, entry.*);
            }
        }

        const cluster_cache = try allocator.create([CLUSTER_SIZE]u8);
        errdefer allocator.destroy(cluster_cache);
        @memset(cluster_cache, 0);

        const file_size: u64 = host_posix.lseekEnd(fd) catch (4 * CLUSTER_SIZE);
        var max_cluster: u64 = @max(4, (file_size + CLUSTER_SIZE - 1) / CLUSTER_SIZE);
        var data_clusters: u64 = 0;

        var disk: Qcow2Disk = .{
            .allocator = allocator,
            .fd = fd,
            .virtual_size = virtual_size,
            .next_cluster = max_cluster,
            .allocated_data_clusters = 0,
            .l1_table = l1_table,
            .cluster_cache = cluster_cache,
        };

        for (l1_table) |l1_entry| {
            const l2_off = l1_entry & OFFSET_MASK;
            if (l2_off == 0) continue;
            const l2_c = (l2_off / CLUSTER_SIZE) + 1;
            if (l2_c > max_cluster) max_cluster = l2_c;

            const raw_l2 = std.mem.sliceAsBytes(&disk.l2_cache);
            preadAll(fd, raw_l2, l2_off) catch continue;
            for (disk.l2_cache) |l2_be| {
                const d_off = std.mem.bigToNative(u64, l2_be) & OFFSET_MASK;
                if (d_off != 0) {
                    data_clusters += 1;
                    const d_c = (d_off / CLUSTER_SIZE) + 1;
                    if (d_c > max_cluster) max_cluster = d_c;
                }
            }
        }
        @memset(&disk.l2_cache, 0);
        disk.cached_l1_idx = std.math.maxInt(usize);
        disk.next_cluster = max_cluster;
        disk.allocated_data_clusters = data_clusters;
        return disk;
    }

    pub fn deinit(self: *Qcow2Disk) void {
        self.flush() catch {};
        if (self.fd >= 0) {
            host_posix.close(self.fd);
            self.fd = -1;
        }
        self.allocator.free(self.l1_table);
        self.allocator.destroy(self.cluster_cache);
    }

    /// Total bytes occupied on disk by the QCOW2 image (metadata + allocated non-zero 64 KiB clusters).
    pub fn diskAllocatedBytes(self: *const Qcow2Disk) u64 {
        return self.next_cluster * CLUSTER_SIZE;
    }

    pub fn readByte(self: *Qcow2Disk, offset: u64) u8 {
        if (offset >= self.virtual_size) return 0;
        const vcluster = offset >> CLUSTER_BITS;
        const in_cluster: usize = @intCast(offset & CLUSTER_MASK);
        self.loadClusterIntoCache(vcluster) catch return 0;
        return self.cluster_cache[in_cluster];
    }

    pub fn writeByte(self: *Qcow2Disk, offset: u64, b: u8) void {
        if (offset >= self.virtual_size) return;
        const vcluster = offset >> CLUSTER_BITS;
        const in_cluster: usize = @intCast(offset & CLUSTER_MASK);
        self.loadClusterIntoCache(vcluster) catch return;
        if (self.cluster_cache[in_cluster] != b) {
            self.cluster_cache[in_cluster] = b;
            self.cluster_dirty = true;
        }
    }

    /// Reads the boot prefix of the virtual SD card (covering the MBR and FAT16/FAT32 boot partition)
    /// into a slice so `loader.loadFromSdImage` can parse `config.txt`, `kernel.img`, and `.dtb`.
    pub fn readBootVolumeAlloc(self: *Qcow2Disk, allocator: std.mem.Allocator) ![]u8 {
        try self.flush();
        var sec0: [512]u8 = @splat(0);
        for (0..512) |i| sec0[i] = self.readByte(i);

        var needed_bytes: u64 = @min(self.virtual_size, 64 * 1024 * 1024);
        // Check MBR partition 1 extent so we read the entire FAT boot partition
        if (sec0[510] == 0x55 and sec0[511] == 0xaa) {
            for (0..4) |i| {
                const entry = sec0[446 + i * 16 ..][0..16];
                if (entry[4] != 0) {
                    const lba_start = std.mem.readInt(u32, entry[8..12], .little);
                    const lba_count = std.mem.readInt(u32, entry[12..16], .little);
                    const part_end = (@as(u64, lba_start) + @as(u64, lba_count)) * 512;
                    needed_bytes = @min(self.virtual_size, @max(needed_bytes, @min(part_end, 600 * 1024 * 1024)));
                    break;
                }
            }
        }

        const len: usize = @intCast(needed_bytes);
        const buf = try allocator.alloc(u8, len);
        errdefer allocator.free(buf);
        @memset(buf, 0);

        const num_clusters = (len + CLUSTER_SIZE - 1) / CLUSTER_SIZE;
        for (0..num_clusters) |vc| {
            const host_off = try self.lookupHostClusterOffset(@intCast(vc), false);
            if (host_off != 0) {
                const dst_off = vc * CLUSTER_SIZE;
                const copy_len = @min(CLUSTER_SIZE, len - dst_off);
                try preadAll(self.fd, buf[dst_off .. dst_off + copy_len], host_off);
            }
        }
        return buf;
    }

    pub fn flush(self: *Qcow2Disk) !void {
        if (self.cluster_dirty and self.cached_vcluster != std.math.maxInt(u64)) {
            const vcluster = self.cached_vcluster;
            self.cluster_dirty = false;
            const existing_off = try self.lookupHostClusterOffset(vcluster, false);
            if (existing_off != 0 or !isAllZero(self.cluster_cache)) {
                const host_off = if (existing_off != 0) existing_off else try self.lookupHostClusterOffset(vcluster, true);
                try pwriteAll(self.fd, self.cluster_cache, host_off);
            }
        }
        if (self.l2_dirty and self.cached_l1_idx < self.l1_table.len) {
            self.l2_dirty = false;
            const l2_host_off = self.l1_table[self.cached_l1_idx] & OFFSET_MASK;
            if (l2_host_off != 0) {
                try self.writeL2TableToDisk(l2_host_off);
            }
        }
    }

    fn writeClusterSlice(self: *Qcow2Disk, vcluster: u64, data: []const u8) !void {
        if (self.cached_vcluster == vcluster) {
            @memset(self.cluster_cache, 0);
            @memcpy(self.cluster_cache[0..data.len], data);
            self.cluster_dirty = true;
            return;
        }
        const host_off = try self.lookupHostClusterOffset(vcluster, true);
        if (data.len == CLUSTER_SIZE) {
            try pwriteAll(self.fd, data, host_off);
        } else {
            var tmp: [CLUSTER_SIZE]u8 = @splat(0);
            @memcpy(tmp[0..data.len], data);
            try pwriteAll(self.fd, &tmp, host_off);
        }
    }

    fn loadClusterIntoCache(self: *Qcow2Disk, vcluster: u64) !void {
        if (self.cached_vcluster == vcluster) return;
        try self.flush();

        const host_off = try self.lookupHostClusterOffset(vcluster, false);
        if (host_off == 0) {
            @memset(self.cluster_cache, 0);
        } else {
            try preadAll(self.fd, self.cluster_cache, host_off);
        }
        self.cached_vcluster = vcluster;
        self.cluster_dirty = false;
    }

    fn lookupHostClusterOffset(self: *Qcow2Disk, vcluster: u64, allocate: bool) !u64 {
        const l1_idx: usize = @intCast(vcluster >> L2_BITS);
        const l2_idx: usize = @intCast(vcluster & L2_MASK);
        if (l1_idx >= self.l1_table.len) return 0;

        try self.loadL2Table(l1_idx, allocate);
        if (self.l1_table[l1_idx] == 0) return 0;

        const l2_entry = self.l2_cache[l2_idx];
        var data_off = l2_entry & OFFSET_MASK;
        if (data_off == 0 and allocate) {
            data_off = self.allocCluster();
            self.allocated_data_clusters += 1;
            self.l2_cache[l2_idx] = OFLAG_COPIED | data_off;
            self.l2_dirty = true;
        }
        return data_off;
    }

    fn loadL2Table(self: *Qcow2Disk, l1_idx: usize, allocate: bool) !void {
        if (self.cached_l1_idx == l1_idx) {
            if (self.l1_table[l1_idx] == 0 and allocate) {
                const new_l2_off = self.allocCluster();
                self.l1_table[l1_idx] = OFLAG_COPIED | new_l2_off;
                @memset(&self.l2_cache, 0);
                try self.writeL1EntryToDisk(l1_idx);
                try self.writeL2TableToDisk(new_l2_off);
            }
            return;
        }

        if (self.l2_dirty and self.cached_l1_idx < self.l1_table.len) {
            self.l2_dirty = false;
            const old_l2_off = self.l1_table[self.cached_l1_idx] & OFFSET_MASK;
            if (old_l2_off != 0) {
                try self.writeL2TableToDisk(old_l2_off);
            }
        }

        self.cached_l1_idx = l1_idx;
        var l2_off = self.l1_table[l1_idx] & OFFSET_MASK;
        if (l2_off == 0) {
            @memset(&self.l2_cache, 0);
            if (allocate) {
                l2_off = self.allocCluster();
                self.l1_table[l1_idx] = OFLAG_COPIED | l2_off;
                try self.writeL1EntryToDisk(l1_idx);
                try self.writeL2TableToDisk(l2_off);
            }
            return;
        }

        const raw_bytes = std.mem.sliceAsBytes(&self.l2_cache);
        try preadAll(self.fd, raw_bytes, l2_off);
        for (&self.l2_cache) |*entry| {
            entry.* = std.mem.bigToNative(u64, entry.*);
        }
    }

    fn writeL1EntryToDisk(self: *Qcow2Disk, l1_idx: usize) !void {
        var be_val: [8]u8 = undefined;
        std.mem.writeInt(u64, &be_val, self.l1_table[l1_idx], .big);
        const l1_disk_off: u64 = 3 * CLUSTER_SIZE + @as(u64, l1_idx) * 8;
        try pwriteAll(self.fd, &be_val, l1_disk_off);
    }

    fn writeL2TableToDisk(self: *Qcow2Disk, l2_host_off: u64) !void {
        var be_table: [L2_ENTRIES]u64 = undefined;
        for (self.l2_cache, 0..) |v, i| {
            be_table[i] = std.mem.nativeToBig(u64, v);
        }
        try pwriteAll(self.fd, std.mem.sliceAsBytes(&be_table), l2_host_off);
    }

    fn allocCluster(self: *Qcow2Disk) u64 {
        const off = self.next_cluster * CLUSTER_SIZE;
        self.next_cluster += 1;
        return off;
    }

    fn writeInitialHeaders(self: *Qcow2Disk) !void {
        // Cluster 0: QCOW2 v3 header (104 bytes)
        var hdr: [104]u8 = @splat(0);
        std.mem.writeInt(u32, hdr[0..4], QCOW2_MAGIC, .big);
        std.mem.writeInt(u32, hdr[4..8], QCOW2_VERSION, .big);
        std.mem.writeInt(u64, hdr[8..16], 0, .big); // backing_file_offset
        std.mem.writeInt(u32, hdr[16..20], 0, .big); // backing_file_size
        std.mem.writeInt(u32, hdr[20..24], CLUSTER_BITS, .big);
        std.mem.writeInt(u64, hdr[24..32], self.virtual_size, .big);
        std.mem.writeInt(u32, hdr[32..36], 0, .big); // crypt_method
        std.mem.writeInt(u32, hdr[36..40], @intCast(self.l1_table.len), .big); // l1_size
        std.mem.writeInt(u64, hdr[40..48], 3 * CLUSTER_SIZE, .big); // l1_table_offset
        std.mem.writeInt(u64, hdr[48..56], 1 * CLUSTER_SIZE, .big); // refcount_table_offset
        std.mem.writeInt(u32, hdr[56..60], 1, .big); // refcount_table_clusters
        std.mem.writeInt(u32, hdr[60..64], 0, .big); // nb_snapshots
        std.mem.writeInt(u64, hdr[64..72], 0, .big); // snapshots_offset
        std.mem.writeInt(u64, hdr[72..80], 0, .big); // incompatible_features
        std.mem.writeInt(u64, hdr[80..88], 0, .big); // compatible_features
        std.mem.writeInt(u64, hdr[88..96], 0, .big); // autoclear_features
        std.mem.writeInt(u32, hdr[96..100], 4, .big); // refcount_order = 4 (16-bit refcounts)
        std.mem.writeInt(u32, hdr[100..104], 104, .big); // header_length = 104
        try pwriteAll(self.fd, &hdr, 0);

        // Cluster 1: Refcount table pointing to Cluster 2
        var ref_tbl_entry: [8]u8 = undefined;
        std.mem.writeInt(u64, &ref_tbl_entry, 2 * CLUSTER_SIZE, .big);
        try pwriteAll(self.fd, &ref_tbl_entry, 1 * CLUSTER_SIZE);

        // Cluster 2: Refcount block 0 (mark clusters 0..3 as refcount=1)
        var ref_blk: [8]u8 = undefined;
        for (0..4) |i| {
            std.mem.writeInt(u16, ref_blk[i * 2 ..][0..2], 1, .big);
        }
        try pwriteAll(self.fd, &ref_blk, 2 * CLUSTER_SIZE);

        // Ensure file size covers metadata clusters 0..3 (256 KiB)
        host_posix.ftruncate(self.fd, 4 * CLUSTER_SIZE);
    }
};

fn isAllZero(buf: []const u8) bool {
    for (buf) |b| {
        if (b != 0) return false;
    }
    return true;
}

fn createFileFd(path: []const u8) !host_posix.fd_t {
    return host_posix.openCreateTruncWrite(path, true);
}

pub fn unlinkFileLinux(path: []const u8) void {
    host_posix.unlinkFile(path);
}

fn createBackingFd() !host_posix.fd_t {
    return host_posix.createTempBackingFd();
}

fn preadAll(fd: host_posix.fd_t, buf: []u8, offset: u64) !void {
    return host_posix.preadAll(fd, buf, offset);
}

fn pwriteAll(fd: host_posix.fd_t, buf: []const u8, offset: u64) !void {
    return host_posix.pwriteAll(fd, buf, offset);
}

const PosixFdReader = struct {
    fd: host_posix.fd_t,
    reader: std.Io.Reader,

    pub fn init(fd: host_posix.fd_t, buffer: []u8) PosixFdReader {
        return .{
            .fd = fd,
            .reader = .{
                .vtable = &.{
                    .stream = stream,
                },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *PosixFdReader = @alignCast(@fieldParentPtr("reader", r));
        const avail = w.buffer[w.end..];
        const dest = limit.slice(avail);
        if (dest.len == 0) return 0;
        const n = host_posix.read(self.fd, dest) catch return error.ReadFailed;
        if (n == 0) return error.EndOfStream;
        w.end += n;
        return n;
    }
};

fn decodeXzVliSlice(buf: []const u8, pos: *usize) !u64 {
    if (pos.* >= buf.len) return error.CorruptXzStream;
    var result: u64 = 0;
    var i: usize = 0;
    while (i < 9) : (i += 1) {
        if (pos.* >= buf.len) return error.CorruptXzStream;
        const b = buf[pos.*];
        pos.* += 1;
        if (b == 0 and i > 0) return error.CorruptXzStream;
        result |= @as(u64, b & 0x7F) << @intCast(i * 7);
        if ((b & 0x80) == 0) return result;
    }
    return error.CorruptXzStream;
}

const XzIndexInfo = struct {
    blocks_compressed_padded: u64,
    uncompressed_size: u64,
};

fn parseXzIndexSlice(index_bytes: []const u8) !XzIndexInfo {
    if (index_bytes.len < 8 or (index_bytes.len % 4) != 0) return error.CorruptXzStream;
    if (index_bytes[0] != 0x00) return error.CorruptXzStream;

    const declared_crc = std.mem.readInt(u32, index_bytes[index_bytes.len - 4 ..][0..4], .little);
    const computed_crc = std.hash.Crc32.hash(index_bytes[0 .. index_bytes.len - 4]);
    if (declared_crc != computed_crc) return error.WrongXzChecksum;

    var pos: usize = 1;
    const num_records = try decodeXzVliSlice(index_bytes[0 .. index_bytes.len - 4], &pos);
    var blocks_size: u64 = 0;
    var uncomp_size: u64 = 0;

    var rec: u64 = 0;
    while (rec < num_records) : (rec += 1) {
        const unpadded = try decodeXzVliSlice(index_bytes[0 .. index_bytes.len - 4], &pos);
        if (unpadded < 5) return error.CorruptXzStream;
        const uncomp = try decodeXzVliSlice(index_bytes[0 .. index_bytes.len - 4], &pos);
        blocks_size = try std.math.add(u64, blocks_size, (unpadded + 3) & ~@as(u64, 3));
        uncomp_size = try std.math.add(u64, uncomp_size, uncomp);
    }

    const pad_end = index_bytes.len - 4;
    if (pad_end - pos > 3) return error.CorruptXzStream;
    for (index_bytes[pos..pad_end]) |b| {
        if (b != 0) return error.CorruptXzStream;
    }

    return .{
        .blocks_compressed_padded = blocks_size,
        .uncompressed_size = uncomp_size,
    };
}

/// Parses the XZ Stream Footer(s) and Index(es) from the end of an in-memory `.xz` slice
/// to compute the total uncompressed size in O(number of blocks) time without decompressing.
pub fn readXzUncompressedSizeFromSlice(data: []const u8) !u64 {
    if (data.len < 24 or (data.len % 4) != 0) return error.CorruptXzStream;
    if (!Qcow2Disk.isXzMagic(data)) return error.NotXzStream;

    var pos: usize = data.len;
    var total_uncompressed: u64 = 0;
    var streams_found: usize = 0;

    while (pos > 0) {
        while (pos >= 4 and std.mem.eql(u8, data[pos - 4 .. pos], &.{ 0, 0, 0, 0 })) {
            pos -= 4;
        }
        if (pos == 0) break;
        if (pos < 24 or (pos % 4) != 0) return error.CorruptXzStream;

        const footer = data[pos - 12 .. pos];
        if (footer[10] != 'Y' or footer[11] != 'Z') return error.CorruptXzStream;
        const footer_crc = std.mem.readInt(u32, footer[0..4], .little);
        if (footer_crc != std.hash.Crc32.hash(footer[4..10])) return error.WrongXzChecksum;

        const backward_size = std.mem.readInt(u32, footer[4..8], .little);
        const index_size_u64 = (@as(u64, backward_size) + 1) * 4;
        const footer_pos = pos - 12;
        if (index_size_u64 > footer_pos or footer_pos - @as(usize, @intCast(index_size_u64)) < 12) {
            return error.CorruptXzStream;
        }
        const index_size: usize = @intCast(index_size_u64);
        const index_pos = footer_pos - index_size;
        const idx_info = try parseXzIndexSlice(data[index_pos..footer_pos]);

        if (idx_info.blocks_compressed_padded > index_pos or index_pos - @as(usize, @intCast(idx_info.blocks_compressed_padded)) < 12) {
            return error.CorruptXzStream;
        }
        const header_pos = index_pos - @as(usize, @intCast(idx_info.blocks_compressed_padded)) - 12;
        const header = data[header_pos .. header_pos + 12];
        if (!Qcow2Disk.isXzMagic(header)) return error.CorruptXzStream;
        if (header[6] != footer[8] or header[7] != footer[9]) return error.CorruptXzStream;

        total_uncompressed = try std.math.add(u64, total_uncompressed, idx_info.uncompressed_size);
        streams_found += 1;
        pos = header_pos;
    }

    if (streams_found == 0) return error.CorruptXzStream;
    return total_uncompressed;
}

/// Parses the XZ Stream Footer(s) and Index(es) from the end of an `.xz` file descriptor
/// to compute the total uncompressed size in O(number of blocks) time without decompressing.
pub fn readXzUncompressedSizeFromFd(fd: host_posix.fd_t, file_size: u64) !u64 {
    if (file_size < 24 or (file_size % 4) != 0) return error.CorruptXzStream;

    var pos: u64 = file_size;
    var total_uncompressed: u64 = 0;
    var streams_found: usize = 0;

    while (pos > 0) {
        // Skip trailing/inter-stream 4-byte zero padding
        while (pos >= 4) {
            var pad_buf: [4]u8 = undefined;
            try preadAll(fd, &pad_buf, pos - 4);
            if (!std.mem.eql(u8, &pad_buf, &.{ 0, 0, 0, 0 })) break;
            pos -= 4;
        }
        if (pos == 0) break;
        if (pos < 24 or (pos % 4) != 0) return error.CorruptXzStream;

        var footer: [12]u8 = undefined;
        try preadAll(fd, &footer, pos - 12);
        if (footer[10] != 'Y' or footer[11] != 'Z') return error.CorruptXzStream;
        const footer_crc = std.mem.readInt(u32, footer[0..4], .little);
        if (footer_crc != std.hash.Crc32.hash(footer[4..10])) return error.WrongXzChecksum;

        const backward_size = std.mem.readInt(u32, footer[4..8], .little);
        const index_size: u64 = (@as(u64, backward_size) + 1) * 4;
        const footer_pos = pos - 12;
        if (index_size > footer_pos or footer_pos - index_size < 12 or index_size > 16 * 1024 * 1024) {
            return error.CorruptXzStream;
        }
        const index_pos = footer_pos - index_size;

        var stack_idx_buf: [4096]u8 = undefined;
        var heap_idx_buf: ?[]u8 = null;
        defer if (heap_idx_buf) |hb| std.heap.page_allocator.free(hb);
        const idx_slice: []u8 = if (index_size <= stack_idx_buf.len)
            stack_idx_buf[0..@intCast(index_size)]
        else blk: {
            heap_idx_buf = try std.heap.page_allocator.alloc(u8, @intCast(index_size));
            break :blk heap_idx_buf.?;
        };
        try preadAll(fd, idx_slice, index_pos);
        const idx_info = try parseXzIndexSlice(idx_slice);

        if (idx_info.blocks_compressed_padded > index_pos or index_pos - idx_info.blocks_compressed_padded < 12) {
            return error.CorruptXzStream;
        }
        const header_pos = index_pos - idx_info.blocks_compressed_padded - 12;
        var header: [12]u8 = undefined;
        try preadAll(fd, &header, header_pos);
        if (!Qcow2Disk.isXzMagic(&header)) return error.CorruptXzStream;
        if (header[6] != footer[8] or header[7] != footer[9]) return error.CorruptXzStream;

        total_uncompressed = try std.math.add(u64, total_uncompressed, idx_info.uncompressed_size);
        streams_found += 1;
        pos = header_pos;
    }

    if (streams_found == 0) return error.CorruptXzStream;
    return total_uncompressed;
}

const ClusterSink = struct {
    disk: *Qcow2Disk,
    cluster_buf: *[CLUSTER_SIZE]u8,
    cluster_pos: usize = 0,
    vcluster: u64 = 0,
    total_written: u64 = 0,
    progress_bytes: ?*std.atomic.Value(u64) = null,

    pub fn writeByte(self: *ClusterSink, b: u8) !void {
        self.cluster_buf[self.cluster_pos] = b;
        self.cluster_pos += 1;
        self.total_written += 1;
        if (self.cluster_pos == CLUSTER_SIZE) {
            try self.flushFullCluster();
        }
    }

    fn flushFullCluster(self: *ClusterSink) !void {
        if (self.total_written > self.disk.virtual_size) return error.ImageTooLarge;
        if (!isAllZero(self.cluster_buf)) {
            try self.disk.writeClusterSlice(self.vcluster, self.cluster_buf);
        }
        self.vcluster += 1;
        self.cluster_pos = 0;
        if (self.progress_bytes) |p| p.store(self.total_written, .monotonic);
    }

    pub fn finish(self: *ClusterSink) !void {
        if (self.total_written > self.disk.virtual_size) return error.ImageTooLarge;
        if (self.cluster_pos > 0) {
            const tail = self.cluster_buf[0..self.cluster_pos];
            if (!isAllZero(tail)) {
                try self.disk.writeClusterSlice(self.vcluster, tail);
            }
            self.cluster_pos = 0;
        }
        if (self.progress_bytes) |p| p.store(self.total_written, .monotonic);
    }
};

const StreamingLzma2Buffer = struct {
    dict: []u8,
    dict_pos: usize = 0,
    len: usize = 0,
    sink: *ClusterSink,

    pub fn resetDict(self: *StreamingLzma2Buffer) void {
        self.dict_pos = 0;
        self.len = 0;
    }

    pub fn lastOr(self: *const StreamingLzma2Buffer, lit: u8) u8 {
        if (self.len == 0) return lit;
        const idx = if (self.dict_pos == 0) self.dict.len - 1 else self.dict_pos - 1;
        return self.dict[idx];
    }

    pub fn lastN(self: *const StreamingLzma2Buffer, dist: usize) !u8 {
        if (dist == 0 or dist > self.len or dist > self.dict.len) return error.CorruptInput;
        const idx = if (self.dict_pos >= dist)
            self.dict_pos - dist
        else
            self.dict.len - (dist - self.dict_pos);
        return self.dict[idx];
    }

    pub fn appendByteDirect(self: *StreamingLzma2Buffer, b: u8) !void {
        self.dict[self.dict_pos] = b;
        self.dict_pos += 1;
        if (self.dict_pos == self.dict.len) self.dict_pos = 0;
        self.len += 1;
        try self.sink.writeByte(b);
    }

    pub fn appendLiteral(
        self: *StreamingLzma2Buffer,
        _: std.mem.Allocator,
        lit: u8,
        _: *std.Io.Writer,
    ) !void {
        try self.appendByteDirect(lit);
    }

    pub fn appendLz(
        self: *StreamingLzma2Buffer,
        _: std.mem.Allocator,
        match_len: usize,
        dist: usize,
        _: *std.Io.Writer,
    ) !void {
        if (dist == 0 or dist > self.len or dist > self.dict.len) return error.CorruptInput;
        var src_pos = if (self.dict_pos >= dist)
            self.dict_pos - dist
        else
            self.dict.len - (dist - self.dict_pos);
        for (0..match_len) |_| {
            const b = self.dict[src_pos];
            src_pos += 1;
            if (src_pos == self.dict.len) src_pos = 0;
            try self.appendByteDirect(b);
        }
    }
};

fn takeXzVliCounted(reader: *std.Io.Reader, counter: *u64, hasher: *std.hash.Crc32) !u64 {
    var result: u64 = 0;
    var i: usize = 0;
    while (i < 9) : (i += 1) {
        const b = try reader.takeByte();
        counter.* += 1;
        hasher.update(&.{b});
        if (b == 0 and i > 0) return error.CorruptInput;
        result |= @as(u64, b & 0x7F) << @intCast(i * 7);
        if ((b & 0x80) == 0) return result;
    }
    return error.CorruptInput;
}

fn xzCheckSize(check_id: u4) usize {
    return if (check_id == 0) 0 else @as(usize, 4) << @intCast((check_id - 1) / 3);
}

fn decodeLzma2DictSize(props_byte: u8) !usize {
    if ((props_byte & 0xC0) != 0) return error.CorruptInput;
    const bits: u6 = @truncate(props_byte & 0x3F);
    if (bits > 40) return error.CorruptInput;
    return if (bits == 40)
        0xFFFF_FFFF
    else
        (@as(usize, 2) | (bits & 1)) << @intCast(bits / 2 + 11);
}

/// Streams an XZ-compressed disk image (`.img.xz`) from `input` into `disk` in 64 KiB clusters
/// using a bounded LZMA2 dictionary ring buffer without buffering the entire image in memory.
pub fn streamXzToQcow2(
    allocator: std.mem.Allocator,
    input: *std.Io.Reader,
    disk: *Qcow2Disk,
) !void {
    return streamXzToQcow2WithProgress(allocator, input, disk, null);
}

pub fn streamXzToQcow2WithProgress(
    allocator: std.mem.Allocator,
    input: *std.Io.Reader,
    disk: *Qcow2Disk,
    progress_bytes_opt: ?*std.atomic.Value(u64),
) !void {
    const cluster_buf = try allocator.create([CLUSTER_SIZE]u8);
    defer allocator.destroy(cluster_buf);
    @memset(cluster_buf, 0);

    var sink: ClusterSink = .{
        .disk = disk,
        .cluster_buf = cluster_buf,
        .progress_bytes = progress_bytes_opt,
    };

    var dict_buf: []u8 = &.{};
    defer if (dict_buf.len > 0) allocator.free(dict_buf);

    var lzma_decode = try std.compress.lzma.Decode.init(allocator, .{ .lc = 0, .lp = 0, .pb = 0 });
    defer lzma_decode.deinit(allocator);

    var dummy_allocating = std.Io.Writer.Allocating.init(allocator);
    defer dummy_allocating.deinit();

    var streams_decoded: usize = 0;
    stream_loop: while (true) {
        const magic = try input.takeArray(6);
        if (!std.mem.eql(u8, magic, &Qcow2Disk.XZ_HEADER_MAGIC)) return error.NotXzStream;

        const stream_flags: [2]u8 = (try input.takeArray(2)).*;
        const header_crc = try input.takeInt(u32, .little);
        if (header_crc != std.hash.Crc32.hash(&stream_flags)) return error.WrongChecksum;
        if (stream_flags[0] != 0 or (stream_flags[1] & 0xF0) != 0) return error.CorruptInput;
        const check_id: u4 = @truncate(stream_flags[1] & 0x0F);
        const check_len = xzCheckSize(check_id);

        var block_count: u64 = 0;
        while (true) {
            const first_byte: usize = try input.peekByte();
            if (first_byte == 0) break; // Index Indicator

            const declared_header_size = first_byte * 4;
            const header_bytes = try input.take(declared_header_size);
            const declared_hdr_crc = try input.takeInt(u32, .little);
            if (declared_hdr_crc != std.hash.Crc32.hash(header_bytes)) return error.WrongChecksum;

            var hdr_pos: usize = 1;
            const blk_flags = header_bytes[hdr_pos];
            hdr_pos += 1;
            const filter_count = @as(usize, blk_flags & 0x03) + 1;
            if ((blk_flags & 0x3C) != 0 or filter_count != 1) return error.Unsupported;

            const has_packed_size = (blk_flags & 0x40) != 0;
            const has_unpacked_size = (blk_flags & 0x80) != 0;
            const expected_packed_size: ?u64 = if (has_packed_size) try decodeXzVliSlice(header_bytes, &hdr_pos) else null;
            const expected_unpacked_size: ?u64 = if (has_unpacked_size) try decodeXzVliSlice(header_bytes, &hdr_pos) else null;

            const filter_id = try decodeXzVliSlice(header_bytes, &hdr_pos);
            if (filter_id != 0x21) return error.Unsupported; // 0x21 = LZMA2
            const props_size = try decodeXzVliSlice(header_bytes, &hdr_pos);
            if (props_size != 1 or hdr_pos >= header_bytes.len) return error.CorruptInput;
            const dict_size = try decodeLzma2DictSize(header_bytes[hdr_pos]);
            hdr_pos += 1;

            for (header_bytes[hdr_pos..]) |pad_b| {
                if (pad_b != 0) return error.CorruptInput;
            }

            const needed_dict = @max(dict_size, 4096);
            if (dict_buf.len < needed_dict) {
                if (dict_buf.len > 0) allocator.free(dict_buf);
                dict_buf = try allocator.alloc(u8, needed_dict);
            }

            var lzma2_buf: StreamingLzma2Buffer = .{
                .dict = dict_buf[0..needed_dict],
                .sink = &sink,
            };

            const before_unpacked = sink.total_written;
            var packed_bytes_read: u64 = 0;

            while (true) {
                const status = try input.takeByte();
                packed_bytes_read += 1;
                if (status == 0) break;

                if (status == 1 or status == 2) {
                    const chunk_unpacked = @as(usize, try input.takeInt(u16, .big)) + 1;
                    packed_bytes_read += 2 + chunk_unpacked;
                    if (status == 1) lzma2_buf.resetDict();
                    for (0..chunk_unpacked) |_| {
                        try lzma2_buf.appendByteDirect(try input.takeByte());
                    }
                } else {
                    if ((status & 0x80) == 0) return error.CorruptInput;
                    const reset_mode: u2 = @truncate((status >> 5) & 0x03);
                    const reset_dict = (reset_mode == 3);
                    const reset_state = (reset_mode >= 1);
                    const reset_props = (reset_mode >= 2);

                    const chunk_unpacked: usize = (@as(usize, status & 0x1F) << 16) +
                        @as(usize, try input.takeInt(u16, .big)) + 1;
                    const chunk_packed: u64 = @as(u64, try input.takeInt(u16, .big)) + 1;
                    packed_bytes_read += 4;

                    if (reset_dict) lzma2_buf.resetDict();
                    if (reset_state) {
                        var new_props = lzma_decode.properties;
                        if (reset_props) {
                            var props = try input.takeByte();
                            packed_bytes_read += 1;
                            if (props >= 225) return error.CorruptInput;
                            const lc: u4 = @intCast(props % 9);
                            props /= 9;
                            const lp: u3 = @intCast(props % 5);
                            props /= 5;
                            const pb: u3 = @intCast(props);
                            if (lc + lp > 4) return error.CorruptInput;
                            new_props = .{ .lc = lc, .lp = lp, .pb = pb };
                        }
                        try lzma_decode.resetState(allocator, new_props);
                    }

                    const target_len = lzma2_buf.len + chunk_unpacked;
                    const start_packed = packed_bytes_read;
                    var range_decoder = try std.compress.lzma.RangeDecoder.initCounting(input, &packed_bytes_read);
                    while (lzma2_buf.len < target_len) {
                        switch (try lzma_decode.process(input, &dummy_allocating, &lzma2_buf, &range_decoder, &packed_bytes_read)) {
                            .more => continue,
                            .finished => break,
                        }
                    }
                    if (lzma2_buf.len != target_len) return error.DecompressedSizeMismatch;
                    if (packed_bytes_read - start_packed != chunk_packed) return error.CompressedSizeMismatch;
                }
            }

            const block_unpacked = sink.total_written - before_unpacked;
            if (expected_packed_size) |s| {
                if (s != packed_bytes_read) return error.CorruptInput;
            }
            if (expected_unpacked_size) |s| {
                if (s != block_unpacked) return error.CorruptInput;
            }

            const block_pad_len: usize = @intCast((4 - (packed_bytes_read % 4)) % 4);
            const block_pad = try input.take(block_pad_len);
            for (block_pad) |b| {
                if (b != 0) return error.CorruptInput;
            }
            if (check_len > 0) {
                _ = try input.take(check_len);
            }
            block_count += 1;
        }

        // Parse Stream Index and Stream Footer
        _ = try input.takeByte(); // 0x00 Index Indicator
        var idx_counter: u64 = 1;
        var idx_crc: std.hash.Crc32 = .init();
        idx_crc.update(&.{0});

        const record_count = try takeXzVliCounted(input, &idx_counter, &idx_crc);
        if (record_count != block_count) return error.CorruptInput;
        for (0..@intCast(record_count)) |_| {
            _ = try takeXzVliCounted(input, &idx_counter, &idx_crc);
            _ = try takeXzVliCounted(input, &idx_counter, &idx_crc);
        }
        const idx_pad_len: usize = @intCast((4 - (idx_counter % 4)) % 4);
        const idx_pad = try input.take(idx_pad_len);
        for (idx_pad) |b| {
            if (b != 0) return error.CorruptInput;
        }
        idx_crc.update(idx_pad);
        const declared_idx_crc = try input.takeInt(u32, .little);
        if (declared_idx_crc != idx_crc.final()) return error.WrongChecksum;
        const index_size = idx_counter + idx_pad_len + 4;

        const footer = try input.takeArray(12);
        const footer_crc = std.mem.readInt(u32, footer[0..4], .little);
        if (footer_crc != std.hash.Crc32.hash(footer[4..10])) return error.WrongChecksum;
        const backward_size = (@as(u64, std.mem.readInt(u32, footer[4..8], .little)) + 1) * 4;
        if (backward_size != index_size) return error.CorruptInput;
        if (footer[8] != stream_flags[0] or footer[9] != stream_flags[1]) return error.CorruptInput;
        if (footer[10] != 'Y' or footer[11] != 'Z') return error.CorruptInput;

        streams_decoded += 1;

        // Check for trailing stream padding or another concatenated XZ stream
        while (true) {
            const next_b = input.peekByte() catch |err| switch (err) {
                error.EndOfStream => break :stream_loop,
                else => |e| return e,
            };
            if (next_b == 0) {
                const pad4 = try input.takeArray(4);
                if (!std.mem.eql(u8, pad4, &.{ 0, 0, 0, 0 })) return error.CorruptInput;
                continue;
            }
            break;
        }
    }

    if (streams_decoded == 0) return error.NotXzStream;
    try sink.finish();
}

const testing = std.testing;

test "QCOW2 sparse disk creation, size validation, and cluster allocation" {
    const allocator = testing.allocator;

    // 1. Image larger than selected card size must fail with error.ImageTooLarge
    var oversized_img: [1024]u8 = @splat(0xaa);
    try testing.expectError(
        error.ImageTooLarge,
        Qcow2Disk.createFromSlice(allocator, 512, &oversized_img),
    );

    // 2. Create a 4 GiB card with a small image containing only 1 non-zero cluster
    const card_size = SdCardSize.gb_4.bytes();
    const img_buf = try allocator.alloc(u8, CLUSTER_SIZE * 3);
    defer allocator.free(img_buf);
    @memset(img_buf, 0);
    // Cluster 0 has MBR signature, Cluster 1 is all zeros, Cluster 2 has data
    img_buf[510] = 0x55;
    img_buf[511] = 0xaa;
    std.mem.writeInt(u32, img_buf[CLUSTER_SIZE * 2 ..][0..4], 0xCAFEBABE, .little);

    var disk = try Qcow2Disk.createFromSlice(allocator, card_size, img_buf);
    defer disk.deinit();

    // Verify QCOW2 header magic and virtual size on disk
    var hdr: [32]u8 = undefined;
    try preadAll(disk.fd, &hdr, 0);
    try testing.expectEqual(QCOW2_MAGIC, std.mem.readInt(u32, hdr[0..4], .big));
    try testing.expectEqual(QCOW2_VERSION, std.mem.readInt(u32, hdr[4..8], .big));
    try testing.expectEqual(card_size, std.mem.readInt(u64, hdr[24..32], .big));

    // Only 2 data clusters (Cluster 0 and Cluster 2) should be allocated on disk (skipping all-zero Cluster 1)
    try testing.expectEqual(@as(u64, 2), disk.allocated_data_clusters);
    // 4 metadata clusters + 1 L2 table cluster + 2 data clusters = 7 clusters (448 KiB on disk for a 4 GiB card!)
    try testing.expectEqual(@as(u64, 7 * CLUSTER_SIZE), disk.diskAllocatedBytes());

    // Read back bytes across clusters and unallocated regions (e.g. at 2 GiB offset)
    try testing.expectEqual(@as(u8, 0x55), disk.readByte(510));
    try testing.expectEqual(@as(u8, 0xaa), disk.readByte(511));
    try testing.expectEqual(@as(u8, 0x00), disk.readByte(CLUSTER_SIZE + 10));
    try testing.expectEqual(@as(u8, 0xbe), disk.readByte(CLUSTER_SIZE * 2 + 0));
    try testing.expectEqual(@as(u8, 0xba), disk.readByte(CLUSTER_SIZE * 2 + 1));
    try testing.expectEqual(@as(u8, 0xfe), disk.readByte(CLUSTER_SIZE * 2 + 2));
    try testing.expectEqual(@as(u8, 0xca), disk.readByte(CLUSTER_SIZE * 2 + 3));
    try testing.expectEqual(@as(u8, 0x00), disk.readByte(2 * 1024 * 1024 * 1024));

    // Write at a high offset (e.g. 3 GiB) and verify persistence after flush
    const high_off: u64 = 3 * 1024 * 1024 * 1024 + 512;
    disk.writeByte(high_off, 0x42);
    try disk.flush();
    try testing.expectEqual(@as(u8, 0x42), disk.readByte(high_off));
}

test "QCOW2 persistent file creation and reopening via openExistingFile" {
    const allocator = testing.allocator;

    var rnd: [8]u8 = undefined;
    host_posix.getRandomBytes(&rnd);
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/fauxpi-test-{x}.qcow2", .{std.mem.readInt(u64, &rnd, .little)});
    defer unlinkFileLinux(path);

    const card_size = SdCardSize.gb_2.bytes();
    var init_data: [1024]u8 = @splat(0);
    init_data[510] = 0x55;
    init_data[511] = 0xAA;

    const high_off: u64 = 1 * 1024 * 1024 * 1024 + 123;
    {
        var disk = try Qcow2Disk.createFromSliceAtPath(allocator, card_size, &init_data, path);
        defer disk.deinit();
        disk.writeByte(high_off, 0x7E);
        try disk.flush();
    }

    // Reopen from disk and verify virtual size, allocated clusters, and persisted bytes
    {
        var reopened = try Qcow2Disk.openExistingFile(allocator, path);
        defer reopened.deinit();
        try testing.expectEqual(card_size, reopened.virtual_size);
        try testing.expectEqual(@as(u64, 2), reopened.allocated_data_clusters);
        try testing.expectEqual(@as(u8, 0x55), reopened.readByte(510));
        try testing.expectEqual(@as(u8, 0xAA), reopened.readByte(511));
        try testing.expectEqual(@as(u8, 0x7E), reopened.readByte(high_off));

        // Write another cluster after reopening and flush
        reopened.writeByte(CLUSTER_SIZE * 5 + 7, 0x99);
        try reopened.flush();
    }

    // Reopen a second time to verify new writes on reopened file also persist
    {
        var reopened2 = try Qcow2Disk.openExistingFile(allocator, path);
        defer reopened2.deinit();
        try testing.expectEqual(@as(u64, 3), reopened2.allocated_data_clusters);
        try testing.expectEqual(@as(u8, 0x7E), reopened2.readByte(high_off));
        try testing.expectEqual(@as(u8, 0x99), reopened2.readByte(CLUSTER_SIZE * 5 + 7));
    }
}

fn encodeXzVli(val: u64, out: []u8) usize {
    var v = val;
    var i: usize = 0;
    while (true) {
        const b: u8 = @intCast(v & 0x7F);
        v >>= 7;
        if (v == 0) {
            out[i] = b;
            return i + 1;
        }
        out[i] = b | 0x80;
        i += 1;
    }
}

/// Builds a valid `.xz` archive containing `raw` using LZMA2 uncompressed chunks for unit testing.
fn buildTestXzArchiveAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    // 1. Stream Header (12 bytes: magic + flags(CRC32=0x01) + crc32)
    try out.appendSlice(allocator, &Qcow2Disk.XZ_HEADER_MAGIC);
    const stream_flags = [2]u8{ 0x00, 0x01 };
    try out.appendSlice(allocator, &stream_flags);
    var crc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_buf, std.hash.Crc32.hash(&stream_flags), .little);
    try out.appendSlice(allocator, &crc_buf);

    // 2. Block Header (8 bytes + 4-byte CRC32 = 12 bytes): 1 filter (LZMA2 = 0x21, dict props = 0x00 -> 4 KiB)
    const blk_hdr = [8]u8{
        0x02, // encoded header size: 2 * 4 = 8 bytes before CRC32
        0x00, // flags: 1 filter, no explicit sizes in header
        0x21, // Filter ID = LZMA2
        0x01, // Size of properties = 1
        0x00, // Dictionary size property (4 KiB)
        0x00, 0x00, 0x00, // header padding
    };
    try out.appendSlice(allocator, &blk_hdr);
    std.mem.writeInt(u32, &crc_buf, std.hash.Crc32.hash(&blk_hdr), .little);
    try out.appendSlice(allocator, &crc_buf);

    // 3. LZMA2 data chunks (max 64 KiB per uncompressed chunk)
    var packed_len: u64 = 0;
    var off: usize = 0;
    var first = true;
    while (off < raw.len) {
        const chunk_len = @min(raw.len - off, 65536);
        const status: u8 = if (first) 0x01 else 0x02;
        first = false;
        try out.append(allocator, status);
        var len_be: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_be, @intCast(chunk_len - 1), .big);
        try out.appendSlice(allocator, &len_be);
        try out.appendSlice(allocator, raw[off .. off + chunk_len]);
        packed_len += 3 + chunk_len;
        off += chunk_len;
    }
    // End of LZMA2 stream marker (0x00)
    try out.append(allocator, 0x00);
    packed_len += 1;

    // Block Padding to 4-byte boundary
    const blk_pad = (4 - (packed_len % 4)) % 4;
    for (0..@intCast(blk_pad)) |_| try out.append(allocator, 0x00);

    // Block Check (CRC32, 4 bytes)
    std.mem.writeInt(u32, &crc_buf, std.hash.Crc32.hash(raw), .little);
    try out.appendSlice(allocator, &crc_buf);

    const unpadded_size: u64 = 12 + packed_len + 4;

    // 4. Index: 0x00 indicator + num_records(1) + unpadded_size + uncompressed_size + padding + CRC32
    var idx_buf: [64]u8 = @splat(0);
    var idx_len: usize = 0;
    idx_buf[idx_len] = 0x00;
    idx_len += 1;
    idx_len += encodeXzVli(1, idx_buf[idx_len..]);
    idx_len += encodeXzVli(unpadded_size, idx_buf[idx_len..]);
    idx_len += encodeXzVli(raw.len, idx_buf[idx_len..]);
    while ((idx_len % 4) != 0) : (idx_len += 1) {
        idx_buf[idx_len] = 0x00;
    }
    const idx_crc = std.hash.Crc32.hash(idx_buf[0..idx_len]);
    std.mem.writeInt(u32, idx_buf[idx_len..][0..4], idx_crc, .little);
    idx_len += 4;
    try out.appendSlice(allocator, idx_buf[0..idx_len]);

    // 5. Stream Footer (12 bytes: CRC32 + backward_size + stream_flags + "YZ")
    var footer: [12]u8 = undefined;
    const backward_size: u32 = @intCast((idx_len / 4) - 1);
    std.mem.writeInt(u32, footer[4..8], backward_size, .little);
    footer[8] = stream_flags[0];
    footer[9] = stream_flags[1];
    footer[10] = 'Y';
    footer[11] = 'Z';
    std.mem.writeInt(u32, footer[0..4], std.hash.Crc32.hash(footer[4..10]), .little);
    try out.appendSlice(allocator, &footer);

    return out.toOwnedSlice(allocator);
}

test "QCOW2 creation and uncompressed size inspection from .img.xz file and slice" {
    const allocator = testing.allocator;

    // Build a 3-cluster (192 KiB) disk image with MBR signature in cluster 0, zeros in cluster 1, and data in cluster 2
    const raw_len = CLUSTER_SIZE * 3;
    const raw_img = try allocator.alloc(u8, raw_len);
    defer allocator.free(raw_img);
    @memset(raw_img, 0);
    raw_img[510] = 0x55;
    raw_img[511] = 0xAA;
    std.mem.writeInt(u32, raw_img[CLUSTER_SIZE * 2 + 16 ..][0..4], 0xDEADBEEF, .little);

    const xz_bytes = try buildTestXzArchiveAlloc(allocator, raw_img);
    defer allocator.free(xz_bytes);

    // 1. Verify XZ Index inspection returns exact uncompressed size (196,608 bytes) from slice
    try testing.expectEqual(@as(u64, raw_len), try Qcow2Disk.getSliceLogicalSize(xz_bytes));

    // 2. Write .img.xz to disk and verify getFileSizeLinux returns uncompressed size and createFromImageFile works
    var rnd: [8]u8 = undefined;
    host_posix.getRandomBytes(&rnd);
    var xz_path_buf: [128]u8 = undefined;
    const xz_path = try std.fmt.bufPrint(&xz_path_buf, "/tmp/fauxpi-test-{x}.img.xz", .{std.mem.readInt(u64, &rnd, .little)});
    defer unlinkFileLinux(xz_path);

    {
        const fd = try host_posix.openCreateTruncWrite(xz_path, false);
        defer host_posix.close(fd);
        try host_posix.writeAll(fd, xz_bytes);
    }

    try testing.expectEqual(@as(u64, raw_len), try Qcow2Disk.getFileSizeLinux(xz_path));

    // Rejects when uncompressed size (192 KiB) exceeds virtual_size (64 KiB)
    try testing.expectError(
        error.ImageTooLarge,
        Qcow2Disk.createFromImageFile(allocator, CLUSTER_SIZE, xz_path),
    );

    // Streams .img.xz into a 4 GiB sparse QCOW2 disk, allocating only the 2 non-zero clusters
    var disk = try Qcow2Disk.createFromImageFile(allocator, SdCardSize.gb_4.bytes(), xz_path);
    defer disk.deinit();
    try testing.expectEqual(@as(u64, 2), disk.allocated_data_clusters);
    try testing.expectEqual(@as(u8, 0x55), disk.readByte(510));
    try testing.expectEqual(@as(u8, 0xAA), disk.readByte(511));
    try testing.expectEqual(@as(u8, 0x00), disk.readByte(CLUSTER_SIZE + 42));
    try testing.expectEqual(@as(u8, 0xEF), disk.readByte(CLUSTER_SIZE * 2 + 16));
    try testing.expectEqual(@as(u8, 0xBE), disk.readByte(CLUSTER_SIZE * 2 + 17));
    try testing.expectEqual(@as(u8, 0xAD), disk.readByte(CLUSTER_SIZE * 2 + 18));
    try testing.expectEqual(@as(u8, 0xDE), disk.readByte(CLUSTER_SIZE * 2 + 19));
}
