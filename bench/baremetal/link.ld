/* The bare-metal benchmark, as the Pi's firmware loads a 32-bit kernel.img: at 0x8000, started
   there. */
ENTRY(_start)

SECTIONS
{
    . = 0x8000;
    .text : {
        KEEP(*(.text.boot))
        *(.text .text.*)
    }
    .rodata : ALIGN(16) {
        KEEP(*(.rodata.config))
        *(.rodata .rodata.*)
    }
    .data : ALIGN(16) {
        *(.data .data.*)
    }
    .bss (NOLOAD) : ALIGN(16) {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        __bss_end = .;
    }
    /DISCARD/ : {
        *(.ARM.exidx*)
        *(.comment)
    }
}
