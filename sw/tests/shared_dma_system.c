// SPDX-License-Identifier: Apache-2.0
#include <stdint.h>
#include "shared_dma.h"
#ifndef TILE_ID
#define TILE_ID 0
#endif
#ifndef NUM_TILES
#define NUM_TILES 4
#endif
static volatile uint32_t *const scratch = (volatile uint32_t *)0x03000000UL;
void trap_vector(void) {
    uintptr_t cause, value;
    __asm__ volatile("csrr %0, mcause" : "=r"(cause));
    __asm__ volatile("csrr %0, mtval" : "=r"(value));
    scratch[3] = (uint32_t)cause;
    scratch[4] = (uint32_t)value;
    scratch[2] = (0x100u << 1) | 1;
    for (;;) __asm__ volatile("wfi");
}
int main(void) {
    scratch[0] = TILE_ID;
    scratch[1] = 1;
    volatile uint64_t *data = (volatile uint64_t *)(0x84000000UL + TILE_ID * 0x10000UL);
    *data = 0x1234567800000000ULL | TILE_ID;
    shared_dma_fence();
    if (*data != (0x1234567800000000ULL | TILE_ID)) return 1;
    scratch[1] = 2;
    return 0;
}
