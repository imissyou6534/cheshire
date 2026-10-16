/* SPDX-License-Identifier: Apache-2.0 */
INCLUDE common.ldh
ENTRY(_start)
SECTIONS {
  .text : {
    KEEP(*(.text._start))
    *(.text .text.*)
  } > bootrom
  .misc : ALIGN(16) {
    *(.rodata .rodata.* .srodata .srodata.*)
    *(.rom_payload_meta)
    *(.rom_payload)
  } > bootrom
  .data : { *(.data .data.* .sdata .sdata.*) } > bootrom
  .bss (NOLOAD) : { *(.bss .bss.* .sbss .sbss.* COMMON) } > bootrom
  /DISCARD/ : { *(.eh_frame .eh_frame.* .note .note.*) }
}
ASSERT(_start == 0x02000000, "autoboot reset entry must be in ROM")
ASSERT(SIZEOF(.data) == 0 && SIZEOF(.bss) == 0, "ROM loader must not have writable globals")
ASSERT(SIZEOF(.text) + SIZEOF(.misc) <= LENGTH(bootrom), "autoboot ROM exceeds capacity")
