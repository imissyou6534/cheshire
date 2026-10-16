/* SPDX-License-Identifier: Apache-2.0 */
.section .text._start,"ax",@progbits
.global _start
_start:
    .irp reg,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    li x\reg, 0
    .endr
    csrwi mie, 0
    csrci mstatus, 8
    la t0, rom_trap
    csrw mtvec, t0
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop

    la t0, __base_llc
1:  lw t1, 72(t0)
    andi t1, t1, 1
    beqz t1, 1b
    li t1, -1
    sw t1, 0(t0)
    sw t1, 4(t0)
    li t1, 1
    sw t1, 16(t0)

    la t0, __base_regs
    lw t1, 84(t0)
    la sp, __base_spm
    add sp, sp, t1
    addi sp, sp, -16
    andi sp, sp, -16
    fence
    call main
    j rom_park

.section .text.rom_enter,"ax",@progbits
.global rom_autoboot_enter
.type rom_autoboot_enter,@function
rom_autoboot_enter:
    mv t0, a0
    fence iorw, iorw
    fence.i
    la ra, rom_app_exit
    csrr a0, mhartid
    jr t0
.size rom_autoboot_enter, .-rom_autoboot_enter

/* The application's CRT returns here with no ROM gp/stack assumptions. */
rom_app_exit:
    li t0, 0x03000000
    slli t1, a0, 1
    ori t1, t1, 1
    sw t1, 8(t0)
    li t1, 0x524f4d44
    sw t1, 60(t0)
rom_park:
    wfi
    j rom_park

.align 2
rom_trap:
    li t0, 0x03000000
    csrr t1, mcause
    sw t1, 44(t0)
    csrr t1, mtval
    sw t1, 40(t0)
    csrr t1, mepc
    sw t1, 36(t0)
    li t1, 255
    sw t1, 56(t0)
    li t1, 0x524f4d46
    sw t1, 60(t0)
    li t1, 511
    sw t1, 8(t0)
    j rom_park
