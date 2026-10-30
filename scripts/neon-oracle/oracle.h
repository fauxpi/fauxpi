/* Shared layout of the Advanced SIMD oracle. FauxPi's test (src/cpu/neon.zig) must match it. */

#define STATE_D 0       /* d0..d31, 32 x 8 bytes */
#define STATE_R 256     /* r0..r12, 13 x 4 bytes */
#define STATE_CPSR 308
#define STATE_FPSCR 312

/* Memory the load/store tests use, and where r8..r12 point into it */
#define BUF_ADDR 0x40100000
#define BUF_SIZE 2048
#define BUF_PTR_MIN 0x100
#define BUF_PTR_SPAN 0x500

#define CPSR_MASK 0xf80f0000u   /* NZCV, Q, GE */
#define FPSCR_MASK 0xf8000000u  /* NZCV, QC */
#define FPSCR_INPUT_MASK 0xffc00000u  /* also AHP, DN, FZ, RMode, which Advanced SIMD ignores except AHP */

#define STATUS_OK 0
#define STATUS_UNDEFINED 1
#define STATUS_ABORT 2
