@ Bare-metal start-up for the Advanced SIMD oracle on QEMU's `virt` machine (AArch32).
@
@ Sets up exception vectors and stacks, enables the MMU (so RAM is Normal memory and unaligned
@ accesses are allowed) and the FPU/Advanced SIMD, then calls main(). run_test() loads a test
@ state, executes the instruction in test_slot, and stores the resulting state back.

#include "oracle.h"

    .syntax unified
    .arch armv7-a
    .fpu neon-vfpv4
    .arm

    .section .text.vectors, "ax"
    .global _start
    .align 5
vectors:
    b _start            @ Reset
    b und_handler       @ Undefined Instruction
    b .                 @ SVC
    b .                 @ Prefetch Abort
    b abt_handler       @ Data Abort
    b .                 @ Unused
    b .                 @ IRQ
    b .                 @ FIQ

_start:
    @ Stacks for Undefined and Abort modes, then back to SVC
    cps #0x1b
    ldr sp, =und_stack_top
    cps #0x17
    ldr sp, =abt_stack_top
    cps #0x13
    ldr sp, =svc_stack_top

    ldr r0, =vectors
    mcr p15, 0, r0, c12, c0, 0      @ VBAR

    @ Full access to CP10/CP11, then FPEXC.EN
    mrc p15, 0, r0, c1, c0, 2
    orr r0, r0, #(0xf << 20)
    mcr p15, 0, r0, c1, c0, 2
    isb
    mov r0, #0x40000000
    vmsr fpexc, r0

    bl setup_mmu
    bl main

    @ Semihosting SYS_EXIT (ADP_Stopped_ApplicationExit)
    mov r0, #0x18
    ldr r1, =0x20026
    svc 0x123456
    b .

und_handler:
    push {r0, r1}
    ldr r0, =g_status
    mov r1, #1
    str r1, [r0]
    pop {r0, r1}
    movs pc, lr                     @ resume after the instruction

abt_handler:
    sub lr, lr, #4
    push {r0, r1}
    ldr r0, =g_status
    mov r1, #2
    str r1, [r0]
    pop {r0, r1}
    movs pc, lr

    @ void run_test(struct state *s)
    .global run_test
run_test:
    push {r4-r11, lr}
    ldr r1, =g_state
    str r0, [r1]
    ldr r1, [r0, #STATE_FPSCR]
    vmsr fpscr, r1
    ldr r1, [r0, #STATE_CPSR]
    msr APSR_nzcvqg, r1
    add r1, r0, #STATE_D
    vldmia r1!, {d0-d15}
    vldmia r1, {d16-d31}
    add r0, r0, #STATE_R
    ldm r0, {r0-r12}
    bl test_slot
    push {r0-r12}
    mrs r0, APSR
    vmrs r1, fpscr
    ldr r2, =g_state
    ldr r2, [r2]
    str r0, [r2, #STATE_CPSR]
    str r1, [r2, #STATE_FPSCR]
    add r3, r2, #STATE_D
    vstmia r3!, {d0-d15}
    vstmia r3, {d16-d31}
    add r3, r2, #STATE_R
    mov r4, #0
1:  ldr r5, [sp, r4]
    str r5, [r3, r4]
    add r4, r4, #4
    cmp r4, #52
    bne 1b
    add sp, sp, #52
    pop {r4-r11, pc}

    .section .data
    .align 2
    .global test_slot
test_slot:
    .word 0xe320f000                @ nop, replaced by the instruction under test
    bx lr
