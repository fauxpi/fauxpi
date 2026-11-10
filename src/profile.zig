//! Where FauxPi spends its time, for benchmarking (`--profile <file>`): the host time in each stage
//! of emulating the GPU and the display, and counts of what they did, written as JSON when FauxPi
//! exits. Off unless asked for, when a stage costs a branch.

const std = @import("std");
const host_posix = @import("host/posix.zig");

pub const Stage = enum {
    /// The binning control list run (V3D's draws read).
    v3d_bin,
    /// Vertices shaded on the CPU (`qpu_sim`), and their triangles binned into tiles.
    v3d_vertex_shade,
    v3d_tile_bin,
    /// A frame drawn with its vertices shaded on the GPU, all of it.
    v3d_gpu_vertices_frame,
    /// A frame drawn on the GPU with its vertices shaded on the CPU (after `v3d_vertex_shade`).
    v3d_gpu_frame,
    /// A frame drawn on the CPU, tile by tile.
    v3d_cpu_frame,
    /// Parts of the GPU frames: tiles loaded into the frame and stored from it on the CPU, shaders
    /// translated and compiled, vertices gathered for the GPU, shaded there, the frame drawn, and
    /// read back (waiting for the GPU).
    gpu_load_tiles,
    gpu_store_tiles,
    gpu_programs,
    gpu_gather_vertices,
    /// Of gathering them: whether the clipper cuts triangles (their clip coordinates, from the
    /// coordinate shader), and the primitives made on the CPU (lines, points, and triangles cut).
    gpu_clip_test,
    gpu_cpu_primitives,
    gpu_shade_vertices,
    /// Of shading them: the vertices read back, for the layers (`gpu_layers`) of triangles
    /// reading the tile's colour, each layer's triangles not overlapping.
    gpu_vertex_read_back,
    gpu_layers,
    gpu_draw,
    gpu_read_back,
    /// Textures decoded from RAM (and uploaded).
    gpu_textures,
    /// The display composed from the HVS's planes, and checked for changes.
    hvs_compose,
    hvs_hash,
};

pub const Counter = enum {
    frames_gpu_vertices,
    frames_gpu,
    frames_cpu,
    draws,
    triangles,
    blended_triangles,
    layers,
    textures_decoded,
    display_frames,
    /// Frames whose vertices couldn't be shaded on the GPU, by why: lines or points (or NV or
    /// VG), a triangle the clipper cuts, a shader too long or untranslatable, too many vertices or
    /// draws, or no triangles.
    gpu_vertices_no_triangles,
    gpu_vertices_not_triangles,
    gpu_vertices_clipped,
    gpu_vertices_shaders,
    gpu_vertices_too_many,
    gpu_vertices_render,
    /// Primitives of frames shaded on the GPU made on the CPU instead (lines, points, triangles
    /// the clipper cuts).
    cpu_primitives,
};

pub var enabled: bool = false;

const stage_count = @typeInfo(Stage).@"enum".field_names.len;
const counter_count = @typeInfo(Counter).@"enum".field_names.len;
var stage_ns: [stage_count]std.atomic.Value(u64) = @splat(.init(0));
var stage_calls: [stage_count]std.atomic.Value(u64) = @splat(.init(0));
var counters: [counter_count]std.atomic.Value(u64) = @splat(.init(0));

pub fn now() u64 {
    if (!enabled) return 0;
    return host_posix.monotonicNs();
}

/// A stage timed from `start` (`now()`'s) until now.
pub fn end(stage: Stage, start: u64) void {
    if (!enabled) return;
    const i = @backingInt(stage);
    _ = stage_ns[i].fetchAdd(now() -| start, .monotonic);
    _ = stage_calls[i].fetchAdd(1, .monotonic);
}

pub fn count(counter: Counter, n: u64) void {
    if (!enabled) return;
    _ = counters[@backingInt(counter)].fetchAdd(n, .monotonic);
}

/// What the whole run was: host time, and the guest's time and instructions.
pub const Run = struct {
    wall_ns: u64,
    guest_us: u64,
    instructions: u64,
};

/// The report, as JSON.
pub fn write(w: *std.Io.Writer, run: Run) std.Io.Writer.Error!void {
    try w.print("{{\n  \"wall_ms\": {d:.3},\n  \"guest_ms\": {d:.3},\n  \"instructions\": {d},\n", .{
        @as(f64, @floatFromInt(run.wall_ns)) / 1e6,
        @as(f64, @floatFromInt(run.guest_us)) / 1e3,
        run.instructions,
    });
    try w.writeAll("  \"stages\": {");
    for (0..stage_count) |i| {
        try w.print("{s}\n    \"{s}\": {{ \"ms\": {d:.3}, \"calls\": {d} }}", .{
            if (i == 0) "" else ",",
            @tagName(@as(Stage, @fromBackingInt(@intCast(i)))),
            @as(f64, @floatFromInt(stage_ns[i].load(.monotonic))) / 1e6,
            stage_calls[i].load(.monotonic),
        });
    }
    try w.writeAll("\n  },\n  \"counters\": {");
    for (0..counter_count) |i| {
        try w.print("{s}\n    \"{s}\": {d}", .{ if (i == 0) "" else ",", @tagName(@as(Counter, @fromBackingInt(@intCast(i)))), counters[i].load(.monotonic) });
    }
    try w.writeAll("\n  }\n}\n");
}

test "the report lists every stage and counter" {
    enabled = true;
    defer enabled = false;
    const t = now();
    end(.hvs_compose, t);
    count(.triangles, 3);
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(&w, .{ .wall_ns = 2_000_000, .guest_us = 1500, .instructions = 7 });
    const json = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"hvs_compose\": { \"ms\": ") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"triangles\": 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"guest_ms\": 1.500") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    parsed.deinit();
}
