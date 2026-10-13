// SPDX-License-Identifier: Apache-2.0
#ifndef CHESHIRE_SHARED_DMA_CVA6_WB_H
#define CHESHIRE_SHARED_DMA_CVA6_WB_H

#include <stdint.h>

enum { SHDMA_CVA6_WB_LINE_BYTES = 16, SHDMA_CVA6_WB_CACHE_BYTES = 32768 };

static inline void shared_dma_compiler_barrier(void) {
    __asm__ volatile ("" ::: "memory");
}

static inline uint64_t shared_dma_mcycle(void) {
    uint64_t value;
    __asm__ volatile ("csrr %0, mcycle" : "=r" (value));
    return value;
}

static inline uintptr_t shared_dma_mcause(void) {
    uintptr_t value;
    __asm__ volatile ("csrr %0, mcause" : "=r" (value));
    return value;
}

static inline uintptr_t shared_dma_mtval(void) {
    uintptr_t value;
    __asm__ volatile ("csrr %0, mtval" : "=r" (value));
    return value;
}

static inline void shared_dma_machine_irq_off(void) {
    __asm__ volatile ("csrci mstatus, 8\n\tcsrw mie, zero" ::: "memory");
}

static inline void shared_dma_machine_external_irq_on(void) {
    uintptr_t meie = (uintptr_t)1 << 11;
    __asm__ volatile ("csrs mie, %0\n\tcsrsi mstatus, 8"
                      :: "r" (meie) : "memory");
}

static inline void shared_dma_machine_global_irq_on(void) {
    __asm__ volatile ("csrsi mstatus, 8" ::: "memory");
}

static inline void shared_dma_dcache_set(unsigned enabled) {
    /* CSR disable alone does not clean dirty cache lines. */
    __asm__ volatile ("csrw 0x7c1, %0" :: "r" ((uintptr_t)enabled) : "memory");
}

static inline void shared_dma_icache_set(unsigned enabled) {
    __asm__ volatile ("csrw 0x7c0, %0" :: "r" ((uintptr_t)enabled) : "memory");
}

static inline void shared_dma_cva6_wb_handoff(const volatile uint64_t *guard) {
    /* On this target fence flushes the whole D-cache. Its ack can precede B;
       the subsequent private read-only cache miss drains the cache adapter. */
    __asm__ volatile ("fence iorw, iorw" ::: "memory");
    uint64_t value = *guard;
    __asm__ volatile ("" :: "r" (value) : "memory");
}

static inline void shared_dma_cva6_wb_disable(const volatile uint64_t *guard) {
    shared_dma_cva6_wb_handoff(guard);
    shared_dma_dcache_set(0);
}

/* These words reside in shared DDR; a cached C load is not a synchronization
   operation. RV64 .w AMOs sign-extend, so expose only the low 32 bits. */
static inline uint32_t shared_dma_amo_load(uintptr_t address) {
    uintptr_t value;
    __asm__ volatile ("amoadd.w %0, zero, (%1)"
                      : "=r" (value) : "r" (address) : "memory");
    return (uint32_t)value;
}

static inline void shared_dma_amo_store(uintptr_t address, uint32_t value) {
    __asm__ volatile ("amoswap.w.aqrl zero, %0, (%1)"
                      :: "r" ((uintptr_t)value), "r" (address) : "memory");
}

static inline uint32_t shared_dma_amo_add(uintptr_t address, uint32_t value) {
    uintptr_t old;
    __asm__ volatile ("amoadd.w.aqrl %0, %1, (%2)"
                      : "=r" (old) : "r" ((uintptr_t)value), "r" (address)
                      : "memory");
    return (uint32_t)old;
}

#endif
