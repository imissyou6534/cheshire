/* SPDX-License-Identifier: Apache-2.0 */
/* Link with --no-relax: legacy CRT loads the stack before setting gp. */
INCLUDE common.ldh
ENTRY(_start)

PHDRS {
  code PT_LOAD FLAGS(5);
  data PT_LOAD FLAGS(6);
  probe PT_LOAD FLAGS(6);
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

  .bulk : ALIGN(16) {
    *(.bulk .bulk.*)
  } > spm :data
  __private_spm_program_end = .;

  /* Fixed addresses let an AXI-only TB inspect/invalidate the reservation. */
  .private_spm_probe 0x1000f000 : {
    KEEP(*(.private_spm_probe))
  } > spm :probe
  __private_spm_image_end = .;

  /* No loadable stack section: boot ROM is still using the top of SPM.
     The program owns 32 KiB in the upper half of the 128 KiB private SPM;
     the remaining 32 KiB retains the active boot ROM context. */
  __private_spm_stack_bottom = 0x10010000;
  __private_spm_stack_top = 0x10018000;
  /* crt0.S saves 24 bytes before main: (top - 8 - 24) % 16 == 0. */
  __stack_pointer$ = __private_spm_stack_top - 8;

  /DISCARD/ : { *(.eh_frame .eh_frame.* .note .note.*) }
}

ASSERT(_start == 0x10000000, "private SPM entry must be 0x10000000")
ASSERT(__private_spm_program_end <= 0x1000f000,
       "private SPM code/data overlaps fixed probes")
ASSERT(SIZEOF(.private_spm_probe) > 0, "private SPM probes missing")
ASSERT(__private_spm_image_end <= 0x10010000,
       "private SPM code/data exceeds 64 KiB")
ASSERT(((__stack_pointer$ - 24) & 15) == 0,
       "private SPM CRT-to-C stack is not 16-byte aligned")
ASSERT(__private_spm_stack_bottom >= __private_spm_image_end &&
       __private_spm_stack_top <= 0x10020000,
       "private SPM stack outside upper half of 128 KiB")
