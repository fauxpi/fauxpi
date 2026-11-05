//! Draws V3D frames with OpenGL, on the host's GPU (EGL's surfaceless platform: the GPU, without a
//! window). V3D shades the vertices, bins the triangles and loads and stores the tile buffer on the
//! CPU as before; OpenGL rasterizes the triangles and runs the fragment shaders (translated to GLSL
//! by `qpu_to_shader.zig`) into a copy of the tile buffer as big as the framebuffer. The textures
//! they sample are decoded from RAM as the TMU reads them, and kept until those bytes change.
//!
//! Shaders that read the tile's colour (V3D blends in its fragment shaders) read the framebuffer as
//! a texture, which is only defined after a texture barrier for pixels drawn since: their triangles
//! are drawn in batches no two of which cover the same pixel, a barrier before each (`Batcher`).

const std = @import("std");
const host_posix = @import("../host/posix.zig");
const qpu = @import("qpu.zig");
const qpu_sim = @import("qpu_sim.zig");
const shader = @import("qpu_to_shader.zig");
const gpu_draw = @import("gpu_draw.zig");

pub const Vertex = gpu_draw.Vertex;
pub const Draw = gpu_draw.Draw;

pub const Error = error{ Unsupported, GlFailed };

const EGLDisplay = ?*anyopaque;
const EGLContext = ?*anyopaque;
const EGLenum = u32;
const EGLint = i32;
const EGLBoolean = u32;

const GLenum = u32;
const GLuint = u32;
const GLint = i32;
const GLsizei = i32;
const GLboolean = u8;

const EGL_PLATFORM_SURFACELESS_MESA: EGLenum = 0x31DD;
const EGL_OPENGL_API: EGLenum = 0x30A2;
const EGL_CONTEXT_MAJOR_VERSION: EGLint = 0x3098;
const EGL_CONTEXT_MINOR_VERSION: EGLint = 0x30FB;
const EGL_CONTEXT_OPENGL_PROFILE_MASK: EGLint = 0x30FD;
const EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT: EGLint = 1;
const EGL_NONE: EGLint = 0x3038;

const GL_RENDERER: GLenum = 0x1F01;
const GL_FRAGMENT_SHADER: GLenum = 0x8B30;
const GL_VERTEX_SHADER: GLenum = 0x8B31;
const GL_COMPILE_STATUS: GLenum = 0x8B81;
const GL_LINK_STATUS: GLenum = 0x8B82;
const GL_ARRAY_BUFFER: GLenum = 0x8892;
const GL_STREAM_DRAW: GLenum = 0x88E0;
const GL_FLOAT: GLenum = 0x1406;
const GL_UNSIGNED_INT: GLenum = 0x1405;
const GL_TEXTURE_2D: GLenum = 0x0DE1;
const GL_TEXTURE0: GLenum = 0x84C0;
const GL_R32UI: GLint = 0x8236;
const GL_RED_INTEGER: GLenum = 0x8D94;
const GL_DEPTH_COMPONENT32F: GLint = 0x8CAC;
const GL_DEPTH_COMPONENT: GLenum = 0x1902;
const GL_TEXTURE_MIN_FILTER: GLenum = 0x2801;
const GL_TEXTURE_MAG_FILTER: GLenum = 0x2800;
const GL_NEAREST: GLint = 0x2600;
const GL_FRAMEBUFFER: GLenum = 0x8D40;
const GL_COLOR_ATTACHMENT0: GLenum = 0x8CE0;
const GL_DEPTH_ATTACHMENT: GLenum = 0x8D00;
const GL_FRAMEBUFFER_COMPLETE: GLenum = 0x8CD5;
const GL_DEPTH: GLenum = 0x1801;
const GL_DEPTH_TEST: GLenum = 0x0B71;
const GL_SCISSOR_TEST: GLenum = 0x0C11;
const GL_DEPTH_CLAMP: GLenum = 0x864F;
const GL_TRIANGLES: GLenum = 0x0004;
const GL_UNPACK_ALIGNMENT: GLenum = 0x0CF5;
const GL_PACK_ALIGNMENT: GLenum = 0x0D05;
const GL_NEVER: GLenum = 0x0200;
const GL_NO_ERROR: GLenum = 0;

/// The texture unit the tile buffer is read from (after those of the textures sampled).
const tlb_unit = shader.max_samples;

/// OpenGL's functions, as EGL gives them.
const Gl = struct {
    GetString: *const fn (GLenum) callconv(.c) ?[*:0]const u8,
    GetError: *const fn () callconv(.c) GLenum,
    CreateShader: *const fn (GLenum) callconv(.c) GLuint,
    ShaderSource: *const fn (GLuint, GLsizei, [*]const [*]const u8, ?[*]const GLint) callconv(.c) void,
    CompileShader: *const fn (GLuint) callconv(.c) void,
    GetShaderiv: *const fn (GLuint, GLenum, *GLint) callconv(.c) void,
    GetShaderInfoLog: *const fn (GLuint, GLsizei, ?*GLsizei, [*]u8) callconv(.c) void,
    DeleteShader: *const fn (GLuint) callconv(.c) void,
    CreateProgram: *const fn () callconv(.c) GLuint,
    AttachShader: *const fn (GLuint, GLuint) callconv(.c) void,
    LinkProgram: *const fn (GLuint) callconv(.c) void,
    GetProgramiv: *const fn (GLuint, GLenum, *GLint) callconv(.c) void,
    GetProgramInfoLog: *const fn (GLuint, GLsizei, ?*GLsizei, [*]u8) callconv(.c) void,
    DeleteProgram: *const fn (GLuint) callconv(.c) void,
    UseProgram: *const fn (GLuint) callconv(.c) void,
    GetUniformLocation: *const fn (GLuint, [*:0]const u8) callconv(.c) GLint,
    Uniform1i: *const fn (GLint, GLint) callconv(.c) void,
    Uniform1iv: *const fn (GLint, GLsizei, [*]const GLint) callconv(.c) void,
    Uniform1ui: *const fn (GLint, GLuint) callconv(.c) void,
    Uniform1uiv: *const fn (GLint, GLsizei, [*]const GLuint) callconv(.c) void,
    Uniform2f: *const fn (GLint, f32, f32) callconv(.c) void,
    GenVertexArrays: *const fn (GLsizei, [*]GLuint) callconv(.c) void,
    BindVertexArray: *const fn (GLuint) callconv(.c) void,
    GenBuffers: *const fn (GLsizei, [*]GLuint) callconv(.c) void,
    BindBuffer: *const fn (GLenum, GLuint) callconv(.c) void,
    BufferData: *const fn (GLenum, isize, ?*const anyopaque, GLenum) callconv(.c) void,
    VertexAttribPointer: *const fn (GLuint, GLint, GLenum, GLboolean, GLsizei, ?*const anyopaque) callconv(.c) void,
    VertexAttribIPointer: *const fn (GLuint, GLint, GLenum, GLsizei, ?*const anyopaque) callconv(.c) void,
    EnableVertexAttribArray: *const fn (GLuint) callconv(.c) void,
    GenTextures: *const fn (GLsizei, [*]GLuint) callconv(.c) void,
    BindTexture: *const fn (GLenum, GLuint) callconv(.c) void,
    ActiveTexture: *const fn (GLenum) callconv(.c) void,
    TexImage2D: *const fn (GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, ?*const anyopaque) callconv(.c) void,
    TexSubImage2D: *const fn (GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, ?*const anyopaque) callconv(.c) void,
    TexParameteri: *const fn (GLenum, GLenum, GLint) callconv(.c) void,
    PixelStorei: *const fn (GLenum, GLint) callconv(.c) void,
    GenFramebuffers: *const fn (GLsizei, [*]GLuint) callconv(.c) void,
    BindFramebuffer: *const fn (GLenum, GLuint) callconv(.c) void,
    FramebufferTexture2D: *const fn (GLenum, GLenum, GLenum, GLuint, GLint) callconv(.c) void,
    CheckFramebufferStatus: *const fn (GLenum) callconv(.c) GLenum,
    Viewport: *const fn (GLint, GLint, GLsizei, GLsizei) callconv(.c) void,
    Scissor: *const fn (GLint, GLint, GLsizei, GLsizei) callconv(.c) void,
    Enable: *const fn (GLenum) callconv(.c) void,
    Disable: *const fn (GLenum) callconv(.c) void,
    DepthFunc: *const fn (GLenum) callconv(.c) void,
    DepthMask: *const fn (GLboolean) callconv(.c) void,
    ClearBufferfv: *const fn (GLenum, GLint, [*]const f32) callconv(.c) void,
    DrawArrays: *const fn (GLenum, GLint, GLsizei) callconv(.c) void,
    ReadPixels: *const fn (GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, ?*anyopaque) callconv(.c) void,
    /// GL 4.5's, or NV_texture_barrier's: without it, shaders can't read the tile's colour.
    TextureBarrier: ?*const fn () callconv(.c) void,
};

pub const Renderer = struct {
    egl: std.DynLib,
    dpy: EGLDisplay,
    ctx: EGLContext,
    makeCurrent: *const fn (EGLDisplay, ?*anyopaque, ?*anyopaque, EGLContext) callconv(.c) EGLBoolean,
    gl: Gl,
    vertex_shader: GLuint = 0,
    vao: GLuint = 0,
    vbo: GLuint = 0,
    fbo: GLuint = 0,
    color: GLuint = 0,
    depth: GLuint = 0,
    width: u32 = 0,
    height: u32 = 0,
    programs: [64]Program = @splat(.{}),
    next_program: usize = 0,
    textures: [32]Texture = @splat(.{}),
    /// Counts the frames drawn: which textures were checked this frame, and used least recently.
    frame: u64 = 0,
    /// Where textures are decoded.
    texels: std.ArrayList(u32) = .empty,
    batcher: Batcher = .{},

    /// A fragment shader's program (0 if OpenGL can't draw it), and where its uniforms are.
    const Program = struct {
        hash: u64 = 0,
        used: bool = false,
        program: GLuint = 0,
        shader: shader.Shader = .{},
        unif: GLint = -1,
        n_var: GLint = -1,
        fb: GLint = -1,
        tex_ok: GLint = -1,
    };

    /// A texture decoded from RAM: which (its TMU parameters, less its filters and wrapping, which
    /// don't change what is decoded), and what its bytes hashed to when it was.
    const Texture = struct {
        p0: u32 = 0,
        p1: u32 = 0,
        used: bool = false,
        hash: u64 = 0,
        /// The frame it was last checked in, and whether it could be decoded then.
        checked: u64 = 0,
        ok: bool = false,
        tex: GLuint = 0,
        width: u32 = 0,
        height: u32 = 0,
    };

    /// Parameter 1's filter and wrap bits.
    const p1_sampling_bits: u32 = 0xff;

    /// The GPU, or `error.Unsupported` if there isn't one OpenGL 3.3 draws with (a software renderer
    /// would be slower than V3D's own).
    pub fn init() Error!Renderer {
        var lib = std.DynLib.open("libEGL.so.1") catch return error.Unsupported;
        errdefer lib.close();
        const getPlatformDisplay = lib.lookup(*const fn (EGLenum, ?*anyopaque, ?[*]const isize) callconv(.c) EGLDisplay, "eglGetPlatformDisplay") orelse return error.Unsupported;
        const initialize = lib.lookup(*const fn (EGLDisplay, ?*EGLint, ?*EGLint) callconv(.c) EGLBoolean, "eglInitialize") orelse return error.Unsupported;
        const bindApi = lib.lookup(*const fn (EGLenum) callconv(.c) EGLBoolean, "eglBindAPI") orelse return error.Unsupported;
        const createContext = lib.lookup(*const fn (EGLDisplay, ?*anyopaque, EGLContext, [*]const EGLint) callconv(.c) EGLContext, "eglCreateContext") orelse return error.Unsupported;
        const makeCurrent = lib.lookup(*const fn (EGLDisplay, ?*anyopaque, ?*anyopaque, EGLContext) callconv(.c) EGLBoolean, "eglMakeCurrent") orelse return error.Unsupported;
        const getProcAddress = lib.lookup(*const fn ([*:0]const u8) callconv(.c) ?*const anyopaque, "eglGetProcAddress") orelse return error.Unsupported;

        // Surfaceless: the GPU itself (the default display can be a software renderer).
        const dpy = getPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, null, null) orelse return error.Unsupported;
        if (initialize(dpy, null, null) == 0) return error.Unsupported;
        if (bindApi(EGL_OPENGL_API) == 0) return error.Unsupported;
        const attribs = [_]EGLint{
            EGL_CONTEXT_MAJOR_VERSION,       3,
            EGL_CONTEXT_MINOR_VERSION,       3,
            EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
            EGL_NONE,
        };
        const ctx = createContext(dpy, null, null, &attribs) orelse return error.Unsupported;
        if (makeCurrent(dpy, null, null, ctx) == 0) return error.Unsupported;
        defer _ = makeCurrent(dpy, null, null, null);

        var gl: Gl = undefined;
        inline for (@typeInfo(Gl).@"struct".field_names) |name| {
            const p = getProcAddress("gl" ++ name);
            @field(gl, name) = if (@typeInfo(@FieldType(Gl, name)) == .optional) @ptrCast(p) else @ptrCast(p orelse return error.Unsupported);
        }
        if (gl.TextureBarrier == null) gl.TextureBarrier = @ptrCast(getProcAddress("glTextureBarrierNV"));

        const name = std.mem.span(gl.GetString(GL_RENDERER) orelse return error.Unsupported);
        if (std.mem.indexOf(u8, name, "llvmpipe") != null or std.mem.indexOf(u8, name, "softpipe") != null) return error.Unsupported;

        var r: Renderer = .{ .egl = lib, .dpy = dpy, .ctx = ctx, .makeCurrent = makeCurrent, .gl = gl };
        r.vertex_shader = r.compileShader(GL_VERTEX_SHADER, shader.glsl_vertex) orelse return error.GlFailed;
        gl.GenVertexArrays(1, @ptrCast(&r.vao));
        gl.BindVertexArray(r.vao);
        gl.GenBuffers(1, @ptrCast(&r.vbo));
        gl.BindBuffer(GL_ARRAY_BUFFER, r.vbo);
        const stride: GLsizei = @sizeOf(Vertex);
        gl.VertexAttribPointer(0, 4, GL_FLOAT, 0, stride, @ptrFromInt(@offsetOf(Vertex, "x")));
        gl.VertexAttribIPointer(1, 1, GL_UNSIGNED_INT, stride, @ptrFromInt(@offsetOf(Vertex, "unit_w")));
        for (0..4) |i| gl.VertexAttribPointer(@intCast(2 + i), 4, GL_FLOAT, 0, stride, @ptrFromInt(@offsetOf(Vertex, "varyings") + i * 16));
        for (0..6) |i| gl.EnableVertexAttribArray(@intCast(i));
        gl.GenFramebuffers(1, @ptrCast(&r.fbo));
        gl.PixelStorei(GL_UNPACK_ALIGNMENT, 4);
        gl.PixelStorei(GL_PACK_ALIGNMENT, 4);
        if (gl.GetError() != GL_NO_ERROR) return error.GlFailed;
        std.debug.print("fauxpi: V3D draws with OpenGL on {s}\n", .{name});
        return r;
    }

    fn compileShader(r: *Renderer, kind: GLenum, source: []const u8) ?GLuint {
        const gl = &r.gl;
        const sh = gl.CreateShader(kind);
        const srcs = [_][*]const u8{source.ptr};
        const lens = [_]GLint{@intCast(source.len)};
        gl.ShaderSource(sh, 1, &srcs, &lens);
        gl.CompileShader(sh);
        var ok: GLint = 0;
        gl.GetShaderiv(sh, GL_COMPILE_STATUS, &ok);
        if (ok == 0) {
            var log: [2048]u8 = undefined;
            var len: GLsizei = 0;
            gl.GetShaderInfoLog(sh, log.len, &len, &log);
            std.debug.print("fauxpi: V3D on OpenGL: compiling a shader failed: {s}\n", .{log[0..@intCast(@max(len, 0))]});
            gl.DeleteShader(sh);
            return null;
        }
        return sh;
    }

    /// The program for a fragment shader, translated and compiled the first time it draws (null if
    /// OpenGL can't draw it).
    fn program(r: *Renderer, code: []const qpu.Inst) ?*const Program {
        const hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(code));
        for (&r.programs) |*p| {
            if (p.used and p.hash == hash) return if (p.program != 0) p else null;
        }
        const gl = &r.gl;
        const slot = &r.programs[r.next_program];
        r.next_program = (r.next_program + 1) % r.programs.len;
        if (slot.program != 0) gl.DeleteProgram(slot.program);
        slot.* = .{ .hash = hash, .used = true };

        var decoded_buf: [512]qpu_sim.DecodedInst = undefined;
        if (code.len > decoded_buf.len) return null;
        const decoded = qpu_sim.decodeProgram(code, &decoded_buf);
        var src: std.Io.Writer.Allocating = .init(std.heap.smp_allocator);
        defer src.deinit();
        src.writer.writeAll(shader.glsl_common) catch return null;
        const sh = shader.translate(&src.writer, decoded, .glsl) catch return null;
        if (sh.too_many_samples) return null;
        if (sh.reads_color and gl.TextureBarrier == null) return null;

        const frag = r.compileShader(GL_FRAGMENT_SHADER, src.written()) orelse return null;
        defer gl.DeleteShader(frag);
        const prog = gl.CreateProgram();
        gl.AttachShader(prog, r.vertex_shader);
        gl.AttachShader(prog, frag);
        gl.LinkProgram(prog);
        var ok: GLint = 0;
        gl.GetProgramiv(prog, GL_LINK_STATUS, &ok);
        if (ok == 0) {
            var log: [2048]u8 = undefined;
            var len: GLsizei = 0;
            gl.GetProgramInfoLog(prog, log.len, &len, &log);
            std.debug.print("fauxpi: V3D on OpenGL: linking a program failed: {s}\n", .{log[0..@intCast(@max(len, 0))]});
            gl.DeleteProgram(prog);
            return null;
        }
        gl.UseProgram(prog);
        // Each texture sampled on its own unit, and the tile buffer after them.
        var units: [shader.max_samples]GLint = undefined;
        for (&units, 0..) |*u, i| u.* = @intCast(i);
        gl.Uniform1iv(gl.GetUniformLocation(prog, "tex"), units.len, &units);
        gl.Uniform1i(gl.GetUniformLocation(prog, "tlb_tex"), tlb_unit);
        slot.* = .{
            .hash = hash,
            .used = true,
            .program = prog,
            .shader = sh,
            .unif = gl.GetUniformLocation(prog, "unif"),
            .n_var = gl.GetUniformLocation(prog, "n_var"),
            .fb = gl.GetUniformLocation(prog, "fb"),
            .tex_ok = gl.GetUniformLocation(prog, "tex_ok"),
        };
        return slot;
    }

    /// The texture `p0`, `p1` decoded from `ram` (again, if its bytes changed since it was), or null
    /// if the TMU doesn't read it.
    fn texture(r: *Renderer, ram: []const u8, p0: u32, p1: u32) ?GLuint {
        const k1 = p1 & ~p1_sampling_bits;
        var found: ?*Texture = null;
        var oldest: *Texture = &r.textures[0];
        for (&r.textures) |*e| {
            if (e.used and e.p0 == p0 and e.p1 == k1) {
                found = e;
                break;
            }
            if (!e.used or (oldest.used and e.checked < oldest.checked)) oldest = e;
        }
        const e = found orelse blk: {
            // Its OpenGL texture is kept, for the next decoded into it.
            oldest.* = .{ .p0 = p0, .p1 = k1, .used = true, .tex = oldest.tex, .width = oldest.width, .height = oldest.height };
            break :blk oldest;
        };
        if (e.checked == r.frame) return if (e.ok) e.tex else null;
        e.checked = r.frame;

        const dt = qpu_sim.DecodedTexture.of(ram, p0, p1) orelse {
            e.ok = false;
            return null;
        };
        const hash = std.hash.Wyhash.hash(0, dt.bytes);
        if (e.ok and e.hash == hash) return e.tex;
        e.ok = false;
        if (dt.width == 0 or dt.height == 0) return null;
        r.texels.resize(std.heap.smp_allocator, @as(usize, dt.width) * dt.height) catch return null;
        if (!qpu_sim.DecodedTexture.decode(ram, p0, p1, r.texels.items)) return null;
        const gl = &r.gl;
        if (e.tex == 0) gl.GenTextures(1, @ptrCast(&e.tex));
        gl.BindTexture(GL_TEXTURE_2D, e.tex);
        if (e.width != dt.width or e.height != dt.height) {
            gl.TexImage2D(GL_TEXTURE_2D, 0, GL_R32UI, @intCast(dt.width), @intCast(dt.height), 0, GL_RED_INTEGER, GL_UNSIGNED_INT, r.texels.items.ptr);
            gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
            gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
            e.width = dt.width;
            e.height = dt.height;
        } else {
            gl.TexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, @intCast(dt.width), @intCast(dt.height), GL_RED_INTEGER, GL_UNSIGNED_INT, r.texels.items.ptr);
        }
        e.hash = hash;
        e.ok = true;
        return e.tex;
    }

    fn useSize(r: *Renderer, width: u32, height: u32) Error!void {
        if (r.color != 0 and r.width == width and r.height == height) return;
        const gl = &r.gl;
        if (r.color == 0) {
            gl.GenTextures(1, @ptrCast(&r.color));
            gl.GenTextures(1, @ptrCast(&r.depth));
        }
        gl.BindTexture(GL_TEXTURE_2D, r.color);
        gl.TexImage2D(GL_TEXTURE_2D, 0, GL_R32UI, @intCast(width), @intCast(height), 0, GL_RED_INTEGER, GL_UNSIGNED_INT, null);
        gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        gl.BindTexture(GL_TEXTURE_2D, r.depth);
        gl.TexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT32F, @intCast(width), @intCast(height), 0, GL_DEPTH_COMPONENT, GL_FLOAT, null);
        gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        gl.BindFramebuffer(GL_FRAMEBUFFER, r.fbo);
        gl.FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, r.color, 0);
        gl.FramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D, r.depth, 0);
        if (gl.CheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) return error.GlFailed;
        r.width = width;
        r.height = height;
    }

    /// Draws `draws` of `vertices` into `color` (`width` by `height`, its rows from the top as V3D
    /// has them: the tile buffer, loaded or cleared), with depth cleared to `clear_z`, and leaves
    /// what was drawn in `color`. `error.Unsupported` (a shader OpenGL can't draw) leaves `color`
    /// as it was, for the CPU to draw the frame.
    pub fn render(r: *Renderer, ram: []const u8, width: u32, height: u32, color: []u32, clear_z: f32, vertices: []const Vertex, draws: []const Draw) Error!void {
        if (draws.len > gpu_draw.max_draws or vertices.len > gpu_draw.max_vertices) return error.Unsupported;
        if (width == 0 or height == 0 or color.len < @as(usize, width) * height) return error.Unsupported;
        if (r.makeCurrent(r.dpy, null, null, r.ctx) == 0) return error.GlFailed;
        // The next frame may be drawn from another thread.
        defer _ = r.makeCurrent(r.dpy, null, null, null);
        const gl = &r.gl;
        r.frame += 1;

        // The shaders first: one OpenGL can't draw sends the frame to the CPU.
        var programs: [gpu_draw.max_draws]*const Program = undefined;
        for (draws, 0..) |d, i| programs[i] = r.program(d.code) orelse return error.Unsupported;

        try r.useSize(width, height);
        gl.BindFramebuffer(GL_FRAMEBUFFER, r.fbo);
        gl.Viewport(0, 0, @intCast(width), @intCast(height));
        gl.ActiveTexture(GL_TEXTURE0);
        gl.BindTexture(GL_TEXTURE_2D, r.color);
        gl.TexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, @intCast(width), @intCast(height), GL_RED_INTEGER, GL_UNSIGNED_INT, color.ptr);
        gl.Disable(GL_SCISSOR_TEST);
        gl.DepthMask(1);
        gl.ClearBufferfv(GL_DEPTH, 0, @ptrCast(&clear_z));
        // V3D doesn't clip on depth: a fragment's depth is clamped instead.
        gl.Enable(GL_DEPTH_CLAMP);
        gl.Enable(GL_DEPTH_TEST);
        gl.Enable(GL_SCISSOR_TEST);
        gl.BindVertexArray(r.vao);
        gl.BindBuffer(GL_ARRAY_BUFFER, r.vbo);
        gl.BufferData(GL_ARRAY_BUFFER, @intCast(vertices.len * @sizeOf(Vertex)), vertices.ptr, GL_STREAM_DRAW);

        for (draws, programs[0..draws.len]) |d, p| {
            const x0 = @min(d.clip_x, width);
            const y0 = @min(d.clip_y, height);
            const x1 = @min(d.clip_x +| d.clip_w, width);
            const y1 = @min(d.clip_y +| d.clip_h, height);
            if (x1 <= x0 or y1 <= y0 or d.vertex_count < 3) continue;
            gl.UseProgram(p.program);
            gl.Uniform1uiv(p.unif, shader.max_uniforms, d.uniforms);
            gl.Uniform1ui(p.n_var, @min(d.num_varyings, shader.max_varyings));
            gl.Uniform2f(p.fb, @floatFromInt(width), @floatFromInt(height));
            var ok: [shader.max_samples]GLuint = @splat(0);
            for (0..shader.max_samples) |k| {
                const s = p.shader.samples[k];
                const tex: GLuint = if (k < p.shader.sample_count) r.texture(ram, d.uniforms[s.p0], d.uniforms[s.p1]) orelse 0 else 0;
                gl.ActiveTexture(GL_TEXTURE0 + @as(GLenum, @intCast(k)));
                gl.BindTexture(GL_TEXTURE_2D, tex);
                ok[k] = @intFromBool(tex != 0);
            }
            gl.Uniform1uiv(p.tex_ok, ok.len, &ok);
            gl.ActiveTexture(GL_TEXTURE0 + tlb_unit);
            gl.BindTexture(GL_TEXTURE_2D, if (p.shader.reads_color) r.color else 0);
            gl.ActiveTexture(GL_TEXTURE0);
            gl.DepthFunc(GL_NEVER + @as(GLenum, d.depth_func));
            gl.DepthMask(@intFromBool(d.depth_write));
            gl.Scissor(@intCast(x0), @intCast(y0), @intCast(x1 - x0), @intCast(y1 - y0));
            if (p.shader.reads_color) {
                // Each triangle reads what those before it drew: those it covers pixels of are
                // drawn, with a barrier, before it.
                const tris = vertices[d.first_vertex..][0 .. d.vertex_count / 3 * 3];
                r.batcher.start(width, height);
                var batch_start: u32 = 0;
                var t: u32 = 0;
                while (t * 3 < tris.len) : (t += 1) {
                    const tri = tris[t * 3 ..][0..3];
                    if (!r.batcher.add(tri)) {
                        gl.TextureBarrier.?();
                        gl.DrawArrays(GL_TRIANGLES, @intCast(d.first_vertex + batch_start * 3), @intCast((t - batch_start) * 3));
                        batch_start = t;
                        r.batcher.clear();
                        _ = r.batcher.add(tri);
                    }
                }
                if (t > batch_start) {
                    gl.TextureBarrier.?();
                    gl.DrawArrays(GL_TRIANGLES, @intCast(d.first_vertex + batch_start * 3), @intCast((t - batch_start) * 3));
                }
            } else {
                gl.DrawArrays(GL_TRIANGLES, @intCast(d.first_vertex), @intCast(d.vertex_count));
            }
        }

        gl.ReadPixels(0, 0, @intCast(width), @intCast(height), GL_RED_INTEGER, GL_UNSIGNED_INT, color.ptr);
        if (gl.GetError() != GL_NO_ERROR) return error.GlFailed;
    }
};

/// Makes batches of triangles no two of which cover the same pixel, so a batch can be drawn at once
/// by shaders reading the framebuffer (each pixel drawn once since the barrier before it). Triangles
/// are only said to overlap if their insides do: those sharing an edge (a quad's two halves, say)
/// cover no pixel centre in common.
pub const Batcher = struct {
    /// The triangles in the batch, by the 16-pixel cells their bounds touch: a list of entries for
    /// each cell, valid if the cell's generation is the batch's.
    cell_gen: [cells * cells]u32 = @splat(0),
    cell_head: [cells * cells]u32 = undefined,
    entries: std.ArrayList(Entry) = .empty,
    gen: u32 = 1,
    /// The cells the framebuffer is wide and high.
    cols: u32 = 0,
    rows: u32 = 0,
    /// The batch's triangles' corners, by their index.
    tris: std.ArrayList([3][2]f32) = .empty,

    const cell_size = 16;
    /// As many as a 2048-pixel framebuffer has.
    const cells = 2048 / cell_size;
    const none = std.math.maxInt(u32);

    const Entry = struct { tri: u32, next: u32 };

    /// Starts a draw's batches, in a framebuffer `width` by `height`.
    pub fn start(b: *Batcher, width: u32, height: u32) void {
        b.cols = @min((width + cell_size - 1) / cell_size, cells);
        b.rows = @min((height + cell_size - 1) / cell_size, cells);
        b.clear();
    }

    /// Starts a new batch.
    pub fn clear(b: *Batcher) void {
        b.gen +%= 1;
        if (b.gen == 0) {
            b.cell_gen = @splat(0);
            b.gen = 1;
        }
        b.entries.clearRetainingCapacity();
        b.tris.clearRetainingCapacity();
    }

    /// Adds triangle `tri` to the batch (true), unless it covers pixels one in it does (false).
    /// A triangle that can't be added (out of memory) is said to overlap.
    pub fn add(b: *Batcher, tri: *const [3]Vertex) bool {
        const corners: [3][2]f32 = .{ .{ tri[0].x, tri[0].y }, .{ tri[1].x, tri[1].y }, .{ tri[2].x, tri[2].y } };
        const lo = .{ @min(corners[0][0], corners[1][0], corners[2][0]), @min(corners[0][1], corners[1][1], corners[2][1]) };
        const hi = .{ @max(corners[0][0], corners[1][0], corners[2][0]), @max(corners[0][1], corners[1][1], corners[2][1]) };
        if (!(lo[0] < hi[0] and lo[1] < hi[1])) return true; // No inside (or NaN): covers no pixel.
        const c0 = cellOf(lo[0], b.cols);
        const c1 = cellOf(hi[0], b.cols);
        const r0 = cellOf(lo[1], b.rows);
        const r1 = cellOf(hi[1], b.rows);
        var cy = r0;
        while (cy <= r1) : (cy += 1) {
            var cx = c0;
            while (cx <= c1) : (cx += 1) {
                const c = cy * cells + cx;
                if (b.cell_gen[c] != b.gen) continue;
                var e = b.cell_head[c];
                while (e != none) : (e = b.entries.items[e].next) {
                    if (overlap(&corners, &b.tris.items[b.entries.items[e].tri])) return false;
                }
            }
        }
        const index: u32 = @intCast(b.tris.items.len);
        b.tris.append(std.heap.smp_allocator, corners) catch return false;
        cy = r0;
        while (cy <= r1) : (cy += 1) {
            var cx = c0;
            while (cx <= c1) : (cx += 1) {
                const c = cy * cells + cx;
                if (b.cell_gen[c] != b.gen) {
                    b.cell_gen[c] = b.gen;
                    b.cell_head[c] = none;
                }
                b.entries.append(std.heap.smp_allocator, .{ .tri = index, .next = b.cell_head[c] }) catch return false;
                b.cell_head[c] = @intCast(b.entries.items.len - 1);
            }
        }
        return true;
    }

    fn cellOf(v: f32, n: u32) u32 {
        if (!(v > 0)) return 0;
        const c = v / cell_size;
        return if (c >= @as(f32, @floatFromInt(n))) n -| 1 else @intFromFloat(c);
    }

    /// Whether the insides of triangles `a` and `b` overlap: no edge of either separates them
    /// (touching is apart).
    fn overlap(a: *const [3][2]f32, b: *const [3][2]f32) bool {
        return !separates(a, a, b) and !separates(b, a, b);
    }

    /// Whether one of `edges`' edges has `a` on one side of it and `b` on the other.
    fn separates(edges: *const [3][2]f32, a: *const [3][2]f32, b: *const [3][2]f32) bool {
        for (0..3) |i| {
            const p = edges[i];
            const q = edges[(i + 1) % 3];
            const n = .{ p[1] - q[1], q[0] - p[0] };
            var a_lo: f32 = std.math.inf(f32);
            var a_hi: f32 = -std.math.inf(f32);
            var b_lo: f32 = std.math.inf(f32);
            var b_hi: f32 = -std.math.inf(f32);
            for (a, b) |va, vb| {
                const pa = n[0] * va[0] + n[1] * va[1];
                const pb = n[0] * vb[0] + n[1] * vb[1];
                a_lo = @min(a_lo, pa);
                a_hi = @max(a_hi, pa);
                b_lo = @min(b_lo, pb);
                b_hi = @max(b_hi, pb);
            }
            if (a_hi <= b_lo or b_hi <= a_lo) return true;
        }
        return false;
    }
};

fn testTri(x0: f32, y0: f32, x1: f32, y1: f32, x2: f32, y2: f32) [3]Vertex {
    const v = struct {
        fn at(x: f32, y: f32) Vertex {
            return .{ .x = x, .y = y, .z = 0, .inv_w = 1, .unit_w = 1, .varyings = @splat(0) };
        }
    };
    return .{ v.at(x0, y0), v.at(x1, y1), v.at(x2, y2) };
}

test "Batcher batches a quad's halves and apart triangles, not overlapping ones" {
    var b: Batcher = .{};
    defer b.entries.deinit(std.heap.smp_allocator);
    defer b.tris.deinit(std.heap.smp_allocator);
    b.start(640, 480);
    // A quad's two halves share an edge.
    try std.testing.expect(b.add(&testTri(10, 10, 40, 10, 10, 40)));
    try std.testing.expect(b.add(&testTri(40, 10, 40, 40, 10, 40)));
    // The next quad, touching the first along x = 40.
    try std.testing.expect(b.add(&testTri(40, 10, 70, 10, 40, 40)));
    // Far away, in other cells.
    try std.testing.expect(b.add(&testTri(500, 400, 600, 400, 500, 470)));
    // Inside the first.
    try std.testing.expect(!b.add(&testTri(12, 12, 14, 12, 12, 14)));
    // In a new batch, inside the first's bounds but past its diagonal (x + y = 50).
    b.clear();
    try std.testing.expect(b.add(&testTri(10, 10, 40, 10, 10, 40)));
    try std.testing.expect(b.add(&testTri(35, 35, 39, 35, 39, 39)));
    // Over the first.
    try std.testing.expect(!b.add(&testTri(15, 15, 30, 15, 15, 30)));
    // A new batch takes it.
    b.clear();
    try std.testing.expect(b.add(&testTri(15, 15, 30, 15, 15, 30)));
    // Off the framebuffer, or with no inside, it covers nothing.
    try std.testing.expect(b.add(&testTri(-100, -100, -90, -100, -100, -90)));
    try std.testing.expect(b.add(&testTri(30, 30, 50, 30, 70, 30)));
}
