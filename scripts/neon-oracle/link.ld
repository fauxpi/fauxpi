ENTRY(_start)
SECTIONS
{
    . = 0x40010000;
    .text : { *(.text.vectors) *(.text*) }
    .rodata : { *(.rodata*) }
    .data : { *(.data*) }
    .bss : { *(.bss*) *(COMMON) }
    . = ALIGN(16);
    . = . + 0x4000;
    und_stack_top = .;
    . = . + 0x4000;
    abt_stack_top = .;
    . = . + 0x10000;
    svc_stack_top = .;
    ASSERT(. < 0x40100000, "image overlaps the test buffer")
}
