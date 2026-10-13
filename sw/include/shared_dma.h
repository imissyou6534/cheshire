// SPDX-License-Identifier: Apache-2.0
#ifndef CHESHIRE_SHARED_DMA_H
#define CHESHIRE_SHARED_DMA_H
#include <stdint.h>
#include <stddef.h>

enum {
    SHDMA_SUBMIT = 0x100, SHDMA_QUEUE_STATUS = 0x104, SHDMA_COMP_VALID = 0x108,
    SHDMA_COMP_JOB_ID = 0x10c, SHDMA_COMP_STATUS = 0x110, SHDMA_COMP_POP = 0x114,
    SHDMA_IRQ_ENABLE = 0x118, SHDMA_LAST_JOB_ID = 0x11c, SHDMA_SUBMIT_STATUS = 0x120
};
typedef struct {
    uint64_t src, dst;
    uint32_t length, reps, src_stride, dst_stride;
} shared_dma_job_t;
typedef struct {
    uint32_t job_id;
    uint16_t engine_id;
    uint8_t error_code;
} shared_dma_completion_t;

static inline void shared_dma_fence(void) {
#ifdef __riscv
    __asm__ volatile ("fence iorw, iorw" ::: "memory");
#else
    __asm__ volatile ("" ::: "memory");
#endif
}
static inline uint32_t shared_dma_read(uintptr_t base, unsigned off) {
    return *(volatile uint32_t *)(base + off);
}
static inline void shared_dma_write(uintptr_t base, unsigned off, uint32_t value) {
    *(volatile uint32_t *)(base + off) = value;
}
static inline void shared_dma_write64(uintptr_t base, unsigned off, uint64_t value) {
    shared_dma_write(base, off, (uint32_t)value);
    shared_dma_write(base, off + 4, (uint32_t)(value >> 32));
}

// One software producer per tile (or hold a software lock around the whole operation).
// Caller must clean source and dirty destination lines before submit; invalidate
// destination after completion. Plain RISC-V fences are not portable cache
// maintenance; the selected CVA6 WB target uses fence to flush its whole cache.
// See shared_dma_cva6_wb.h for this target's flush and writeback-drain sequence.
// Returns 0 accepted, -1 no capacity, -2 invalid; ID is set only on success.
static inline int shared_dma_try_submit(uintptr_t base, const shared_dma_job_t *job,
        uint64_t mem_start, uint64_t mem_end, unsigned addr_width, uint32_t *id) {
    if (!job || !id || !job->length || !job->reps || mem_start >= mem_end) return -2;
    if (addr_width < 32 || addr_width > 64 ||
        (addr_width < 64 && mem_end > (UINT64_C(1) << addr_width))) return -2;
    uint64_t src_span = (uint64_t)(job->reps - 1) * job->src_stride;
    uint64_t dst_span = (uint64_t)(job->reps - 1) * job->dst_stride;
    if (job->src < mem_start || job->dst < mem_start ||
        job->src >= mem_end || job->dst >= mem_end) return -2;
    if (src_span >= mem_end - job->src || dst_span >= mem_end - job->dst ||
        job->length > mem_end - job->src - src_span ||
        job->length > mem_end - job->dst - dst_span) return -2;
    uint64_t src_end = job->src + src_span + job->length;
    uint64_t dst_end = job->dst + dst_span + job->length;
    if (job->src < dst_end && job->dst < src_end) return -2;
    if (!(shared_dma_read(base, SHDMA_QUEUE_STATUS) & 1)) return -1;
    shared_dma_write(base, 0x000, 1u << 10);
    shared_dma_write64(base, 0x0d0, job->dst);
    shared_dma_write64(base, 0x0d8, job->src);
    shared_dma_write64(base, 0x0e0, job->length);
    shared_dma_write64(base, 0x0e8, job->dst_stride);
    shared_dma_write64(base, 0x0f0, job->src_stride);
    shared_dma_write64(base, 0x0f8, job->reps);
    shared_dma_fence();
    shared_dma_write(base, SHDMA_SUBMIT, 1);
    shared_dma_fence();
    uint32_t submit_status = shared_dma_read(base, SHDMA_SUBMIT_STATUS) & 0xff;
    if (submit_status != 0) return submit_status == 4 ? -1 : -2;
    *id = shared_dma_read(base, SHDMA_LAST_JOB_ID);
    return 0;
}
// Events must be consumed in order; callers store all events they receive.
static inline int shared_dma_poll(uintptr_t base, shared_dma_completion_t *event) {
    if (!event || !(shared_dma_read(base, SHDMA_COMP_VALID) & 1)) return 0;
    shared_dma_fence();
    event->job_id = shared_dma_read(base, SHDMA_COMP_JOB_ID);
    uint32_t status = shared_dma_read(base, SHDMA_COMP_STATUS);
    event->engine_id = (uint16_t)(status >> 16);
    event->error_code = (uint8_t)status;
    shared_dma_write(base, SHDMA_COMP_POP, 1);
    shared_dma_fence();
    return 1;
}
#endif
