//! Read-only MBR + FAT16/FAT32 filesystem reader for booting Raspberry Pi SD
//! card images.
//!
//! Supports both 8.3 short names and VFAT Long File Names (LFN), nested
//! subdirectories (e.g. `slot-a/kernel.img`, `slot-a/overlays/vc4-kms-v3d.dtbo`),
//! and case-insensitive path resolution.

const std = @import("std");

pub const sector_size = 512;

pub const FatKind = enum {
    fat16,
    fat32,
};

pub const FatFs = struct {
    part: []const u8,
    kind: FatKind,
    bytes_per_sector: u32,
    sectors_per_cluster: u32,
    reserved_sectors: u32,
    num_fats: u32,
    root_entries: u32,
    fat_sectors: u32,
    root_cluster: u32,
    root_dir_offset: usize,
    root_dir_size: usize,
    data_start_sector: u32,
    total_clusters: u32,

    /// Opens the first FAT16/FAT32 partition in `image` (or treats `image`
    /// itself as a partition boot sector if there is no MBR partition table).
    pub fn init(image: []const u8) !FatFs {
        if (image.len < sector_size) return error.InvalidImage;
        if (image[510] != 0x55 or image[511] != 0xaa) return error.InvalidSignature;

        const part = findPartition(image) catch image;
        if (part.len < sector_size) return error.InvalidPartition;
        if (part[510] != 0x55 or part[511] != 0xaa) return error.InvalidBootSector;

        const bps = std.mem.readInt(u16, part[11..13], .little);
        if (bps != 512 and bps != 1024 and bps != 2048 and bps != 4096) return error.UnsupportedSectorSize;
        const spc = part[13];
        if (spc == 0 or (spc & (spc - 1)) != 0) return error.InvalidSectorsPerCluster;
        const reserved = std.mem.readInt(u16, part[14..16], .little);
        const fats = part[16];
        if (fats == 0) return error.InvalidFatCount;
        const root_ent = std.mem.readInt(u16, part[17..19], .little);
        const total16 = std.mem.readInt(u16, part[19..21], .little);
        const total32 = std.mem.readInt(u32, part[32..36], .little);
        const total_sectors: u32 = if (total16 != 0) total16 else total32;

        const fat16_sectors = std.mem.readInt(u16, part[22..24], .little);
        const fat32_sectors = std.mem.readInt(u32, part[36..40], .little);
        const fat_sectors: u32 = if (fat16_sectors != 0) fat16_sectors else fat32_sectors;
        if (fat_sectors == 0) return error.InvalidFatSectors;

        const root_sectors = ((@as(u32, root_ent) * 32) + (bps - 1)) / bps;
        const data_start = @as(u32, reserved) + (@as(u32, fats) * fat_sectors) + root_sectors;
        if (total_sectors <= data_start) return error.InvalidLayout;
        const data_sectors = total_sectors - data_start;
        const total_clusters = data_sectors / spc;

        const kind: FatKind = if (fat16_sectors == 0 or total_clusters >= 65525) .fat32 else .fat16;
        const root_cluster: u32 = if (kind == .fat32) std.mem.readInt(u32, part[44..48], .little) else 0;
        const root_dir_offset = (@as(usize, reserved) + @as(usize, fats) * fat_sectors) * bps;
        const root_dir_size = @as(usize, root_ent) * 32;

        return .{
            .part = part,
            .kind = kind,
            .bytes_per_sector = bps,
            .sectors_per_cluster = spc,
            .reserved_sectors = reserved,
            .num_fats = fats,
            .root_entries = root_ent,
            .fat_sectors = fat_sectors,
            .root_cluster = root_cluster,
            .root_dir_offset = root_dir_offset,
            .root_dir_size = root_dir_size,
            .data_start_sector = data_start,
            .total_clusters = total_clusters,
        };
    }

    fn findPartition(image: []const u8) ![]const u8 {
        // Check if sector 0 looks like a FAT BPB already:
        // Jump instruction 0xEB xx 0x90 or 0xE9 xx xx AND valid bytes_per_sector + media descriptor
        const looks_like_bpb = (image[0] == 0xeb or image[0] == 0xe9) and
            std.mem.readInt(u16, image[11..13], .little) == 512 and
            image[16] >= 1 and image[16] <= 2 and
            (std.mem.eql(u8, image[54..59], "FAT16") or std.mem.eql(u8, image[54..59], "FAT12") or std.mem.eql(u8, image[82..87], "FAT32"));
        if (looks_like_bpb) return image;

        for (0..4) |i| {
            const entry = image[446 + i * 16 ..][0..16];
            const ptype = entry[4];
            if (ptype == 0) continue;
            // Common FAT partition types: 0x01, 0x04, 0x06, 0x0b, 0x0c, 0x0e
            const lba_start = std.mem.readInt(u32, entry[8..12], .little);
            const lba_count = std.mem.readInt(u32, entry[12..16], .little);
            const start_byte = @as(usize, lba_start) * sector_size;
            const len_byte = @as(usize, lba_count) * sector_size;
            if (start_byte < image.len) {
                const avail = image.len - start_byte;
                return image[start_byte .. start_byte + @min(avail, len_byte)];
            }
        }
        return error.NoPartitionFound;
    }

    fn nextCluster(self: *const FatFs, cluster: u32) ?u32 {
        const fat_offset = @as(usize, self.reserved_sectors) * self.bytes_per_sector;
        switch (self.kind) {
            .fat16 => {
                const pos = fat_offset + @as(usize, cluster) * 2;
                if (pos + 2 > self.part.len) return null;
                const val = std.mem.readInt(u16, self.part[pos..][0..2], .little);
                if (val >= 0xfff8 or val < 2) return null;
                return val;
            },
            .fat32 => {
                const pos = fat_offset + @as(usize, cluster) * 4;
                if (pos + 4 > self.part.len) return null;
                const val = std.mem.readInt(u32, self.part[pos..][0..4], .little) & 0x0fffffff;
                if (val >= 0x0ffffff8 or val < 2) return null;
                return val;
            },
        }
    }

    fn clusterSlice(self: *const FatFs, cluster: u32) ![]const u8 {
        if (cluster < 2) return error.InvalidCluster;
        const cluster_bytes = @as(usize, self.sectors_per_cluster) * self.bytes_per_sector;
        const start_sector = @as(usize, self.data_start_sector) + (@as(usize, cluster - 2) * self.sectors_per_cluster);
        const start_byte = start_sector * self.bytes_per_sector;
        if (start_byte + cluster_bytes > self.part.len) return error.ClusterOutOfBounds;
        return self.part[start_byte .. start_byte + cluster_bytes];
    }

    fn readChainAlloc(self: *const FatFs, allocator: std.mem.Allocator, first_cluster: u32, size: ?usize) ![]u8 {
        if (size) |s| {
            if (s == 0) return allocator.alloc(u8, 0);
        }
        if (first_cluster < 2) return error.InvalidCluster;

        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(allocator);
        if (size) |s| try list.ensureTotalCapacity(allocator, s);

        var cur: ?u32 = first_cluster;
        var guard: usize = 0;
        while (cur) |c| : (guard += 1) {
            if (guard > self.total_clusters + 4) return error.FatLoopDetected;
            const bytes = try self.clusterSlice(c);
            if (size) |s| {
                const rem = s - list.items.len;
                if (rem <= bytes.len) {
                    try list.appendSlice(allocator, bytes[0..rem]);
                    break;
                }
            }
            try list.appendSlice(allocator, bytes);
            cur = self.nextCluster(c);
        }

        if (size) |s| {
            if (list.items.len < s) return error.UnexpectedEof;
        }
        return list.toOwnedSlice(allocator);
    }

    const DirEntry = struct {
        is_dir: bool,
        first_cluster: u32,
        file_size: u32,
    };

    /// Reads the file at `path` (e.g. `"config.txt"` or `"slot-a/kernel.img"`).
    pub fn readFileAlloc(self: *const FatFs, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const entry = try self.lookupPath(allocator, path);
        if (entry.is_dir) return error.IsDir;
        return self.readChainAlloc(allocator, entry.first_cluster, entry.file_size);
    }

    /// Checks whether a file or directory exists at `path`.
    pub fn exists(self: *const FatFs, allocator: std.mem.Allocator, path: []const u8) bool {
        _ = self.lookupPath(allocator, path) catch return false;
        return true;
    }

    fn lookupPath(self: *const FatFs, allocator: std.mem.Allocator, path: []const u8) !DirEntry {
        var cur_cluster: ?u32 = if (self.kind == .fat32) self.root_cluster else null;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        var last_entry: ?DirEntry = null;

        while (it.next()) |component| {
            if (last_entry) |prev| {
                if (!prev.is_dir) return error.NotDir;
                cur_cluster = prev.first_cluster;
            }
            const dir_bytes = if (cur_cluster) |c|
                try self.readChainAlloc(allocator, c, null)
            else blk: {
                if (self.root_dir_offset + self.root_dir_size > self.part.len) return error.CorruptRootDir;
                break :blk self.part[self.root_dir_offset .. self.root_dir_offset + self.root_dir_size];
            };
            defer if (cur_cluster != null) allocator.free(dir_bytes);

            last_entry = try findInDir(self.kind, dir_bytes, component);
        }

        return last_entry orelse error.FileNotFound;
    }

    fn findInDir(kind: FatKind, dir_bytes: []const u8, target_name: []const u8) !DirEntry {
        const lfn_offsets = [13]usize{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
        var lfn_buf: [260]u8 = @splat(0);
        var lfn_len: usize = 0;
        var has_lfn = false;

        var i: usize = 0;
        while (i + 32 <= dir_bytes.len) : (i += 32) {
            const e = dir_bytes[i..][0..32];
            if (e[0] == 0x00) break; // End of directory
            if (e[0] == 0xe5) {
                has_lfn = false;
                lfn_len = 0;
                continue;
            }

            const attr = e[11];
            if (attr == 0x0f) {
                // VFAT Long File Name entry
                const seq = (e[0] & 0x1f);
                if (seq == 0 or seq > 20) {
                    has_lfn = false;
                    continue;
                }
                if ((e[0] & 0x40) != 0) {
                    @memset(&lfn_buf, 0);
                    lfn_len = 0;
                    has_lfn = true;
                }
                if (has_lfn) {
                    const base_idx = (@as(usize, seq) - 1) * 13;
                    for (lfn_offsets, 0..) |off, k| {
                        const ch = std.mem.readInt(u16, e[off..][0..2], .little);
                        if (ch == 0x0000 or ch == 0xffff) break;
                        const pos = base_idx + k;
                        if (pos < lfn_buf.len) {
                            lfn_buf[pos] = @truncate(ch);
                            if (pos + 1 > lfn_len) lfn_len = pos + 1;
                        }
                    }
                }
                continue;
            }

            // Skip volume label
            if ((attr & 0x08) != 0) {
                has_lfn = false;
                lfn_len = 0;
                continue;
            }

            var short_buf: [12]u8 = undefined;
            const short_name = formatShortName(e[0..11], &short_buf);

            const matched = (has_lfn and std.ascii.eqlIgnoreCase(lfn_buf[0..lfn_len], target_name)) or
                std.ascii.eqlIgnoreCase(short_name, target_name);

            has_lfn = false;
            lfn_len = 0;

            if (matched) {
                const cluster_hi: u16 = if (kind == .fat32) std.mem.readInt(u16, e[20..22], .little) else 0;
                const cluster_lo = std.mem.readInt(u16, e[26..28], .little);
                const first_cluster = (@as(u32, cluster_hi) << 16) | cluster_lo;
                const file_size = std.mem.readInt(u32, e[28..32], .little);
                return .{
                    .is_dir = (attr & 0x10) != 0,
                    .first_cluster = first_cluster,
                    .file_size = file_size,
                };
            }
        }
        return error.FileNotFound;
    }

    fn formatShortName(raw: *const [11]u8, out: *[12]u8) []const u8 {
        const base = std.mem.trimEnd(u8, raw[0..8], " ");
        const ext = std.mem.trimEnd(u8, raw[8..11], " ");
        @memcpy(out[0..base.len], base);
        if (ext.len == 0) return out[0..base.len];
        out[base.len] = '.';
        @memcpy(out[base.len + 1 .. base.len + 1 + ext.len], ext);
        return out[0 .. base.len + 1 + ext.len];
    }
};

test "read FAT16 image with VFAT long filenames and nested directories" {
    const allocator = std.testing.allocator;
    // Build a minimal synthetic MBR + FAT16 image in memory
    const total_sectors = 2048 + 4200;
    const img = try allocator.alloc(u8, total_sectors * 512);
    defer allocator.free(img);
    @memset(img, 0);

    // MBR
    const entry = img[446..][0..16];
    entry[0] = 0x80;
    entry[4] = 0x0e;
    std.mem.writeInt(u32, entry[8..12], 2048, .little);
    std.mem.writeInt(u32, entry[12..16], 4200, .little);
    img[510] = 0x55;
    img[511] = 0xaa;

    // Boot sector at 2048
    const part = img[2048 * 512 ..];
    part[0] = 0xeb;
    part[1] = 0x3c;
    part[2] = 0x90;
    std.mem.writeInt(u16, part[11..13], 512, .little); // bps
    part[13] = 1; // spc
    std.mem.writeInt(u16, part[14..16], 1, .little); // reserved
    part[16] = 2; // fats
    std.mem.writeInt(u16, part[17..19], 512, .little); // root entries (32 sectors)
    std.mem.writeInt(u16, part[19..21], 4200, .little); // total sectors
    std.mem.writeInt(u16, part[22..24], 17, .little); // fat sectors
    @memcpy(part[54..62], "FAT16   ");
    part[510] = 0x55;
    part[511] = 0xaa;

    // FAT1 at sector 1: cluster 2 = EOF (0xffff)
    const fat1 = part[512..];
    std.mem.writeInt(u16, fat1[0..2], 0xfff8, .little);
    std.mem.writeInt(u16, fat1[2..4], 0xffff, .little);
    std.mem.writeInt(u16, fat1[4..6], 0xffff, .little); // cluster 2

    // Root dir at sector 1 + 2*17 = 35
    const root = part[35 * 512 ..];
    @memcpy(root[0..11], "CONFIG  TXT");
    root[11] = 0x20;
    std.mem.writeInt(u16, root[26..28], 2, .little); // cluster 2
    std.mem.writeInt(u32, root[28..32], 17, .little); // 17 bytes

    // Data area at sector 35 + 32 = 67 (cluster 2)
    const data = part[67 * 512 ..];
    @memcpy(data[0..17], "os_prefix=slot-a/");

    const fs = try FatFs.init(img);
    const content = try fs.readFileAlloc(allocator, "config.txt");
    defer allocator.free(content);
    try std.testing.expectEqualStrings("os_prefix=slot-a/", content);
}
