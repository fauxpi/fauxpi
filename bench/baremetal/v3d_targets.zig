//! V3D feature tests of the tile buffer and what frames are stored to: every colour format and
//! memory layout, general stores and loads (colour, depth and stencil, depth alone, the VG mask,
//! full dumps), full-resolution stores and reloads, stores not clearing the tile buffer, the
//! 64-bit (HDR) tile buffer, double-buffering, 16x decimation, the clear values, and the
//! binner's tile allocation block sizes.

const std = @import("std");
const scene = @import("scene");
const hw = @import("hw.zig");
const gpu = @import("gpu.zig");
const main = @import("main.zig");
const features = @import("v3d_features.zig");

const programs = scene.programs;
const Cl = gpu.Cl;
const Geo = features.Geo;
const Params = main.Params;
const Result = main.Result;

/// Overlapping triangles, depth-tested.
fn drawScene(seed0: u32, g: *Geo, cl: *Cl) void {
    var seed = seed0;
    g.clear();
    const w: f32 = @floatFromInt(g.t.width);
    const h: f32 = @floatFromInt(g.t.height);
    for (0..120) |_| {
        const x = scene.rand(&seed) * w;
        const y = scene.rand(&seed) * h;
        _ = g.vertex(x, y, scene.rand(&seed), features.colour(&seed));
        _ = g.vertex(x + 220, y + 40, scene.rand(&seed), features.colour(&seed));
        _ = g.vertex(x + 60, y + 190, scene.rand(&seed), features.colour(&seed));
    }
    cl.config(.{ .depth_func = 1, .z_updates = true });
    cl.glShaderState(g.record(), 2, false);
    cl.arrays(.triangles, g.n, 0);
}

/// What the tiles' extra loads and stores use (the callbacks have no context of their own).
var store: Cl.General = .{ .buffer = .color };
var store_addr: u32 = 0;
var load: Cl.General = .{ .buffer = .color };
var load_addr: u32 = 0;
/// Where each tile's full-resolution dump goes: 16 KiB a tile, in rows of tiles.
var dump_base: u32 = 0;
var dump_tiles_w: u32 = 0;

fn dumpAddr(x: u32, y: u32) u32 {
    return dump_base + (y * dump_tiles_w + x) * 16384;
}

/// Each tile stored with `store` (the last ending the frame).
fn storeGeneralAfter(_: *const gpu.Target, cl: *Cl, _: u32, _: u32, last: bool) void {
    var g = store;
    g.last = last;
    cl.storeGeneral(g, store_addr);
}

/// Each tile stored with `store` (keeping the tile buffer) then resolved to the framebuffer.
fn storeThenResolve(_: *const gpu.Target, cl: *Cl, x: u32, y: u32, last: bool) void {
    var g = store;
    g.disable_color_clear = true;
    g.disable_zs_clear = true;
    g.disable_vg_clear = true;
    cl.storeGeneral(g, store_addr);
    cl.tileCoordinates(@intCast(x), @intCast(y));
    cl.storeMsResolved(last);
}

fn loadBefore(_: *const gpu.Target, cl: *Cl, _: u32, _: u32) void {
    cl.loadGeneral(load, load_addr);
}

/// Each tile dumped at full resolution (keeping it), then resolved.
fn fullResThenResolve(_: *const gpu.Target, cl: *Cl, x: u32, y: u32, last: bool) void {
    cl.storeFullRes(dumpAddr(x, y), .{ .disable_clear = true });
    cl.tileCoordinates(@intCast(x), @intCast(y));
    cl.storeMsResolved(last);
}

fn fullResBefore(_: *const gpu.Target, cl: *Cl, x: u32, y: u32) void {
    cl.loadFullRes(dumpAddr(x, y), .{});
}

pub fn tileBuffer(p: Params, r: *Result) void {
    var g: Geo = .init(p);
    const base_cfg = g.t.renderConfig();
    const fb_bytes = g.t.fb.len;
    const side = gpu.alloc(u8, fb_bytes, 4096);
    const side2 = gpu.alloc(u8, fb_bytes, 4096);
    const tiles = g.t.tiles();
    dump_tiles_w = tiles[0];
    const dump = gpu.alloc(u8, tiles[0] * tiles[1] * 16384 * 2, 4096);
    dump_base = hw.bus(dump.ptr);

    // Every colour format in every memory layout.
    const names = [3][3][]const u8{
        .{ "bgr565_dither_raster", "bgr565_dither_t", "bgr565_dither_lt" },
        .{ "rgba8888_raster", "rgba8888_t", "rgba8888_lt" },
        .{ "bgr565_raster", "bgr565_t", "bgr565_lt" },
    };
    g.bin(@as(u32, 71), drawScene);
    _ = gpu.run(&g.bcl, null);
    for (0..3) |f| {
        for (0..3) |m| {
            var cfg = base_cfg;
            cfg.format = @intCast(f);
            cfg.mem_format = @fromBackingInt(@intCast(m));
            @memset(g.t.fb, 0);
            g.renderTiles(.{ .config = cfg });
            r.add(names[f][m], gpu.checksum(g.t.fb));
        }
    }

    // General colour stores: T-format RGBA8888, dithered BGR565 raster, and 2x2 decimated.
    const general = [_]struct { name: []const u8, g: Cl.General }{
        .{ .name = "general_t", .g = .{ .buffer = .color, .format = .t } },
        .{ .name = "general_565_dither", .g = .{ .buffer = .color, .pixel = .bgr565_dithered } },
        .{ .name = "general_decimate4", .g = .{ .buffer = .color, .decimate = .x4 } },
    };
    for (general) |gs| {
        @memset(side, 0);
        store = gs.g;
        store_addr = hw.bus(side.ptr);
        g.renderTiles(.{ .config = base_cfg, .after = storeGeneralAfter });
        r.add(gs.name, gpu.checksum(side));
    }

    // Depth and stencil stored, then loaded into another frame's tile buffer, which draws more
    // tested against them; depth alone stored.
    @memset(side, 0);
    store = .{ .buffer = .zs };
    store_addr = hw.bus(side.ptr);
    g.renderTiles(.{ .config = base_cfg, .after = storeThenResolve });
    g.bin(@as(u32, 72), drawScene);
    _ = gpu.run(&g.bcl, null);
    load = .{ .buffer = .zs };
    load_addr = hw.bus(side.ptr);
    g.renderTiles(.{ .config = base_cfg, .before = loadBefore });
    r.add("zs_store_load", gpu.checksum(g.t.fb) ^ gpu.checksum(side));
    @memset(side2, 0);
    store = .{ .buffer = .z };
    store_addr = hw.bus(side2.ptr);
    g.renderTiles(.{ .config = base_cfg, .after = storeThenResolve });
    r.add("z_store", gpu.checksum(side2));

    // Full resolution: dumped, then reloaded under more drawing; and the general full dump and
    // reload.
    @memset(dump, 0);
    g.renderTiles(.{ .config = base_cfg, .after = fullResThenResolve });
    r.add("full_res_store", gpu.checksum(dump));
    g.renderTiles(.{ .config = base_cfg, .before = fullResBefore });
    r.add("full_res_reload", gpu.checksum(g.t.fb));
    @memset(side, 0);
    store = .{ .buffer = .full };
    store_addr = hw.bus(side.ptr);
    g.renderTiles(.{ .config = base_cfg, .after = storeThenResolve });
    r.add("full_dump", gpu.checksum(side));
    load = .{ .buffer = .full };
    load_addr = hw.bus(side.ptr);
    g.renderTiles(.{ .config = base_cfg, .before = loadBefore });
    r.add("full_reload", gpu.checksum(g.t.fb));

    // Stores that leave the tile buffer as it is: each tile starts with the last one's contents.
    store = .{ .buffer = .color, .disable_color_clear = true, .disable_zs_clear = true };
    store_addr = hw.bus(g.t.fb.ptr);
    g.renderTiles(.{ .config = base_cfg, .after = storeGeneralAfter });
    r.add("no_clear", gpu.checksum(g.t.fb));

    // The VG mask buffer: written by the shader, stored.
    {
        const fs = gpu.upload(programs.alphaMaskFragmentShader().code());
        const Vg = struct {
            fn draw(rec_fs: u32, geo: *Geo, cl: *Cl) void {
                drawScene(73, geo, cl);
                cl.glShaderState(geo.recordWith(rec_fs, gpu.words(&.{}), 3, .{}), 2, false);
                cl.arrays(.triangles, geo.n, 0);
            }
        };
        g.bin(fs, Vg.draw);
        _ = gpu.run(&g.bcl, null);
        var cfg = base_cfg;
        cfg.vg_mask = true;
        @memset(side, 0);
        store = .{ .buffer = .vg_mask };
        store_addr = hw.bus(side.ptr);
        g.renderTiles(.{ .config = cfg, .clear_vg_mask = 0x33, .after = storeThenResolve });
        r.add("vg_mask", gpu.checksum(side) ^ gpu.checksum(g.t.fb));
    }

    // Clear values (colour, depth, stencil, VG mask) as a full dump has them.
    @memset(side, 0);
    store = .{ .buffer = .full };
    store_addr = hw.bus(side.ptr);
    g.renderTiles(.{ .config = base_cfg, .binned = false, .clear_color = 0x80112233_80445566, .clear_z = 0x123456, .clear_stencil = 0x5a, .clear_vg_mask = 0xa5, .after = storeGeneralAfter });
    r.add("clear_values", gpu.checksum(side));

    // Tile allocation block sizes: the same frame binned with initial and later blocks of 32 to
    // 256 bytes.
    for ([_][2]u2{ .{ 0, 3 }, .{ 3, 0 }, .{ 2, 1 } }, [_][]const u8{ "blocks_32_256", "blocks_256_32", "blocks_128_64" }) |b, name| {
        g.t.initial_block_size = b[0];
        g.t.block_size = b[1];
        g.frame(r, name, @as(u32, 74), drawScene);
    }
    g.t.initial_block_size = 0;
    g.t.block_size = 0;

    // Double-buffered (not multisampled) tiles.
    g.t.double_buffer = true;
    g.frame(r, "double_buffer", @as(u32, 75), drawScene);
    g.t.double_buffer = false;

    // The 64-bit tile buffer: half-height tiles, 16-bit float colours (two writes), cleared to a
    // 16-bit float colour, stored converted, and dumped as it is.
    {
        const hdr_fs = gpu.upload(programs.hdrFragmentShader().code());
        const Hdr = struct {
            fn draw(fs: u32, geo: *Geo, cl: *Cl) void {
                drawScene(76, geo, cl);
                cl.glShaderState(geo.recordWith(fs, gpu.words(&.{}), 3, .{}), 2, false);
                cl.arrays(.triangles, geo.n, 0);
            }
        };
        g.t.hdr = true;
        g.bin(hdr_fs, Hdr.draw);
        _ = gpu.run(&g.bcl, null);
        // Red 0.25, green 0.5, blue 0.75, alpha 1, as 16-bit floats.
        const clear: u64 = 0x3c00_3a00_3800_3400;
        g.renderTiles(.{ .config = g.t.renderConfig(), .clear_color = clear });
        r.add("hdr", g.t.checksum());
        @memset(dump, 0);
        dump_tiles_w = g.t.tiles()[0];
        g.renderTiles(.{ .config = g.t.renderConfig(), .clear_color = clear, .after = fullResThenResolve });
        r.add("hdr_dump", gpu.checksum(dump));
        g.t.hdr = false;
        dump_tiles_w = tiles[0];
    }

    // Multisampled, stored decimated 16x (each 4x4 pixels' samples averaged).
    {
        g.t.msaa = true;
        g.bin(@as(u32, 77), drawScene);
        _ = gpu.run(&g.bcl, null);
        @memset(side, 0);
        store = .{ .buffer = .color, .decimate = .x16 };
        store_addr = hw.bus(side.ptr);
        g.renderTiles(.{ .config = g.t.renderConfig(), .after = storeGeneralAfter });
        r.add("decimate16", gpu.checksum(side));
        g.t.msaa = false;
    }
    r.add("timeouts", g.timeouts);
}
