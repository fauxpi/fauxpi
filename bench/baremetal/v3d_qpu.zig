//! V3D feature tests of the QPU's instruction set (the guide's section 3), run as fragment
//! shaders: each group (every add and mul op; regfile A and r4 unpacks; regfile A and mul packs;
//! conditions and flags; branches; small immediates; vector rotation; the SFU; load immediates;
//! special registers; threads; semaphores and the mutex) draws a band of the frame from each
//! fragment's coordinates, reported by its checksum.

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

const groups = std.enums.values(programs.AluGroup);

const Ctx = struct {
    recs: [groups.len]u32,

    fn draw(ctx: *const Ctx, _: *Geo, cl: *Cl) void {
        for (ctx.recs, 0..) |rec, i| {
            cl.glShaderState(rec, 2, false);
            cl.arrays(.triangles, 6, @intCast(i * 6));
        }
    }
};

pub fn qpu(p: Params, r: *Result) void {
    var g: Geo = .init(p);
    const w: f32 = @floatFromInt(g.t.width);
    const band = @as(f32, @floatFromInt(g.t.height)) / @as(f32, @floatFromInt(groups.len));
    var ctx: Ctx = undefined;
    const list = gpu.words(&.{ 0xcafef00d, 0x0badf00d });
    for (groups, 0..) |group, i| {
        const y0 = band * @as(f32, @floatFromInt(i));
        for ([6][2]f32{ .{ 0, y0 }, .{ w, y0 }, .{ 0, y0 + band }, .{ w, y0 }, .{ w, y0 + band }, .{ 0, y0 + band } }) |c| {
            _ = g.vertex4(c[0], c[1], 0.5, 1, .{ 0, 0, 0, 0 });
        }
        const fs = gpu.upload(programs.aluFragmentShader(group).code());
        const unifs = gpu.words(&.{ 0x12345678, list });
        var rec = gpu.GlRecord{
            .single_threaded = group != .threads,
            .fs_varyings = 0,
            .fs_code = fs,
            .fs_unifs = unifs,
            .vs_attr_mask = 0b01,
            .vs_attr_size = 16,
            .vs_code = g.vs[0],
            .vs_unifs = g.unifs,
            .cs_attr_mask = 0b01,
            .cs_attr_size = 16,
            .cs_code = g.cs,
            .cs_unifs = g.unifs,
            .attrs = &.{.{ .addr = hw.bus(g.pos.ptr), .bytes = 16, .stride = 16 }},
        };
        ctx.recs[i] = rec.write();
        rec = rec;
    }
    g.frame(r, "frame", &ctx, Ctx.draw);
    for (groups, 0..) |group, i| {
        const y0: u32 = @intFromFloat(band * @as(f32, @floatFromInt(i)));
        const y1: u32 = @intFromFloat(band * @as(f32, @floatFromInt(i + 1)));
        r.add(@tagName(group), gpu.checksum(g.t.fb[y0 * g.t.width * 4 .. y1 * g.t.width * 4]));
    }
    r.add("timeouts", g.timeouts);
}
