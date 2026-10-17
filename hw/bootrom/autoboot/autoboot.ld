/* SPDX-License-Identifier: Apache-2.0 */
/* One firmware: execute the loader in ROM, then copy the application to SPM. */
INCLUDE common.ldh
ENTRY(_rom_start)

PHDRS {
  boot PT_LOAD FLAGS(5);
  application PT_LOAD FLAGS(7);
}

SECTIONS {
  .boot : {
    KEEP(*boot_start.o(.text._rom_start))
    *boot_start.o(.text .text.* .rodata .rodata.* .srodata .srodata.*)
    *boot_main.o(.text .text.* .rodata .rodata.* .srodata .srodata.*)
  } > bootrom :boot

  .boot_writable : {
    *boot_start.o(.data .data.* .sdata .sdata.* .bss .bss.* .sbss .sbss.* COMMON)
    *boot_main.o(.data .data.* .sdata .sdata.* .bss .bss.* .sbss .sbss.* COMMON)
  } > bootrom :boot

  /* The packager fills this word after linking; no second link is needed. */
  .rom_checksum : ALIGN(4) {
    __rom_app_checksum = .;
    LONG(0)
  } > bootrom :boot

  .app : ALIGN(16) {
    KEEP(*(.text._start))
    *(.text .text.*)
    . = ALIGN(16);
  } > spm AT> bootrom :application

  .misc ALIGN(16) : AT(LOADADDR(.app) + ADDR(.misc) - ADDR(.app)) {
    *(.rodata .rodata.* .srodata .srodata.*)
    *(.data .data.* .sdata .sdata.*)
    *(.bulk .bulk.*)
    . = ALIGN(16);
  } > spm :application

  .bss ALIGN(16) (NOLOAD) : AT(LOADADDR(.app) + ADDR(.bss) - ADDR(.app)) {
    __bss_start = .;
    *(.bss .bss.* .sbss .sbss.* COMMON)
    . = ALIGN(16);
    __bss_end = .;
  } > spm :application

  __app_load_start = LOADADDR(.app);
  __app_start = ADDR(.app);
  __app_copy_size = ADDR(.misc) + SIZEOF(.misc) - ADDR(.app);
  __app_mem_size = __bss_end - __app_start;
  __rom_image_end = __app_load_start + __app_copy_size;
  __rom_global_pointer$ = ORIGIN(bootrom) + 0x800;
  __global_pointer$ = ADDR(.app) + 0x800;
  __app_stack_bottom = 0x10010000;
  __app_stack_top = 0x10018000;
  __stack_pointer$ = __app_stack_top - 8;

  /DISCARD/ : { *(.eh_frame .eh_frame.* .note .note.*) }
}

ASSERT(_rom_start == ORIGIN(bootrom), "reset entry must be in ROM")
ASSERT(_start == ORIGIN(spm), "application entry must be at the SPM base")
ASSERT(SIZEOF(.boot_writable) == 0, "ROM loader must not have writable globals")
ASSERT(__rom_image_end <= ORIGIN(bootrom) + LENGTH(bootrom), "firmware exceeds 16 KiB ROM")
ASSERT(__bss_end <= ORIGIN(spm) + LENGTH(spm), "application overlaps its stack")
ASSERT(((__stack_pointer$ - 24) & 15) == 0, "unaligned CRT-to-C stack")
