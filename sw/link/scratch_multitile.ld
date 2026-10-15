/* SPDX-License-Identifier: Apache-2.0 */
INCLUDE common.ldh
ENTRY(_start)
PHDRS {
  code PT_LOAD FLAGS(5);
  data PT_LOAD FLAGS(6);
}
SECTIONS {
  .text : {
    KEEP(*(.text._start))
    *(.text .text.*)
  } > spm :code
  .misc : ALIGN(16) {
    *(.rodata .rodata.* .srodata .srodata.*)
    *(.data .data.* .sdata .sdata.*)
    . = ALIGN(16);
  } > spm :data
  .bss (NOLOAD) : ALIGN(16) {
    __bss_start = .;
    *(.bss .bss.* .sbss .sbss.* COMMON)
    . = ALIGN(16);
    __bss_end = .;
  } > spm :data
  __stack_pointer$ = 0x10017ff8;
  /DISCARD/ : { *(.eh_frame .eh_frame.* .note .note.*) }
}
ASSERT(_start == 0x10000000, "scratch test entry must be in private SPM")
ASSERT(__bss_end <= 0x10010000, "scratch test image overlaps stack")
ASSERT(((__stack_pointer$ - 24) & 15) == 0, "unaligned CRT-to-C stack")
