// SPDX-License-Identifier: Apache-2.0
.section .text.system_entry,"ax",@progbits
.globl _system_entry
_system_entry:
    la ra, _system_park
    j _start
_system_park:
    wfi
    j _system_park
