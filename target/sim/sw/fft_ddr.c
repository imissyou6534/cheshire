/* SPDX-License-Identifier: Apache-2.0 */
#include <stdint.h>
#include "regs/cheshire.h"
#include "util.h"

int main(void) {
    uint32_t tile = *reg32(&__base_regs, CHESHIRE_SCRATCH_3_REG_OFFSET);
    uint32_t inverse = *reg32(&__base_regs, CHESHIRE_SCRATCH_6_REG_OFFSET);
    if (tile >= 64 || inverse > 1) return 1;
    uintptr_t base = UINT64_C(0x80000000) + tile * UINT64_C(0x100000);
    for (unsigned job = 0; job < 3; ++job) {
        uintptr_t source = base + job * UINT64_C(0x10000);
        uintptr_t destination = source + UINT64_C(0x4000);
        asm volatile ("fence rw,rw" ::: "memory");
        if (inverse) {
            asm volatile (".insn r 0x0b, 5, 0x4c, x0, %0, %1"
                          :: "r"(source), "r"(destination) : "memory");
        } else {
            asm volatile (".insn r 0x0b, 5, 0x0c, x0, %0, %1"
                          :: "r"(source), "r"(destination) : "memory");
        }
        asm volatile (".word 0x0000002b" ::: "memory");
        asm volatile ("fence rw,rw" ::: "memory");
    }
    return 0;
}
