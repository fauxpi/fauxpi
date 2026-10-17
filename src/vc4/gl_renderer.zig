const std = @import("std");
const host_posix = @import("../host/posix.zig");
const qpu = @import("qpu.zig");
const qpu_sim = @import("qpu_sim.zig");
const qpu_to_glsl = @import("qpu_to_glsl.zig");
const texture = @import("texture.zig");

/// Hardware-accelerated OpenGL FBO renderer (via dynamic `libEGL.so.1` + `eglGetProcAddress`)
/// with compiled GLSL shader cache for translated VC4 QPU shaders.
pub const GlRenderer = struct {
    const EGLDisplay = ?*anyopaque;
    const EGLContext = ?*anyopaque;
    const EGLSurface = ?*anyopaque;
    const EGLConfig = ?*anyopaque;
    const EGLint = i32;
    const EGLenum = u32;
    const EGLBoolean = u32;

    const GLenum = u32;
    const GLuint = u32;
    const GLint = i32;
    const GLsizei = i32;
    const GLboolean = u8;
    const GLfloat = f32;

    const EGL_DEFAULT_DISPLAY: ?*anyopaque = null;
    const EGL_NO_CONTEXT: EGLContext = null;
    const EGL_NO_SURFACE: EGLSurface = null;
    const EGL_NO_CONFIG_KHR: EGLConfig = null;
    const EGL_OPENGL_API: EGLenum = 0x30A2;
    const EGL_CONTEXT_MAJOR_VERSION: EGLint = 0x3098;
    const EGL_CONTEXT_MINOR_VERSION: EGLint = 0x30FB;
    const EGL_NONE: EGLint = 0x3038;

    const GL_FRAMEBUFFER: GLenum = 0x8D40;
    const GL_RENDERBUFFER: GLenum = 0x8D41;
    const GL_COLOR_ATTACHMENT0: GLenum = 0x8CE0;
    const GL_DEPTH_ATTACHMENT: GLenum = 0x8D00;
    const GL_TEXTURE_2D: GLenum = 0x0DE1;
    const GL_RGBA8: GLenum = 0x8058;
    const GL_RGBA: GLenum = 0x1908;
    const GL_UNSIGNED_BYTE: GLenum = 0x1401;
    const GL_DEPTH_COMPONENT24: GLenum = 0x81A6;
    const GL_TEXTURE_MIN_FILTER: GLenum = 0x2801;
    const GL_TEXTURE_MAG_FILTER: GLenum = 0x2800;
    const GL_NEAREST: GLint = 0x2600;
    const GL_LINEAR: GLint = 0x2601;
    const GL_FRAGMENT_SHADER: GLenum = 0x8B30;
    const GL_VERTEX_SHADER: GLenum = 0x8B31;
    const GL_COMPILE_STATUS: GLenum = 0x8B81;
    const GL_LINK_STATUS: GLenum = 0x8B82;

    pub const CachedProgram = struct {
        vs_hash: u64 = 0,
        fs_hash: u64 = 0,
        gl_prog: GLuint = 0,
        vs_meta: qpu_to_glsl.TranslatedShader = .{},
        fs_meta: qpu_to_glsl.TranslatedShader = .{},
        valid: bool = false,
    };

    egl_lib: ?host_posix.DynLib = null,
    dpy: EGLDisplay = null,
    ctx: EGLContext = null,
    available: bool = false,

    // Dynamically loaded GL entry points
    glCreateShader: ?*const fn (GLenum) callconv(.c) GLuint = null,
    glShaderSource: ?*const fn (GLuint, GLsizei, [*]const [*]const u8, ?[*]const GLint) callconv(.c) void = null,
    glCompileShader: ?*const fn (GLuint) callconv(.c) void = null,
    glGetShaderiv: ?*const fn (GLuint, GLenum, *GLint) callconv(.c) void = null,
    glDeleteShader: ?*const fn (GLuint) callconv(.c) void = null,
    glCreateProgram: ?*const fn () callconv(.c) GLuint = null,
    glAttachShader: ?*const fn (GLuint, GLuint) callconv(.c) void = null,
    glLinkProgram: ?*const fn (GLuint) callconv(.c) void = null,
    glGetProgramiv: ?*const fn (GLuint, GLenum, *GLint) callconv(.c) void = null,
    glUseProgram: ?*const fn (GLuint) callconv(.c) void = null,

    program_cache: [16]CachedProgram = @splat(.{}),
    cache_next: usize = 0,

    pub fn init() GlRenderer {
        var self = GlRenderer{};
        self.tryInitEgl();
        return self;
    }

    pub fn deinit(self: *GlRenderer) void {
        if (self.egl_lib) |*lib| {
            lib.close();
            self.egl_lib = null;
        }
    }

    fn tryInitEgl(self: *GlRenderer) void {
        var lib = host_posix.DynLib.open("libEGL.so.1") catch return;
        const eglGetDisplay = lib.lookup(*const fn (?*anyopaque) callconv(.c) EGLDisplay, "eglGetDisplay") orelse {
            lib.close();
            return;
        };
        const eglInitialize = lib.lookup(*const fn (EGLDisplay, ?*EGLint, ?*EGLint) callconv(.c) EGLBoolean, "eglInitialize") orelse {
            lib.close();
            return;
        };
        const eglBindAPI = lib.lookup(*const fn (EGLenum) callconv(.c) EGLBoolean, "eglBindAPI") orelse {
            lib.close();
            return;
        };
        const eglCreateContext = lib.lookup(*const fn (EGLDisplay, EGLConfig, EGLContext, [*]const EGLint) callconv(.c) EGLContext, "eglCreateContext") orelse {
            lib.close();
            return;
        };
        const eglMakeCurrent = lib.lookup(*const fn (EGLDisplay, EGLSurface, EGLSurface, EGLContext) callconv(.c) EGLBoolean, "eglMakeCurrent") orelse {
            lib.close();
            return;
        };
        const eglGetProcAddress = lib.lookup(*const fn ([*:0]const u8) callconv(.c) ?*const anyopaque, "eglGetProcAddress") orelse {
            lib.close();
            return;
        };

        const dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
        if (dpy == null) {
            lib.close();
            return;
        }
        var major: EGLint = 0;
        var minor: EGLint = 0;
        if (eglInitialize(dpy, &major, &minor) == 0) {
            lib.close();
            return;
        }
        if (eglBindAPI(EGL_OPENGL_API) == 0) {
            lib.close();
            return;
        }
        const attribs = [_]EGLint{
            EGL_CONTEXT_MAJOR_VERSION, 3,
            EGL_CONTEXT_MINOR_VERSION, 3,
            EGL_NONE,
        };
        const ctx = eglCreateContext(dpy, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, &attribs);
        if (ctx == null) {
            lib.close();
            return;
        }
        if (eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx) == 0) {
            lib.close();
            return;
        }

        self.glCreateShader = @ptrCast(@alignCast(eglGetProcAddress("glCreateShader")));
        self.glShaderSource = @ptrCast(@alignCast(eglGetProcAddress("glShaderSource")));
        self.glCompileShader = @ptrCast(@alignCast(eglGetProcAddress("glCompileShader")));
        self.glGetShaderiv = @ptrCast(@alignCast(eglGetProcAddress("glGetShaderiv")));
        self.glDeleteShader = @ptrCast(@alignCast(eglGetProcAddress("glDeleteShader")));
        self.glCreateProgram = @ptrCast(@alignCast(eglGetProcAddress("glCreateProgram")));
        self.glAttachShader = @ptrCast(@alignCast(eglGetProcAddress("glAttachShader")));
        self.glLinkProgram = @ptrCast(@alignCast(eglGetProcAddress("glLinkProgram")));
        self.glGetProgramiv = @ptrCast(@alignCast(eglGetProcAddress("glGetProgramiv")));
        self.glUseProgram = @ptrCast(@alignCast(eglGetProcAddress("glUseProgram")));

        if (self.glCreateShader != null and self.glCreateProgram != null) {
            self.egl_lib = lib;
            self.dpy = dpy;
            self.ctx = ctx;
            self.available = true;
        } else {
            lib.close();
        }
    }

    pub fn getOrTranslateProgram(self: *GlRenderer, vs_code: []const qpu.Inst, fs_code: []const qpu.Inst) *const CachedProgram {
        const vs_hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(vs_code));
        const fs_hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(fs_code));

        for (&self.program_cache) |*entry| {
            if (entry.valid and entry.vs_hash == vs_hash and entry.fs_hash == fs_hash) {
                return entry;
            }
        }

        const slot = &self.program_cache[self.cache_next];
        self.cache_next = (self.cache_next + 1) % self.program_cache.len;

        slot.vs_hash = vs_hash;
        slot.fs_hash = fs_hash;
        slot.vs_meta = qpu_to_glsl.translate(vs_code, .vertex);
        slot.fs_meta = qpu_to_glsl.translate(fs_code, .fragment);
        slot.gl_prog = 0;
        slot.valid = true;

        if (self.available) {
            slot.gl_prog = self.compileGlProgram(slot.vs_meta.glsl(), slot.fs_meta.glsl());
        }
        return slot;
    }

    fn compileGlProgram(self: *GlRenderer, vs_src: []const u8, fs_src: []const u8) GLuint {
        const createShader = self.glCreateShader orelse return 0;
        const shaderSource = self.glShaderSource orelse return 0;
        const compileShader = self.glCompileShader orelse return 0;
        const getShaderiv = self.glGetShaderiv orelse return 0;
        const deleteShader = self.glDeleteShader orelse return 0;
        const createProgram = self.glCreateProgram orelse return 0;
        const attachShader = self.glAttachShader orelse return 0;
        const linkProgram = self.glLinkProgram orelse return 0;
        const getProgramiv = self.glGetProgramiv orelse return 0;

        const vs = createShader(GL_VERTEX_SHADER);
        const vs_ptr = [_][*]const u8{vs_src.ptr};
        const vs_len = [_]GLint{@intCast(vs_src.len)};
        shaderSource(vs, 1, &vs_ptr, &vs_len);
        compileShader(vs);
        var ok: GLint = 0;
        getShaderiv(vs, GL_COMPILE_STATUS, &ok);
        if (ok == 0) {
            deleteShader(vs);
            return 0;
        }

        const fs = createShader(GL_FRAGMENT_SHADER);
        const fs_ptr = [_][*]const u8{fs_src.ptr};
        const fs_len = [_]GLint{@intCast(fs_src.len)};
        shaderSource(fs, 1, &fs_ptr, &fs_len);
        compileShader(fs);
        getShaderiv(fs, GL_COMPILE_STATUS, &ok);
        if (ok == 0) {
            deleteShader(vs);
            deleteShader(fs);
            return 0;
        }

        const prog = createProgram();
        attachShader(prog, vs);
        attachShader(prog, fs);
        linkProgram(prog);
        deleteShader(vs);
        deleteShader(fs);
        getProgramiv(prog, GL_LINK_STATUS, &ok);
        if (ok == 0) return 0;
        return prog;
    }
};
