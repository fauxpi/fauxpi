const std = @import("std");

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
        _ = std.os.linux.futex_4arg(
            @ptrCast(&self.write_idx.raw),
            .{ .cmd = .WAKE, .private = true },
            1,
            null,
        );
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

        _ = std.os.linux.futex_4arg(
            @ptrCast(&self.write_idx.raw),
            .{ .cmd = .WAIT, .private = true },
            w2,
            null,
        );
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
