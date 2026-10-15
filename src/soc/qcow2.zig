//! QCOW2 v3 (`QFI\xfb`) sparse virtual disk image implementation for SD cards.
//!
//! Uses 64 KiB clusters (`cluster_bits = 16`) allocated on demand so that large
//! SD cards (1 GB, 4 GB, 16 GB, 32 GB, etc.) consume minimal space on disk and
//! in memory, storing only non-zero 64 KiB clusters.

const std = @import("std");
const linux = std.os.linux;

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
    fd: linux.fd_t,
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

    /// Creates a new QCOW2 v3 disk of `virtual_size` bytes and populates it with `initial_image`.
    /// Returns `error.ImageTooLarge` if `initial_image.len > virtual_size`.
    pub fn createFromSlice(
        allocator: std.mem.Allocator,
        virtual_size: u64,
        initial_image: []const u8,
    ) !Qcow2Disk {
        if (initial_image.len > virtual_size) return error.ImageTooLarge;

        var disk = try initEmpty(allocator, virtual_size);
        errdefer disk.deinit();

        var off: usize = 0;
        while (off < initial_image.len) : (off += CLUSTER_SIZE) {
            const rem = @min(CLUSTER_SIZE, initial_image.len - off);
            const chunk = initial_image[off .. off + rem];
            if (!isAllZero(chunk)) {
                const vcluster: u64 = @intCast(off / CLUSTER_SIZE);
                try disk.writeClusterSlice(vcluster, chunk);
            }
        }
        try disk.flush();
        return disk;
    }

    /// Queries the size in bytes of a file on disk without reading it into memory.
    pub fn getFileSizeLinux(path: []const u8) !u64 {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (path.len >= path_buf.len) return error.NameTooLong;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;

        const fd_rc = linux.openat(linux.AT.FDCWD, path_buf[0..path.len :0], .{ .ACCMODE = .RDONLY }, 0);
        if (linux.errno(fd_rc) != .SUCCESS) return error.FileOpenFailed;
        const fd: linux.fd_t = @intCast(fd_rc);
        defer _ = linux.close(fd);

        const end_rc = linux.lseek(fd, 0, linux.SEEK.END);
        if (linux.errno(end_rc) != .SUCCESS) return error.FileSeekFailed;
        return @intCast(end_rc);
    }

    /// Creates a new QCOW2 v3 disk of `virtual_size` bytes by streaming `image_path` in 64 KiB clusters.
    /// Returns `error.ImageTooLarge` if the file size of `image_path` exceeds `virtual_size`.
    pub fn createFromImageFile(
        allocator: std.mem.Allocator,
        virtual_size: u64,
        image_path: []const u8,
    ) !Qcow2Disk {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (image_path.len >= path_buf.len) return error.NameTooLong;
        @memcpy(path_buf[0..image_path.len], image_path);
        path_buf[image_path.len] = 0;

        const fd_rc = linux.openat(linux.AT.FDCWD, path_buf[0..image_path.len :0], .{ .ACCMODE = .RDONLY }, 0);
        if (linux.errno(fd_rc) != .SUCCESS) return error.FileOpenFailed;
        const src_fd: linux.fd_t = @intCast(fd_rc);
        defer _ = linux.close(src_fd);

        const end_rc = linux.lseek(src_fd, 0, linux.SEEK.END);
        if (linux.errno(end_rc) != .SUCCESS) return error.FileSeekFailed;
        const file_size: u64 = @intCast(end_rc);

        if (file_size > virtual_size) return error.ImageTooLarge;

        _ = linux.lseek(src_fd, 0, linux.SEEK.SET);

        var disk = try initEmpty(allocator, virtual_size);
        errdefer disk.deinit();

        const io_buf = try allocator.alloc(u8, CLUSTER_SIZE);
        defer allocator.free(io_buf);

        var off: u64 = 0;
        while (off < file_size) {
            const want: usize = @intCast(@min(@as(u64, CLUSTER_SIZE), file_size - off));
            var got: usize = 0;
            while (got < want) {
                const rc = linux.read(src_fd, io_buf[got..want].ptr, want - got);
                if (linux.errno(rc) != .SUCCESS) return error.FileReadFailed;
                if (rc == 0) break;
                got += rc;
            }
            if (got == 0) break;
            if (!isAllZero(io_buf[0..got])) {
                try disk.writeClusterSlice(off / CLUSTER_SIZE, io_buf[0..got]);
            }
            off += got;
        }

        try disk.flush();
        return disk;
    }

    pub fn initEmpty(allocator: std.mem.Allocator, virtual_size: u64) !Qcow2Disk {
        if (virtual_size == 0) return error.InvalidSize;
        const fd = try createBackingFd();
        errdefer _ = linux.close(fd);

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

    pub fn deinit(self: *Qcow2Disk) void {
        self.flush() catch {};
        if (self.fd >= 0) {
            _ = linux.close(self.fd);
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
                    needed_bytes = @min(self.virtual_size, @max(needed_bytes, @min(part_end, 256 * 1024 * 1024)));
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
            if (!isAllZero(self.cluster_cache)) {
                const host_off = try self.lookupHostClusterOffset(vcluster, true);
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
        _ = linux.ftruncate(self.fd, @intCast(4 * CLUSTER_SIZE));
    }
};

fn isAllZero(buf: []const u8) bool {
    for (buf) |b| {
        if (b != 0) return false;
    }
    return true;
}

fn createBackingFd() !linux.fd_t {
    // Prefer an unlinked O_TMPFILE on disk (/var/tmp or /tmp) so large SD cards
    // do not consume RAM; fall back to memfd_create if O_TMPFILE is unavailable.
    const tmp_dirs = [_][:0]const u8{ "/var/tmp", "/tmp" };
    for (tmp_dirs) |dir| {
        const rc = linux.openat(
            linux.AT.FDCWD,
            dir,
            .{
                .ACCMODE = .RDWR,
                .TMPFILE = true,
                .CLOEXEC = true,
            },
            0o600,
        );
        if (linux.errno(rc) == .SUCCESS) {
            return @intCast(rc);
        }
    }
    const mfd_rc = linux.memfd_create("fauxpi-sdcard-qcow2", linux.MFD.CLOEXEC);
    if (linux.errno(mfd_rc) != .SUCCESS) return error.FileOpenFailed;
    return @intCast(mfd_rc);
}

fn preadAll(fd: linux.fd_t, buf: []u8, offset: u64) !void {
    var done: usize = 0;
    while (done < buf.len) {
        const rc = linux.pread(fd, buf[done..].ptr, buf.len - done, @intCast(offset + done));
        if (linux.errno(rc) != .SUCCESS) return error.DiskReadFailed;
        if (rc == 0) {
            @memset(buf[done..], 0);
            return;
        }
        done += rc;
    }
}

fn pwriteAll(fd: linux.fd_t, buf: []const u8, offset: u64) !void {
    var done: usize = 0;
    while (done < buf.len) {
        const rc = linux.pwrite(fd, buf[done..].ptr, buf.len - done, @intCast(offset + done));
        if (linux.errno(rc) != .SUCCESS) return error.DiskWriteFailed;
        done += rc;
    }
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
