//! Draws V3D frames with Metal, on macOS. Metal shades the vertices (each vertex shader translated
//! to a kernel by `qpu_to_shader.zig`), culls the triangles, rasterizes them and runs the fragment
//! shaders (translated too), into a copy of the tile buffer as big as the framebuffer, which kernels
//! load from and store to the guest's RAM. The guest's RAM is a Metal buffer, not a copy, so the
//! shaders read textures where the guest wrote them. Frames with a vertex shader Metal can't run are
//! shaded on the CPU, as V3D does, and Metal draws them.

const std = @import("std");
const builtin = @import("builtin");
const kete = @import("kete");
const objc = kete.gfx.objc;
const qpu = @import("qpu.zig");
const qpu_sim = @import("qpu_sim.zig");
const msl = @import("qpu_to_shader.zig");
const gpu_draw = @import("gpu_draw.zig");

const Id = objc.Id;
const msg = objc.msg;

pub const supported = builtin.os.tag == .macos;

pub const Vertex = gpu_draw.Vertex;
pub const Draw = gpu_draw.Draw;

/// What a draw's fragment shader is given besides its uniforms (MSL `DrawInfo`).
const DrawInfo = extern struct {
    n_var: u32,
    ram_len: u32,
    ram_mask: u32,
    pad: u32 = 0,
};

/// What a vertex shader's kernel is given (MSL `VertexInfo`).
const VertexInfo = extern struct {
    n_vpm: u32,
    n_var: u32,
    first_input: u32,
    stride: u32,
    count: u32,
    first_vertex: u32,
    vp_x: f32,
    vp_y: f32,
};

/// What `cull_triangles` is given (MSL `CullInfo`).
const CullInfo = extern struct {
    first_corner: u32,
    triangles: u32,
    first_vertex: u32,
    cull: u32,
};

/// What `ls_load` and `ls_store` are given (MSL `LoadStore`).
const LoadStore = extern struct {
    base: u32,
    fb_w: u32,
    fb_h: u32,
    tiling: u32,
    cpp: u32,
    ram_len: u32,
    pad: [2]u32 = @splat(0),
    tiles: [32]u32,
};

/// Where a framebuffer is in RAM, as a tile load or store has it.
pub const Surface = struct {
    /// The offset in RAM.
    base: u32,
    /// 0 for linear, otherwise tiled (T or LT, by size).
    tiling: u2,
    /// 4 for RGBA8888, 2 for RGB565.
    cpp: u32,
};

/// A frame as the RCL describes it.
pub const Frame = struct {
    width: u32,
    height: u32,
    clear_color: u32,
    clear_z: f32,
    /// What the tile buffer starts as, if not the clear colour.
    load: ?Surface,
    store: Surface,
    /// The tiles stored (bit `x` of `tiles[y]`).
    tiles: [32]u32,
};

pub const Error = error{ Unsupported, MetalFailed };

const max_draws = gpu_draw.max_draws;
pub const max_vertices = gpu_draw.max_vertices;
const pixel_r32uint: u64 = 53;
const pixel_depth32: u64 = 252;
const primitive_triangle: u64 = 3;

pub const Renderer = struct {
    device: Id,
    queue: Id,
    shared_lib: Id,
    vertex_fn: Id,
    load_pipe: Id,
    store_pipe: Id,
    cull_pipe: Id = null,
    /// Whether fragment shaders can read the tile's colour (framebuffer fetch: Apple GPUs).
    framebuffer_fetch: bool,
    vertices: Id,
    vertices_cap: usize = 0,
    uniforms: Id,
    /// The frame's vertices' VPM words, its triangles' corners, and the corners drawn.
    inputs: Id = null,
    inputs_cap: usize = 0,
    corners: Id = null,
    corners_cap: usize = 0,
    indices: Id = null,
    indices_cap: usize = 0,
    vertex_programs: [32]VertexProgram = @splat(.{}),
    next_vertex_program: usize = 0,
    /// The guest's RAM, as a buffer.
    ram_buf: Id = null,
    ram_ptr: ?[*]u8 = null,
    ram_len: usize = 0,
    color: Id = null,
    depth: Id = null,
    width: u32 = 0,
    height: u32 = 0,
    /// The depth tests, by V3D function and whether depth is written.
    depth_states: [16]Id = @splat(null),
    programs: [64]Program = @splat(.{}),
    next_program: usize = 0,

    /// A vertex shader's kernel (or the shader not shading on Metal: `pipeline` null).
    const VertexProgram = struct {
        hash: u64 = 0,
        used: bool = false,
        pipeline: Id = null,
    };

    /// A fragment shader's pipeline (or the shader not drawing on Metal: `pipeline` null).
    const Program = struct {
        hash: u64 = 0,
        used: bool = false,
        pipeline: Id = null,
        reads_color: bool = false,
    };

    pub fn init() Error!Renderer {
        if (!supported) return error.Unsupported;
        objc.load() catch return error.Unsupported;
        const pool = objc.push();
        defer objc.pop(pool);
        const create = objc.symbol(*const fn () callconv(.c) Id, "MTLCreateSystemDefaultDevice") orelse return error.Unsupported;
        const device = create() orelse return error.Unsupported;
        var r: Renderer = .{
            .device = device,
            .queue = null,
            .shared_lib = null,
            .vertex_fn = null,
            .load_pipe = null,
            .store_pipe = null,
            // MTLGPUFamilyApple1.
            .framebuffer_fetch = msg(objc.Bool, device, "supportsFamily:", .{@as(u64, 1001)}) != 0,
            .vertices = null,
            .uniforms = null,
        };
        errdefer r.deinit();
        r.queue = msg(Id, device, "newCommandQueue", .{}) orelse return error.MetalFailed;
        r.shared_lib = try r.compile(msl.msl_common ++ msl.msl_shared_functions);
        r.vertex_fn = msg(Id, r.shared_lib, "newFunctionWithName:", .{objc.nsString("vertex_main")}) orelse return error.MetalFailed;
        r.load_pipe = try r.computePipeline("ls_load");
        r.store_pipe = try r.computePipeline("ls_store");
        r.cull_pipe = try r.computePipeline("cull_triangles");
        r.vertices = msg(Id, device, "newBufferWithLength:options:", .{ @as(u64, max_vertices * @sizeOf(Vertex)), @as(u64, 0) }) orelse return error.MetalFailed;
        r.vertices_cap = max_vertices * @sizeOf(Vertex);
        r.uniforms = msg(Id, device, "newBufferWithLength:options:", .{ @as(u64, max_draws * msl.max_uniforms * 4), @as(u64, 0) }) orelse return error.MetalFailed;
        return r;
    }

    pub fn deinit(r: *Renderer) void {
        for (r.programs) |p| objc.release(p.pipeline);
        for (r.vertex_programs) |p| objc.release(p.pipeline);
        for ([_]Id{ r.inputs, r.corners, r.indices, r.cull_pipe }) |o| objc.release(o);
        for (r.depth_states) |s| objc.release(s);
        for ([_]Id{ r.color, r.depth, r.ram_buf, r.uniforms, r.vertices, r.store_pipe, r.load_pipe, r.vertex_fn, r.shared_lib, r.queue, r.device }) |o| objc.release(o);
        r.* = undefined;
    }

    fn compile(r: *Renderer, source: []const u8) Error!Id {
        const opts = objc.new(objc.class("MTLCompileOptions"));
        defer objc.release(opts);
        // The shaders compute what the CPU path does, bit for bit where they can.
        msg(void, opts, "setFastMathEnabled:", .{objc.no});
        var err: Id = null;
        const lib = msg(Id, r.device, "newLibraryWithSource:options:error:", .{ objc.nsString(source), opts, &err });
        if (lib == null) {
            logError("compiling shaders", err);
            return error.MetalFailed;
        }
        return lib;
    }

    fn computePipeline(r: *Renderer, name: [:0]const u8) Error!Id {
        return r.kernel(r.shared_lib, name);
    }

    fn kernel(r: *Renderer, lib: Id, name: [:0]const u8) Error!Id {
        const func = msg(Id, lib, "newFunctionWithName:", .{objc.nsString(name)}) orelse return error.MetalFailed;
        defer objc.release(func);
        var err: Id = null;
        const pipe = msg(Id, r.device, "newComputePipelineStateWithFunction:error:", .{ func, &err });
        if (pipe == null) {
            logError("making a kernel", err);
            return error.MetalFailed;
        }
        return pipe;
    }

    fn logError(what: []const u8, err: Id) void {
        const desc = if (err != null) objc.utf8(msg(Id, err, "localizedDescription", .{})) else "";
        std.debug.print("fauxpi: V3D on Metal: {s} failed: {s}\n", .{ what, desc });
    }

    /// Whether the guest's RAM can be a buffer: Metal wants it page-aligned.
    fn useRam(r: *Renderer, ram: []u8) Error!void {
        if (r.ram_ptr == ram.ptr and r.ram_len == ram.len) return;
        objc.release(r.ram_buf);
        r.ram_buf = null;
        r.ram_ptr = null;
        const page = std.heap.pageSize();
        if (@intFromPtr(ram.ptr) % page != 0 or ram.len % page != 0) return error.Unsupported;
        if (ram.len > msg(u64, r.device, "maxBufferLength", .{})) return error.Unsupported;
        r.ram_buf = msg(Id, r.device, "newBufferWithBytesNoCopy:length:options:deallocator:", .{
            @as(*anyopaque, ram.ptr), @as(u64, ram.len), @as(u64, 0), @as(?*anyopaque, null),
        }) orelse return error.Unsupported;
        r.ram_ptr = ram.ptr;
        r.ram_len = ram.len;
    }

    fn useSize(r: *Renderer, width: u32, height: u32) Error!void {
        if (r.color != null and r.width == width and r.height == height) return;
        objc.release(r.color);
        objc.release(r.depth);
        r.color = null;
        r.depth = null;
        // ShaderRead | ShaderWrite | RenderTarget, on the GPU only.
        r.color = r.texture(pixel_r32uint, width, height, 7) orelse return error.MetalFailed;
        r.depth = r.texture(pixel_depth32, width, height, 4) orelse return error.MetalFailed;
        r.width = width;
        r.height = height;
    }

    fn texture(r: *Renderer, format: u64, width: u32, height: u32, usage: u64) Id {
        const desc = msg(Id, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
            format, @as(u64, width), @as(u64, height), objc.no,
        });
        msg(void, desc, "setUsage:", .{usage});
        msg(void, desc, "setStorageMode:", .{@as(u64, 2)}); // Private
        return msg(Id, r.device, "newTextureWithDescriptor:", .{desc});
    }

    fn depthState(r: *Renderer, func: u3, write: bool) Id {
        const i = @as(usize, func) * 2 + @intFromBool(write);
        if (r.depth_states[i] == null) {
            const desc = objc.new(objc.class("MTLDepthStencilDescriptor"));
            defer objc.release(desc);
            msg(void, desc, "setDepthCompareFunction:", .{@as(u64, func)});
            msg(void, desc, "setDepthWriteEnabled:", .{if (write) objc.yes else objc.no});
            r.depth_states[i] = msg(Id, r.device, "newDepthStencilStateWithDescriptor:", .{desc});
        }
        return r.depth_states[i];
    }

    /// `buf` (of `cap` bytes) at least `len` bytes, made again bigger if it isn't.
    fn ensureBuffer(r: *Renderer, buf: *Id, cap: *usize, len: usize) Error!void {
        if (buf.* != null and cap.* >= len) return;
        objc.release(buf.*);
        buf.* = null;
        cap.* = 0;
        const size = @max(len, 64 * 1024);
        if (size > msg(u64, r.device, "maxBufferLength", .{})) return error.Unsupported;
        buf.* = msg(Id, r.device, "newBufferWithLength:options:", .{ @as(u64, size), @as(u64, 0) }) orelse return error.MetalFailed;
        cap.* = size;
    }

    /// The kernel shading a vertex shader's vertices, translated and compiled the first time it
    /// shades (null if Metal can't shade them as qpu_sim does).
    fn vertexProgram(r: *Renderer, code: []const qpu.Inst) ?*const VertexProgram {
        const hash = std.hash.Wyhash.hash(1, std.mem.sliceAsBytes(code));
        for (&r.vertex_programs) |*p| {
            if (p.used and p.hash == hash) return if (p.pipeline != null) p else null;
        }
        const slot = &r.vertex_programs[r.next_vertex_program];
        r.next_vertex_program = (r.next_vertex_program + 1) % r.vertex_programs.len;
        objc.release(slot.pipeline);
        slot.* = .{ .hash = hash, .used = true };

        var decoded_buf: [gpu_draw.max_program_len]qpu_sim.DecodedInst = undefined;
        if (code.len > decoded_buf.len) return null;
        const decoded = qpu_sim.decodeProgram(code, &decoded_buf);
        var src: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer src.deinit();
        src.writer.writeAll(msl.msl_common) catch return null;
        const vs = msl.translateVertex(&src.writer, decoded, .msl) catch return null;
        if (vs.unsupported) return null;
        const lib = r.compile(src.written()) catch return null;
        defer objc.release(lib);
        slot.pipeline = r.kernel(lib, "vertex_shade") catch return null;
        return slot;
    }

    /// The pipeline for a fragment shader, translated and compiled the first time it is drawn with
    /// (null if it can't be drawn on Metal).
    fn program(r: *Renderer, code: []const qpu.Inst) ?*const Program {
        const hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(code));
        for (&r.programs) |*p| {
            if (p.used and p.hash == hash) return if (p.pipeline != null) p else null;
        }
        const slot = &r.programs[r.next_program];
        r.next_program = (r.next_program + 1) % r.programs.len;
        objc.release(slot.pipeline);
        slot.* = .{ .hash = hash, .used = true };

        var decoded_buf: [gpu_draw.max_program_len]qpu_sim.DecodedInst = undefined;
        if (code.len > decoded_buf.len) return null;
        const decoded = qpu_sim.decodeProgram(code, &decoded_buf);
        var src: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer src.deinit();
        src.writer.writeAll(msl.msl_common) catch return null;
        const shader = msl.translate(&src.writer, decoded, .msl) catch return null;
        if (shader.too_many_uniforms or shader.unsupported or (shader.reads_color and !r.framebuffer_fetch)) return null;

        const lib = r.compile(src.written()) catch return null;
        defer objc.release(lib);
        const frag = msg(Id, lib, "newFunctionWithName:", .{objc.nsString("fragment_main")}) orelse return null;
        defer objc.release(frag);
        const desc = objc.new(objc.class("MTLRenderPipelineDescriptor"));
        defer objc.release(desc);
        msg(void, desc, "setVertexFunction:", .{r.vertex_fn});
        msg(void, desc, "setFragmentFunction:", .{frag});
        msg(void, desc, "setDepthAttachmentPixelFormat:", .{pixel_depth32});
        const att = msg(Id, msg(Id, desc, "colorAttachments", .{}), "objectAtIndexedSubscript:", .{@as(u64, 0)});
        msg(void, att, "setPixelFormat:", .{pixel_r32uint});
        var err: Id = null;
        slot.pipeline = msg(Id, r.device, "newRenderPipelineStateWithDescriptor:error:", .{ desc, &err });
        if (slot.pipeline == null) {
            logError("making a pipeline", err);
            return null;
        }
        slot.reads_color = shader.reads_color;
        return slot;
    }

    /// Draws `frame`: loads (or clears) the tile buffer, draws `draws` of `vertices` into it, and
    /// stores it to RAM, waiting until it is done. Draws with a vertex stage (all of them, or none)
    /// shade their vertices from `inputs` (`vertices` unused), and make triangles of them by
    /// `corners`. An error before anything is drawn (`error.Unsupported`: a shader Metal can't
    /// run, or RAM it can't use) leaves RAM as it was, for the CPU to draw the frame.
    pub fn render(r: *Renderer, ram: []u8, frame: *const Frame, vertices: []const Vertex, draws: []const Draw, inputs: []const u32, corners: []const u32) Error!void {
        if (draws.len > max_draws or vertices.len > max_vertices) return error.Unsupported;
        const shaded_on_gpu = draws.len > 0 and draws[0].vertex_stage != null;
        for (draws) |d| if ((d.vertex_stage != null) != shaded_on_gpu) return error.Unsupported;
        if (ram.len > std.math.maxInt(u32)) return error.Unsupported;
        const pool = objc.push();
        defer objc.pop(pool);
        try r.useRam(ram);
        try r.useSize(frame.width, frame.height);

        // The shaders first: one Metal can't run sends the frame to the CPU.
        var pipelines: [max_draws]Id = undefined;
        var vertex_pipelines: [max_draws]Id = undefined;
        var vertex_total: usize = 0;
        for (draws, 0..) |d, i| {
            const p = r.program(d.code) orelse return error.Unsupported;
            pipelines[i] = p.pipeline;
            if (d.vertex_stage) |vs| {
                const vp = r.vertexProgram(vs.code) orelse return error.Unsupported;
                vertex_pipelines[i] = vp.pipeline;
                vertex_total = @max(vertex_total, @as(usize, d.first_vertex) + d.vertex_count);
            }
        }

        if (shaded_on_gpu) {
            try r.ensureBuffer(&r.vertices, &r.vertices_cap, vertex_total * @sizeOf(Vertex));
            try r.ensureBuffer(&r.inputs, &r.inputs_cap, inputs.len * 4);
            try r.ensureBuffer(&r.corners, &r.corners_cap, corners.len * 4);
            try r.ensureBuffer(&r.indices, &r.indices_cap, corners.len * 4);
            const idst: [*]u32 = @ptrCast(@alignCast(msg(*anyopaque, r.inputs, "contents", .{})));
            @memcpy(idst[0..inputs.len], inputs);
            const cdst: [*]u32 = @ptrCast(@alignCast(msg(*anyopaque, r.corners, "contents", .{})));
            @memcpy(cdst[0..corners.len], corners);
        } else {
            const vdst: [*]Vertex = @ptrCast(@alignCast(msg(*anyopaque, r.vertices, "contents", .{})));
            @memcpy(vdst[0..vertices.len], vertices);
        }
        const udst: [*][msl.max_uniforms]u32 = @ptrCast(@alignCast(msg(*anyopaque, r.uniforms, "contents", .{})));
        for (draws, 0..) |d, i| udst[i] = d.uniforms.*;

        const cmd = msg(Id, r.queue, "commandBuffer", .{}) orelse return error.MetalFailed;
        const ram_len: u32 = @intCast(ram.len);
        const groups: MtlSize = .{ .width = (frame.width + 7) / 8, .height = (frame.height + 7) / 8, .depth = 1 };
        const group: MtlSize = .{ .width = 8, .height = 8, .depth = 1 };

        if (frame.load) |l| {
            const ls: LoadStore = .{ .base = l.base, .fb_w = frame.width, .fb_h = frame.height, .tiling = l.tiling, .cpp = l.cpp, .ram_len = ram_len, .tiles = frame.tiles };
            const enc = msg(Id, cmd, "computeCommandEncoder", .{}) orelse return error.MetalFailed;
            msg(void, enc, "setComputePipelineState:", .{r.load_pipe});
            msg(void, enc, "setTexture:atIndex:", .{ r.color, @as(u64, 0) });
            msg(void, enc, "setBuffer:offset:atIndex:", .{ r.ram_buf, @as(u64, 0), @as(u64, 0) });
            msg(void, enc, "setBytes:length:atIndex:", .{ @as(*const anyopaque, &ls), @as(u64, @sizeOf(LoadStore)), @as(u64, 1) });
            msg(void, enc, "dispatchThreadgroups:threadsPerThreadgroup:", .{ groups, group });
            msg(void, enc, "endEncoding", .{});
        }

        if (shaded_on_gpu) {
            // Each draw's vertices shaded, then its triangles culled, as V3D does.
            const enc = msg(Id, cmd, "computeCommandEncoder", .{}) orelse return error.MetalFailed;
            // Each run of draws shading alike in one dispatch (`gpu_draw.shadeRun`).
            var first: usize = 0;
            while (first < draws.len) {
                const run = gpu_draw.shadeRun(draws, first);
                const i = first;
                const d = draws[first];
                first = run.end;
                const vs = d.vertex_stage.?;
                if (run.vertices == 0) continue;
                const info: VertexInfo = .{
                    .n_vpm = vs.vpm_words,
                    .n_var = @min(d.num_varyings, msl.max_varyings),
                    .first_input = vs.first_input,
                    .stride = vs.input_stride,
                    .count = run.vertices,
                    .first_vertex = d.first_vertex,
                    .vp_x = vs.vp_x,
                    .vp_y = vs.vp_y,
                };
                msg(void, enc, "setComputePipelineState:", .{vertex_pipelines[i]});
                msg(void, enc, "setBuffer:offset:atIndex:", .{ r.inputs, @as(u64, 0), @as(u64, 0) });
                msg(void, enc, "setBuffer:offset:atIndex:", .{ r.vertices, @as(u64, 0), @as(u64, 1) });
                msg(void, enc, "setBytes:length:atIndex:", .{ @as(*const anyopaque, vs.uniforms), @as(u64, msl.max_uniforms * 4), @as(u64, 2) });
                msg(void, enc, "setBytes:length:atIndex:", .{ @as(*const anyopaque, &info), @as(u64, @sizeOf(VertexInfo)), @as(u64, 3) });
                msg(void, enc, "dispatchThreadgroups:threadsPerThreadgroup:", .{ MtlSize{ .width = (run.vertices + 63) / 64, .height = 1, .depth = 1 }, MtlSize{ .width = 64, .height = 1, .depth = 1 } });
            }
            // The culling reads every draw's vertices once they are all shaded.
            msg(void, enc, "memoryBarrierWithScope:", .{@as(u64, 1)}); // MTLBarrierScopeBuffers
            msg(void, enc, "setComputePipelineState:", .{r.cull_pipe});
            msg(void, enc, "setBuffer:offset:atIndex:", .{ r.corners, @as(u64, 0), @as(u64, 0) });
            msg(void, enc, "setBuffer:offset:atIndex:", .{ r.vertices, @as(u64, 0), @as(u64, 1) });
            msg(void, enc, "setBuffer:offset:atIndex:", .{ r.indices, @as(u64, 0), @as(u64, 2) });
            for (draws) |d| {
                const vs = d.vertex_stage.?;
                const triangles = vs.corner_count / 3;
                if (triangles == 0) continue;
                const info: CullInfo = .{ .first_corner = vs.first_corner, .triangles = triangles, .first_vertex = d.first_vertex, .cull = vs.cull };
                msg(void, enc, "setBytes:length:atIndex:", .{ @as(*const anyopaque, &info), @as(u64, @sizeOf(CullInfo)), @as(u64, 3) });
                msg(void, enc, "dispatchThreadgroups:threadsPerThreadgroup:", .{ MtlSize{ .width = (triangles + 63) / 64, .height = 1, .depth = 1 }, MtlSize{ .width = 64, .height = 1, .depth = 1 } });
            }
            msg(void, enc, "endEncoding", .{});
        }

        {
            const pass = msg(Id, objc.class("MTLRenderPassDescriptor"), "renderPassDescriptor", .{});
            const att = msg(Id, msg(Id, pass, "colorAttachments", .{}), "objectAtIndexedSubscript:", .{@as(u64, 0)});
            msg(void, att, "setTexture:", .{r.color});
            if (frame.load == null) {
                msg(void, att, "setLoadAction:", .{@as(u64, 2)}); // Clear
                msg(void, att, "setClearColor:", .{ClearColor{ .r = @floatFromInt(frame.clear_color), .g = 0, .b = 0, .a = 0 }});
            } else {
                msg(void, att, "setLoadAction:", .{@as(u64, 1)}); // Load
            }
            msg(void, att, "setStoreAction:", .{@as(u64, 1)}); // Store
            const datt = msg(Id, pass, "depthAttachment", .{});
            msg(void, datt, "setTexture:", .{r.depth});
            msg(void, datt, "setLoadAction:", .{@as(u64, 2)});
            msg(void, datt, "setClearDepth:", .{@as(f64, frame.clear_z)});
            msg(void, datt, "setStoreAction:", .{@as(u64, 0)}); // DontCare

            const enc = msg(Id, cmd, "renderCommandEncoderWithDescriptor:", .{pass}) orelse return error.MetalFailed;
            // V3D doesn't clip on depth: a fragment's depth is clamped instead.
            msg(void, enc, "setDepthClipMode:", .{@as(u64, 1)});
            const fb_size = [2]f32{ @floatFromInt(frame.width), @floatFromInt(frame.height) };
            msg(void, enc, "setVertexBuffer:offset:atIndex:", .{ r.vertices, @as(u64, 0), @as(u64, 0) });
            msg(void, enc, "setVertexBytes:length:atIndex:", .{ @as(*const anyopaque, &fb_size), @as(u64, @sizeOf(@TypeOf(fb_size))), @as(u64, 1) });
            msg(void, enc, "setFragmentBuffer:offset:atIndex:", .{ r.ram_buf, @as(u64, 0), @as(u64, 1) });
            for (draws, 0..) |d, i| {
                const x0 = @min(d.clip_x, frame.width);
                const y0 = @min(d.clip_y, frame.height);
                const x1 = @min(d.clip_x +| d.clip_w, frame.width);
                const y1 = @min(d.clip_y +| d.clip_h, frame.height);
                if (x1 <= x0 or y1 <= y0 or d.vertex_count == 0) continue;
                if (d.vertex_stage) |vs| if (vs.corner_count < 3) continue;
                msg(void, enc, "setRenderPipelineState:", .{pipelines[i]});
                msg(void, enc, "setDepthStencilState:", .{r.depthState(d.depth_func, d.depth_write)});
                msg(void, enc, "setScissorRect:", .{ScissorRect{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 }});
                const info: DrawInfo = .{ .n_var = @min(d.num_varyings, msl.max_varyings), .ram_len = ram_len, .ram_mask = ramMask(ram.len) };
                msg(void, enc, "setFragmentBuffer:offset:atIndex:", .{ r.uniforms, @as(u64, i * msl.max_uniforms * 4), @as(u64, 0) });
                msg(void, enc, "setFragmentBytes:length:atIndex:", .{ @as(*const anyopaque, &info), @as(u64, @sizeOf(DrawInfo)), @as(u64, 2) });
                if (d.vertex_stage) |vs| {
                    // MTLIndexTypeUInt32.
                    msg(void, enc, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:", .{ primitive_triangle, @as(u64, vs.corner_count / 3 * 3), @as(u64, 1), r.indices, @as(u64, vs.first_corner) * 4 });
                } else {
                    msg(void, enc, "drawPrimitives:vertexStart:vertexCount:", .{ primitive_triangle, @as(u64, d.first_vertex), @as(u64, d.vertex_count) });
                }
            }
            msg(void, enc, "endEncoding", .{});
        }

        {
            const ls: LoadStore = .{ .base = frame.store.base, .fb_w = frame.width, .fb_h = frame.height, .tiling = frame.store.tiling, .cpp = frame.store.cpp, .ram_len = ram_len, .tiles = frame.tiles };
            const enc = msg(Id, cmd, "computeCommandEncoder", .{}) orelse return error.MetalFailed;
            msg(void, enc, "setComputePipelineState:", .{r.store_pipe});
            msg(void, enc, "setTexture:atIndex:", .{ r.color, @as(u64, 0) });
            msg(void, enc, "setBuffer:offset:atIndex:", .{ r.ram_buf, @as(u64, 0), @as(u64, 0) });
            msg(void, enc, "setBytes:length:atIndex:", .{ @as(*const anyopaque, &ls), @as(u64, @sizeOf(LoadStore)), @as(u64, 1) });
            msg(void, enc, "dispatchThreadgroups:threadsPerThreadgroup:", .{ groups, group });
            msg(void, enc, "endEncoding", .{});
        }

        msg(void, cmd, "commit", .{});
        msg(void, cmd, "waitUntilCompleted", .{});
        // MTLCommandBufferStatusCompleted.
        if (msg(u64, cmd, "status", .{}) != 4) {
            logError("drawing a frame", msg(Id, cmd, "error", .{}));
            return error.MetalFailed;
        }
    }
};

const MtlSize = extern struct { width: u64, height: u64, depth: u64 };
const ClearColor = extern struct { r: f64, g: f64, b: f64, a: f64 };
const ScissorRect = extern struct { x: u64, y: u64, width: u64, height: u64 };

fn ramMask(len: usize) u32 {
    return @import("../soc/vc_bus.zig").ramMask(len);
}

test "Metal renderer's structs are laid out as the shaders' are" {
    try std.testing.expectEqual(@as(usize, 96), @sizeOf(Vertex));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(DrawInfo));
    try std.testing.expectEqual(@as(usize, 160), @sizeOf(LoadStore));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(VertexInfo));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(CullInfo));
    if (!supported) try std.testing.expectError(error.Unsupported, Renderer.init());
}
