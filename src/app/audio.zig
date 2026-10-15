const std = @import("std");
const linux = std.os.linux;
const audio_mod = @import("../soc/audio.zig");

/// Non-blocking host audio output player for Linux.
/// Spawns a background playback thread that drains 48 kHz stereo S16_LE PCM frames
/// from `AudioFifo` and streams them to PulseAudio/PipeWire (`libpulse-simple.so.0`)
/// or ALSA (`libasound.so.2`).
pub const HostAudioOutput = struct {
    const PaSimple = opaque {};
    const PaSampleSpec = extern struct {
        format: c_int, // PA_SAMPLE_S16LE = 3
        rate: u32,
        channels: u8,
    };
    const PaBufferAttr = extern struct {
        maxlength: u32,
        tlength: u32,
        prebuf: u32,
        minreq: u32,
        fragsize: u32,
    };

    const SndPcm = opaque {};

    fifo: *audio_mod.AudioFifo,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    paused: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    // PulseAudio simple API state
    pa_lib: ?std.DynLib = null,
    pa_handle: ?*PaSimple = null,
    pa_simple_write: ?*const fn (*PaSimple, *const anyopaque, usize, *c_int) callconv(.c) c_int = null,
    pa_simple_free: ?*const fn (*PaSimple) callconv(.c) void = null,

    // ALSA API fallback state
    alsa_lib: ?std.DynLib = null,
    alsa_handle: ?*SndPcm = null,
    snd_pcm_writei: ?*const fn (*SndPcm, *const anyopaque, c_ulong) callconv(.c) c_long = null,
    snd_pcm_recover: ?*const fn (*SndPcm, c_int, c_int) callconv(.c) c_int = null,
    snd_pcm_prepare: ?*const fn (*SndPcm) callconv(.c) c_int = null,
    snd_pcm_close: ?*const fn (*SndPcm) callconv(.c) c_int = null,

    pub fn create(allocator: std.mem.Allocator, fifo: *audio_mod.AudioFifo) !*HostAudioOutput {
        const self = try allocator.create(HostAudioOutput);
        self.* = .{ .fifo = fifo };

        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, workerMain, .{self}) catch null;
        return self;
    }

    pub fn destroy(self: *HostAudioOutput, allocator: std.mem.Allocator) void {
        self.running.store(false, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.closeBackend();
        allocator.destroy(self);
    }

    pub fn setPaused(self: *HostAudioOutput, p: bool) void {
        self.paused.store(p, .release);
    }

    fn tryOpenPulse(self: *HostAudioOutput) bool {
        var lib = std.DynLib.open("libpulse-simple.so.0") catch return false;
        const pa_simple_new = lib.lookup(
            *const fn (
                ?[*:0]const u8,
                [*:0]const u8,
                c_int,
                ?[*:0]const u8,
                [*:0]const u8,
                *const PaSampleSpec,
                ?*const anyopaque,
                ?*const PaBufferAttr,
                *c_int,
            ) callconv(.c) ?*PaSimple,
            "pa_simple_new",
        ) orelse {
            lib.close();
            return false;
        };
        const pa_write = lib.lookup(
            *const fn (*PaSimple, *const anyopaque, usize, *c_int) callconv(.c) c_int,
            "pa_simple_write",
        ) orelse {
            lib.close();
            return false;
        };
        const pa_free = lib.lookup(
            *const fn (*PaSimple) callconv(.c) void,
            "pa_simple_free",
        ) orelse {
            lib.close();
            return false;
        };

        const spec = PaSampleSpec{
            .format = 3, // PA_SAMPLE_S16LE
            .rate = audio_mod.AudioFifo.HOST_SAMPLE_RATE,
            .channels = 2,
        };
        const attr = PaBufferAttr{
            .maxlength = 9600 * 4,
            .tlength = 2400 * 4, // ~50 ms target playback buffer
            .prebuf = 0xffffffff,
            .minreq = 0xffffffff,
            .fragsize = 0xffffffff,
        };
        var err: c_int = 0;
        const handle = pa_simple_new(
            null,
            "fauxpi",
            1, // PA_STREAM_PLAYBACK
            null,
            "Raspberry Pi Audio",
            &spec,
            null,
            &attr,
            &err,
        ) orelse {
            lib.close();
            return false;
        };

        self.pa_lib = lib;
        self.pa_handle = handle;
        self.pa_simple_write = pa_write;
        self.pa_simple_free = pa_free;
        return true;
    }

    fn tryOpenAlsa(self: *HostAudioOutput) bool {
        var lib = std.DynLib.open("libasound.so.2") catch return false;
        const snd_pcm_open = lib.lookup(
            *const fn (*?*SndPcm, [*:0]const u8, c_int, c_int) callconv(.c) c_int,
            "snd_pcm_open",
        ) orelse {
            lib.close();
            return false;
        };
        const snd_pcm_set_params = lib.lookup(
            *const fn (*SndPcm, c_int, c_int, c_uint, c_uint, c_int, c_uint) callconv(.c) c_int,
            "snd_pcm_set_params",
        ) orelse {
            lib.close();
            return false;
        };
        const pcm_writei = lib.lookup(
            *const fn (*SndPcm, *const anyopaque, c_ulong) callconv(.c) c_long,
            "snd_pcm_writei",
        ) orelse {
            lib.close();
            return false;
        };
        const pcm_recover = lib.lookup(
            *const fn (*SndPcm, c_int, c_int) callconv(.c) c_int,
            "snd_pcm_recover",
        );
        const pcm_prepare = lib.lookup(
            *const fn (*SndPcm) callconv(.c) c_int,
            "snd_pcm_prepare",
        );
        const pcm_close = lib.lookup(
            *const fn (*SndPcm) callconv(.c) c_int,
            "snd_pcm_close",
        ) orelse {
            lib.close();
            return false;
        };

        var handle: ?*SndPcm = null;
        if (snd_pcm_open(&handle, "default", 0, 0) < 0 or handle == null) {
            lib.close();
            return false;
        }
        // SND_PCM_FORMAT_S16_LE = 2, SND_PCM_ACCESS_RW_INTERLEAVED = 3, 2 channels, 48000 Hz, soft_resample=1, latency=50000us
        if (snd_pcm_set_params(handle.?, 2, 3, 2, audio_mod.AudioFifo.HOST_SAMPLE_RATE, 1, 50_000) < 0) {
            _ = pcm_close(handle.?);
            lib.close();
            return false;
        }

        self.alsa_lib = lib;
        self.alsa_handle = handle;
        self.snd_pcm_writei = pcm_writei;
        self.snd_pcm_recover = pcm_recover;
        self.snd_pcm_prepare = pcm_prepare;
        self.snd_pcm_close = pcm_close;
        return true;
    }

    fn closeBackend(self: *HostAudioOutput) void {
        if (self.pa_handle) |h| {
            if (self.pa_simple_free) |free_fn| free_fn(h);
            self.pa_handle = null;
        }
        if (self.pa_lib) |*lib| {
            lib.close();
            self.pa_lib = null;
        }
        if (self.alsa_handle) |h| {
            if (self.snd_pcm_close) |close_fn| _ = close_fn(h);
            self.alsa_handle = null;
        }
        if (self.alsa_lib) |*lib| {
            lib.close();
            self.alsa_lib = null;
        }
    }

    fn workerMain(self: *HostAudioOutput) void {
        var backend_initialized = false;
        var buf: [512 * 2]i16 = undefined;

        while (self.running.load(.acquire)) {
            if (self.paused.load(.acquire)) {
                var req: linux.timespec = .{ .sec = 0, .nsec = 5_000_000 };
                _ = linux.nanosleep(&req, null);
                continue;
            }

            const frames = self.fifo.popFrames(&buf);
            if (frames == 0) {
                var req: linux.timespec = .{ .sec = 0, .nsec = 2_000_000 };
                _ = linux.nanosleep(&req, null);
                continue;
            }

            if (!backend_initialized) {
                backend_initialized = true;
                if (!self.tryOpenPulse()) {
                    _ = self.tryOpenAlsa();
                }
            }

            if (self.pa_handle) |pa| {
                if (self.pa_simple_write) |write_fn| {
                    var err: c_int = 0;
                    _ = write_fn(pa, @ptrCast(&buf), frames * 4, &err);
                }
            } else if (self.alsa_handle) |pcm| {
                if (self.snd_pcm_writei) |writei_fn| {
                    const rc = writei_fn(pcm, @ptrCast(&buf), @intCast(frames));
                    if (rc < 0) {
                        if (self.snd_pcm_recover) |rec_fn| {
                            _ = rec_fn(pcm, @intCast(rc), 1);
                        } else if (self.snd_pcm_prepare) |prep_fn| {
                            _ = prep_fn(pcm);
                        }
                    }
                }
            }
        }
    }
};
