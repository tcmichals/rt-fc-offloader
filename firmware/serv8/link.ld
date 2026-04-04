OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    /* 4KB BRAM instantiated for SERV inside the Tang9K */
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 4K
}

SECTIONS
{
    .text :
    {
        *(.text.init) /* Boot entry point must strictly be at 0x00000000 */
        *(.text*)
        *(.rodata*)
    } > RAM

    .data :
    {
        *(.data*)
        *(.sdata*)
    } > RAM

    .bss :
    {
        *(.bss*)
        *(.sbss*)
    } > RAM

    /* Set the stack pointer at the very top of our extremely small 4KB block */
    _stack_start = ORIGIN(RAM) + LENGTH(RAM);
}
