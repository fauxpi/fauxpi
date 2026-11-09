//! V3D feature tests of QPU user programs (general-purpose computing, queued through the
//! SRQPC/SRQUA/SRQUL registers): VPM memory reserved for them, DMA loads (VDR) and stores (VDW),
//! generic VPM reads and writes in each mode, general memory lookups, the mutex, semaphores
//! between programs, host interrupts, and the queue's counters. Rounds of them, over more data,
//! are the compute stress test.

const std = @import("std");
const scene = @import("scene");
const hw = @import("hw.zig");
const gpu = @import("gpu.zig");
const main = @import("main.zig");

const programs = scene.programs;
const reg = gpu.reg;
const Params = main.Params;
const Result = main.Result;

/// Queues a program (its uniforms `unifs`, `len` of them; 0 for none, over 1023 unlimited).
fn queue(code: u32, unifs: u32, len: u32) void {
    hw.write(reg.srqua, unifs);
    hw.write(reg.srqul, len);
    hw.write(reg.srqpc, code);
}

/// Waits until `n` programs have completed since the counters were reset (or the time is up).
fn waitCompleted(n: u32) bool {
    const until = hw.timer.now() + gpu.timeout_us;
    while ((hw.read(reg.srqcs) >> 16) & 0xff != n & 0xff) {
        if (hw.timer.now() > until) return false;
    }
    return true;
}

fn resetQueue() void {
    // Clear the queue, its error, and both counts.
    hw.write(reg.srqcs, 1 << 16 | 1 << 8 | 1 << 7 | 1);
}

pub fn userPrograms(p: Params, r: *Result) void {
    // VPM for user programs: 24 x 256 bytes (96 rows), before any shading.
    hw.write(reg.vpmbase, 24);
    r.add("vpmbase", hw.read(reg.vpmbase) & 0x1f);
    // The QPU interrupt registers (not in the guide's register map; as Broadcom's headers have
    // them).
    hw.write(reg.dbqite, 0xffff);
    hw.write(reg.dbqitc, 0xffff);

    const worker = gpu.upload(programs.userProgram(false).code());
    const master = gpu.upload(programs.userProgram(true).code());
    const rounds = p.amount(20);
    const input = gpu.alloc(u32, 12 * 128, 4096);
    const output = gpu.alloc(u32, 12 * 128, 4096);
    const counter = gpu.alloc(u32, 16, 64);
    for (input, 0..) |*v, i| v.* = @as(u32, @intCast(i)) *% 2654435761;
    var timeouts: u64 = 0;
    var sum: u64 = 0;
    var interrupts: u64 = 0;
    for (0..rounds) |round| {
        resetQueue();
        for (0..12) |i| {
            const unifs = gpu.words(&.{ hw.bus(input.ptr), hw.bus(output.ptr), @intCast(i), hw.bus(counter.ptr) });
            // The master last; the others' uniforms limited to the four, and unlimited.
            queue(if (i == 11) master else worker, unifs, if (i % 2 == 0) 4 else 1024);
        }
        if (!waitCompleted(12)) {
            // User programs don't run here: the rest would only wait as long.
            timeouts += 1;
            resetQueue();
            break;
        }
        interrupts += @intFromBool(hw.read(reg.dbqitc) & 0xffff != 0);
        hw.write(reg.dbqitc, 0xffff);
        sum +%= gpu.checksum(std.mem.sliceAsBytes(output));
        // Each round's output is the next one's input.
        @memcpy(input, output);
        _ = round;
    }
    r.add("output", sum);
    r.add("counter", counter[0]);
    r.add("counter_last", counter[15]);
    r.add("rounds", rounds);
    r.add("host_interrupts", interrupts);
    const cs = hw.read(reg.srqcs);
    r.add("completed", (cs >> 16) & 0xff);
    r.add("requested", (cs >> 8) & 0xff);
    r.add("queue_error", (cs >> 7) & 1);

    // VPM access modes.
    {
        const modes = gpu.upload(programs.vpmModesProgram().code());
        const in = gpu.alloc(u8, 4096, 4096);
        const out = gpu.alloc(u8, 4096, 4096);
        for (in, 0..) |*b, i| b.* = @truncate(i * 37 + 11);
        resetQueue();
        queue(modes, gpu.words(&.{ hw.bus(in.ptr), hw.bus(out.ptr) }), 2);
        if (!waitCompleted(1)) {
            timeouts += 1;
            resetQueue();
        }
        r.add("vpm_modes", gpu.checksum(out));
    }

    // A queue overfilled: 17 requests to a 16-deep queue, every QPU reserved against user
    // programs (SQRSV) so none starts; the error bit, then the queue cleared.
    {
        resetQueue();
        hw.write(reg.sqrsv0, 0xffffffff);
        hw.write(reg.sqrsv1, 0xffffffff);
        for (0..17) |_| queue(worker, gpu.words(&.{ hw.bus(input.ptr), hw.bus(output.ptr), 0, hw.bus(counter.ptr) }), 4);
        const cs2 = hw.read(reg.srqcs);
        r.add("overfilled_error", (cs2 >> 7) & 1);
        r.add("overfilled_length", cs2 & 0x3f);
        resetQueue();
        hw.write(reg.sqrsv0, 0);
        hw.write(reg.sqrsv1, 0);
    }
    r.add("timeouts", timeouts);
}
