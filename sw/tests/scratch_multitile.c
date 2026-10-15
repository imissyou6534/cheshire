// SPDX-License-Identifier: Apache-2.0
#include <stdint.h>
#include "shared_dma_cva6_wb.h"

#ifndef TILE_ID
#define TILE_ID 0
#endif
#ifndef NUM_TILES
#define NUM_TILES 4
#endif
#if TILE_ID < 0 || TILE_ID >= NUM_TILES
#error Invalid scratch test tile
#endif

#define SCRATCH_BASE ((uintptr_t)0x03000000UL)
#define ROUNDS 70u
#define SUCCESS UINT32_C(0x53435250)
#define FAILURE UINT32_C(0x53435246)
static volatile uint32_t *const scratch = (volatile uint32_t *)SCRATCH_BASE;
static volatile uint32_t *const mailbox =
    (volatile uint32_t *)(0x84000000UL + TILE_ID * 0x10000UL);
static const uint64_t drain_guard[2] __attribute__((aligned(16), used)) = {1, 2};

static __attribute__((noreturn)) void finish(uint32_t status, uint32_t error) {
    mailbox[5] = error;
    __asm__ volatile ("fence iorw, iorw" ::: "memory");
    mailbox[0] = status;
    for (;;) __asm__ volatile ("wfi");
}

void trap_vector(void) {
    uintptr_t cause = shared_dma_mcause(), value = shared_dma_mtval(), pc;
    __asm__ volatile ("csrr %0, mepc" : "=r" (pc));
    mailbox[6] = (uint32_t)cause;
    mailbox[8] = (uint32_t)value;
    mailbox[9] = (uint32_t)pc;
    finish(FAILURE, 0x70);
}

static uint32_t pattern(unsigned round, unsigned reg) {
    if (round == 0) return 0;
    if (round == 1) return UINT32_MAX;
    if (round == 2) return UINT32_C(0xaaaaaaaa);
    if (round == 3) return UINT32_C(0x55555555);
    if (round < 36) return UINT32_C(1) << (round - 4);
    if (round < 68) return ~(UINT32_C(1) << (round - 36));
    uint32_t stamp = UINT32_C(0x5a000000) | ((uint32_t)TILE_ID << 16) |
                     ((uint32_t)reg << 8) | (0x80u + reg);
    return round == 68 ? stamp : ~stamp;
}

static void rejected_store(uintptr_t address, unsigned halfword) {
    // This CVA6 WB adapter does not turn ordinary-store B errors into traps.
    // The TB checks SLVERR; software checks that storage remains unchanged.
    if (halfword) {
        __asm__ volatile (".option push\n.option norvc\nsh %0, 0(%1)\n.option pop"
                          :: "r" ((uintptr_t)0x3c5a), "r" (address) : "memory");
    } else {
        __asm__ volatile (".option push\n.option norvc\nsb %0, 0(%1)\n.option pop"
                          :: "r" ((uintptr_t)0xa6), "r" (address) : "memory");
    }
    __asm__ volatile ("fence iorw, iorw" ::: "memory");
}

int main(void) {
    shared_dma_machine_irq_off();
    shared_dma_cva6_wb_disable(drain_guard);
    shared_dma_icache_set(0);
    mailbox[1] = TILE_ID;
    unsigned writes = 0, reads = 0;
    unsigned negative = mailbox[7];
    for (unsigned round = 0; round < ROUNDS; ++round) {
        for (unsigned reg = 0; reg < 16; ++reg) {
            uint32_t value = pattern(round, reg);
            uintptr_t address = SCRATCH_BASE + 4u * reg;
            if (TILE_ID == 1 && round == 0 && reg == 7) {
                if (negative == 1) value ^= 1;
                if (negative == 2) address += 0x80;
            }
            *(volatile uint32_t *)address = value;
            __asm__ volatile ("fence iorw, iorw" ::: "memory");
            ++writes;
            if (scratch[reg] != pattern(round, reg)) finish(FAILURE, 0x11);
            ++reads;
        }
        // Verify earlier registers have not changed when another word is written.
        for (unsigned reg = 0; reg < 16; ++reg) {
            if (scratch[reg] != pattern(round, reg)) finish(FAILURE, 0x12);
            ++reads;
        }
    }
    for (unsigned lane = 0; lane < 4; ++lane) {
        for (unsigned reg = 0; reg < 16; ++reg) {
            rejected_store(SCRATCH_BASE + 4u * reg + lane, 0);
            if (scratch[reg] != pattern(69, reg)) finish(FAILURE, 0x22);
            ++reads;
        }
    }
    for (unsigned lane = 0; lane < 2; ++lane) {
        for (unsigned reg = 0; reg < 16; ++reg) {
            rejected_store(SCRATCH_BASE + 4u * reg + 2u * lane, 1);
            if (scratch[reg] != pattern(69, reg)) finish(FAILURE, 0x23);
            ++reads;
        }
    }
    mailbox[2] = writes;
    mailbox[3] = 96;
    mailbox[4] = reads;
    finish(SUCCESS, 0);
}
