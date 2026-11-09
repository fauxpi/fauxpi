//! V3D feature tests of its control: control lists branching and calling sub-lists (in binning
//! and rendering), the threads' semaphores (rendering queued before binning), lists extended
//! while they run, Flush All State, interrupts, the binner running out of memory and taking
//! overspill blocks, performance counters, and the identity, scheduler, VPM and cache registers.

const std = @import("std");
const scene = @import("scene");
const hw = @import("hw.zig");
const gpu = @import("gpu.zig");
const main = @import("main.zig");
const features = @import("v3d_features.zig");

const Cl = gpu.Cl;
const Geo = features.Geo;
const reg = gpu.reg;
const Params = main.Params;
const Result = main.Result;

/// `n` overlapping triangles, depth-tested, in this frame's vertices.
fn triangles(g: *Geo, n: usize, seed0: u32) void {
    var seed = seed0;
    g.clear();
    const w: f32 = @floatFromInt(g.t.width);
    const h: f32 = @floatFromInt(g.t.height);
    for (0..n) |_| {
        const x = scene.rand(&seed) * w;
        const y = scene.rand(&seed) * h;
        _ = g.vertex(x, y, scene.rand(&seed), features.colour(&seed));
        _ = g.vertex(x + 160, y + 30, scene.rand(&seed), features.colour(&seed));
        _ = g.vertex(x + 50, y + 150, scene.rand(&seed), features.colour(&seed));
    }
}

pub fn control(p: Params, r: *Result) void {
    var g: Geo = .init(p);
    triangles(&g, 300, 81);
    const rec = g.record();
    const cfg = g.t.renderConfig();

    // Branches and sub-lists in the binning list: state in a sub-list (called twice, nested two
    // deep), primitives after a branch; the same in the rendering list's tiles.
    {
        var state: Cl = .init(64);
        state.config(.{ .depth_func = 1, .z_updates = true });
        state.glShaderState(rec, 2, false);
        state.returnFromSubList();
        var outer: Cl = .init(64);
        outer.branchToSubList(state.start());
        outer.returnFromSubList();
        var prims: Cl = .init(64);
        prims.arrays(.triangles, g.n / 2, 0);
        prims.branchToSubList(outer.start());
        prims.arrays(.triangles, g.n - g.n / 2, g.n / 2);
        prims.incrementSemaphore();
        prims.flush();
        g.bcl.reset();
        g.t.beginBinning(&g.bcl);
        g.bcl.branchToSubList(outer.start());
        g.bcl.branch(prims.start());
        // The binning list ends where `prims` does.
        const bins = hw.read(reg.bfc);
        hw.write(reg.ct0ca, g.bcl.start());
        hw.write(reg.ct0ea, prims.end());
        if (!gpu.waitCount(reg.bfc, bins)) {
            gpu.resetThreads();
            g.timeouts += 1;
        }
        g.renderTiles(.{ .config = cfg });
        r.add("bin_branches", g.t.checksum());
    }

    // Rendering queued first, waiting on the semaphore until binning (started after) is done.
    {
        g.bin({}, struct {
            fn draw(_: void, geo: *Geo, cl: *Cl) void {
                cl.config(.{ .depth_func = 1, .z_updates = true });
                cl.glShaderState(geo.record(), 2, false);
                cl.arrays(.triangles, geo.n, 0);
            }
        }.draw);
        g.rcl.reset();
        g.t.renderList(&g.rcl, .{ .config = cfg });
        const renders = hw.read(reg.rfc);
        const bins = hw.read(reg.bfc);
        hw.write(reg.ct1ca, g.rcl.start());
        hw.write(reg.ct1ea, g.rcl.end());
        // The rendering thread is waiting, at its semaphore.
        const waiting = hw.read(reg.ct1cs);
        hw.write(reg.ct0ca, g.bcl.start());
        hw.write(reg.ct0ea, g.bcl.end());
        const ok = gpu.waitCount(reg.bfc, bins) and gpu.waitCount(reg.rfc, renders);
        if (!ok) {
            gpu.resetThreads();
            g.timeouts += 1;
        }
        r.add("semaphore_order", g.t.checksum());
        r.add("ct1cs_waiting", waiting & 0x7030);
    }

    // A binning list run in three pieces, its end address moved on each time (after Flush All
    // State, not Flush).
    {
        g.bcl.reset();
        g.t.beginBinning(&g.bcl);
        g.bcl.config(.{ .depth_func = 1, .z_updates = true });
        g.bcl.glShaderState(rec, 2, false);
        const first = g.bcl.end();
        g.bcl.arrays(.triangles, g.n / 3 * 3 / 3, 0);
        const second = g.bcl.end();
        g.bcl.arrays(.triangles, g.n - g.n / 3 * 3 / 3, g.n / 3 * 3 / 3);
        g.bcl.incrementSemaphore();
        g.bcl.flushAllState();
        const bins = hw.read(reg.bfc);
        hw.write(reg.ct0ca, g.bcl.start());
        hw.write(reg.ct0ea, first);
        hw.timer.waitUntil(hw.timer.now() + 1000);
        hw.write(reg.ct0ea, second);
        hw.timer.waitUntil(hw.timer.now() + 1000);
        hw.write(reg.ct0ea, g.bcl.end());
        if (!gpu.waitCount(reg.bfc, bins)) {
            gpu.resetThreads();
            g.timeouts += 1;
        }
        g.renderTiles(.{ .config = cfg });
        r.add("extended_list", g.t.checksum());
    }

    // Interrupts: enabled, the frame's bits seen, cleared, then disabled.
    {
        hw.write(reg.intctl, 0xf);
        hw.write(reg.intena, 0xf);
        g.frame(r, "interrupt_frame", {}, struct {
            fn draw(_: void, geo: *Geo, cl: *Cl) void {
                cl.glShaderState(geo.record(), 2, false);
                cl.arrays(.triangles, geo.n, 0);
            }
        }.draw);
        r.add("intctl_after_frame", hw.read(reg.intctl) & 0xf);
        hw.write(reg.intctl, 0xf);
        r.add("intctl_cleared", hw.read(reg.intctl) & 0xf);
        r.add("intena", hw.read(reg.intena) & 0xf);
        hw.write(reg.intdis, 0xf);
        r.add("intena_disabled", hw.read(reg.intena) & 0xf);
        hw.write(reg.intctl, 0xf);
    }

    // The binner out of memory: a pool too small for the frame, more given (each overspill
    // block) as it asks, until it finishes.
    {
        triangles(&g, 3000, 82);
        const small = gpu.alloc(u8, 16384, 4096);
        g.bcl.reset();
        const n = g.t.tiles();
        g.bcl.binConfig(.{
            .tile_alloc = hw.bus(small.ptr),
            .tile_alloc_size = @intCast(small.len),
            .tile_state = hw.bus(g.t.tile_state.ptr),
            .width_tiles = @intCast(n[0]),
            .height_tiles = @intCast(n[1]),
        });
        g.bcl.startTileBinning();
        g.t.viewState(&g.bcl);
        g.bcl.config(.{ .depth_func = 1, .z_updates = true });
        g.bcl.glShaderState(g.record(), 2, false);
        g.bcl.arrays(.triangles, g.n, 0);
        g.bcl.incrementSemaphore();
        g.bcl.flush();
        hw.write(reg.bpoa, 0);
        hw.write(reg.bpos, 0);
        hw.write(reg.intctl, 0xf);
        const bins = hw.read(reg.bfc);
        hw.write(reg.ct0ca, g.bcl.start());
        hw.write(reg.ct0ea, g.bcl.end());
        var refills: u64 = 0;
        var spills: u64 = 0;
        const until = hw.timer.now() + gpu.timeout_us;
        while (hw.read(reg.bfc) & 0xff == bins & 0xff) {
            const ints = hw.read(reg.intctl);
            if (ints & gpu.int_spilluse != 0) {
                spills += 1;
                hw.write(reg.intctl, gpu.int_spilluse);
            }
            if (ints & gpu.int_outomem != 0 and hw.read(reg.bpos) == 0 and refills < 64) {
                const more = gpu.alloc(u8, 1 << 20, 4096);
                hw.write(reg.bpoa, hw.bus(more.ptr));
                hw.write(reg.bpos, @intCast(more.len));
                refills += 1;
                hw.write(reg.intctl, gpu.int_outomem);
            }
            if (hw.timer.now() > until) {
                gpu.resetThreads();
                g.timeouts += 1;
                break;
            }
        }
        // Rendered from the small pool's tile lists (and the overspill blocks they chain to).
        g.rcl.reset();
        g.rcl.clearColors(0xff000000_ff000000, 0xffffff, 0, 0);
        g.rcl.renderConfig(cfg);
        for (0..n[1]) |ty| {
            for (0..n[0]) |tx| {
                g.rcl.tileCoordinates(@intCast(tx), @intCast(ty));
                g.rcl.branchToSubList(hw.bus(small.ptr) + @as(u32, @intCast(ty * n[0] + tx)) * 32);
                g.rcl.storeMsResolved(ty + 1 == n[1] and tx + 1 == n[0]);
            }
        }
        if (!gpu.run(null, &g.rcl)) g.timeouts += 1;
        r.add("out_of_memory", g.t.checksum());
        r.add("overspill_refills", refills);
        r.add("spill_interrupts", spills);
        r.add("bpca_bpcs_nonzero", @intFromBool(hw.read(reg.bpca) != 0) + @as(u64, @intFromBool(hw.read(reg.bpcs) != 0)));
    }

    // Performance counters: all 16, mapped to each source in turn, over a frame.
    {
        triangles(&g, 300, 83);
        var sum: u64 = 0;
        var nonzero: u64 = 0;
        for (0..2) |round| {
            hw.write(reg.pctrc, 0xffff);
            for (0..16) |c| hw.write(reg.pctrs(@intCast(c)), @intCast(c + round * 14));
            hw.write(reg.pctre, 0x8000ffff);
            g.frame(r, if (round == 0) "counted_frame_a" else "counted_frame_b", {}, struct {
                fn draw(_: void, geo: *Geo, cl: *Cl) void {
                    cl.config(.{ .depth_func = 1, .z_updates = true });
                    cl.glShaderState(geo.record(), 2, false);
                    cl.arrays(.triangles, geo.n, 0);
                }
            }.draw);
            for (0..16) |c| {
                const v = hw.read(reg.pctr(@intCast(c)));
                sum +%= v;
                nonzero += @intFromBool(v != 0);
            }
            hw.write(reg.pctre, 0);
        }
        r.add("counters_nonzero", nonzero);
        r.add("counters_sum", sum);
    }

    // Registers: identity, scratch, scheduler, VPM and cache control, and status.
    hw.write(reg.scratch, 0x12345678);
    r.add("scratch", hw.read(reg.scratch));
    r.add("ident0", hw.read(reg.ident0));
    r.add("ident1", hw.read(reg.ident1));
    r.add("ident2", hw.read(reg.ident2));
    hw.write(reg.sqrsv0, 0x00000000);
    hw.write(reg.sqrsv1, 0x11111111);
    r.add("sqrsv1", hw.read(reg.sqrsv1));
    hw.write(reg.sqrsv1, 0);
    hw.write(reg.sqcntl, 0x5);
    r.add("sqcntl", hw.read(reg.sqcntl) & 0xf);
    hw.write(reg.vpacntl, 0x3000);
    r.add("vpacntl", hw.read(reg.vpacntl) & 0x3fff);
    hw.write(reg.vpacntl, 0);
    hw.write(reg.l2cactl, 1 << 2);
    hw.write(reg.slcactl, 0x0f0f0f0f);
    r.add("l2cactl", hw.read(reg.l2cactl) & 1);
    r.add("errstat", hw.read(reg.errstat));
    r.add("pcs", hw.read(reg.pcs) & 0x1ff);
    r.add("timeouts", g.timeouts);
}
