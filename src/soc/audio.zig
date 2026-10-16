const std = @import("std");
const host_posix = @import("../host/posix.zig");

/// Lock-free Single-Producer Single-Consumer (SPSC) stereo 16-bit PCM FIFO at 48 kHz.
/// Producer: emulated BCM2835 SoC thread (`vc4-hdmi` MAI DMA, `vchiq` `AUDS`, or `bcm2835-pwm`).
/// Consumer: host audio output thread (`src/app/audio.zig`).
pub const AudioFifo = struct {
    pub const HOST_SAMPLE_RATE: u32 = 48_000;
    pub const CAPACITY: u32 = 16_384; // ~341 ms at 48 kHz stereo (power of two)
    pub const MASK: u32 = CAPACITY - 1;

    /// Interleaved stereo samples (`samples[idx * 2 + 0]` = left, `samples[idx * 2 + 1]` = right)
    samples: [CAPACITY * 2]i16 = [_]i16{0} ** (CAPACITY * 2),
    write_idx: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    read_idx: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    consumer_sleeping: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Resampler state (guest sample rate -> 48 kHz)
    phase_fp: u32 = 0,
    prev_left: i16 = 0,
    prev_right: i16 = 0,
    last_src_rate: u32 = HOST_SAMPLE_RATE,

    /// Total stereo frames pushed since initialization (for diagnostics and tests)
    total_frames_pushed: u64 = 0,

    pub fn availableFrames(self: *const AudioFifo) u32 {
        const w = self.write_idx.load(.acquire);
        const r = self.read_idx.load(.acquire);
        return w -% r;
    }

    pub fn clear(self: *AudioFifo) void {
        const w = self.write_idx.load(.acquire);
        self.read_idx.store(w, .release);
        self.phase_fp = 0;
    }

    pub fn pushFrame48k(self: *AudioFifo, left: i16, right: i16) void {
        const w = self.write_idx.load(.monotonic);
        const r = self.read_idx.load(.acquire);
        if (w -% r >= CAPACITY) {
            // Drop oldest frame if consumer falls behind so emulation never blocks
            self.read_idx.store(r +% 1, .release);
        }
        const slot = (w & MASK) * 2;
        self.samples[slot] = left;
        self.samples[slot + 1] = right;
        self.write_idx.store(w +% 1, .release);
        self.total_frames_pushed += 1;
        if (self.consumer_sleeping.load(.acquire) != 0) {
            self.wakeConsumer();
        }
    }

    pub fn wakeConsumer(self: *AudioFifo) void {
        host_posix.futexWake(&self.write_idx.raw);
    }

    pub fn waitForFrames(
        self: *AudioFifo,
        running: *const std.atomic.Value(bool),
        paused: *const std.atomic.Value(bool),
    ) void {
        if (!running.load(.acquire)) return;
        const w = self.write_idx.load(.acquire);
        const r = self.read_idx.load(.acquire);
        if (!paused.load(.acquire) and w != r) return;

        self.consumer_sleeping.store(1, .seq_cst);
        defer self.consumer_sleeping.store(0, .release);

        if (!running.load(.acquire)) return;
        const w2 = self.write_idx.load(.seq_cst);
        const r2 = self.read_idx.load(.acquire);
        if (!paused.load(.acquire) and w2 != r2) return;

        host_posix.futexWait(&self.write_idx.raw, w2);
    }

    /// Pushes one stereo sample frame at `src_rate_hz`, resampling linearly to `HOST_SAMPLE_RATE` (48 kHz).
    pub fn pushStereoSample(self: *AudioFifo, left: i16, right: i16, src_rate_hz: u32) void {
        const rate = if (src_rate_hz >= 4_000 and src_rate_hz <= 192_000) src_rate_hz else HOST_SAMPLE_RATE;
        if (rate != self.last_src_rate) {
            self.last_src_rate = rate;
            self.phase_fp = 0;
            self.prev_left = left;
            self.prev_right = right;
        }

        if (rate == HOST_SAMPLE_RATE) {
            self.prev_left = left;
            self.prev_right = right;
            self.pushFrame48k(left, right);
            return;
        }

        const step_fp: u32 = @intCast((@as(u64, rate) << 16) / HOST_SAMPLE_RATE);
        while (self.phase_fp < 65536) {
            const frac: i32 = @intCast(self.phase_fp);
            const l_interp = @as(i32, self.prev_left) + (((@as(i32, left) - @as(i32, self.prev_left)) * frac) >> 16);
            const r_interp = @as(i32, self.prev_right) + (((@as(i32, right) - @as(i32, self.prev_right)) * frac) >> 16);
            self.pushFrame48k(
                @intCast(std.math.clamp(l_interp, -32768, 32767)),
                @intCast(std.math.clamp(r_interp, -32768, 32767)),
            );
            self.phase_fp += step_fp;
        }
        self.phase_fp -= 65536;
        self.prev_left = left;
        self.prev_right = right;
    }

    /// Pops up to `out_interleaved.len / 2` stereo frames into `out_interleaved` (`[L, R, L, R, ...]`).
    /// Returns the number of stereo frames popped.
    pub fn popFrames(self: *AudioFifo, out_interleaved: []i16) usize {
        const max_frames = out_interleaved.len / 2;
        var r = self.read_idx.load(.monotonic);
        const w = self.write_idx.load(.acquire);
        const avail = w -% r;
        const count: usize = @min(max_frames, avail);
        for (0..count) |i| {
            const slot = (r & MASK) * 2;
            out_interleaved[i * 2] = self.samples[slot];
            out_interleaved[i * 2 + 1] = self.samples[slot + 1];
            r +%= 1;
        }
        self.read_idx.store(r, .release);
        return count;
    }
};

/// BCM2835 VideoCore VCHIQ Doorbell (`brcm,bcm2835-vchiq`) at `0x2000b840` (size `0x3c`)
/// and shared-memory slot protocol with `AUDS` (`bcm2835-audio`) and `KEEP` services.
pub const Vchiq = struct {
    pub const BASE_ADDR: u32 = 0x2000b840;
    pub const SIZE: u32 = 0x3c;

    pub const ARM_DS_ACTIVE: u32 = 1 << 2;

    // VCHIQ message types
    pub const VCHIQ_MSG_PADDING: u32 = 0;
    pub const VCHIQ_MSG_CONNECT: u32 = 1;
    pub const VCHIQ_MSG_OPEN: u32 = 2;
    pub const VCHIQ_MSG_OPENACK: u32 = 3;
    pub const VCHIQ_MSG_CLOSE: u32 = 4;
    pub const VCHIQ_MSG_DATA: u32 = 5;
    pub const VCHIQ_MSG_BULK_RX: u32 = 6;
    pub const VCHIQ_MSG_BULK_TX: u32 = 7;
    pub const VCHIQ_MSG_BULK_RX_DONE: u32 = 8;
    pub const VCHIQ_MSG_BULK_TX_DONE: u32 = 9;
    pub const VCHIQ_MSG_PAUSE: u32 = 10;
    pub const VCHIQ_MSG_RESUME: u32 = 11;
    pub const VCHIQ_MSG_REMOTE_USE: u32 = 12;
    pub const VCHIQ_MSG_REMOTE_RELEASE: u32 = 13;
    pub const VCHIQ_MSG_REMOTE_USE_ACTIVE: u32 = 14;

    // VC_AUDIO_MSG_TYPE_* constants (from vc_vchi_audioserv_defs.h)
    pub const VC_AUDIO_MSG_TYPE_RESULT: u32 = 0;
    pub const VC_AUDIO_MSG_TYPE_COMPLETE: u32 = 1;
    pub const VC_AUDIO_MSG_TYPE_CONFIG: u32 = 2;
    pub const VC_AUDIO_MSG_TYPE_CONTROL: u32 = 3;
    pub const VC_AUDIO_MSG_TYPE_OPEN: u32 = 4;
    pub const VC_AUDIO_MSG_TYPE_CLOSE: u32 = 5;
    pub const VC_AUDIO_MSG_TYPE_START: u32 = 6;
    pub const VC_AUDIO_MSG_TYPE_STOP: u32 = 7;
    pub const VC_AUDIO_MSG_TYPE_WRITE: u32 = 8;

    // VC_SM_MSG_TYPE_* constants (from vc_sm_defs.h)
    pub const VC_SM_MSG_TYPE_ALLOC: u32 = 0;
    pub const VC_SM_MSG_TYPE_LOCK: u32 = 1;
    pub const VC_SM_MSG_TYPE_UNLOCK: u32 = 2;
    pub const VC_SM_MSG_TYPE_UNLOCK_NOANS: u32 = 3;
    pub const VC_SM_MSG_TYPE_FREE: u32 = 4;
    pub const VC_SM_MSG_TYPE_RESIZE: u32 = 5;
    pub const VC_SM_MSG_TYPE_WALK_ALLOC: u32 = 6;
    pub const VC_SM_MSG_TYPE_ACTION_CLEAN: u32 = 7;
    pub const VC_SM_MSG_TYPE_IMPORT: u32 = 8;
    pub const VC_SM_MSG_TYPE_CLIENT_VERSION: u32 = 9;
    pub const VC_SM_MSG_TYPE_VC_MEM_REQUEST_REPLY: u32 = 10;
    pub const VC_SM_MSG_TYPE_RELEASED: u32 = 11;
    pub const VC_SM_MSG_TYPE_VC_MEM_REQUEST: u32 = 12;

    pub const SmemResource = struct {
        active: bool = false,
        vc_handle: u32 = 0,
        addr: u32 = 0,
        size: u32 = 0,
        kernel_id: u32 = 0,
    };

    // MMAL_MSG_TYPE_* constants (from mmal-msg.h)
    pub const MMAL_MAGIC: u32 = 0x6C616D6D; // 'mmal' little-endian
    pub const MMAL_MSG_TYPE_QUIT: u32 = 1;
    pub const MMAL_MSG_TYPE_SERVICE_CLOSED: u32 = 2;
    pub const MMAL_MSG_TYPE_GET_VERSION: u32 = 3;
    pub const MMAL_MSG_TYPE_COMPONENT_CREATE: u32 = 4;
    pub const MMAL_MSG_TYPE_COMPONENT_DESTROY: u32 = 5;
    pub const MMAL_MSG_TYPE_COMPONENT_ENABLE: u32 = 6;
    pub const MMAL_MSG_TYPE_COMPONENT_DISABLE: u32 = 7;
    pub const MMAL_MSG_TYPE_PORT_INFO_GET: u32 = 8;
    pub const MMAL_MSG_TYPE_PORT_INFO_SET: u32 = 9;
    pub const MMAL_MSG_TYPE_PORT_ACTION: u32 = 10;
    pub const MMAL_MSG_TYPE_BUFFER_FROM_HOST: u32 = 11;
    pub const MMAL_MSG_TYPE_BUFFER_TO_HOST: u32 = 12;
    pub const MMAL_MSG_TYPE_GET_STATS: u32 = 13;
    pub const MMAL_MSG_TYPE_PORT_PARAMETER_SET: u32 = 14;
    pub const MMAL_MSG_TYPE_PORT_PARAMETER_GET: u32 = 15;
    pub const MMAL_MSG_TYPE_EVENT_TO_HOST: u32 = 16;
    pub const MMAL_MSG_TYPE_GET_CORE_STATS_FOR_PORT: u32 = 17;
    pub const MMAL_MSG_TYPE_OPAQUE_ALLOCATOR: u32 = 18;
    pub const MMAL_MSG_TYPE_CONSUME_MEM: u32 = 19;
    pub const MMAL_MSG_TYPE_LMK: u32 = 20;
    pub const MMAL_MSG_TYPE_OPAQUE_ALLOCATOR_DESC: u32 = 21;
    pub const MMAL_MSG_TYPE_DRM_GET_LHS32: u32 = 22;
    pub const MMAL_MSG_TYPE_DRM_GET_TIME: u32 = 23;
    pub const MMAL_MSG_TYPE_BUFFER_FROM_HOST_ZEROLEN: u32 = 24;
    pub const MMAL_MSG_TYPE_PORT_FLUSH: u32 = 25;
    pub const MMAL_MSG_TYPE_HOST_LOG: u32 = 26;

    // MMAL parameter IDs
    pub const MMAL_PARAMETER_SUPPORTED_ENCODINGS: u32 = 1;
    pub const MMAL_PARAMETER_CAMERA_INFO: u32 = 0x1001c;

    pub const MmalCompKind = enum(u8) {
        generic = 0,
        camera_info = 1,
        camera = 2,
        isp = 3,
        video_decode = 4,
        video_encode = 5,
        image_encode = 6,
        video_render = 7,
    };

    pub const MmalPortState = struct {
        configured: bool = false,
        is_enabled: u32 = 0,
        buffer_num: u32 = 1,
        buffer_size: u32 = 4096,
        format: [32]u8 = [_]u8{0} ** 32,
        es: [44]u8 = [_]u8{0} ** 44,
    };

    pub const MmalComponent = struct {
        active: bool = false,
        kind: MmalCompKind = .generic,
        ports: [8]MmalPortState = [_]MmalPortState{.{}} ** 8,
    };

    // Layout offsets within vchiq_slot_zero (sizeof(vchiq_shared_state) == 372 with DEBUG_MAX == 11)
    const MASTER_OFFSET: u32 = 32;
    const SLAVE_OFFSET: u32 = 404;
    const SLOTS_INFO_OFFSET: u32 = 776;
    const SLOT_SIZE: u32 = 4096;

    // Layout offsets within vchiq_shared_state
    const STATE_INITIALISED: u32 = 0;
    const STATE_SLOT_FIRST: u32 = 4;
    const STATE_SLOT_LAST: u32 = 8;
    const STATE_SLOT_SYNC: u32 = 12;
    const STATE_TRIGGER_ARMED: u32 = 16;
    const STATE_TRIGGER_FIRED: u32 = 20;
    const STATE_TX_POS: u32 = 28;
    const STATE_RECYCLE_ARMED: u32 = 32;
    const STATE_RECYCLE_FIRED: u32 = 36;
    const STATE_SLOT_QUEUE_RECYCLE: u32 = 44;
    const STATE_SYNC_TRIGGER_ARMED: u32 = 48;
    const STATE_SYNC_TRIGGER_FIRED: u32 = 52;
    const STATE_SYNC_RELEASE_ARMED: u32 = 60;
    const STATE_SYNC_RELEASE_FIRED: u32 = 64;
    const STATE_SLOT_QUEUE: u32 = 72;

    pub const PendingComplete = struct {
        count: u32 = 0,
        cookie1: u32 = 0,
        cookie2: u32 = 0,
        remaining_us: u64 = 0,
        active: bool = false,
    };

    slot_zero_phys: u32 = 0,
    initialized: bool = false,
    bell0_active: bool = false,

    // Master (VPU -> ARM) slot state
    vc_current_slot: u32 = 0,
    vc_slot_avail: u32 = 0,
    vc_tx_pos: u32 = 0,

    // Slave (ARM -> VPU) slot parsing state
    arm_current_slot: u32 = 0,
    arm_slot_queue_avail: u32 = 0,
    arm_parse_pos: u32 = 0,

    // AUDS service state (vc_port = 1)
    auds_arm_port: u12 = 0,
    auds_channels: u32 = 2,
    auds_samplerate: u32 = 48_000,
    auds_bps: u32 = 16,
    auds_dest: u32 = 1, // 0 = auto, 1 = headphones (3.5mm jack), 2 = HDMI
    auds_volume_atten: i32 = 0, // 1/256 dB attenuation (0 = 0dB full volume, >= 20000 = muted)
    auds_started: bool = false,

    // Pending AUDS write payload tracking
    auds_write_remaining: u32 = 0,
    auds_write_total: u32 = 0,
    auds_cookie1: u32 = 0,
    auds_cookie2: u32 = 0,
    pcm_carry_buf: [4]u8 = [_]u8{0} ** 4,
    pcm_carry_len: u8 = 0,

    // Paced completion queue so ALSA ring buffer advances at real sample rate
    pending_completes: [32]PendingComplete = [_]PendingComplete{.{}} ** 32,
    pending_head: usize = 0,
    pending_tail: usize = 0,
    pending_count: usize = 0,

    // SMEM service state (vc_port = 3)
    smem_arm_port: u12 = 0,
    smem_client_version: u32 = 0,
    smem_next_handle: u32 = 1,
    smem_next_alloc_addr: u32 = 0xdf00_0000,
    smem_resources: [64]SmemResource = [_]SmemResource{.{}} ** 64,

    // MMAL service state (vc_port = 4)
    mmal_arm_port: u12 = 0,
    mmal_next_comp_handle: u32 = 1,
    mmal_components: [32]MmalComponent = [_]MmalComponent{.{}} ** 32,

    pub fn irqPending(self: *const Vchiq) bool {
        return self.bell0_active;
    }

    fn makeMsgid(msg_type: u32, srcport: u12, dstport: u12) u32 {
        return (msg_type << 24) | (@as(u32, srcport) << 12) | @as(u32, dstport);
    }

    /// Handles Mailbox Property Tag `0x00048010` (`RPI_FIRMWARE_VCHIQ_INIT`).
    pub fn initSlotZero(self: *Vchiq, channel_base: u32, ram: []u8) u32 {
        const base = channel_base & 0x1FFFFFFF;
        if (base + 0x1000 > ram.len) return 1;

        self.slot_zero_phys = base;
        self.initialized = true;
        self.bell0_active = false;

        const master = base + MASTER_OFFSET;
        const slot_first = std.mem.readInt(u32, ram[master + STATE_SLOT_FIRST ..][0..4], .little);
        const slot_last = std.mem.readInt(u32, ram[master + STATE_SLOT_LAST ..][0..4], .little);
        const slot_sync = std.mem.readInt(u32, ram[master + STATE_SLOT_SYNC ..][0..4], .little);

        if (slot_last < slot_first or slot_last >= 128) return 1;
        const sync_off = base + slot_sync * SLOT_SIZE;
        if (sync_off + 4 <= ram.len) {
            std.mem.writeInt(u32, ram[sync_off..][0..4], VCHIQ_MSG_PADDING, .little);
        }

        // Populate master.slot_queue with master's available slots
        const num_slots = @min(slot_last - slot_first + 1, 64);
        var i: u32 = 0;
        while (i < num_slots) : (i += 1) {
            const q_off = master + STATE_SLOT_QUEUE + i * 4;
            std.mem.writeInt(u32, ram[q_off..][0..4], slot_first + i, .little);
        }
        std.mem.writeInt(u32, ram[master + STATE_SLOT_QUEUE_RECYCLE ..][0..4], num_slots, .little);
        std.mem.writeInt(u32, ram[master + STATE_TX_POS ..][0..4], 0, .little);
        // Keep master remote_events armed = 1 so Linux remote_event_signal() always writes BELL2
        std.mem.writeInt(u32, ram[master + STATE_TRIGGER_ARMED ..][0..4], 1, .little);
        std.mem.writeInt(u32, ram[master + STATE_RECYCLE_ARMED ..][0..4], 1, .little);
        std.mem.writeInt(u32, ram[master + STATE_SYNC_TRIGGER_ARMED ..][0..4], 1, .little);
        std.mem.writeInt(u32, ram[master + STATE_SYNC_RELEASE_ARMED ..][0..4], 1, .little);

        // Allocate first master slot for VPU -> ARM messages
        self.vc_current_slot = slot_first;
        self.vc_slot_avail = 1;
        self.vc_tx_pos = 0;
        const first_slot_off = base + slot_first * SLOT_SIZE;
        if (first_slot_off + 4 <= ram.len) {
            std.mem.writeInt(u32, ram[first_slot_off..][0..4], VCHIQ_MSG_PADDING, .little);
        }

        // Reset slave parsing state (will latch slave.slot_queue[0] once slave.initialised == 1)
        self.arm_current_slot = 0;
        self.arm_slot_queue_avail = 0;
        self.arm_parse_pos = 0;
        self.pending_head = 0;
        self.pending_tail = 0;
        self.pending_count = 0;
        self.auds_write_remaining = 0;
        self.pcm_carry_len = 0;
        self.smem_arm_port = 0;
        self.smem_client_version = 0;
        self.smem_next_handle = 1;
        self.smem_next_alloc_addr = 0xdf00_0000;
        self.smem_resources = [_]SmemResource{.{}} ** 64;
        self.mmal_arm_port = 0;
        self.mmal_next_comp_handle = 1;
        self.mmal_components = [_]MmalComponent{.{}} ** 32;

        // Mark master as initialised
        std.mem.writeInt(u32, ram[master + STATE_INITIALISED ..][0..4], 1, .little);
        return 0;
    }

    pub fn read32(self: *Vchiq, offset: u32) u32 {
        if (offset == 0x00) { // BELL0
            const status: u32 = if (self.bell0_active) ARM_DS_ACTIVE else 0;
            self.bell0_active = false;
            return status;
        }
        return 0;
    }

    pub fn write32(
        self: *Vchiq,
        offset: u32,
        val: u32,
        ram: []u8,
        audio_fifo: *AudioFifo,
        audio_connected: bool,
        hdmi_connected: bool,
    ) void {
        _ = val;
        if (offset == 0x08) { // BELL2: ARM signals VideoCore
            self.processArmSlots(ram, audio_fifo, audio_connected, hdmi_connected);
        }
    }

    /// Advances paced VCHIQ `AUDS` buffer completion notifications by `elapsed_us`.
    pub fn advanceAudio(self: *Vchiq, elapsed_us: u64, ram: []u8) void {
        if (!self.initialized or self.pending_count == 0) return;

        var rem_us = elapsed_us;
        while (self.pending_count > 0 and rem_us > 0) {
            var item = &self.pending_completes[self.pending_head];
            if (!item.active) {
                self.pending_head = (self.pending_head + 1) % self.pending_completes.len;
                self.pending_count -= 1;
                continue;
            }
            if (rem_us >= item.remaining_us) {
                rem_us -= item.remaining_us;
                item.remaining_us = 0;
                item.active = false;
                const count = item.count;
                const cookie1 = item.cookie1;
                const cookie2 = item.cookie2;
                self.pending_head = (self.pending_head + 1) % self.pending_completes.len;
                self.pending_count -= 1;

                var resp: [20]u8 = [_]u8{0} ** 20;
                std.mem.writeInt(u32, resp[0..4], VC_AUDIO_MSG_TYPE_COMPLETE, .little);
                std.mem.writeInt(u32, resp[4..8], count, .little);
                std.mem.writeInt(u32, resp[8..12], cookie1, .little);
                std.mem.writeInt(u32, resp[12..16], cookie2, .little);
                self.sendVcMessage(ram, makeMsgid(VCHIQ_MSG_DATA, 1, self.auds_arm_port), &resp);
            } else {
                item.remaining_us -= rem_us;
                break;
            }
        }
    }

    fn processArmSlots(
        self: *Vchiq,
        ram: []u8,
        audio_fifo: *AudioFifo,
        audio_connected: bool,
        hdmi_connected: bool,
    ) void {
        if (!self.initialized) return;
        const base = self.slot_zero_phys;
        if (base + 0x1000 > ram.len) return;

        const master = base + MASTER_OFFSET;
        const slave = base + SLAVE_OFFSET;

        // Clear master remote_event fired flags and keep armed = 1 so ARM continues ringing BELL2
        std.mem.writeInt(u32, ram[master + STATE_TRIGGER_FIRED ..][0..4], 0, .little);
        std.mem.writeInt(u32, ram[master + STATE_TRIGGER_ARMED ..][0..4], 1, .little);
        std.mem.writeInt(u32, ram[master + STATE_RECYCLE_FIRED ..][0..4], 0, .little);
        std.mem.writeInt(u32, ram[master + STATE_RECYCLE_ARMED ..][0..4], 1, .little);
        std.mem.writeInt(u32, ram[master + STATE_SYNC_TRIGGER_FIRED ..][0..4], 0, .little);
        std.mem.writeInt(u32, ram[master + STATE_SYNC_TRIGGER_ARMED ..][0..4], 1, .little);
        std.mem.writeInt(u32, ram[master + STATE_SYNC_RELEASE_FIRED ..][0..4], 0, .little);
        std.mem.writeInt(u32, ram[master + STATE_SYNC_RELEASE_ARMED ..][0..4], 1, .little);

        const slave_init = std.mem.readInt(u32, ram[slave + STATE_INITIALISED ..][0..4], .little);
        if (slave_init == 0) return;

        if (self.arm_current_slot == 0) {
            self.arm_current_slot = std.mem.readInt(u32, ram[slave + STATE_SLOT_QUEUE ..][0..4], .little);
            self.arm_slot_queue_avail = 1;
        }

        const slave_tx_pos = std.mem.readInt(u32, ram[slave + STATE_TX_POS ..][0..4], .little);
        var safety: usize = 512;

        while (self.arm_parse_pos < slave_tx_pos and safety > 0) : (safety -= 1) {
            const offset_in_slot = self.arm_parse_pos & (SLOT_SIZE - 1);
            if (offset_in_slot + 8 > SLOT_SIZE) {
                self.recycleArmSlotAndAdvance(ram);
                continue;
            }

            const slot_phys = base + self.arm_current_slot * SLOT_SIZE;
            if (slot_phys + SLOT_SIZE > ram.len) break;

            const msgid = std.mem.readInt(u32, ram[slot_phys + offset_in_slot ..][0..4], .little);
            const size = std.mem.readInt(u32, ram[slot_phys + offset_in_slot + 4 ..][0..4], .little);

            if (msgid == VCHIQ_MSG_PADDING) {
                self.recycleArmSlotAndAdvance(ram);
                continue;
            }

            const payload_start = slot_phys + offset_in_slot + 8;
            const safe_size = @min(size, SLOT_SIZE - offset_in_slot - 8);
            if (payload_start + safe_size <= ram.len) {
                self.handleArmMessage(
                    msgid,
                    ram[payload_start .. payload_start + safe_size],
                    ram,
                    audio_fifo,
                    audio_connected,
                    hdmi_connected,
                );
            }

            const stride = (size + 8 + 7) & ~@as(u32, 7);
            self.arm_parse_pos +%= stride;
            if ((self.arm_parse_pos & (SLOT_SIZE - 1)) == 0) {
                self.recycleArmSlotAndAdvance(ram);
            }
        }
    }

    fn recycleArmSlotAndAdvance(self: *Vchiq, ram: []u8) void {
        const base = self.slot_zero_phys;
        const slave = base + SLAVE_OFFSET;

        // Return finished arm_current_slot to slave.slot_queue
        const recycle_idx = std.mem.readInt(u32, ram[slave + STATE_SLOT_QUEUE_RECYCLE ..][0..4], .little);
        const q_off = slave + STATE_SLOT_QUEUE + (recycle_idx & 63) * 4;
        std.mem.writeInt(u32, ram[q_off..][0..4], self.arm_current_slot, .little);
        std.mem.writeInt(u32, ram[slave + STATE_SLOT_QUEUE_RECYCLE ..][0..4], recycle_idx +% 1, .little);

        // Signal slave.recycle event so ARM knows the slot is free
        std.mem.writeInt(u32, ram[slave + STATE_RECYCLE_FIRED ..][0..4], 1, .little);
        self.bell0_active = true;

        // Advance to next slot queued by ARM
        const next_q_off = slave + STATE_SLOT_QUEUE + (self.arm_slot_queue_avail & 63) * 4;
        self.arm_current_slot = std.mem.readInt(u32, ram[next_q_off..][0..4], .little);
        self.arm_slot_queue_avail +%= 1;
        self.arm_parse_pos = (self.arm_parse_pos & ~@as(u32, SLOT_SIZE - 1)) +% SLOT_SIZE;
    }

    fn handleArmMessage(
        self: *Vchiq,
        msgid: u32,
        payload: []const u8,
        ram: []u8,
        audio_fifo: *AudioFifo,
        audio_connected: bool,
        hdmi_connected: bool,
    ) void {
        const msg_type = msgid >> 24;
        const srcport: u12 = @truncate((msgid >> 12) & 0xfff);
        const dstport: u12 = @truncate(msgid & 0xfff);

        switch (msg_type) {
            VCHIQ_MSG_CONNECT => {
                self.sendVcMessage(ram, makeMsgid(VCHIQ_MSG_CONNECT, 0, 0), &.{});
            },
            VCHIQ_MSG_OPEN => {
                if (payload.len >= 4) {
                    const fourcc = std.mem.readInt(u32, payload[0..4], .little);
                    // 'AUDS' (0x41554453 or 0x53445541)
                    if (fourcc == 0x41554453 or fourcc == 0x53445541) {
                        self.auds_arm_port = srcport;
                        var ack: [2]u8 = undefined;
                        std.mem.writeInt(i16, &ack, 2, .little); // peer_version = 2
                        self.sendVcMessage(ram, makeMsgid(VCHIQ_MSG_OPENACK, 1, srcport), &ack);
                        return;
                    }
                    // 'KEEP' (0x4B454550 or 0x5045454B)
                    if (fourcc == 0x4B454550 or fourcc == 0x5045454B) {
                        var ack: [2]u8 = undefined;
                        std.mem.writeInt(i16, &ack, 1, .little);
                        self.sendVcMessage(ram, makeMsgid(VCHIQ_MSG_OPENACK, 2, srcport), &ack);
                        return;
                    }
                    // 'SMEM' (0x534D454D or 0x4D454D53) - VideoCore Shared Memory service (vc_sm_cma / vmcs_sm)
                    if (fourcc == 0x534D454D or fourcc == 0x4D454D53) {
                        self.smem_arm_port = srcport;
                        var ack: [2]u8 = undefined;
                        const req_ver: i16 = if (payload.len >= 10) std.mem.readInt(i16, payload[8..10], .little) else 1;
                        std.mem.writeInt(i16, &ack, if (req_ver > 0) req_ver else 1, .little);
                        self.sendVcMessage(ram, makeMsgid(VCHIQ_MSG_OPENACK, 3, srcport), &ack);
                        return;
                    }
                    // 'mmal' (0x6C616D6D or 0x6D6D616C) - VideoCore Multi-Media Abstraction Layer (vchiq_mmal)
                    if (fourcc == 0x6C616D6D or fourcc == 0x6D6D616C) {
                        self.mmal_arm_port = srcport;
                        var ack: [2]u8 = undefined;
                        const req_ver: i16 = if (payload.len >= 10) std.mem.readInt(i16, payload[8..10], .little) else 15;
                        std.mem.writeInt(i16, &ack, if (req_ver > 0) req_ver else 15, .little);
                        self.sendVcMessage(ram, makeMsgid(VCHIQ_MSG_OPENACK, 4, srcport), &ack);
                        return;
                    }
                }
                // Reject unimplemented services immediately with CLOSE so guest doesn't block
                self.sendVcMessage(ram, makeMsgid(VCHIQ_MSG_CLOSE, 0, srcport), &.{});
            },
            VCHIQ_MSG_CLOSE => {
                if (dstport == 1) {
                    self.auds_started = false;
                    self.auds_write_remaining = 0;
                    self.pending_count = 0;
                }
                self.sendVcMessage(ram, makeMsgid(VCHIQ_MSG_CLOSE, dstport, srcport), &.{});
            },
            VCHIQ_MSG_DATA => {
                if (dstport == 1) {
                    self.handleAudsData(srcport, payload, ram, audio_fifo, audio_connected, hdmi_connected);
                } else if (dstport == 3) {
                    self.handleSmemData(srcport, payload, ram);
                } else if (dstport == 4) {
                    self.handleMmalData(srcport, payload, ram);
                }
            },
            else => {},
        }
    }

    fn handleAudsData(
        self: *Vchiq,
        srcport: u12,
        payload: []const u8,
        ram: []u8,
        audio_fifo: *AudioFifo,
        audio_connected: bool,
        hdmi_connected: bool,
    ) void {
        self.auds_arm_port = srcport;

        // If we are in the middle of receiving raw PCM data bytes following VC_AUDIO_MSG_TYPE_WRITE:
        if (self.auds_write_remaining > 0) {
            const take = @min(@as(u32, @intCast(payload.len)), self.auds_write_remaining);
            self.consumeAudsPcm(payload[0..take], audio_fifo, audio_connected, hdmi_connected);
            self.auds_write_remaining -= take;
            if (self.auds_write_remaining == 0) {
                self.enqueueOrSendWriteComplete(ram);
            }
            return;
        }

        if (payload.len < 4) return;
        const cmd = std.mem.readInt(u32, payload[0..4], .little);

        switch (cmd) {
            VC_AUDIO_MSG_TYPE_OPEN => {
                self.auds_write_remaining = 0;
                self.pcm_carry_len = 0;
            },
            VC_AUDIO_MSG_TYPE_CONFIG => {
                if (payload.len >= 16) {
                    const ch = std.mem.readInt(u32, payload[4..8], .little);
                    const rate = std.mem.readInt(u32, payload[8..12], .little);
                    const bps = std.mem.readInt(u32, payload[12..16], .little);
                    if (ch == 1 or ch == 2) self.auds_channels = ch;
                    if (rate >= 8_000 and rate <= 192_000) self.auds_samplerate = rate;
                    if (bps == 8 or bps == 16) self.auds_bps = bps;
                }
                self.sendAudsResult(ram, 0);
            },
            VC_AUDIO_MSG_TYPE_CONTROL => {
                if (payload.len >= 12) {
                    self.auds_volume_atten = std.mem.readInt(i32, payload[4..8], .little);
                    self.auds_dest = std.mem.readInt(u32, payload[8..12], .little);
                }
                self.sendAudsResult(ram, 0);
            },
            VC_AUDIO_MSG_TYPE_START => {
                self.auds_started = true;
                self.pcm_carry_len = 0;
            },
            VC_AUDIO_MSG_TYPE_STOP => {
                self.auds_started = false;
                self.auds_write_remaining = 0;
                self.pcm_carry_len = 0;
                self.pending_count = 0;
            },
            VC_AUDIO_MSG_TYPE_CLOSE => {
                self.auds_started = false;
                self.auds_write_remaining = 0;
                self.pcm_carry_len = 0;
                self.pending_count = 0;
                self.sendAudsResult(ram, 0);
            },
            VC_AUDIO_MSG_TYPE_WRITE => {
                if (payload.len >= 16) {
                    const count = std.mem.readInt(u32, payload[4..8], .little);
                    self.auds_cookie1 = std.mem.readInt(u32, payload[8..12], .little);
                    self.auds_cookie2 = std.mem.readInt(u32, payload[12..16], .little);
                    self.auds_write_total = count;
                    self.auds_write_remaining = count;
                    if (count == 0) {
                        self.enqueueOrSendWriteComplete(ram);
                    }
                }
            },
            else => {},
        }
    }

    fn sendAudsResult(self: *Vchiq, ram: []u8, success: i32) void {
        var resp: [20]u8 = [_]u8{0} ** 20;
        std.mem.writeInt(u32, resp[0..4], VC_AUDIO_MSG_TYPE_RESULT, .little);
        std.mem.writeInt(i32, resp[4..8], success, .little);
        self.sendVcMessage(ram, makeMsgid(VCHIQ_MSG_DATA, 1, self.auds_arm_port), &resp);
    }

    fn allocSmemHandle(self: *Vchiq) u32 {
        const h = if (self.smem_next_handle == 0) 1 else self.smem_next_handle;
        self.smem_next_handle = h +% 1;
        if (self.smem_next_handle == 0) self.smem_next_handle = 1;
        return h;
    }

    fn recordSmemResource(self: *Vchiq, vc_handle: u32, addr: u32, size: u32, kernel_id: u32) void {
        for (&self.smem_resources) |*slot| {
            if (!slot.active) {
                slot.* = .{
                    .active = true,
                    .vc_handle = vc_handle,
                    .addr = addr,
                    .size = size,
                    .kernel_id = kernel_id,
                };
                return;
            }
        }
        // Overwrite slot 0 if full
        self.smem_resources[0] = .{
            .active = true,
            .vc_handle = vc_handle,
            .addr = addr,
            .size = size,
            .kernel_id = kernel_id,
        };
    }

    fn lookupSmemResource(self: *const Vchiq, vc_handle: u32) ?SmemResource {
        for (&self.smem_resources) |*slot| {
            if (slot.active and slot.vc_handle == vc_handle) {
                return slot.*;
            }
        }
        return null;
    }

    fn freeSmemResource(self: *Vchiq, vc_handle: u32) ?SmemResource {
        for (&self.smem_resources) |*slot| {
            if (slot.active and slot.vc_handle == vc_handle) {
                const res = slot.*;
                slot.* = .{};
                return res;
            }
        }
        return null;
    }

    fn handleSmemData(
        self: *Vchiq,
        srcport: u12,
        payload: []const u8,
        ram: []u8,
    ) void {
        self.smem_arm_port = srcport;
        if (payload.len < 8) return;

        const msg_type = std.mem.readInt(u32, payload[0..4], .little);
        const trans_id = std.mem.readInt(u32, payload[4..8], .little);
        const body = payload[8..];

        switch (msg_type) {
            VC_SM_MSG_TYPE_CLIENT_VERSION => {
                if (body.len >= 4) {
                    self.smem_client_version = std.mem.readInt(u32, body[0..4], .little);
                }
                // Acknowledge client version support via VPU event callback (top bit of trans_id set)
                var resp: [8]u8 = [_]u8{0} ** 8;
                std.mem.writeInt(u32, resp[0..4], VC_SM_MSG_TYPE_CLIENT_VERSION | 0x8000_0000, .little);
                std.mem.writeInt(i32, resp[4..8], 0, .little);
                self.sendVcMessage(ram, makeMsgid(VCHIQ_MSG_DATA, 3, srcport), &resp);
            },
            VC_SM_MSG_TYPE_IMPORT => {
                const addr: u32 = if (body.len >= 8) std.mem.readInt(u32, body[4..8], .little) else 0xc000_0000;
                const size: u32 = if (body.len >= 12) std.mem.readInt(u32, body[8..12], .little) else 4096;
                const kernel_id: u32 = if (body.len >= 16) std.mem.readInt(u32, body[12..16], .little) else 0;
                const res_handle = self.allocSmemHandle();
                self.recordSmemResource(res_handle, addr, size, kernel_id);

                // struct vc_sm_import_result { u32 trans_id; u32 res_handle; }
                var resp: [8]u8 = [_]u8{0} ** 8;
                std.mem.writeInt(u32, resp[0..4], trans_id, .little);
                std.mem.writeInt(u32, resp[4..8], res_handle, .little);
                self.sendVcMessage(ram, makeMsgid(VCHIQ_MSG_DATA, 3, srcport), &resp);
            },
            VC_SM_MSG_TYPE_ALLOC => {
                const base_unit: u32 = if (body.len >= 8) std.mem.readInt(u32, body[4..8], .little) else 4096;
                const num_unit: u32 = if (body.len >= 12) std.mem.readInt(u32, body[8..12], .little) else 1;
                const total_size = @max(base_unit *| num_unit, 4096);
                const res_handle = self.allocSmemHandle();
                const res_mem = self.smem_next_alloc_addr;
                self.smem_next_alloc_addr +%= std.mem.alignForward(u32, total_size, 4096);
                self.recordSmemResource(res_handle, res_mem, total_size, 0);

                // struct vc_sm_alloc_result_t { u32 trans_id; u32 res_handle; u32 res_mem; u32 res_base_size; u32 res_num; }
                var resp: [20]u8 = [_]u8{0} ** 20;
                std.mem.writeInt(u32, resp[0..4], trans_id, .little);
                std.mem.writeInt(u32, resp[4..8], res_handle, .little);
                std.mem.writeInt(u32, resp[8..12], res_mem, .little);
                std.mem.writeInt(u32, resp[12..16], base_unit, .little);
                std.mem.writeInt(u32, resp[16..20], num_unit, .little);
                self.sendVcMessage(ram, makeMsgid(VCHIQ_MSG_DATA, 3, srcport), &resp);
            },
            VC_SM_MSG_TYPE_LOCK => {
                const res_handle: u32 = if (body.len >= 4) std.mem.readInt(u32, body[0..4], .little) else 0;
                const req_mem: u32 = if (body.len >= 8) std.mem.readInt(u32, body[4..8], .little) else 0;
                const res_mem = if (req_mem != 0)
                    req_mem
                else if (self.lookupSmemResource(res_handle)) |r|
                    r.addr
                else
                    0xdf00_0000;

                // struct vc_sm_lock_result_t { u32 trans_id; u32 res_handle; u32 res_mem; u32 res_old_mem; }
                var resp: [16]u8 = [_]u8{0} ** 16;
                std.mem.writeInt(u32, resp[0..4], trans_id, .little);
                std.mem.writeInt(u32, resp[4..8], res_handle, .little);
                std.mem.writeInt(u32, resp[8..12], res_mem, .little);
                std.mem.writeInt(u32, resp[12..16], res_mem, .little);
                self.sendVcMessage(ram, makeMsgid(VCHIQ_MSG_DATA, 3, srcport), &resp);
            },
            VC_SM_MSG_TYPE_FREE => {
                const res_handle: u32 = if (body.len >= 4) std.mem.readInt(u32, body[0..4], .little) else 0;
                const freed = self.freeSmemResource(res_handle);
                if (self.smem_client_version >= 2) {
                    // Protocol >= 2 uses async VC_SM_MSG_TYPE_RELEASED callback (wait_reply == 0 on FREE)
                    const r = freed orelse SmemResource{ .vc_handle = res_handle };
                    var resp: [20]u8 = [_]u8{0} ** 20;
                    std.mem.writeInt(u32, resp[0..4], VC_SM_MSG_TYPE_RELEASED | 0x8000_0000, .little);
                    std.mem.writeInt(u32, resp[4..8], r.addr, .little);
                    std.mem.writeInt(u32, resp[8..12], r.size, .little);
                    std.mem.writeInt(u32, resp[12..16], r.kernel_id, .little);
                    std.mem.writeInt(u32, resp[16..20], res_handle, .little);
                    self.sendVcMessage(ram, makeMsgid(VCHIQ_MSG_DATA, 3, srcport), &resp);
                } else {
                    var resp: [8]u8 = [_]u8{0} ** 8;
                    std.mem.writeInt(u32, resp[0..4], trans_id, .little);
                    std.mem.writeInt(i32, resp[4..8], 0, .little);
                    self.sendVcMessage(ram, makeMsgid(VCHIQ_MSG_DATA, 3, srcport), &resp);
                }
            },
            VC_SM_MSG_TYPE_UNLOCK_NOANS, VC_SM_MSG_TYPE_VC_MEM_REQUEST_REPLY => {},
            else => {
                // Generic struct vc_sm_result_t { u32 trans_id; s32 success; }
                var resp: [8]u8 = [_]u8{0} ** 8;
                std.mem.writeInt(u32, resp[0..4], trans_id, .little);
                std.mem.writeInt(i32, resp[4..8], 0, .little);
                self.sendVcMessage(ram, makeMsgid(VCHIQ_MSG_DATA, 3, srcport), &resp);
            },
        }
    }

    fn mmalPortSlot(port_type: u32, port_index: u32) usize {
        return switch (port_type) {
            1 => 0, // control
            2 => 1 + @as(usize, @min(port_index, 1)), // input 0..1
            3 => 3 + @as(usize, @min(port_index, 3)), // output 0..3
            else => 7,
        };
    }

    fn initDefaultMmalPort(kind: MmalCompKind, port_type: u32, port_index: u32) MmalPortState {
        var port = MmalPortState{
            .configured = true,
            .is_enabled = 0,
            .buffer_num = 1,
            .buffer_size = 4096,
        };
        const is_isp_stats = (kind == .isp and port_type == 3 and port_index == 2);
        const es_type: u32 = if (is_isp_stats) 0 else 3; // 3 = MMAL_ES_TYPE_VIDEO
        const encoding: u32 = if (is_isp_stats)
            0x54415453 // 'STAT' (MMAL_ENCODING_BRCM_STATS)
        else if (kind == .video_decode and port_type == 2)
            0x34363248 // 'H264'
        else if (kind == .video_encode and port_type == 3)
            0x34363248 // 'H264'
        else if (kind == .image_encode and port_type == 3)
            0x4745504A // 'JPEG'
        else
            0x30323449; // 'I420'

        std.mem.writeInt(u32, port.format[0..4], es_type, .little);
        std.mem.writeInt(u32, port.format[4..8], encoding, .little);

        // Default video ES geometry: 1280x720, crop (0,0,1280,720), 30/1 fps, 1/1 PAR
        std.mem.writeInt(u32, port.es[0..4], 1280, .little);
        std.mem.writeInt(u32, port.es[4..8], 720, .little);
        std.mem.writeInt(i32, port.es[8..12], 0, .little);
        std.mem.writeInt(i32, port.es[12..16], 0, .little);
        std.mem.writeInt(i32, port.es[16..20], 1280, .little);
        std.mem.writeInt(i32, port.es[20..24], 720, .little);
        std.mem.writeInt(i32, port.es[24..28], 30, .little);
        std.mem.writeInt(i32, port.es[28..32], 1, .little);
        std.mem.writeInt(i32, port.es[32..36], 1, .little);
        std.mem.writeInt(i32, port.es[36..40], 1, .little);
        return port;
    }

    fn writeMmalHeader(buf: []u8, msg_type: u32, control_service: u32, context: u32) void {
        std.mem.writeInt(u32, buf[0..4], MMAL_MAGIC, .little);
        std.mem.writeInt(u32, buf[4..8], msg_type, .little);
        std.mem.writeInt(u32, buf[8..12], control_service, .little);
        std.mem.writeInt(u32, buf[12..16], context, .little);
        std.mem.writeInt(u32, buf[16..20], 0, .little); // status = MMAL_MSG_STATUS_SUCCESS
        std.mem.writeInt(u32, buf[20..24], 0, .little);
    }

    fn buildMmalPortInfoReply(
        self: *Vchiq,
        resp: *[316]u8,
        msg_type: u32,
        control_service: u32,
        context: u32,
        comp_handle: u32,
        port_type: u32,
        port_index: u32,
    ) void {
        @memset(resp, 0);
        writeMmalHeader(resp[0..24], msg_type, control_service, context);

        const comp_idx: usize = @intCast((if (comp_handle > 0) comp_handle - 1 else 0) % self.mmal_components.len);
        const comp = &self.mmal_components[comp_idx];
        const pslot = mmalPortSlot(port_type, port_index);
        if (!comp.ports[pslot].configured) {
            comp.ports[pslot] = initDefaultMmalPort(comp.kind, port_type, port_index);
        }
        const pstate = &comp.ports[pslot];
        const port_handle: u32 = ((comp_handle & 0xff) << 8) | ((port_type & 0x0f) << 4) | (port_index & 0x0f);

        std.mem.writeInt(u32, resp[24..28], 0, .little); // status = MMAL_MSG_STATUS_SUCCESS
        std.mem.writeInt(u32, resp[28..32], comp_handle, .little);
        std.mem.writeInt(u32, resp[32..36], port_type, .little);
        std.mem.writeInt(u32, resp[36..40], port_index, .little);
        std.mem.writeInt(i32, resp[40..44], 1, .little); // found = 1
        std.mem.writeInt(u32, resp[44..48], port_handle, .little);

        // struct mmal_port at resp[48..112] (64 bytes)
        const port_buf = resp[48..112];
        std.mem.writeInt(u32, port_buf[8..12], port_type, .little);
        std.mem.writeInt(u16, port_buf[12..14], @truncate(port_index), .little);
        std.mem.writeInt(u16, port_buf[14..16], @truncate(port_index), .little);
        std.mem.writeInt(u32, port_buf[16..20], pstate.is_enabled, .little);
        std.mem.writeInt(u32, port_buf[24..28], 1, .little); // buffer_num_min
        std.mem.writeInt(u32, port_buf[28..32], 64, .little); // buffer_size_min
        std.mem.writeInt(u32, port_buf[32..36], 0, .little); // buffer_alignment_min
        std.mem.writeInt(u32, port_buf[36..40], 1, .little); // buffer_num_recommended
        std.mem.writeInt(u32, port_buf[40..44], 4096, .little); // buffer_size_recommended
        std.mem.writeInt(u32, port_buf[44..48], pstate.buffer_num, .little);
        std.mem.writeInt(u32, port_buf[48..52], pstate.buffer_size, .little);

        // struct mmal_es_format at resp[112..144] (32 bytes)
        @memcpy(resp[112..144], &pstate.format);
        // union mmal_es_specific_format at resp[144..188] (44 bytes)
        @memcpy(resp[144..188], &pstate.es);
    }

    fn handleMmalData(
        self: *Vchiq,
        srcport: u12,
        payload: []const u8,
        ram: []u8,
    ) void {
        self.mmal_arm_port = srcport;
        if (payload.len < 24) return;

        const magic = std.mem.readInt(u32, payload[0..4], .little);
        if (magic != MMAL_MAGIC) return;

        const msg_type = std.mem.readInt(u32, payload[4..8], .little);
        const control_service = std.mem.readInt(u32, payload[8..12], .little);
        const context = std.mem.readInt(u32, payload[12..16], .little);

        switch (msg_type) {
            MMAL_MSG_TYPE_GET_VERSION => {
                var resp: [40]u8 = [_]u8{0} ** 40;
                writeMmalHeader(resp[0..24], msg_type, control_service, context);
                std.mem.writeInt(u32, resp[24..28], 0, .little); // flags
                std.mem.writeInt(u32, resp[28..32], 16, .little); // major
                std.mem.writeInt(u32, resp[32..36], 1, .little); // minor
                std.mem.writeInt(u32, resp[36..40], 10, .little); // minimum
                self.sendVcMessage(ram, makeMsgid(VCHIQ_MSG_DATA, 4, srcport), &resp);
            },
            MMAL_MSG_TYPE_COMPONENT_CREATE => {
                const name_raw = if (payload.len >= 156) payload[28..156] else payload[24..];
                const nul_pos = std.mem.indexOfScalar(u8, name_raw, 0) orelse name_raw.len;
                const name = name_raw[0..nul_pos];

                var kind: MmalCompKind = .generic;
                var inputs: u32 = 1;
                var outputs: u32 = 1;
                const clocks: u32 = 0;

                if (std.mem.indexOf(u8, name, "camera_info") != null) {
                    kind = .camera_info;
                    inputs = 0;
                    outputs = 0;
                } else if (std.mem.indexOf(u8, name, "camera") != null) {
                    kind = .camera;
                    inputs = 0;
                    outputs = 3;
                } else if (std.mem.indexOf(u8, name, "isp") != null) {
                    kind = .isp;
                    inputs = 1;
                    outputs = 3;
                } else if (std.mem.indexOf(u8, name, "video_decode") != null) {
                    kind = .video_decode;
                } else if (std.mem.indexOf(u8, name, "video_encode") != null) {
                    kind = .video_encode;
                } else if (std.mem.indexOf(u8, name, "image_encode") != null) {
                    kind = .image_encode;
                } else if (std.mem.indexOf(u8, name, "video_render") != null) {
                    kind = .video_render;
                    inputs = 1;
                    outputs = 0;
                }

                const comp_handle: u32 = ((self.mmal_next_comp_handle - 1) % @as(u32, @intCast(self.mmal_components.len))) + 1;
                self.mmal_next_comp_handle +%= 1;
                if (self.mmal_next_comp_handle == 0) self.mmal_next_comp_handle = 1;

                var comp = MmalComponent{
                    .active = true,
                    .kind = kind,
                };
                comp.ports[mmalPortSlot(1, 0)] = initDefaultMmalPort(kind, 1, 0);
                var p: u32 = 0;
                while (p < inputs) : (p += 1) {
                    comp.ports[mmalPortSlot(2, p)] = initDefaultMmalPort(kind, 2, p);
                }
                p = 0;
                while (p < outputs) : (p += 1) {
                    comp.ports[mmalPortSlot(3, p)] = initDefaultMmalPort(kind, 3, p);
                }
                self.mmal_components[comp_handle - 1] = comp;

                var resp: [44]u8 = [_]u8{0} ** 44;
                writeMmalHeader(resp[0..24], msg_type, control_service, context);
                std.mem.writeInt(u32, resp[24..28], 0, .little); // status = MMAL_MSG_STATUS_SUCCESS
                std.mem.writeInt(u32, resp[28..32], comp_handle, .little);
                std.mem.writeInt(u32, resp[32..36], inputs, .little);
                std.mem.writeInt(u32, resp[36..40], outputs, .little);
                std.mem.writeInt(u32, resp[40..44], clocks, .little);
                self.sendVcMessage(ram, makeMsgid(VCHIQ_MSG_DATA, 4, srcport), &resp);
            },
            MMAL_MSG_TYPE_PORT_INFO_GET => {
                const comp_handle: u32 = if (payload.len >= 28) std.mem.readInt(u32, payload[24..28], .little) else 1;
                const port_type: u32 = if (payload.len >= 32) std.mem.readInt(u32, payload[28..32], .little) else 1;
                const port_index: u32 = if (payload.len >= 36) std.mem.readInt(u32, payload[32..36], .little) else 0;

                var resp: [316]u8 = undefined;
                self.buildMmalPortInfoReply(&resp, msg_type, control_service, context, comp_handle, port_type, port_index);
                self.sendVcMessage(ram, makeMsgid(VCHIQ_MSG_DATA, 4, srcport), &resp);
            },
            MMAL_MSG_TYPE_PORT_INFO_SET => {
                const comp_handle: u32 = if (payload.len >= 28) std.mem.readInt(u32, payload[24..28], .little) else 1;
                const port_type: u32 = if (payload.len >= 32) std.mem.readInt(u32, payload[28..32], .little) else 1;
                const port_index: u32 = if (payload.len >= 36) std.mem.readInt(u32, payload[32..36], .little) else 0;

                const comp_idx: usize = @intCast((if (comp_handle > 0) comp_handle - 1 else 0) % self.mmal_components.len);
                const comp = &self.mmal_components[comp_idx];
                const pslot = mmalPortSlot(port_type, port_index);
                if (!comp.ports[pslot].configured) {
                    comp.ports[pslot] = initDefaultMmalPort(comp.kind, port_type, port_index);
                }
                if (payload.len >= 88) {
                    const req_num = std.mem.readInt(u32, payload[80..84], .little);
                    const req_size = std.mem.readInt(u32, payload[84..88], .little);
                    comp.ports[pslot].buffer_num = @max(req_num, 1);
                    comp.ports[pslot].buffer_size = @max(req_size, 64);
                }
                if (payload.len >= 132) {
                    @memcpy(&comp.ports[pslot].format, payload[100..132]);
                }
                if (payload.len >= 176) {
                    @memcpy(&comp.ports[pslot].es, payload[132..176]);
                }

                var resp: [316]u8 = undefined;
                self.buildMmalPortInfoReply(&resp, msg_type, control_service, context, comp_handle, port_type, port_index);
                self.sendVcMessage(ram, makeMsgid(VCHIQ_MSG_DATA, 4, srcport), &resp);
            },
            MMAL_MSG_TYPE_PORT_ACTION => {
                if (payload.len >= 36) {
                    const comp_handle = std.mem.readInt(u32, payload[24..28], .little);
                    const port_handle = std.mem.readInt(u32, payload[28..32], .little);
                    const action = std.mem.readInt(u32, payload[32..36], .little);
                    const port_type = (port_handle >> 4) & 0x0f;
                    const port_index = port_handle & 0x0f;
                    const comp_idx: usize = @intCast((if (comp_handle > 0) comp_handle - 1 else 0) % self.mmal_components.len);
                    const pslot = mmalPortSlot(port_type, port_index);
                    if (action == 1) {
                        self.mmal_components[comp_idx].ports[pslot].is_enabled = 1;
                    } else if (action == 2) {
                        self.mmal_components[comp_idx].ports[pslot].is_enabled = 0;
                    }
                }
                var resp: [28]u8 = [_]u8{0} ** 28;
                writeMmalHeader(resp[0..24], msg_type, control_service, context);
                std.mem.writeInt(u32, resp[24..28], 0, .little); // status = MMAL_MSG_STATUS_SUCCESS
                self.sendVcMessage(ram, makeMsgid(VCHIQ_MSG_DATA, 4, srcport), &resp);
            },
            MMAL_MSG_TYPE_PORT_PARAMETER_GET => {
                const comp_handle: u32 = if (payload.len >= 28) std.mem.readInt(u32, payload[24..28], .little) else 1;
                const port_handle: u32 = if (payload.len >= 32) std.mem.readInt(u32, payload[28..32], .little) else 0;
                const param_id: u32 = if (payload.len >= 36) std.mem.readInt(u32, payload[32..36], .little) else 0;
                const req_size: u32 = if (payload.len >= 40) std.mem.readInt(u32, payload[36..40], .little) else 8;

                var resp: [420]u8 = [_]u8{0} ** 420;
                writeMmalHeader(resp[0..24], msg_type, control_service, context);
                std.mem.writeInt(u32, resp[24..28], 0, .little); // status = MMAL_MSG_STATUS_SUCCESS
                std.mem.writeInt(u32, resp[28..32], param_id, .little);

                if (param_id == MMAL_PARAMETER_SUPPORTED_ENCODINGS) {
                    const comp_idx: usize = @intCast((if (comp_handle > 0) comp_handle - 1 else 0) % self.mmal_components.len);
                    const kind = self.mmal_components[comp_idx].kind;
                    const port_type = (port_handle >> 4) & 0x0f;
                    const port_index = port_handle & 0x0f;

                    const stats_encs = [_]u32{0x54415453}; // 'STAT'
                    const vdec_in_encs = [_]u32{
                        0x34363248, // 'H264'
                        0x47504A4D, // 'MJPG'
                        0x5634504D, // 'MP4V'
                        0x5632504D, // 'MP2V'
                        0x33363248, // 'H263'
                        0x31435657, // 'WVC1'
                    };
                    const venc_out_encs = [_]u32{
                        0x34363248, // 'H264'
                        0x47504A4D, // 'MJPG'
                    };
                    const ienc_out_encs = [_]u32{
                        0x4745504A, // 'JPEG'
                    };
                    const raw_encs = [_]u32{
                        0x30323449, // 'I420'
                        0x32315659, // 'YV12'
                        0x3231564E, // 'NV12'
                        0x3132564E, // 'NV21'
                        0x56595559, // 'YUYV'
                        0x59565955, // 'UYVY'
                        0x32424752, // 'RGB2' (RGB565)
                        0x33424752, // 'RGB3' (RGB24)
                        0x33524742, // 'BGR3' (BGR24)
                        0x41524742, // 'BGRA'
                        0x41424752, // 'RGBA'
                        0x42474752, // 'RGGB' (Bayer BGGR8)
                        0x31384142, // 'BA81' (Bayer BGGR8)
                        0x47425247, // 'GRBG'
                        0x47524247, // 'GBRG'
                        0x59455247, // 'GREY'
                    };

                    const encs: []const u32 = if (kind == .isp and port_type == 3 and port_index == 2)
                        &stats_encs
                    else if (kind == .video_decode and port_type == 2)
                        &vdec_in_encs
                    else if (kind == .video_encode and port_type == 3)
                        &venc_out_encs
                    else if (kind == .image_encode and port_type == 3)
                        &ienc_out_encs
                    else
                        &raw_encs;

                    const max_count: usize = @min(encs.len, @min(@as(usize, req_size -| 8) / 4, 96));
                    for (0..max_count) |idx| {
                        std.mem.writeInt(u32, resp[36 + idx * 4 ..][0..4], encs[idx], .little);
                    }
                    const reply_size: usize = 8 + max_count * 4;
                    std.mem.writeInt(u32, resp[32..36], @intCast(reply_size), .little);
                    self.sendVcMessage(ram, makeMsgid(VCHIQ_MSG_DATA, 4, srcport), resp[0 .. 28 + reply_size]);
                } else {
                    // For MMAL_PARAMETER_CAMERA_INFO (0x1001c) and other parameters, zero-filled payload
                    // reports num_cameras = 0 cleanly.
                    const reply_size: usize = @min(@max(@as(usize, req_size), 8), 392);
                    std.mem.writeInt(u32, resp[32..36], @intCast(reply_size), .little);
                    self.sendVcMessage(ram, makeMsgid(VCHIQ_MSG_DATA, 4, srcport), resp[0 .. 28 + reply_size]);
                }
            },
            MMAL_MSG_TYPE_BUFFER_FROM_HOST, MMAL_MSG_TYPE_BUFFER_FROM_HOST_ZEROLEN => {},
            else => {
                // COMPONENT_DESTROY, COMPONENT_ENABLE, COMPONENT_DISABLE, PORT_PARAMETER_SET, PORT_FLUSH, etc.
                var resp: [28]u8 = [_]u8{0} ** 28;
                writeMmalHeader(resp[0..24], msg_type, control_service, context);
                std.mem.writeInt(u32, resp[24..28], 0, .little); // status = MMAL_MSG_STATUS_SUCCESS
                self.sendVcMessage(ram, makeMsgid(VCHIQ_MSG_DATA, 4, srcport), &resp);
            },
        }
    }

    fn enqueueOrSendWriteComplete(self: *Vchiq, ram: []u8) void {
        const frame_bytes = @max((self.auds_channels * self.auds_bps) / 8, 1);
        const bytes_per_sec = @max(self.auds_samplerate * frame_bytes, 8_000);
        const duration_us: u64 = (@as(u64, self.auds_write_total) * 1_000_000) / bytes_per_sec;

        if (duration_us == 0 or self.pending_count >= self.pending_completes.len) {
            var resp: [20]u8 = [_]u8{0} ** 20;
            std.mem.writeInt(u32, resp[0..4], VC_AUDIO_MSG_TYPE_COMPLETE, .little);
            std.mem.writeInt(u32, resp[4..8], self.auds_write_total, .little);
            std.mem.writeInt(u32, resp[8..12], self.auds_cookie1, .little);
            std.mem.writeInt(u32, resp[12..16], self.auds_cookie2, .little);
            self.sendVcMessage(ram, makeMsgid(VCHIQ_MSG_DATA, 1, self.auds_arm_port), &resp);
            return;
        }

        self.pending_completes[self.pending_tail] = .{
            .count = self.auds_write_total,
            .cookie1 = self.auds_cookie1,
            .cookie2 = self.auds_cookie2,
            .remaining_us = duration_us,
            .active = true,
        };
        self.pending_tail = (self.pending_tail + 1) % self.pending_completes.len;
        self.pending_count += 1;
    }

    fn isOutputConnected(self: *const Vchiq, audio_connected: bool, hdmi_connected: bool) bool {
        return switch (self.auds_dest) {
            1 => audio_connected, // Headphones (3.5mm jack)
            2 => hdmi_connected, // HDMI
            else => audio_connected or hdmi_connected, // Auto (0) or Both (3)
        };
    }

    fn scaleSampleByVolume(self: *const Vchiq, sample: i16) i16 {
        // auds_volume_atten is attenuation in 1/256 dB (0 = max volume, 26214 = mute)
        if (self.auds_volume_atten >= 16384) return 0; // <= -64 dB -> mute
        if (self.auds_volume_atten <= 0) return sample;
        // Fast piecewise-linear approximation of 10^(-atten / (256 * 20))
        // Every 6 dB (1536 units) halves the amplitude
        const atten: u32 = @intCast(self.auds_volume_atten);
        const shift: u4 = @intCast(@min(atten / 1536, 15));
        const rem: i32 = @intCast(atten % 1536);
        const base_val: i32 = @as(i32, sample) >> shift;
        const scaled = @divTrunc(base_val * (3072 - rem), 3072);
        return @intCast(std.math.clamp(scaled, -32768, 32767));
    }

    fn consumeAudsPcm(
        self: *Vchiq,
        bytes: []const u8,
        audio_fifo: *AudioFifo,
        audio_connected: bool,
        hdmi_connected: bool,
    ) void {
        const connected = self.isOutputConnected(audio_connected, hdmi_connected);
        const frame_size: usize = @max((self.auds_channels * self.auds_bps) / 8, 1);

        var pos: usize = 0;
        // Complete any partial frame carried over from the previous VCHIQ packet
        if (self.pcm_carry_len > 0) {
            while (self.pcm_carry_len < frame_size and pos < bytes.len) {
                self.pcm_carry_buf[self.pcm_carry_len] = bytes[pos];
                self.pcm_carry_len += 1;
                pos += 1;
            }
            if (self.pcm_carry_len == frame_size) {
                self.pushDecodedFrame(self.pcm_carry_buf[0..frame_size], audio_fifo, connected);
                self.pcm_carry_len = 0;
            }
        }

        while (pos + frame_size <= bytes.len) : (pos += frame_size) {
            self.pushDecodedFrame(bytes[pos .. pos + frame_size], audio_fifo, connected);
        }

        while (pos < bytes.len) : (pos += 1) {
            self.pcm_carry_buf[self.pcm_carry_len] = bytes[pos];
            self.pcm_carry_len += 1;
        }
    }

    fn pushDecodedFrame(self: *Vchiq, frame: []const u8, audio_fifo: *AudioFifo, connected: bool) void {
        if (!connected) return;
        var left: i16 = 0;
        var right: i16 = 0;
        if (self.auds_bps == 8) {
            // Unsigned 8-bit PCM (128 = silence)
            left = (@as(i16, frame[0]) - 128) << 8;
            right = if (self.auds_channels >= 2 and frame.len >= 2)
                (@as(i16, frame[1]) - 128) << 8
            else
                left;
        } else {
            // Signed 16-bit little-endian PCM
            if (frame.len >= 2) {
                left = std.mem.readInt(i16, frame[0..2], .little);
            }
            right = if (self.auds_channels >= 2 and frame.len >= 4)
                std.mem.readInt(i16, frame[2..4], .little)
            else
                left;
        }
        audio_fifo.pushStereoSample(
            self.scaleSampleByVolume(left),
            self.scaleSampleByVolume(right),
            self.auds_samplerate,
        );
    }

    fn sendVcMessage(self: *Vchiq, ram: []u8, msgid: u32, payload: []const u8) void {
        if (!self.initialized) return;
        const base = self.slot_zero_phys;
        const master = base + MASTER_OFFSET;
        const slave = base + SLAVE_OFFSET;

        const stride: u32 = @intCast((payload.len + 8 + 7) & ~@as(usize, 7));
        var offset_in_slot = self.vc_tx_pos & (SLOT_SIZE - 1);

        if (offset_in_slot + stride > SLOT_SIZE) {
            const cur_slot_phys = base + self.vc_current_slot * SLOT_SIZE;
            if (offset_in_slot + 8 <= SLOT_SIZE and cur_slot_phys + offset_in_slot + 8 <= ram.len) {
                std.mem.writeInt(u32, ram[cur_slot_phys + offset_in_slot ..][0..4], VCHIQ_MSG_PADDING, .little);
                std.mem.writeInt(u32, ram[cur_slot_phys + offset_in_slot + 4 ..][0..4], SLOT_SIZE - offset_in_slot - 8, .little);
            }
            const next_q_off = master + STATE_SLOT_QUEUE + (self.vc_slot_avail & 63) * 4;
            self.vc_current_slot = std.mem.readInt(u32, ram[next_q_off..][0..4], .little);
            self.vc_slot_avail +%= 1;
            self.vc_tx_pos = (self.vc_tx_pos & ~@as(u32, SLOT_SIZE - 1)) +% SLOT_SIZE;
            offset_in_slot = 0;
        }

        const slot_phys = base + self.vc_current_slot * SLOT_SIZE;
        if (slot_phys + offset_in_slot + 8 + payload.len > ram.len) return;

        if (offset_in_slot == 0) {
            const info_off = base + SLOTS_INFO_OFFSET + self.vc_current_slot * 4;
            if (info_off + 4 <= ram.len) {
                std.mem.writeInt(i16, ram[info_off..][0..2], 1, .little); // use_count = 1
                std.mem.writeInt(i16, ram[info_off + 2 ..][0..2], 0, .little); // release_count = 0
            }
        }

        std.mem.writeInt(u32, ram[slot_phys + offset_in_slot ..][0..4], msgid, .little);
        std.mem.writeInt(u32, ram[slot_phys + offset_in_slot + 4 ..][0..4], @intCast(payload.len), .little);
        if (payload.len > 0) {
            @memcpy(ram[slot_phys + offset_in_slot + 8 .. slot_phys + offset_in_slot + 8 + payload.len], payload);
        }

        self.vc_tx_pos +%= stride;
        const next_off = self.vc_tx_pos & (SLOT_SIZE - 1);
        if (next_off != 0 and next_off + 8 <= SLOT_SIZE and slot_phys + next_off + 4 <= ram.len) {
            std.mem.writeInt(u32, ram[slot_phys + next_off ..][0..4], VCHIQ_MSG_PADDING, .little);
        }

        std.mem.writeInt(u32, ram[master + STATE_TX_POS ..][0..4], self.vc_tx_pos, .little);
        std.mem.writeInt(u32, ram[slave + STATE_TRIGGER_FIRED ..][0..4], 1, .little);
        self.bell0_active = true;
    }
};

/// BCM2835 Hardware PWM controller (`brcm,bcm2835-pwm`) at `0x2020c000` (size `0x28`, DMA PERMAP 5).
/// Used when bare-metal or custom drivers stream PWM audio directly to `FIF1` (`0x2020c018`).
pub const PwmAudio = struct {
    pub const BASE_ADDR: u32 = 0x2020c000;
    pub const SIZE: u32 = 0x28;

    pub const PWM_CTL: u32 = 0x00;
    pub const PWM_STA: u32 = 0x04;
    pub const PWM_DMAC: u32 = 0x08;
    pub const PWM_RNG1: u32 = 0x10;
    pub const PWM_DAT1: u32 = 0x14;
    pub const PWM_FIF1: u32 = 0x18;
    pub const PWM_RNG2: u32 = 0x20;
    pub const PWM_DAT2: u32 = 0x24;

    pub const STA_EMPT1: u32 = 1 << 1;
    pub const STA_WERR1: u32 = 1 << 2;
    pub const STA_RERR1: u32 = 1 << 3;
    pub const STA_STA1: u32 = 1 << 9;
    pub const STA_STA2: u32 = 1 << 10;

    ctl: u32 = 0,
    dmac: u32 = 0,
    rng1: u32 = 0x400,
    dat1: u32 = 0,
    rng2: u32 = 0x400,
    dat2: u32 = 0,

    pending_left: i16 = 0,
    has_pending_left: bool = false,

    pub fn read32(self: *const PwmAudio, offset: u32) u32 {
        return switch (offset) {
            PWM_CTL => self.ctl,
            PWM_STA => STA_EMPT1 | STA_STA1 | STA_STA2,
            PWM_DMAC => self.dmac,
            PWM_RNG1 => self.rng1,
            PWM_DAT1 => self.dat1,
            PWM_RNG2 => self.rng2,
            PWM_DAT2 => self.dat2,
            else => 0,
        };
    }

    pub fn write32(
        self: *PwmAudio,
        offset: u32,
        val: u32,
        audio_fifo: *AudioFifo,
        audio_connected: bool,
    ) void {
        switch (offset) {
            PWM_CTL => {
                self.ctl = val;
                if ((val & (1 << 6)) != 0) { // CLRF1
                    self.has_pending_left = false;
                }
            },
            PWM_DMAC => self.dmac = val,
            PWM_RNG1 => if (val > 0) {
                self.rng1 = val;
            },
            PWM_DAT1 => self.dat1 = val,
            PWM_RNG2 => if (val > 0) {
                self.rng2 = val;
            },
            PWM_DAT2 => self.dat2 = val,
            PWM_FIF1 => {
                const range: i32 = @intCast(@max(self.rng1, 2));
                const half: i32 = @divTrunc(range, 2);
                const centered: i32 = @as(i32, @intCast(@min(val, self.rng1))) - half;
                const pcm: i16 = @intCast(std.math.clamp(@divTrunc(centered * 32767, @max(half, 1)), -32768, 32767));
                if (!self.has_pending_left) {
                    self.pending_left = pcm;
                    self.has_pending_left = true;
                } else {
                    self.has_pending_left = false;
                    if (audio_connected) {
                        audio_fifo.pushStereoSample(self.pending_left, pcm, 48_000);
                    }
                }
            },
            else => {},
        }
    }
};

/// BCM2835 I2S / PCM Audio Interface (`brcm,bcm2835-i2s`) at `0x20203000` (size `0x24`).
/// Supports IRQ Bank 2 bit 23 (IRQ 55), DMA DREQ `PERMAP 2` (TX) / `PERMAP 3` (RX),
/// `CS_A_SYNC` FIFO clear round-trip handshake, and packed 16-bit / unpacked 24/32-bit stereo PCM output.
pub const I2sPcm = struct {
    pub const BASE_ADDR: u32 = 0x20203000;
    pub const SIZE: u32 = 0x24;

    // Register offsets
    pub const REG_CS_A: u32 = 0x00;
    pub const REG_FIFO_A: u32 = 0x04;
    pub const REG_MODE_A: u32 = 0x08;
    pub const REG_RXC_A: u32 = 0x0c;
    pub const REG_TXC_A: u32 = 0x10;
    pub const REG_DREQ_A: u32 = 0x14;
    pub const REG_INTEN_A: u32 = 0x18;
    pub const REG_INTSTC_A: u32 = 0x1c;
    pub const REG_GRAY: u32 = 0x20;

    // CS_A bits
    pub const CS_STBY: u32 = 1 << 25;
    pub const CS_SYNC: u32 = 1 << 24;
    pub const CS_RXSEX: u32 = 1 << 23;
    pub const CS_RXF: u32 = 1 << 22;
    pub const CS_TXE: u32 = 1 << 21;
    pub const CS_RXD: u32 = 1 << 20;
    pub const CS_TXD: u32 = 1 << 19;
    pub const CS_RXR: u32 = 1 << 18;
    pub const CS_TXW: u32 = 1 << 17;
    pub const CS_RXERR: u32 = 1 << 16;
    pub const CS_TXERR: u32 = 1 << 15;
    pub const CS_RXSYNC: u32 = 1 << 14;
    pub const CS_TXSYNC: u32 = 1 << 13;
    pub const CS_DMAEN: u32 = 1 << 9;
    pub const CS_RXCLR: u32 = 1 << 4;
    pub const CS_TXCLR: u32 = 1 << 3;
    pub const CS_TXON: u32 = 1 << 2;
    pub const CS_RXON: u32 = 1 << 1;
    pub const CS_EN: u32 = 1 << 0;

    // MODE_A bits
    pub const MODE_CLKDIS: u32 = 1 << 28;
    pub const MODE_FRXP: u32 = 1 << 25;
    pub const MODE_FTXP: u32 = 1 << 24;

    // INTEN_A / INTSTC_A bits
    pub const INT_RXERR: u32 = 1 << 3;
    pub const INT_TXERR: u32 = 1 << 2;
    pub const INT_RXR: u32 = 1 << 1;
    pub const INT_TXW: u32 = 1 << 0;

    cs_a: u32 = 0,
    mode_a: u32 = 0,
    rxc_a: u32 = 0,
    txc_a: u32 = 0,
    dreq_a: u32 = 0x10303020,
    inten_a: u32 = 0,
    intstc_a: u32 = 0,
    gray: u32 = 0,

    sample_rate: u32 = 48_000,
    pending_left: i16 = 0,
    has_pending_left: bool = false,

    rx_fifo: [64]u32 = [_]u32{0} ** 64,
    rx_head: u6 = 0,
    rx_tail: u6 = 0,
    rx_count: u7 = 0,

    pub fn pushRxSample(self: *I2sPcm, word: u32) void {
        if (self.rx_count >= 64) return;
        self.rx_fifo[self.rx_tail] = word;
        self.rx_tail +%= 1;
        self.rx_count += 1;
    }

    fn popRxSample(self: *I2sPcm) u32 {
        if (self.rx_count == 0) return 0;
        const w = self.rx_fifo[self.rx_head];
        self.rx_head +%= 1;
        self.rx_count -= 1;
        return w;
    }

    pub fn rxDreqReady(self: *const I2sPcm) bool {
        return (self.cs_a & CS_EN) != 0 and (self.cs_a & CS_DMAEN) != 0 and (self.cs_a & CS_RXON) != 0 and self.rx_count > 0;
    }

    pub fn irqPending(self: *const I2sPcm) bool {
        if ((self.cs_a & CS_EN) == 0) return false;
        var active = self.intstc_a;
        if ((self.cs_a & CS_TXON) != 0) active |= INT_TXW;
        if ((self.cs_a & CS_RXON) != 0 and self.rx_count > 0) active |= INT_RXR;
        return (active & self.inten_a) != 0;
    }

    fn extractUnpackedChannelSample(self: *const I2sPcm, val: u32) i16 {
        // Channel 1 format is in bits [31:16], Channel 2 in bits [15:0]; bcm2835-i2s sets both identically
        const ch_fmt = self.txc_a & 0xffff;
        const chwex: u32 = if ((ch_fmt & (1 << 15)) != 0) 16 else 0;
        const chwid: u32 = ch_fmt & 0x0f;
        const data_bits: u32 = if (ch_fmt != 0) (8 + chwex + chwid) else 16;
        if (data_bits >= 32) {
            return @bitCast(@as(u16, @truncate(val >> 16)));
        } else if (data_bits >= 24) {
            return @bitCast(@as(u16, @truncate(val >> 8)));
        }
        return @bitCast(@as(u16, @truncate(val)));
    }

    pub fn read32(self: *I2sPcm, offset: u32) u32 {
        return switch (offset) {
            REG_CS_A => blk: {
                const ro_mask: u32 = CS_RXF | CS_TXE | CS_RXD | CS_TXD | CS_RXR | CS_TXW | CS_RXSYNC | CS_TXSYNC | CS_RXCLR | CS_TXCLR;
                var cs = (self.cs_a & ~ro_mask) | CS_TXE | CS_TXD | CS_TXW | CS_RXSYNC | CS_TXSYNC;
                if (self.rx_count > 0) cs |= CS_RXD | CS_RXR;
                if (self.rx_count >= 64) cs |= CS_RXF;
                break :blk cs;
            },
            REG_FIFO_A => self.popRxSample(),
            REG_MODE_A => self.mode_a,
            REG_RXC_A => self.rxc_a,
            REG_TXC_A => self.txc_a,
            REG_DREQ_A => self.dreq_a,
            REG_INTEN_A => self.inten_a,
            REG_INTSTC_A => blk: {
                var st = self.intstc_a;
                if ((self.cs_a & CS_TXON) != 0) st |= INT_TXW;
                if ((self.cs_a & CS_RXON) != 0 and self.rx_count > 0) st |= INT_RXR;
                break :blk st;
            },
            REG_GRAY => self.gray,
            else => 0,
        };
    }

    pub fn write32(
        self: *I2sPcm,
        offset: u32,
        val: u32,
        audio_fifo: *AudioFifo,
        audio_connected: bool,
    ) void {
        switch (offset) {
            REG_CS_A => {
                if ((val & CS_TXCLR) != 0) {
                    self.has_pending_left = false;
                }
                if ((val & CS_RXCLR) != 0) {
                    self.rx_head = 0;
                    self.rx_tail = 0;
                    self.rx_count = 0;
                }
                // W1C error flags
                const w1c_err = val & (CS_RXERR | CS_TXERR);
                const writable_mask: u32 = CS_STBY | CS_SYNC | CS_RXSEX | CS_DMAEN | (0x0f << 5) | CS_TXON | CS_RXON | CS_EN;
                self.cs_a = ((self.cs_a & ~w1c_err) & ~writable_mask) | (val & writable_mask);
            },
            REG_FIFO_A => {
                if ((self.mode_a & MODE_FTXP) != 0) {
                    // Frame-packed 16-bit stereo: low 16 bits = Left, high 16 bits = Right
                    const left: i16 = @bitCast(@as(u16, @truncate(val)));
                    const right: i16 = @bitCast(@as(u16, @truncate(val >> 16)));
                    if (audio_connected) {
                        audio_fifo.pushStereoSample(left, right, self.sample_rate);
                    }
                } else {
                    const sample = self.extractUnpackedChannelSample(val);
                    if (!self.has_pending_left) {
                        self.pending_left = sample;
                        self.has_pending_left = true;
                    } else {
                        self.has_pending_left = false;
                        if (audio_connected) {
                            audio_fifo.pushStereoSample(self.pending_left, sample, self.sample_rate);
                        }
                    }
                }
            },
            REG_MODE_A => self.mode_a = val,
            REG_RXC_A => self.rxc_a = val,
            REG_TXC_A => self.txc_a = val,
            REG_DREQ_A => self.dreq_a = val,
            REG_INTEN_A => self.inten_a = val & 0x0f,
            REG_INTSTC_A => self.intstc_a &= ~(val & 0x0f),
            REG_GRAY => self.gray = val,
            else => {},
        }
    }
};

test "AudioFifo push and pop stereo samples with 44.1kHz to 48kHz resampling" {
    var fifo = AudioFifo{};
    // Push 4 frames at 48 kHz (1:1)
    fifo.pushStereoSample(1000, -1000, 48_000);
    fifo.pushStereoSample(2000, -2000, 48_000);
    fifo.pushStereoSample(3000, -3000, 48_000);
    fifo.pushStereoSample(4000, -4000, 48_000);
    try std.testing.expectEqual(@as(u32, 4), fifo.availableFrames());

    var out: [8]i16 = undefined;
    const popped = fifo.popFrames(&out);
    try std.testing.expectEqual(@as(usize, 4), popped);
    try std.testing.expectEqual(@as(i16, 1000), out[0]);
    try std.testing.expectEqual(@as(i16, -1000), out[1]);
    try std.testing.expectEqual(@as(i16, 4000), out[6]);
    try std.testing.expectEqual(@as(i16, -4000), out[7]);

    // Push 441 frames at 44100 Hz -> should produce ~480 frames at 48000 Hz
    for (0..441) |_| {
        fifo.pushStereoSample(12345, -12345, 44_100);
    }
    const resampled = fifo.availableFrames();
    try std.testing.expect(resampled >= 479 and resampled <= 481);
}

test "Vchiq AUDS service opens, configures, streams PCM, and respects audio_connected" {
    var ram: [64 * 1024]u8 = [_]u8{0} ** (64 * 1024);
    var vchiq = Vchiq{};
    var fifo = AudioFifo{};

    // Initialize slot_zero at 0x1000: master slots 1..4, slave slots 5..8, sync slot 9
    const base: u32 = 0x1000;
    const master = base + 32;
    const slave = base + 404;
    std.mem.writeInt(u32, ram[master + 4 ..][0..4], 1, .little); // master.slot_first = 1
    std.mem.writeInt(u32, ram[master + 8 ..][0..4], 4, .little); // master.slot_last = 4
    std.mem.writeInt(u32, ram[master + 12 ..][0..4], 9, .little); // master.slot_sync = 9
    std.mem.writeInt(u32, ram[slave + 4 ..][0..4], 5, .little); // slave.slot_first = 5
    std.mem.writeInt(u32, ram[slave + 8 ..][0..4], 8, .little); // slave.slot_last = 8
    std.mem.writeInt(u32, ram[slave + 72 ..][0..4], 5, .little); // slave.slot_queue[0] = 5
    std.mem.writeInt(u32, ram[slave + 0 ..][0..4], 1, .little); // slave.initialised = 1

    try std.testing.expectEqual(@as(u32, 0), vchiq.initSlotZero(0xc0001000, &ram));

    const slot5 = base + 5 * 4096;
    var tx_off: u32 = 0;

    // 1. VCHIQ_MSG_OPEN 'AUDS' from arm port 7
    std.mem.writeInt(u32, ram[slot5 + tx_off ..][0..4], (Vchiq.VCHIQ_MSG_OPEN << 24) | (7 << 12), .little);
    std.mem.writeInt(u32, ram[slot5 + tx_off + 4 ..][0..4], 12, .little);
    std.mem.writeInt(u32, ram[slot5 + tx_off + 8 ..][0..4], 0x41554453, .little); // 'AUDS'
    tx_off += 24;

    // 2. VC_AUDIO_MSG_TYPE_CONFIG: 2 channels, 48000 Hz, 16 bps
    std.mem.writeInt(u32, ram[slot5 + tx_off ..][0..4], (Vchiq.VCHIQ_MSG_DATA << 24) | (7 << 12) | 1, .little);
    std.mem.writeInt(u32, ram[slot5 + tx_off + 4 ..][0..4], 20, .little);
    std.mem.writeInt(u32, ram[slot5 + tx_off + 8 ..][0..4], Vchiq.VC_AUDIO_MSG_TYPE_CONFIG, .little);
    std.mem.writeInt(u32, ram[slot5 + tx_off + 12 ..][0..4], 2, .little);
    std.mem.writeInt(u32, ram[slot5 + tx_off + 16 ..][0..4], 48_000, .little);
    std.mem.writeInt(u32, ram[slot5 + tx_off + 20 ..][0..4], 16, .little);
    tx_off += 32;

    // 3. VC_AUDIO_MSG_TYPE_WRITE: 8 bytes (2 stereo frames)
    std.mem.writeInt(u32, ram[slot5 + tx_off ..][0..4], (Vchiq.VCHIQ_MSG_DATA << 24) | (7 << 12) | 1, .little);
    std.mem.writeInt(u32, ram[slot5 + tx_off + 4 ..][0..4], 20, .little);
    std.mem.writeInt(u32, ram[slot5 + tx_off + 8 ..][0..4], Vchiq.VC_AUDIO_MSG_TYPE_WRITE, .little);
    std.mem.writeInt(u32, ram[slot5 + tx_off + 12 ..][0..4], 8, .little); // count = 8 bytes
    std.mem.writeInt(u32, ram[slot5 + tx_off + 16 ..][0..4], 0x11223344, .little); // cookie1
    std.mem.writeInt(u32, ram[slot5 + tx_off + 20 ..][0..4], 0x55544144, .little); // cookie2
    tx_off += 32;

    // 4. Raw PCM data: 2 stereo frames [(0x1234, -0x1234), (0x5678, -0x5678)]
    std.mem.writeInt(u32, ram[slot5 + tx_off ..][0..4], (Vchiq.VCHIQ_MSG_DATA << 24) | (7 << 12) | 1, .little);
    std.mem.writeInt(u32, ram[slot5 + tx_off + 4 ..][0..4], 8, .little);
    std.mem.writeInt(i16, ram[slot5 + tx_off + 8 ..][0..2], 0x1234, .little);
    std.mem.writeInt(i16, ram[slot5 + tx_off + 10 ..][0..2], -0x1234, .little);
    std.mem.writeInt(i16, ram[slot5 + tx_off + 12 ..][0..2], 0x5678, .little);
    std.mem.writeInt(i16, ram[slot5 + tx_off + 14 ..][0..2], -0x5678, .little);
    tx_off += 16;

    std.mem.writeInt(u32, ram[slave + 28 ..][0..4], tx_off, .little); // slave.tx_pos
    vchiq.write32(0x08, 0, &ram, &fifo, true, true); // ring BELL2 with audio connected

    try std.testing.expect(vchiq.irqPending());
    try std.testing.expectEqual(@as(u32, 2), fifo.availableFrames());

    var samples: [4]i16 = undefined;
    try std.testing.expectEqual(@as(usize, 2), fifo.popFrames(&samples));
    try std.testing.expectEqual(@as(i16, 0x1234), samples[0]);
    try std.testing.expectEqual(@as(i16, -0x1234), samples[1]);
    try std.testing.expectEqual(@as(i16, 0x5678), samples[2]);
    try std.testing.expectEqual(@as(i16, -0x5678), samples[3]);
}

test "Vchiq SMEM service opens and handles client_version, import, and free" {
    var ram: [64 * 1024]u8 = [_]u8{0} ** (64 * 1024);
    var vchiq = Vchiq{};
    var fifo = AudioFifo{};

    const base: u32 = 0x1000;
    const master = base + 32;
    const slave = base + 404;
    std.mem.writeInt(u32, ram[master + 4 ..][0..4], 1, .little); // master.slot_first = 1
    std.mem.writeInt(u32, ram[master + 8 ..][0..4], 4, .little); // master.slot_last = 4
    std.mem.writeInt(u32, ram[master + 12 ..][0..4], 9, .little); // master.slot_sync = 9
    std.mem.writeInt(u32, ram[slave + 4 ..][0..4], 5, .little); // slave.slot_first = 5
    std.mem.writeInt(u32, ram[slave + 8 ..][0..4], 8, .little); // slave.slot_last = 8
    std.mem.writeInt(u32, ram[slave + 72 ..][0..4], 5, .little); // slave.slot_queue[0] = 5
    std.mem.writeInt(u32, ram[slave + 0 ..][0..4], 1, .little); // slave.initialised = 1

    try std.testing.expectEqual(@as(u32, 0), vchiq.initSlotZero(0xc0001000, &ram));

    const slot5 = base + 5 * 4096;
    var tx_off: u32 = 0;

    // 1. VCHIQ_MSG_OPEN 'SMEM' (0x4D454D53) from arm port 9
    std.mem.writeInt(u32, ram[slot5 + tx_off ..][0..4], (Vchiq.VCHIQ_MSG_OPEN << 24) | (9 << 12), .little);
    std.mem.writeInt(u32, ram[slot5 + tx_off + 4 ..][0..4], 12, .little);
    std.mem.writeInt(u32, ram[slot5 + tx_off + 8 ..][0..4], 0x4D454D53, .little); // 'SMEM'
    std.mem.writeInt(i16, ram[slot5 + tx_off + 16 ..][0..2], 1, .little); // version = 1
    tx_off += 24;

    // 2. VC_SM_MSG_TYPE_CLIENT_VERSION (version = 2)
    std.mem.writeInt(u32, ram[slot5 + tx_off ..][0..4], (Vchiq.VCHIQ_MSG_DATA << 24) | (9 << 12) | 3, .little);
    std.mem.writeInt(u32, ram[slot5 + tx_off + 4 ..][0..4], 12, .little);
    std.mem.writeInt(u32, ram[slot5 + tx_off + 8 ..][0..4], Vchiq.VC_SM_MSG_TYPE_CLIENT_VERSION, .little);
    std.mem.writeInt(u32, ram[slot5 + tx_off + 12 ..][0..4], 1, .little); // trans_id = 1
    std.mem.writeInt(u32, ram[slot5 + tx_off + 16 ..][0..4], 2, .little); // version = 2
    tx_off += 24;

    // 3. VC_SM_MSG_TYPE_IMPORT (addr = 0xc0100000, size = 0x4000, kernel_id = 42)
    std.mem.writeInt(u32, ram[slot5 + tx_off ..][0..4], (Vchiq.VCHIQ_MSG_DATA << 24) | (9 << 12) | 3, .little);
    std.mem.writeInt(u32, ram[slot5 + tx_off + 4 ..][0..4], 60, .little);
    std.mem.writeInt(u32, ram[slot5 + tx_off + 8 ..][0..4], Vchiq.VC_SM_MSG_TYPE_IMPORT, .little);
    std.mem.writeInt(u32, ram[slot5 + tx_off + 12 ..][0..4], 2, .little); // trans_id = 2
    std.mem.writeInt(u32, ram[slot5 + tx_off + 16 ..][0..4], 1, .little); // VC_SM_ALLOC_NON_CACHED
    std.mem.writeInt(u32, ram[slot5 + tx_off + 20 ..][0..4], 0xc010_0000, .little); // addr
    std.mem.writeInt(u32, ram[slot5 + tx_off + 24 ..][0..4], 0x4000, .little); // size
    std.mem.writeInt(u32, ram[slot5 + tx_off + 28 ..][0..4], 42, .little); // kernel_id
    tx_off += 72;

    // 4. VC_SM_MSG_TYPE_FREE (res_handle = 1)
    std.mem.writeInt(u32, ram[slot5 + tx_off ..][0..4], (Vchiq.VCHIQ_MSG_DATA << 24) | (9 << 12) | 3, .little);
    std.mem.writeInt(u32, ram[slot5 + tx_off + 4 ..][0..4], 16, .little);
    std.mem.writeInt(u32, ram[slot5 + tx_off + 8 ..][0..4], Vchiq.VC_SM_MSG_TYPE_FREE, .little);
    std.mem.writeInt(u32, ram[slot5 + tx_off + 12 ..][0..4], 3, .little); // trans_id = 3
    std.mem.writeInt(u32, ram[slot5 + tx_off + 16 ..][0..4], 1, .little); // res_handle = 1
    tx_off += 24;

    std.mem.writeInt(u32, ram[slave + 28 ..][0..4], tx_off, .little); // slave.tx_pos
    vchiq.write32(0x08, 0, &ram, &fifo, false, false);

    try std.testing.expect(vchiq.irqPending());
    try std.testing.expectEqual(@as(u12, 9), vchiq.smem_arm_port);
    try std.testing.expectEqual(@as(u32, 2), vchiq.smem_client_version);

    // Master slot 1 should contain:
    //   [0..16):  OPENACK (msgid = (3<<24)|(3<<12)|9, size = 2)
    //   [16..32): DATA CLIENT_VERSION ack (size = 8, cmd = 0x80000009, success = 0)
    //   [32..48): DATA IMPORT result (size = 8, trans_id = 2, res_handle = 1)
    //   [48..80): DATA RELEASED callback (size = 20, cmd = 0x8000000b, addr = 0xc0100000, size = 0x4000, kernel_id = 42, vc_handle = 1)
    const slot1 = base + 1 * 4096;
    try std.testing.expectEqual((Vchiq.VCHIQ_MSG_OPENACK << 24) | (3 << 12) | 9, std.mem.readInt(u32, ram[slot1 + 0 ..][0..4], .little));
    try std.testing.expectEqual(Vchiq.VC_SM_MSG_TYPE_CLIENT_VERSION | 0x8000_0000, std.mem.readInt(u32, ram[slot1 + 24 ..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, ram[slot1 + 40 ..][0..4], .little)); // trans_id = 2
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, ram[slot1 + 44 ..][0..4], .little)); // res_handle = 1
    try std.testing.expectEqual(Vchiq.VC_SM_MSG_TYPE_RELEASED | 0x8000_0000, std.mem.readInt(u32, ram[slot1 + 56 ..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 0xc010_0000), std.mem.readInt(u32, ram[slot1 + 60 ..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 0x4000), std.mem.readInt(u32, ram[slot1 + 64 ..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, ram[slot1 + 68 ..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, ram[slot1 + 72 ..][0..4], .little));
}

test "Vchiq MMAL service opens and handles component creation, port info, and parameters" {
    var ram: [64 * 1024]u8 = [_]u8{0} ** (64 * 1024);
    var vchiq = Vchiq{};
    var fifo = AudioFifo{};

    const base: u32 = 0x1000;
    const master = base + 32;
    const slave = base + 404;
    std.mem.writeInt(u32, ram[master + 4 ..][0..4], 1, .little); // master.slot_first = 1
    std.mem.writeInt(u32, ram[master + 8 ..][0..4], 4, .little); // master.slot_last = 4
    std.mem.writeInt(u32, ram[master + 12 ..][0..4], 9, .little); // master.slot_sync = 9
    std.mem.writeInt(u32, ram[slave + 4 ..][0..4], 5, .little); // slave.slot_first = 5
    std.mem.writeInt(u32, ram[slave + 8 ..][0..4], 8, .little); // slave.slot_last = 8
    std.mem.writeInt(u32, ram[slave + 72 ..][0..4], 5, .little); // slave.slot_queue[0] = 5
    std.mem.writeInt(u32, ram[slave + 0 ..][0..4], 1, .little); // slave.initialised = 1

    try std.testing.expectEqual(@as(u32, 0), vchiq.initSlotZero(0xc0001000, &ram));

    const slot5 = base + 5 * 4096;
    var tx_off: u32 = 0;

    // 1. VCHIQ_MSG_OPEN 'mmal' (0x6C616D6D) from arm port 11
    std.mem.writeInt(u32, ram[slot5 + tx_off ..][0..4], (Vchiq.VCHIQ_MSG_OPEN << 24) | (11 << 12), .little);
    std.mem.writeInt(u32, ram[slot5 + tx_off + 4 ..][0..4], 12, .little);
    std.mem.writeInt(u32, ram[slot5 + tx_off + 8 ..][0..4], Vchiq.MMAL_MAGIC, .little); // 'mmal'
    std.mem.writeInt(i16, ram[slot5 + tx_off + 16 ..][0..2], 15, .little); // VC_MMAL_VER = 15
    tx_off += 24;

    // 2. MMAL_MSG_TYPE_COMPONENT_CREATE ("vc.ril.isp")
    std.mem.writeInt(u32, ram[slot5 + tx_off ..][0..4], (Vchiq.VCHIQ_MSG_DATA << 24) | (11 << 12) | 4, .little);
    std.mem.writeInt(u32, ram[slot5 + tx_off + 4 ..][0..4], 160, .little);
    std.mem.writeInt(u32, ram[slot5 + tx_off + 8 ..][0..4], Vchiq.MMAL_MAGIC, .little);
    std.mem.writeInt(u32, ram[slot5 + tx_off + 12 ..][0..4], Vchiq.MMAL_MSG_TYPE_COMPONENT_CREATE, .little);
    std.mem.writeInt(u32, ram[slot5 + tx_off + 20 ..][0..4], 0xdeadbeef, .little); // context
    @memcpy(ram[slot5 + tx_off + 36 .. slot5 + tx_off + 46], "vc.ril.isp");
    tx_off += 168;

    std.mem.writeInt(u32, ram[slave + 28 ..][0..4], tx_off, .little); // slave.tx_pos
    vchiq.write32(0x08, 0, &ram, &fifo, false, false);

    try std.testing.expect(vchiq.irqPending());
    try std.testing.expectEqual(@as(u12, 11), vchiq.mmal_arm_port);

    // Master slot 1:
    //   [0..16):  OPENACK (msgid = (3<<24)|(4<<12)|11, size = 2)
    //   [16..68): DATA COMPONENT_CREATE reply (size = 44, context = 0xdeadbeef, status = 0, handle = 1, inputs = 1, outputs = 3)
    const slot1 = base + 1 * 4096;
    try std.testing.expectEqual((Vchiq.VCHIQ_MSG_OPENACK << 24) | (4 << 12) | 11, std.mem.readInt(u32, ram[slot1 + 0 ..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 0xdeadbeef), std.mem.readInt(u32, ram[slot1 + 24 + 12 ..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, ram[slot1 + 24 + 24 ..][0..4], .little)); // status
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, ram[slot1 + 24 + 28 ..][0..4], .little)); // component_handle
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, ram[slot1 + 24 + 32 ..][0..4], .little)); // input_num
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, ram[slot1 + 24 + 36 ..][0..4], .little)); // output_num
}

