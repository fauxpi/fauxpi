//! Builds the SD card image: an MBR partition table with one bootable FAT16
//! partition holding the given files, named by their paths in it (in
//! directories: "slot-a/zImage"), with long (VFAT) file names. No root, loop
//! devices or filesystem tools needed, and the output is the same for the
//! same inputs.
//!
//! Usage: mkimage <output.img> <size in MiB, or "auto"> [--grow-to=<MiB>] <name>=<file> ...
//!
//! The partition starts at 1 MiB and fills the rest of the image. "auto"
//! makes the image just big enough for the files, with some room to spare
//! (a quarter more, and at least 1 MiB), in whole MiB. The Pi's boot ROM
//! and firmware read FAT16, which suits a partition this small (FAT32
//! needs at least 65525 clusters, 32 MiB of 512-byte ones). Clusters are
//! one 512-byte sector, or as many as keep the partition within FAT16's
//! 65524 clusters.
//!
//! --grow-to makes a partition that can grow on the card to end at that
//! many MiB, by changing only its length in the partition table and its
//! boot sector (init does, on the first start): its clusters, FATs and
//! root directory are sized for the bigger partition, so the image stays
//! small and nothing in it moves.

const std = @import("std");

const sector = 512;
const part_start = 2048;
const reserved_sectors = 1;
const num_fats = 2;
/// FAT16's limits on the number of clusters.
const min_clusters = 4085;
const max_clusters = 65524;
/// 2026-01-01, 00:00, for every timestamp.
const fat_date: u16 = (2026 - 1980) << 9 | 1 << 5 | 1;

const File = struct { name: []const u8, data: []const u8 };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        std.debug.print("usage: mkimage <output.img> <size in MiB, or auto> [--grow-to=<MiB>] <name>=<file> ...\n", .{});
        std.process.exit(2);
    }
    var size: Size = .{ .mib = if (std.mem.eql(u8, args[2], "auto")) null else try std.fmt.parseInt(u32, args[2], 10) };
    const cwd = std.Io.Dir.cwd();
    var files: std.ArrayList(File) = .empty;
    for (args[3..]) |spec| {
        if (std.mem.startsWith(u8, spec, "--grow-to=")) {
            size.grow_mib = try std.fmt.parseInt(u32, spec["--grow-to=".len..], 10);
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, spec, '=') orelse return error.BadArgument;
        try files.append(arena, .{
            .name = spec[0..eq],
            .data = try cwd.readFileAlloc(init.io, spec[eq + 1 ..], arena, .limited(256 << 20)),
        });
    }
    const image = try build(arena, size, files.items);
    const out = try cwd.createFile(init.io, args[1], .{});
    defer out.close(init.io);
    try out.writeStreamingAll(init.io, image);
}

fn put16(b: []u8, at: usize, v: u16) void {
    std.mem.writeInt(u16, b[at..][0..2], v, .little);
}

fn put32(b: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], v, .little);
}

/// A file or directory in the partition.
const Node = struct {
    name: []const u8,
    /// A file's contents; null for a directory.
    data: ?[]const u8 = null,
    children: std.ArrayList(*Node) = .empty,
    /// A directory's entries: the volume label (the root's), or "." and
    /// ".." (a subdirectory's), then each child's long name parts and 8.3
    /// entry.
    entries: std.ArrayList([32]u8) = .empty,
    /// Where each child's 8.3 entry is.
    child_entry: std.ArrayList(usize) = .empty,
    first_cluster: u32 = 0,

    fn isDir(n: *const Node) bool {
        return n.data == null;
    }

    /// The directory `path` names under `n`, made if it is not there.
    fn dir(n: *Node, gpa: std.mem.Allocator, path: []const u8) !*Node {
        var at = n;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |part| at = for (at.children.items) |c| {
            if (c.isDir() and std.mem.eql(u8, c.name, part)) break c;
        } else blk: {
            const c = try gpa.create(Node);
            c.* = .{ .name = part };
            try at.children.append(gpa, c);
            break :blk c;
        };
        return at;
    }

    /// The tree of `files` (named by their paths).
    fn tree(gpa: std.mem.Allocator, files: []const File) !*Node {
        const root = try gpa.create(Node);
        root.* = .{ .name = "" };
        for (files) |f| {
            const slash = std.mem.lastIndexOfScalar(u8, f.name, '/');
            const parent = if (slash) |s| try root.dir(gpa, f.name[0..s]) else root;
            const leaf = if (slash) |s| f.name[s + 1 ..] else f.name;
            const c = try gpa.create(Node);
            c.* = .{ .name = leaf, .data = f.data };
            try parent.children.append(gpa, c);
        }
        return root;
    }

    /// Makes this directory's entries (and its subdirectories').
    fn makeEntries(n: *Node, gpa: std.mem.Allocator, root: bool) !void {
        if (root) {
            var label: [32]u8 = @splat(0);
            @memcpy(label[0..11], "DAZZLE     ");
            label[11] = 0x08; // volume label
            try n.entries.append(gpa, label);
        } else for ([_][]const u8{ ".          ", "..         " }) |dots| {
            var e: [32]u8 = @splat(0);
            @memcpy(e[0..11], dots);
            e[11] = 0x10;
            put16(&e, 16, fat_date);
            put16(&e, 18, fat_date);
            put16(&e, 24, fat_date);
            try n.entries.append(gpa, e);
        }
        var shorts: std.ArrayList([11]u8) = .empty;
        for (n.children.items) |c| {
            const short = shortName(c.name, shorts.items);
            try shorts.append(gpa, short);
            try appendLongName(gpa, &n.entries, c.name, short);
            try n.child_entry.append(gpa, n.entries.items.len);
            var e: [32]u8 = @splat(0);
            @memcpy(e[0..11], &short);
            e[11] = if (c.isDir()) 0x10 else 0x20; // directory, or archive
            put16(&e, 16, fat_date); // created
            put16(&e, 18, fat_date); // accessed
            put16(&e, 24, fat_date); // written
            if (c.data) |d| put32(&e, 28, @intCast(d.len));
            try n.entries.append(gpa, e);
            if (c.isDir()) try c.makeEntries(gpa, false);
        }
    }

    /// Root directory entries: room for these (at least the usual 512),
    /// filling whole sectors.
    fn rootEntries(n: *const Node) u32 {
        return @intCast(@max(512, std.mem.alignForward(usize, n.entries.items.len, sector / 32)));
    }

    /// What this node's clusters hold: a file's contents, or a
    /// subdirectory's entries.
    fn bytes(n: *const Node) []const u8 {
        return n.data orelse std.mem.sliceAsBytes(n.entries.items);
    }

    /// Every file's and subdirectory's size, rounded up to `unit`.
    fn dataSize(n: *const Node, unit: u64) u64 {
        var total: u64 = 0;
        for (n.children.items) |c| {
            total += std.mem.alignForward(u64, @max(c.bytes().len, @as(usize, if (c.isDir()) 1 else 0)), unit);
            if (c.isDir()) total += c.dataSize(unit);
        }
        return total;
    }
};

/// Where everything goes in a partition of `part_sectors`.
const Layout = struct {
    sectors_per_cluster: u32,
    fat_sectors: u32,
    root_sectors: u32,
    clusters: u32,

    fn plan(part_sectors: u32, root_entries: u32) !Layout {
        const root_sectors = root_entries * 32 / sector;
        var spc: u32 = 1;
        while (spc <= 64) : (spc *= 2) {
            // FAT size: enough 2-byte entries for every cluster that remains.
            var fat_sectors: u32 = 1;
            var clusters: u32 = 0;
            while (true) {
                const meta = reserved_sectors + num_fats * fat_sectors + root_sectors;
                if (meta >= part_sectors) return error.ImageTooSmall;
                clusters = (part_sectors - meta) / spc;
                const needed = std.math.divCeil(u32, (clusters + 2) * 2, sector) catch unreachable;
                if (needed <= fat_sectors) break;
                fat_sectors = needed;
            }
            if (clusters > max_clusters) continue;
            if (clusters < min_clusters) return error.ImageTooSmall;
            return .{ .sectors_per_cluster = spc, .fat_sectors = fat_sectors, .root_sectors = root_sectors, .clusters = clusters };
        }
        return error.ImageTooBig;
    }

    /// A partition of `part_sectors` laid out as one of `grow_sectors` is,
    /// so that it can grow to that.
    fn growable(part_sectors: u32, grow_sectors: u32, root_entries: u32) !Layout {
        var l = try plan(grow_sectors, root_entries);
        if (part_sectors > grow_sectors) return error.ImageBiggerThanGrowth;
        if (part_sectors <= l.dataStart()) return error.ImageTooSmall;
        l.clusters = (part_sectors - l.dataStart()) / l.sectors_per_cluster;
        // Fewer would make it FAT12.
        if (l.clusters < min_clusters) return error.ImageTooSmall;
        return l;
    }

    fn dataStart(l: Layout) u32 {
        return reserved_sectors + num_fats * l.fat_sectors + l.root_sectors;
    }

    fn clusterBytes(l: Layout) u32 {
        return l.sectors_per_cluster * sector;
    }
};

/// The image's size: in MiB, or (null) just big enough; and, if it is
/// to grow on the card, where its partition is to end.
pub const Size = struct { mib: ?u32 = null, grow_mib: ?u32 = null };

/// The size, in MiB, of an image just big enough for `root`'s files (with
/// some room to spare), laid out for a partition to grow to `grow`.
fn autoSizeGrowable(root: *const Node, grow: Layout) u32 {
    const data = root.dataSize(grow.clusterBytes());
    const room = @max(data / 4, 1 << 20);
    const clusters = @max(std.math.divCeil(u64, data + room, grow.clusterBytes()) catch unreachable, min_clusters + 16);
    const total = part_start + grow.dataStart() + clusters * grow.sectors_per_cluster;
    return @intCast(std.math.divCeil(u64, total, 2048) catch unreachable);
}

/// The size, in MiB, of an image just big enough for `root`'s files (with
/// some room to spare).
fn autoSize(root: *const Node, root_entries: u32) u32 {
    const data = root.dataSize(sector);
    const room = @max(data / 4, 1 << 20);
    // At least FAT16's least clusters.
    const data_sectors = @max((data + room) / sector, min_clusters + 16);
    const fat_sectors = std.math.divCeil(u64, (data_sectors + 2) * 2, sector) catch unreachable;
    const total = part_start + reserved_sectors + num_fats * fat_sectors + root_entries * 32 / sector + data_sectors;
    return @intCast(std.math.divCeil(u64, total, 2048) catch unreachable);
}

/// The image, as big as `size` says. Files are named by their paths:
/// "slot-a/zImage" is in the directory "slot-a".
pub fn build(gpa: std.mem.Allocator, size: Size, files: []const File) ![]u8 {
    const root = try Node.tree(gpa, files);
    try root.makeEntries(gpa, true);
    const root_entries = root.rootEntries();
    const grow: ?Layout = if (size.grow_mib) |g| blk: {
        if (g * 2048 <= part_start) return error.ImageTooSmall;
        break :blk try Layout.plan(g * 2048 - part_start, root_entries);
    } else null;
    const mib = size.mib orelse if (grow) |g| autoSizeGrowable(root, g) else autoSize(root, root_entries);
    const total_sectors = mib * 2048;
    if (total_sectors <= part_start) return error.ImageTooSmall;
    const part_sectors = total_sectors - part_start;
    const l = if (size.grow_mib) |g| try Layout.growable(part_sectors, g * 2048 - part_start, root_entries) else try Layout.plan(part_sectors, root_entries);
    if (root.dataSize(l.clusterBytes()) > @as(u64, l.clusters) * l.clusterBytes()) return error.ImageFull;

    const image = try gpa.alloc(u8, @as(usize, total_sectors) * sector);
    @memset(image, 0);
    const part = image[part_start * sector ..];

    // --- MBR ---
    put32(image, 440, 0x53544152); // disk signature
    const entry = image[446..][0..16];
    entry[0] = 0x80; // bootable
    entry[1..4].* = .{ 0xfe, 0xff, 0xff }; // CHS unused: LBA only
    entry[4] = 0x0e; // FAT16 (LBA)
    entry[5..8].* = .{ 0xfe, 0xff, 0xff };
    put32(entry, 8, part_start);
    put32(entry, 12, part_sectors);
    image[510] = 0x55;
    image[511] = 0xaa;

    // --- Clusters: each file's and subdirectory's, contiguously ---
    // The whole FAT, free past the partition's clusters (room to grow).
    const fat = try gpa.alloc(u16, l.fat_sectors * sector / 2);
    @memset(fat, 0);
    fat[0] = 0xfff8;
    fat[1] = 0xffff;
    var alloc: Allocation = .{ .fat = fat, .end = l.clusters + 2, .cluster_bytes = l.clusterBytes() };
    try alloc.place(root);
    // Then what each holds, now that every first cluster is known.
    alloc.fill(root, 0);
    for (root.children.items) |c| writeTree(part, l, c);

    // --- FATs, and the root directory after them ---
    for (0..num_fats) |k| {
        const at = (reserved_sectors + k * l.fat_sectors) * sector;
        for (fat, 0..) |v, c| put16(part, at + c * 2, v);
    }
    const root_at = (reserved_sectors + num_fats * l.fat_sectors) * sector;
    @memcpy(part[root_at..][0 .. root.entries.items.len * 32], std.mem.sliceAsBytes(root.entries.items));

    // --- Boot sector ---
    const bs = part[0..sector];
    bs[0..3].* = .{ 0xeb, 0x3c, 0x90 };
    @memcpy(bs[3..11], "DAZZLE  ");
    put16(bs, 11, sector);
    bs[13] = @intCast(l.sectors_per_cluster);
    put16(bs, 14, reserved_sectors);
    bs[16] = num_fats;
    put16(bs, 17, @intCast(root_entries));
    if (part_sectors < 65536) put16(bs, 19, @intCast(part_sectors)) else put32(bs, 32, part_sectors);
    bs[21] = 0xf8; // fixed disk
    put16(bs, 22, @intCast(l.fat_sectors));
    put16(bs, 24, 63); // sectors per track (for old BIOSes only)
    put16(bs, 26, 255); // heads
    put32(bs, 28, part_start); // hidden sectors before the partition
    bs[36] = 0x80; // drive number
    bs[38] = 0x29; // extended boot signature
    put32(bs, 39, 0x53544152); // volume ID
    @memcpy(bs[43..54], "DAZZLE     ");
    @memcpy(bs[54..62], "FAT16   ");
    bs[510] = 0x55;
    bs[511] = 0xaa;
    return image;
}

/// Gives each file and subdirectory its clusters, in order.
const Allocation = struct {
    fat: []u16,
    /// Past the last cluster.
    end: u32,
    cluster_bytes: u32,
    next: u32 = 2,

    fn place(a: *Allocation, dir: *Node) !void {
        for (dir.children.items) |c| {
            const len = c.bytes().len;
            // A directory has a cluster even if it were empty.
            const n: u32 = @intCast(@max(std.math.divCeil(usize, len, a.cluster_bytes) catch unreachable, @as(usize, if (c.isDir()) 1 else 0)));
            if (n > 0) {
                if (a.next + n > a.end) return error.ImageFull;
                c.first_cluster = a.next;
                for (0..n) |k| {
                    const cl = a.next + @as(u32, @intCast(k));
                    a.fat[cl] = if (k + 1 == n) 0xffff else @intCast(cl + 1);
                }
                a.next += n;
            }
            if (c.isDir()) try a.place(c);
        }
    }

    /// Puts the first clusters in the entries: each child's, and a
    /// subdirectory's own (".") and its parent's ("..", 0 for the root).
    fn fill(a: *Allocation, dir: *Node, parent_cluster: u32) void {
        if (dir.first_cluster != 0) {
            put16(&dir.entries.items[0], 26, @intCast(dir.first_cluster));
            put16(&dir.entries.items[1], 26, @intCast(parent_cluster));
        }
        for (dir.children.items, dir.child_entry.items) |c, at| {
            put16(&dir.entries.items[at], 26, @intCast(c.first_cluster));
            if (c.isDir()) a.fill(c, dir.first_cluster);
        }
    }
};

/// Writes a file's contents, or a subdirectory's entries (and what is in
/// it), into its clusters.
fn writeTree(part: []u8, l: Layout, n: *const Node) void {
    const b = n.bytes();
    if (n.first_cluster != 0) {
        const at = (@as(usize, l.dataStart()) + (n.first_cluster - 2) * l.sectors_per_cluster) * sector;
        @memcpy(part[at..][0..b.len], b);
    }
    if (n.isDir()) for (n.children.items) |c| writeTree(part, l, c);
}

/// An 8.3 name: the name itself in capitals if it fits, otherwise the first
/// letters of the name, ~N, and the extension's first letters.
fn shortName(name: []const u8, taken: []const [11]u8) [11]u8 {
    var out: [11]u8 = @splat(' ');
    const dot = std.mem.lastIndexOfScalar(u8, name, '.');
    const base = if (dot) |d| name[0..d] else name;
    const ext = if (dot) |d| name[d + 1 ..] else "";
    const valid = struct {
        fn f(c: u8) bool {
            return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "!#$%&'()-@^_`{}~", c) != null;
        }
    }.f;
    var fits = base.len >= 1 and base.len <= 8 and ext.len <= 3;
    for (base) |c| fits = fits and valid(c);
    for (ext) |c| fits = fits and valid(c);
    for (ext, 0..) |c, i| if (i < 3 and valid(c)) {
        out[8 + i] = std.ascii.toUpper(c);
    };
    if (fits) {
        for (base, 0..) |c, i| out[i] = std.ascii.toUpper(c);
        return out;
    }
    var stem: [6]u8 = undefined;
    var n: usize = 0;
    for (base) |c| if (n < 6 and valid(c)) {
        stem[n] = std.ascii.toUpper(c);
        n += 1;
    };
    var k: u8 = 1;
    while (true) : (k += 1) {
        var candidate = out;
        @memcpy(candidate[0..n], stem[0..n]);
        candidate[n] = '~';
        candidate[n + 1] = '0' + k;
        for (taken) |t| {
            if (std.mem.eql(u8, &t, &candidate)) break;
        } else return candidate;
    }
}

fn shortChecksum(short: [11]u8) u8 {
    var sum: u8 = 0;
    for (short) |c| sum = (sum >> 1 | (sum & 1) << 7) +% c;
    return sum;
}

/// The long-name entries for `name`, last part first, as FAT stores them.
fn appendLongName(gpa: std.mem.Allocator, entries: *std.ArrayList([32]u8), name: []const u8, short: [11]u8) !void {
    const parts = std.math.divCeil(usize, name.len + 1, 13) catch unreachable; // with the terminating NUL
    const offsets = [13]usize{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
    var p = parts;
    while (p > 0) : (p -= 1) {
        var e: [32]u8 = @splat(0);
        e[0] = @intCast(p);
        if (p == parts) e[0] |= 0x40; // the last part
        e[11] = 0x0f; // long name
        e[13] = shortChecksum(short);
        for (offsets, 0..) |off, k| {
            const idx = (p - 1) * 13 + k;
            const ch: u16 = if (idx < name.len) name[idx] else if (idx == name.len) 0 else 0xffff;
            put16(&e, off, ch);
        }
        try entries.append(gpa, e);
    }
}

test "short names" {
    try std.testing.expectEqualStrings("CONFIG  TXT", &shortName("config.txt", &.{}));
    try std.testing.expectEqualStrings("ZIMAGE     ", &shortName("zImage", &.{}));
    try std.testing.expectEqualStrings("BCM283~1DTB", &shortName("bcm2835-rpi-zero.dtb", &.{}));
    try std.testing.expectEqualStrings("BCM283~2DTB", &shortName("bcm2835-rpi-zero-w.dtb", &.{"BCM283~1DTB".*}));
    try std.testing.expectEqualStrings("LICENC~1BRO", &shortName("LICENCE.broadcom", &.{}));
}

test "an image has a valid partition and boot sector, and is as big as it needs" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const files = [_]File{
        .{ .name = "config.txt", .data = "hello\n" },
        .{ .name = "bcm2835-rpi-zero-w.dtb", .data = &(@as([1500]u8, @splat(7))) },
    };
    // Small files: FAT16's least clusters (2 MiB of them), and the 1 MiB
    // before the partition.
    const img = try build(arena.allocator(), .{}, &files);
    try std.testing.expectEqual(@as(usize, 4 << 20), img.len);
    try std.testing.expectEqual(@as(u8, 0x0e), img[446 + 4]);
    const part = img[part_start * sector ..];
    try std.testing.expectEqualStrings("FAT16   ", part[54..62]);
    try std.testing.expectEqual(@as(u8, 1), part[13]);
    // 9 MB of files: a quarter more, in whole MiB.
    const big = try arena.allocator().alloc(u8, 9_000_000);
    const sized = try build(arena.allocator(), .{}, &.{.{ .name = "initramfs.cpio", .data = big }});
    try std.testing.expectEqual(@as(usize, 12 << 20), sized.len);
    // A size given, too big for 512-byte clusters: bigger clusters.
    const fixed = try build(arena.allocator(), .{ .mib = 64 }, &files);
    try std.testing.expectEqual(@as(usize, 64 << 20), fixed.len);
    try std.testing.expectEqual(@as(u8, 2), fixed[part_start * sector + 13]);
    try std.testing.expectError(error.ImageTooSmall, build(arena.allocator(), .{ .mib = 2 }, &files));
}

test "files in directories, nested" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const files = [_]File{
        .{ .name = "config.txt", .data = "os_prefix=slot-a/\n" },
        .{ .name = "slot-a/zImage", .data = "kernel a" },
        .{ .name = "slot-b/zImage", .data = "kernel b" },
        .{ .name = "apps/dazzle-demo/dazzle-demo", .data = "demo" },
        .{ .name = "apps/dazzle-demo/NOTICES", .data = "notices" },
    };
    const img = try build(arena.allocator(), .{}, &files);
    const part = img[part_start * sector ..];
    const fat_sectors = std.mem.readInt(u16, part[22..24], .little);
    const root_entries = std.mem.readInt(u16, part[17..19], .little);
    const root_at = (reserved_sectors + num_fats * @as(usize, fat_sectors)) * sector;
    const fs: Fs = .{ .part = part, .data_at = root_at + @as(usize, root_entries) * 32, .spc = part[13] };
    const root = part[root_at..fs.data_at];
    // slot-b/zImage: a directory in the root, a file in it.
    const slot_b = Fs.find(root, "SLOT-B     ").?;
    try std.testing.expectEqual(@as(u8, 0x10), slot_b[11]);
    const in_b = fs.cluster(slot_b);
    // ".", then "..", then the file (its long name, then its 8.3 entry).
    try std.testing.expectEqualStrings(".          ", in_b[0..11]);
    try std.testing.expectEqual(std.mem.readInt(u16, slot_b[26..28], .little), std.mem.readInt(u16, in_b[26..28], .little));
    try std.testing.expectEqualStrings("..         ", in_b[32..43]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, in_b[32 + 26 ..][0..2], .little));
    const kernel = Fs.find(in_b, "ZIMAGE     ").?;
    try std.testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, kernel[28..32], .little));
    try std.testing.expectEqualStrings("kernel b", fs.cluster(kernel)[0..8]);
    // Nested: apps/dazzle-demo/NOTICES, whose ".." is apps.
    const apps = Fs.find(root, "APPS       ").?;
    const demo_dir = Fs.find(fs.cluster(apps), "DAZZLE~1   ").?;
    const in_demo = fs.cluster(demo_dir);
    try std.testing.expectEqual(std.mem.readInt(u16, apps[26..28], .little), std.mem.readInt(u16, in_demo[32 + 26 ..][0..2], .little));
    try std.testing.expectEqualStrings("notices", fs.cluster(Fs.find(in_demo, "NOTICES    ").?)[0..7]);
    try std.testing.expectEqualStrings("demo", fs.cluster(Fs.find(in_demo, "DAZZLE~1   ").?)[0..4]);
}

/// Reading an image back, for the tests.
const Fs = struct {
    part: []const u8,
    data_at: usize,
    spc: usize,

    /// The 8.3 entry named `short` in a directory's entries.
    fn find(entries: []const u8, short: []const u8) ?[]const u8 {
        var i: usize = 0;
        while (i + 32 <= entries.len) : (i += 32) {
            const e = entries[i..][0..32];
            if (e[0] == 0) return null;
            if (e[11] != 0x0f and std.mem.eql(u8, e[0..11], short)) return e;
        }
        return null;
    }

    /// The first cluster of what an entry names.
    fn cluster(f: Fs, e: []const u8) []const u8 {
        const c = std.mem.readInt(u16, e[26..28], .little);
        return f.part[f.data_at + (c - 2) * f.spc * sector ..][0 .. f.spc * sector];
    }
};

test "an image that can grow: small, laid out for the bigger partition" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const files = [_]File{
        .{ .name = "config.txt", .data = "os_prefix=slot-a/\n" },
        .{ .name = "slot-a/zImage", .data = "kernel" },
    };
    const img = try build(arena.allocator(), .{ .grow_mib = 128 }, &files);
    const part = img[part_start * sector ..];
    const big = try Layout.plan(128 * 2048 - part_start, 512);
    // The bigger partition's clusters (2 KiB) and FATs...
    try std.testing.expectEqual(@as(u8, 4), part[13]);
    try std.testing.expectEqual(big.fat_sectors, std.mem.readInt(u16, part[22..24], .little));
    // ...in an image just big enough for FAT16's least clusters of them.
    try std.testing.expectEqual(@as(usize, 10 << 20), img.len);
    const part_sectors = std.mem.readInt(u32, img[446 + 12 ..][0..4], .little);
    try std.testing.expectEqual(@as(u32, 10 * 2048 - part_start), part_sectors);
    try std.testing.expectEqual(part_sectors, std.mem.readInt(u16, part[19..21], .little));
    // Clusters past the partition's are free.
    const fat_at = reserved_sectors * sector;
    const clusters = (part_sectors - big.dataStart()) / 4;
    try std.testing.expect(clusters >= min_clusters);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, part[fat_at + (clusters + 2) * 2 ..][0..2], .little));
    // Not bigger than it is to grow to.
    try std.testing.expectError(error.ImageBiggerThanGrowth, build(arena.allocator(), .{ .mib = 200, .grow_mib = 128 }, &files));
}
