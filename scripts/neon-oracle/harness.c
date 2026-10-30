/* Advanced SIMD oracle: runs each instruction in tests.inc on QEMU from a pseudo-random state and
 * prints "<index> <status> <hash>" for it on the PL011 UART.
 *
 * The state of test i comes from splitmix64 seeded with i * 0x9e3779b97f4a7c15 + 1, drawn in this
 * order: d0..d31; r0..r7 (low 32 bits); r8..r12 = BUF_ADDR + BUF_PTR_MIN + draw % BUF_PTR_SPAN;
 * CPSR = draw & CPSR_MASK; FPSCR = draw & FPSCR_INPUT_MASK; then BUF_SIZE / 8 draws filling the
 * buffer. When i % 3 == 1, each 32-bit lane of d0..d31 then takes special[draw % 24] if that is
 * one of the 20 special values (zeros, infinities, NaNs, denormals, integer limits, ...).
 * The hash is FNV-1a 64 over: status (u32), d0..d31 (u64), r0..r12, CPSR & CPSR_MASK,
 * FPSCR & FPSCR_MASK (u32 each, little-endian), and the buffer. */

#include <stdint.h>
#include "oracle.h"

struct state {
    uint64_t d[32];
    uint32_t r[13];
    uint32_t cpsr;
    uint32_t fpscr;
};

extern void run_test(struct state *s);
extern uint32_t test_slot[2];
volatile uint32_t g_status;
struct state *g_state;

static const uint32_t special[20] = {
    0x00000000, 0x80000000, 0x3f800000, 0xbf800000, 0x7f800000, 0xff800000, 0x7fc00000,
    0x7f800001, 0x00000001, 0x807fffff, 0x00800000, 0x7f7fffff, 0x7fffffff, 0x80008000,
    0x7f7f7f7f, 0xffffffff, 0x4f000000, 0xcf000000, 0x3f000000, 0x00400000,
};

static const uint32_t tests[] = {
#include "tests.inc"
};

static uint32_t page_table[4096] __attribute__((aligned(16384)));

void setup_mmu(void) {
    for (uint32_t i = 0; i < 4096; i++) {
        uint32_t addr = i << 20;
        if (addr >= 0x40000000u && addr < 0x50000000u)
            page_table[i] = addr | 0xc00 | 0x1000 | 0xc | 0x2; /* Normal write-back, full access */
        else
            page_table[i] = addr | 0xc00 | 0x4 | 0x2; /* Device */
    }
    __asm__ volatile(
        "mcr p15, 0, %0, c2, c0, 0\n"   /* TTBR0 */
        "mov r1, #0\n"
        "mcr p15, 0, r1, c2, c0, 2\n"   /* TTBCR */
        "mvn r1, #0\n"
        "mcr p15, 0, r1, c3, c0, 0\n"   /* DACR: manager */
        "mcr p15, 0, r1, c8, c7, 0\n"   /* TLBIALL */
        "dsb\n isb\n"
        "mrc p15, 0, r1, c1, c0, 0\n"
        "orr r1, r1, #0x1000\n"         /* I */
        "orr r1, r1, #0x5\n"            /* M, C */
        "bic r1, r1, #0x2\n"            /* A = 0: unaligned accesses allowed */
        "mcr p15, 0, r1, c1, c0, 0\n"
        "isb\n"
        :
        : "r"(page_table)
        : "r1", "memory");
}

static uint64_t rng;
static uint64_t next(void) {
    uint64_t z = (rng += 0x9e3779b97f4a7c15ull);
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ull;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebull;
    return z ^ (z >> 31);
}

static uint64_t hash;
static void hash_bytes(const void *p, uint32_t n) {
    const uint8_t *b = p;
    for (uint32_t i = 0; i < n; i++) {
        hash ^= b[i];
        hash *= 0x100000001b3ull;
    }
}

static void putc_uart(char c) {
    *(volatile uint32_t *)0x09000000 = (uint32_t)c;
}

static void put_hex(uint64_t v, int digits) {
    for (int i = digits - 1; i >= 0; i--) putc_uart("0123456789abcdef"[(v >> (i * 4)) & 0xf]);
}

int main(void) {
    static struct state s;
    uint8_t *buf = (uint8_t *)BUF_ADDR;
    for (uint32_t t = 0; t < sizeof(tests) / sizeof(tests[0]); t++) {
        rng = (uint64_t)t * 0x9e3779b97f4a7c15ull + 1;
        for (int i = 0; i < 32; i++) s.d[i] = next();
        for (int i = 0; i < 8; i++) s.r[i] = (uint32_t)next();
        for (int i = 8; i < 13; i++) s.r[i] = BUF_ADDR + BUF_PTR_MIN + (uint32_t)(next() % BUF_PTR_SPAN);
        s.cpsr = (uint32_t)next() & CPSR_MASK;
        s.fpscr = (uint32_t)next() & FPSCR_INPUT_MASK;
        for (int i = 0; i < BUF_SIZE / 8; i++) ((uint64_t *)buf)[i] = next();
        if (t % 3 == 1) {
            for (int i = 0; i < 64; i++) {
                uint32_t sel = (uint32_t)(next() % 24);
                if (sel < 20) ((uint32_t *)s.d)[i] = special[sel];
            }
        }

        test_slot[0] = tests[t];
        __asm__ volatile(
            "mcr p15, 0, %0, c7, c11, 1\n"  /* DCCMVAU */
            "dsb\n"
            "mcr p15, 0, %0, c7, c5, 1\n"   /* ICIMVAU */
            "mcr p15, 0, %0, c7, c5, 6\n"   /* BPIALL */
            "dsb\n isb\n"
            :
            : "r"(test_slot)
            : "memory");
        g_status = STATUS_OK;
        run_test(&s);

        uint32_t status = g_status;
        uint32_t cpsr = s.cpsr & CPSR_MASK;
        uint32_t fpscr = s.fpscr & FPSCR_MASK;
        hash = 0xcbf29ce484222325ull;
        hash_bytes(&status, 4);
        hash_bytes(s.d, sizeof(s.d));
        hash_bytes(s.r, sizeof(s.r));
        hash_bytes(&cpsr, 4);
        hash_bytes(&fpscr, 4);
        hash_bytes(buf, BUF_SIZE);

        put_hex(t, 5);
        putc_uart(' ');
        put_hex(status, 1);
        putc_uart(' ');
        put_hex(hash, 16);
        putc_uart('\n');
    }
    return 0;
}
