/* SPDX-License-Identifier: Apache-2.0 */
INCLUDE common.ldh
ENTRY(_system_entry)
MEMORY {
  tile_ram (rwx) : ORIGIN = __tile_base, LENGTH = 256K
}
SECTIONS {
  .text : {
    KEEP(*(.text.system_entry))
    KEEP(*(.text._start))
    *(.text .text.*)
  } > tile_ram
  .misc : ALIGN(64) {
    *(.rodata .rodata.* .srodata .srodata.*)
    *(.data .data.* .sdata .sdata.*)
  } > tile_ram
  .bss : ALIGN(64) {
    __bss_start = .;
    *(.bss .bss.* .sbss .sbss.* COMMON)
    __bss_end = .;
  } > tile_ram
  __global_pointer$ = ADDR(.misc) + 0x800;
  /* Legacy CRT saves 24 bytes before calling C: this leaves SP 16-byte aligned. */
  __stack_pointer$ = ORIGIN(tile_ram) + LENGTH(tile_ram) - 8;
}
