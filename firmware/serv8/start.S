/* 
 * Minimal RISC-V boot assembly for SERV Core
 * Initializes the stack pointer and jumps immediately into the C++ main loop.
 */

.globl _start
.section .text.init

_start:
    /* Load the initial stack pointer from the linker script */
    la sp, _stack_start
    
    /* Jump directly into the main() loop defined in main.cpp */
    call main

    /* In the event of a catastrophic return from main(), trap into infinite loop */
trap:
    j trap
