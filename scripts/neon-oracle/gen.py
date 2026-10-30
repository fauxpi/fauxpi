#!/usr/bin/env python3
"""Generates src/cpu/testdata/neon_vectors.txt: AArch32 Advanced SIMD test vectors from QEMU.

Usage: scripts/neon-oracle/gen.py [--count N] [--seed S]

Random encodings are drawn from the Advanced SIMD data-processing, element/structure load/store,
and core-register transfer spaces, classified with objdump, and run on QEMU's `max` CPU by the
bare-metal harness in this directory (see harness.c for how each test's state is derived and
hashed). Instructions the BCM2837's Cortex-A53 does not implement (the Cryptography Extension and
later ARMv8.x additions, which QEMU's `max` CPU has) are recorded as Undefined. Encodings objdump
cannot decode are kept only when QEMU also treats them as Undefined.

Requires: arm-linux-gnueabihf-gcc and -objdump, qemu-system-arm.
"""

import argparse
import os
import random
import re
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(ROOT, "src", "cpu", "testdata", "neon_vectors.txt")
LISTING = os.path.join(ROOT, "build", "neon-oracle", "neon_vectors.lst")
PER_MNEMONIC = 20
MAX_UNDEFINED = 1200
MAX_ABORTS = 400

BUF_ADDR = 0x40100000
BUF_SIZE = 2048
BUF_PTR_MIN = 0x100
BUF_PTR_SPAN = 0x500
CPSR_MASK = 0xF80F0000
FPSCR_MASK = 0xF8000000
FPSCR_INPUT_MASK = 0xFFC00000
SPECIAL = [
    0x00000000, 0x80000000, 0x3F800000, 0xBF800000, 0x7F800000, 0xFF800000, 0x7FC00000,
    0x7F800001, 0x00000001, 0x807FFFFF, 0x00800000, 0x7F7FFFFF, 0x7FFFFFFF, 0x80008000,
    0x7F7F7F7F, 0xFFFFFFFF, 0x4F000000, 0xCF000000, 0x3F000000, 0x00400000,
]
M64 = (1 << 64) - 1

# Not implemented by the BCM2837's Cortex-A53 (ARMv8.0 without the Cryptography Extension)
NOT_IMPLEMENTED = re.compile(
    r"^(aes|sha|vmull\.p64|vqrdml[as]h|v[su]+dot|vfm[as]l|vcmla|vcadd|v[su]*mmla|vjcvt)|bf16"
)
UNCERTAIN = re.compile(r"undefined|illegal|unpredictable|\.word|<", re.IGNORECASE)


def splitmix(seed):
    state = seed

    def next_():
        nonlocal state
        state = (state + 0x9E3779B97F4A7C15) & M64
        z = state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & M64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & M64
        return z ^ (z >> 31)

    return next_


def base_registers(index):
    """r8..r12 of test `index`."""
    nxt = splitmix((index * 0x9E3779B97F4A7C15 + 1) & M64)
    for _ in range(40):
        nxt()
    return [BUF_ADDR + BUF_PTR_MIN + nxt() % BUF_PTR_SPAN for _ in range(5)]


def unpredictable(inst, d, index):
    """Encodings whose result the architecture leaves UNPREDICTABLE, or where QEMU is known to differ
    from the hardware, so QEMU's result is no reference."""
    # Register lists running past D31
    if re.search(r"\bd(3[2-9]|[4-9][0-9])\b", d):
        return True
    # VTRN / VUZP / VZIP with the same register twice
    m = re.match(r"v(trn|uzp|zip)\.\d+\s+([dq]\d+), ([dq]\d+)$", d)
    if m and m.group(2) == m.group(3):
        return True
    # Single-element loads and stores with an alignment hint: the hardware faults on a misaligned
    # address, but QEMU only checks multiple-element forms
    m = re.search(r"\[\w+ :(\d+)\]", d)
    if m and (inst & (1 << 23)) and re.search(r"\[\d*\]", d.split("}")[0]):
        rn = (inst >> 16) & 0xF
        if base_registers(index)[rn - 8] % (int(m.group(1)) // 8) != 0:
            return True
    return False


def unchanged_hash(index, status):
    """The harness's hash of test `index` when the instruction leaves the state unchanged."""
    nxt = splitmix((index * 0x9E3779B97F4A7C15 + 1) & M64)
    d = [nxt() for _ in range(32)]
    r = [nxt() & 0xFFFFFFFF for _ in range(8)]
    r += [BUF_ADDR + BUF_PTR_MIN + nxt() % BUF_PTR_SPAN for _ in range(5)]
    cpsr = nxt() & CPSR_MASK
    fpscr = nxt() & FPSCR_INPUT_MASK & FPSCR_MASK
    buf = b"".join(struct.pack("<Q", nxt()) for _ in range(BUF_SIZE // 8))
    if index % 3 == 1:
        lanes = [x for q in d for x in (q & 0xFFFFFFFF, q >> 32)]
        for i in range(64):
            sel = nxt() % 24
            if sel < 20:
                lanes[i] = SPECIAL[sel]
        d = [lanes[2 * i] | (lanes[2 * i + 1] << 32) for i in range(32)]
    data = struct.pack("<I", status) + struct.pack("<32Q", *d) + struct.pack("<13I", *r)
    data += struct.pack("<II", cpsr, fpscr) + buf
    h = 0xCBF29CE484222325
    for b in data:
        h = ((h ^ b) * 0x100000001B3) & M64
    return h


def even_regs(rnd, inst):
    """Usually makes Vd, Vn and Vm even, so that Q-register forms are valid."""
    if rnd.random() < 0.85:
        inst &= ~((1 << 12) | (1 << 16) | 1)
    return inst


def candidates(rnd, count):
    out = []
    # Data processing: 1111 001U, everything else random
    for _ in range(count * 5 // 10):
        out.append(even_regs(rnd, 0xF2000000 | (rnd.getrandbits(1) << 24) | rnd.getrandbits(24)))
    # Two registers, miscellaneous: 1111 0011 1D11 size opc1 Vd 0 opc2 Q M 0 Vm
    for _ in range(count * 15 // 100):
        inst = 0xF3B00000 | (rnd.getrandbits(1) << 22) | (rnd.getrandbits(4) << 16) | (rnd.getrandbits(4) << 12)
        inst |= (rnd.getrandbits(4) << 7) | (rnd.getrandbits(2) << 5) | rnd.getrandbits(4)
        out.append(even_regs(rnd, inst))
    # Element and structure load/store: 1111 0100 A D L 0 Rn Vd xxxx xxxx Rm
    for _ in range(count * 25 // 100):
        rn = rnd.randint(8, 12)
        rm = rnd.choice([13, 15, 13, 15] + list(range(8)))
        out.append(0xF4000000 | (rnd.getrandbits(3) << 21) | (rn << 16) | (rnd.getrandbits(12) << 4) | rm)
    # Core register transfers (cond = AL): VMOV scalar <-> core, VDUP from core
    for _ in range(count // 10):
        rt = rnd.randint(0, 12)
        kind = rnd.randrange(3)
        if kind == 0:  # VMOV Rt, Dn[x]
            inst = 0xEE100B10 | (rnd.getrandbits(1) << 23) | (rnd.getrandbits(2) << 21)
            inst |= (rnd.getrandbits(4) << 16) | (rnd.getrandbits(1) << 7) | (rnd.getrandbits(2) << 5)
        elif kind == 1:  # VMOV Dd[x], Rt
            inst = 0xEE000B10 | (rnd.getrandbits(2) << 21) | (rnd.getrandbits(4) << 16)
            inst |= (rnd.getrandbits(1) << 7) | (rnd.getrandbits(2) << 5)
        else:  # VDUP Qd/Dd, Rt
            inst = 0xEE800B10 | (rnd.getrandbits(2) << 21) | (rnd.getrandbits(4) << 16)
            inst |= (rnd.getrandbits(1) << 7) | (rnd.getrandbits(1) << 5)
        out.append(inst | (rt << 12))
    # VFP half-precision conversions (cond = AL): VCVTB / VCVTT between half and single or double
    for _ in range(count // 50):
        inst = 0xEEB20A40 | (rnd.getrandbits(1) << 22) | (rnd.getrandbits(1) << 16) | (rnd.getrandbits(4) << 12)
        inst |= (rnd.getrandbits(1) << 8) | (rnd.getrandbits(1) << 7) | (rnd.getrandbits(1) << 5) | rnd.getrandbits(4)
        out.append(inst)
    seen = set()
    return [i for i in out if not (i in seen or seen.add(i))]


def disassemble(words, tmp):
    path = os.path.join(tmp, "insts.bin")
    with open(path, "wb") as f:
        f.write(b"".join(struct.pack("<I", w) for w in words))
    text = subprocess.run(
        ["arm-linux-gnueabihf-objdump", "-D", "-b", "binary", "-m", "arm", path],
        capture_output=True, text=True, check=True,
    ).stdout
    dis = {}
    for line in text.splitlines():
        m = re.match(r"\s*([0-9a-f]+):\s+([0-9a-f]{8})\s+(.*)$", line)
        if m:
            dis[int(m.group(1), 16) // 4] = m.group(3).strip()
    return [dis.get(i, ".word") for i in range(len(words))]


def run_qemu(words, tmp):
    with open(os.path.join(tmp, "tests.inc"), "w") as f:
        f.write("".join("0x%08x,\n" % w for w in words))
    elf = os.path.join(tmp, "harness.elf")
    subprocess.run(
        ["arm-linux-gnueabihf-gcc", "-nostdlib", "-ffreestanding", "-O2", "-march=armv7-a",
         "-mfpu=neon-vfpv4", "-mfloat-abi=hard", "-marm", "-I", HERE, "-I", tmp,
         "-T", os.path.join(HERE, "link.ld"), "-Wl,--no-warn-rwx-segments", "-o", elf,
         os.path.join(HERE, "start.S"), os.path.join(HERE, "harness.c")],
        check=True,
    )
    out = subprocess.run(
        ["qemu-system-arm", "-M", "virt", "-cpu", "max", "-m", "256M", "-nographic",
         "-semihosting-config", "enable=on,target=native", "-kernel", elf],
        capture_output=True, text=True, timeout=600,
    ).stdout
    results = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 3:
            results[int(parts[0], 16)] = (int(parts[1]), int(parts[2], 16))
    if len(results) != len(words):
        sys.exit("gen.py: QEMU produced %d of %d results" % (len(results), len(words)))
    return results


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--count", type=int, default=100000)
    p.add_argument("--seed", type=int, default=1)
    args = p.parse_args()

    words = candidates(random.Random(args.seed), args.count)
    with tempfile.TemporaryDirectory() as tmp:
        dis = disassemble(words, tmp)
        # Tests 0 and 1 are NOPs: their hashes check this script's model of the harness state, with
        # and without special values
        words = [0xE320F000, 0xE320F000] + words
        dis = ["nop", "nop"] + dis
        results = run_qemu(words, tmp)
    if results[0] != (0, unchanged_hash(0, 0)) or results[1] != (0, unchanged_hash(1, 0)):
        sys.exit("gen.py: the harness state model does not match QEMU")

    # Keep up to PER_MNEMONIC tests of each instruction form, and a sample of Undefined and abort cases
    picked = []
    per = {}
    limits = {1: MAX_UNDEFINED, 2: MAX_ABORTS}
    taken = {1: 0, 2: 0}
    for i, (w, d) in enumerate(zip(words, dis)):
        status, h = results[i]
        mnemonic = d.split()[0] if d else ""
        if NOT_IMPLEMENTED.search(mnemonic) or (".f16" in mnemonic and not mnemonic.startswith(("vcvt.f16.f32", "vcvt.f32.f16", "vcvtb.", "vcvtt."))):
            status, h = 1, unchanged_hash(i, 1)
        elif UNCERTAIN.search(d) and status != 1:
            continue
        elif unpredictable(w, d, i):
            continue
        if status in limits:
            if taken[status] >= limits[status]:
                continue
            taken[status] += 1
        else:
            per[mnemonic] = per.get(mnemonic, 0) + 1
            if per[mnemonic] > PER_MNEMONIC:
                continue
        picked.append((w, status, h, i, d))

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        f.write("# AArch32 Advanced SIMD test vectors, generated by scripts/neon-oracle/gen.py from QEMU.\n")
        f.write("# instruction, status (0 executed, 1 Undefined, 2 abort), state hash (low 32 bits), test index\n")
        f.write("".join("%08x %d %08x %x\n" % (w, st, h & 0xFFFFFFFF, i) for w, st, h, i, _ in picked))
    os.makedirs(os.path.dirname(LISTING), exist_ok=True)
    with open(LISTING, "w") as f:
        f.write("".join("%08x %d %016x %x %s\n" % p for p in picked))
    counts = [sum(1 for p in picked if p[1] == s) for s in (0, 1, 2)]
    print("wrote %s: %d tests (%d executed, %d Undefined, %d aborts), %d instruction forms" % (OUT, len(picked), *counts, len(per)))


if __name__ == "__main__":
    main()
