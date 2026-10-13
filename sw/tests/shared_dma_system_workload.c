// SPDX-License-Identifier: Apache-2.0
#include <stdint.h>
#include "shared_dma.h"
#include "shared_dma_cva6_wb.h"

#ifndef TILE_ID
#define TILE_ID 0
#endif
#ifndef NUM_TILES
#define NUM_TILES 4
#endif
#ifndef CACHE_NEGATIVE
#define CACHE_NEGATIVE 0
#endif
#ifndef IRQ_NEGATIVE
#define IRQ_NEGATIVE 0
#endif
#ifndef DMA_TIMEOUT_CYCLES
#define DMA_TIMEOUT_CYCLES 1000000UL
#endif
#ifndef SYNC_TIMEOUT_CYCLES
#define SYNC_TIMEOUT_CYCLES 4000000UL
#endif
#if NUM_TILES < 1 || NUM_TILES > 64 || TILE_ID < 0 || TILE_ID >= NUM_TILES
#error Invalid tile configuration
#endif
#if CACHE_NEGATIVE && IRQ_NEGATIVE
#error Select one negative experiment at a time
#endif

enum {
    PH_BOOT = 1, PH_BASELINE = 2, PH_ND = 3, PH_CACHE = 4,
    PH_IRQ = 5, PH_SYNC = 6, PH_DONE = 7,
    ERR_READY = 0x61, ERR_BARRIER = 0x62, ERR_SUBMIT = 0x63,
    ERR_COMPLETION = 0x64, ERR_EVENT = 0x65, ERR_BYTES = 0x66,
    ERR_PEER = 0x67, ERR_IRQ = 0x68, ERR_TRAP = 0x70,
    ERR_CACHE_NEGATIVE = 0x74, ERR_IRQ_NEGATIVE = 0x75,
    ERR_CACHE_NEGATIVE_MISSED = 0x76,
    JOBS = 5, BASELINE_BYTES = 4096, CACHE_BYTES = 512, IRQ_BYTES = 512,
    POISON = 0xa5, RESULT_MAGIC = 0x53444d41, READY_MAGIC = 0x52445931
};

#define DMA_BASE ((uintptr_t)0x01000000UL)
#define READY_ADDR ((uintptr_t)0x88000000UL)
#define BARRIER_ADDR(phase) ((uintptr_t)0x88000100UL + (phase) * 4UL)
#define TILE_BUFFER(tile) ((uintptr_t)0x84000000UL + (tile) * 0x10000UL)
#define PLIC_PRIORITY ((uintptr_t)0x040000e8UL)
#define PLIC_ENABLE ((uintptr_t)0x04002004UL)
#define PLIC_THRESHOLD ((uintptr_t)0x04200000UL)
#define PLIC_CLAIM ((uintptr_t)0x04200004UL)

/* Fixed DDR metadata at buffer + 0x8000, all fields little-endian u32:
   +00 magic, +04 tile, +08 successful jobs, +0c cache evidence,
   +10 IRQ claims, +14 IRQ events, +18 published phase, +1c sync evidence,
   +20 submitted[5], +34 completed[5], +48 raw status[5].
   Status bits 31:16 are engine ID, bits 7:0 error (zero on success).
   Expected submitted/completed IDs are 1,2,3,4,5 on each local frontend. */
typedef struct {
    uint32_t magic, tile, successful_jobs, cache_success;
    uint32_t irq_count, irq_events, published_phase, sync_success;
    uint32_t submitted[JOBS], completed[JOBS], status[JOBS];
} result_t;
_Static_assert(sizeof(result_t) == 0x5c, "DDR result ABI");

static volatile uint32_t *const scratch = (volatile uint32_t *)0x03000000UL;
static volatile result_t *const result =
    (volatile result_t *)(TILE_BUFFER(TILE_ID) + 0x8000UL);

/* Each ELF owns its copy in private, cacheable DDR. Never write this line. */
static const uint64_t drain_guard[2] __attribute__((aligned(16), used)) = {
    UINT64_C(0x5348444d41475244), UINT64_C(0x1122334455667788)
};

static inline uint32_t mmio_read(uintptr_t address) {
    return *(volatile uint32_t *)address;
}

static inline void mmio_write(uintptr_t address, uint32_t value) {
    *(volatile uint32_t *)address = value;
}

static inline int expired(uint64_t start, uint64_t limit) {
    return shared_dma_mcycle() - start >= limit;
}

static uint8_t initial_byte(unsigned tile, unsigned offset) {
    return (uint8_t)(0x31u + tile * 37u + offset * 13u + (offset >> 4));
}

/* TB contract: initialize [B,B+0x4000) with initial_byte(tile, offset),
   [B+0x4000,B+0x8000) with 0xa5. Only the five destination ranges below
   change; phase 4 also changes source [B+0x2800,B+0x2a00) to cache_byte.
   Every other byte in these two 16-KiB regions must retain its initial value. */
static uint8_t cache_byte(unsigned tile, unsigned index) {
    return (uint8_t)(0xc3u + tile * 29u + index * 7u + (index >> 3));
}

static uint8_t source_byte(unsigned tile, unsigned offset, unsigned phase) {
    if (phase >= PH_CACHE && offset >= 0x2800u && offset < 0x2a00u)
        return cache_byte(tile, offset - 0x2800u);
    return initial_byte(tile, offset);
}

static uint8_t destination_byte(unsigned tile, unsigned offset, unsigned phase) {
    if (offset < BASELINE_BYTES)
        return initial_byte(tile, offset);
    if (phase >= PH_ND && offset >= 0x2005u && offset < 0x2348u) {
        unsigned relative = offset - 0x2005u;
        unsigned rep = relative / 256u, byte = relative % 256u;
        if (rep < 4 && byte < 67)
            return initial_byte(tile, 0x2003u + rep * 128u + byte);
    }
    if (phase >= PH_CACHE && offset >= 0x2800u && offset < 0x2a00u)
        return cache_byte(tile, offset - 0x2800u);
    if (phase >= PH_IRQ && offset >= 0x3000u && offset < 0x3400u)
        return initial_byte(tile, offset);
    return POISON;
}

static int check_range(unsigned tile, unsigned phase, unsigned first, unsigned end) {
    volatile const uint8_t *src = (volatile const uint8_t *)TILE_BUFFER(tile);
    volatile const uint8_t *dst = src + 0x4000;
    for (unsigned i = first; i < end; ++i) {
        if (src[i] != source_byte(tile, i, phase) ||
            dst[i] != destination_byte(tile, i, phase)) return ERR_BYTES;
    }
    return 0;
}

static int check_buffers(unsigned tile, unsigned phase) {
    /* Check every transferred byte and ND hole, with 16-byte guard pads. */
    if (phase == PH_BASELINE)
        return check_range(tile, phase, 0, BASELINE_BYTES + 16u);
    if (phase == PH_ND) {
        int error = check_range(tile, phase, 0x1ff0u, 0x2410u);
        if (error) return error;
        return check_range(tile, phase, 0x37f0u, 0x3910u);
    }
    if (phase == PH_CACHE)
        return check_range(tile, phase, 0x27f0u, 0x2a10u);
    return check_range(tile, phase, 0x2ff0u, 0x3410u);
}

static void set_phase(unsigned phase) {
    scratch[1] = phase;
}

static int barrier(unsigned phase) {
    uintptr_t address = BARRIER_ADDR(phase);
    /* All callers have D-cache off; order private DDR publication before AMO. */
    shared_dma_fence();
    if (shared_dma_amo_add(address, 1) >= NUM_TILES) return ERR_BARRIER;
    uint64_t start = shared_dma_mcycle();
    for (;;) {
        uint32_t count = shared_dma_amo_load(address);
        if (count == NUM_TILES) {
            shared_dma_fence();
            return 0;
        }
        if (count > NUM_TILES || expired(start, SYNC_TIMEOUT_CYCLES))
            return ERR_BARRIER;
    }
}

static void program_job(const shared_dma_job_t *job) {
    shared_dma_write(DMA_BASE, 0x000, 1u << 10);
    shared_dma_write64(DMA_BASE, 0x0d0, job->dst);
    shared_dma_write64(DMA_BASE, 0x0d8, job->src);
    shared_dma_write64(DMA_BASE, 0x0e0, job->length);
    shared_dma_write64(DMA_BASE, 0x0e8, job->dst_stride);
    shared_dma_write64(DMA_BASE, 0x0f0, job->src_stride);
    shared_dma_write64(DMA_BASE, 0x0f8, job->reps);
}

/* Deliberately no hardware fence: phase 4 must preserve its primed line. */
static int submit_raw(const shared_dma_job_t *job, uint32_t *id) {
    uint64_t start = shared_dma_mcycle();
    while (!(shared_dma_read(DMA_BASE, SHDMA_QUEUE_STATUS) & 1u)) {
        if (expired(start, DMA_TIMEOUT_CYCLES)) return ERR_SUBMIT;
    }
    uint32_t previous = shared_dma_read(DMA_BASE, SHDMA_LAST_JOB_ID);
    program_job(job);
    shared_dma_compiler_barrier();
    shared_dma_write(DMA_BASE, SHDMA_SUBMIT, 1);
    while ((*id = shared_dma_read(DMA_BASE, SHDMA_LAST_JOB_ID)) == previous) {
        if (expired(start, DMA_TIMEOUT_CYCLES)) return ERR_SUBMIT;
    }
    if (*id != previous + 1u ||
        (shared_dma_read(DMA_BASE, SHDMA_SUBMIT_STATUS) & 0xffu)) return ERR_SUBMIT;
    return 0;
}

static int wait_completion_raw(uint32_t id) {
    uint64_t start = shared_dma_mcycle();
    while (!(shared_dma_read(DMA_BASE, SHDMA_COMP_VALID) & 1u)) {
        if (shared_dma_read(DMA_BASE, SHDMA_LAST_JOB_ID) != id ||
            expired(start, DMA_TIMEOUT_CYCLES)) return ERR_COMPLETION;
    }
    if (shared_dma_read(DMA_BASE, SHDMA_COMP_JOB_ID) != id ||
        (shared_dma_read(DMA_BASE, SHDMA_COMP_STATUS) & 0xffu)) return ERR_EVENT;
    return 0;
}

static void record_poll_event(unsigned slot) {
    result->completed[slot] = shared_dma_read(DMA_BASE, SHDMA_COMP_JOB_ID);
    result->status[slot] = shared_dma_read(DMA_BASE, SHDMA_COMP_STATUS);
    shared_dma_write(DMA_BASE, SHDMA_COMP_POP, 1);
    shared_dma_fence();
}

static void job_success(void) {
    result->successful_jobs++;
    scratch[6] = result->successful_jobs;
}

static void fatal_trap(uintptr_t cause, uintptr_t value) __attribute__((noreturn));
static void fatal_trap(uintptr_t cause, uintptr_t value) {
    shared_dma_machine_irq_off();
    scratch[3] = (uint32_t)cause;
    scratch[4] = (uint32_t)value;
    scratch[2] = (ERR_TRAP << 1) | 1u;
    for (;;) __asm__ volatile ("wfi");
}

/* Project CRT saves integer registers and executes mret around this C call. */
void trap_vector(void) {
    uintptr_t cause = shared_dma_mcause();
    uintptr_t value = shared_dma_mtval();
    scratch[3] = (uint32_t)cause;
    scratch[4] = (uint32_t)value;
    if (cause != (((uintptr_t)1 << 63) | 11u)) fatal_trap(cause, value);
    uint32_t claim = mmio_read(PLIC_CLAIM);
    if (claim == 0) return;
    if (claim != 58) {
        mmio_write(PLIC_CLAIM, claim);
        fatal_trap(cause, claim);
    }
    result->irq_count++;
    scratch[5] = result->irq_count;
    /* Frontend has four entries; this bound also catches a broken pop path. */
    for (unsigned drained = 0; drained < 4; ++drained) {
        if (!(shared_dma_read(DMA_BASE, SHDMA_COMP_VALID) & 1u)) break;
        unsigned index = result->irq_events;
        if (index >= 2) fatal_trap(cause, index);
        result->completed[3u + index] = shared_dma_read(DMA_BASE, SHDMA_COMP_JOB_ID);
        result->status[3u + index] = shared_dma_read(DMA_BASE, SHDMA_COMP_STATUS);
        shared_dma_write(DMA_BASE, SHDMA_COMP_POP, 1);
        shared_dma_fence();
        shared_dma_compiler_barrier();
        result->irq_events = index + 1u;
    }
    if (shared_dma_read(DMA_BASE, SHDMA_COMP_VALID) & 1u) fatal_trap(cause, 4);
    shared_dma_fence();
    mmio_write(PLIC_CLAIM, claim);
    shared_dma_fence();
}

static int polling_job(unsigned slot, shared_dma_job_t *job, int snapshot_edit) {
    uint32_t id;
    shared_dma_fence();
    int error = submit_raw(job, &id);
    if (error) return error;
    result->submitted[slot] = id;
    if (id != slot + 1u) return ERR_EVENT;
    if (snapshot_edit) {
        /* Decoy descriptor is never submitted. No accepted job may read it. */
        shared_dma_job_t decoy = {
            TILE_BUFFER(TILE_ID) + 0x3800u, TILE_BUFFER(TILE_ID) + 0x7800u,
            31, 2, 64, 96
        };
        program_job(&decoy);
    }
    error = wait_completion_raw(id);
    if (error) return error;
    record_poll_event(slot);
    return 0;
}

static int cache_job(void) {
    volatile uint8_t *src = (volatile uint8_t *)(TILE_BUFFER(TILE_ID) + 0x2800u);
    volatile uint8_t *dst = (volatile uint8_t *)(TILE_BUFFER(TILE_ID) + 0x6800u);
    shared_dma_job_t job = { (uintptr_t)src, (uintptr_t)dst, CACHE_BYTES, 1, 0, 0 };
    shared_dma_dcache_set(1);
    /* Both source and destination become dirty before handing ownership over. */
    for (unsigned i = 0; i < CACHE_BYTES; ++i) {
        src[i] = cache_byte(TILE_ID, i);
        dst[i] = POISON;
    }
    shared_dma_cva6_wb_handoff(drain_guard);
    uint8_t primed = dst[0];
    shared_dma_compiler_barrier();
    if (primed != POISON) return ERR_BYTES;
    uint32_t id;
    int error = submit_raw(&job, &id);
    if (error) return error;
    error = wait_completion_raw(id);
    if (error) return error;
    /* No fence, AMO, barrier or destination write between prime and this read. */
    if (CACHE_NEGATIVE && TILE_ID == 0) {
        uint8_t stale = dst[0];
        scratch[7] = 0x74000000u | ((uint32_t)primed << 8) | stale;
        return stale == POISON ? ERR_CACHE_NEGATIVE : ERR_CACHE_NEGATIVE_MISSED;
    }
    shared_dma_cva6_wb_handoff(drain_guard);
    if (id != 3) return ERR_EVENT;
    for (unsigned i = 0; i < CACHE_BYTES; ++i)
        if (dst[i] != cache_byte(TILE_ID, i)) return ERR_BYTES;
    result->submitted[2] = id;
    record_poll_event(2);
    result->cache_success = 1;
    scratch[7] = 1;
    job_success();
    shared_dma_cva6_wb_disable(drain_guard);
    return 0;
}

static int irq_jobs(void) {
    shared_dma_machine_irq_off();
    mmio_write(PLIC_PRIORITY, 1);
    mmio_write(PLIC_ENABLE, 1u << 26);
    mmio_write(PLIC_THRESHOLD, 0);
    shared_dma_write(DMA_BASE, SHDMA_IRQ_ENABLE, 1);
    shared_dma_fence();
    if (IRQ_NEGATIVE && TILE_ID == 0) shared_dma_machine_global_irq_on();
    else shared_dma_machine_external_irq_on();
    for (unsigned index = 0; index < 2; ++index) {
        unsigned offset = 0x3000u + index * IRQ_BYTES;
        shared_dma_job_t job = {
            TILE_BUFFER(TILE_ID) + offset, TILE_BUFFER(TILE_ID) + 0x4000u + offset,
            IRQ_BYTES, 1, 0, 0
        };
        uint32_t id;
        int error = submit_raw(&job, &id);
        if (error) return error;
        result->submitted[3u + index] = id;
        if (id != 4u + index) return ERR_EVENT;
        uint64_t start = shared_dma_mcycle();
        while (result->irq_events < index + 1u) {
            if (expired(start, DMA_TIMEOUT_CYCLES)) {
                if (IRQ_NEGATIVE && TILE_ID == 0) {
                    uintptr_t mstatus, mie;
                    __asm__ volatile("csrr %0, mstatus" : "=r"(mstatus));
                    __asm__ volatile("csrr %0, mie" : "=r"(mie));
                    scratch[9] = (uint32_t)mstatus;
                    scratch[10] = (uint32_t)mie;
                    return ERR_IRQ_NEGATIVE;
                }
                return ERR_IRQ;
            }
        }
        shared_dma_compiler_barrier();
        if (result->irq_events != index + 1u ||
            result->completed[3u + index] != id ||
            (result->status[3u + index] & 0xffu) ||
            result->irq_count != index + 1u) return ERR_EVENT;
        volatile const uint8_t *dst = (volatile const uint8_t *)job.dst;
        for (unsigned i = 0; i < IRQ_BYTES; ++i)
            if (dst[i] != initial_byte(TILE_ID, offset + i)) return ERR_BYTES;
        job_success();
        /* Main resumes only after complete(58); the next job must rearm PLIC. */
    }
    shared_dma_machine_irq_off();
    shared_dma_write(DMA_BASE, SHDMA_IRQ_ENABLE, 0);
    shared_dma_fence();
    return 0;
}

static int workload(void) {
    shared_dma_machine_irq_off();
    shared_dma_cva6_wb_disable(drain_guard);
    shared_dma_icache_set(1);
    scratch[0] = TILE_ID;
    scratch[1] = PH_BOOT;
    for (unsigned i = 3; i <= 8; ++i) scratch[i] = 0;
    shared_dma_write(DMA_BASE, SHDMA_IRQ_ENABLE, 0);
    if (TILE_ID == 0) {
        shared_dma_amo_store(READY_ADDR, 0);
        for (unsigned phase = PH_BASELINE; phase <= PH_SYNC; ++phase)
            shared_dma_amo_store(BARRIER_ADDR(phase), 0);
        shared_dma_amo_store(READY_ADDR, READY_MAGIC);
    } else {
        uint64_t start = shared_dma_mcycle();
        while (shared_dma_amo_load(READY_ADDR) != READY_MAGIC)
            if (expired(start, SYNC_TIMEOUT_CYCLES)) return ERR_READY;
    }
    volatile uint8_t *buffer = (volatile uint8_t *)TILE_BUFFER(TILE_ID);
    shared_dma_dcache_set(1);
    for (unsigned i = 0; i < 0x4000u; ++i) {
        buffer[i] = initial_byte(TILE_ID, i);
        buffer[0x4000u + i] = POISON;
    }
    shared_dma_cva6_wb_disable(drain_guard);
    volatile uint32_t *words = (volatile uint32_t *)result;
    for (unsigned i = 0; i < sizeof(result_t) / sizeof(uint32_t); ++i) words[i] = 0;
    result->magic = RESULT_MAGIC;
    result->tile = TILE_ID;

    set_phase(PH_BASELINE);
    int error = barrier(PH_BASELINE);
    if (error) return error;
    shared_dma_job_t baseline = {
        TILE_BUFFER(TILE_ID), TILE_BUFFER(TILE_ID) + 0x4000u,
        BASELINE_BYTES, 1, 0, 0
    };
    error = polling_job(0, &baseline, 0);
    if (error) return error;
    error = check_buffers(TILE_ID, PH_BASELINE);
    if (error) return error;
    job_success();

    set_phase(PH_ND);
    error = barrier(PH_ND);
    if (error) return error;
    shared_dma_job_t nd = {
        TILE_BUFFER(TILE_ID) + 0x2003u, TILE_BUFFER(TILE_ID) + 0x6005u,
        67, 4, 128, 256
    };
    error = polling_job(1, &nd, 1);
    if (error) return error;
    error = check_buffers(TILE_ID, PH_ND);
    if (error) return error;
    job_success();

    set_phase(PH_CACHE);
    error = barrier(PH_CACHE);
    if (error) return error;
    error = cache_job();
    if (error) return error;
    error = check_buffers(TILE_ID, PH_CACHE);
    if (error) return error;

    set_phase(PH_IRQ);
    error = barrier(PH_IRQ);
    if (error) return error;
    error = irq_jobs();
    if (error) return error;
    error = check_buffers(TILE_ID, PH_IRQ);
    if (error) return error;
    result->published_phase = PH_IRQ;

    set_phase(PH_SYNC);
    error = barrier(PH_SYNC);
    if (error) return error;
    for (unsigned tile = 0; tile < NUM_TILES; ++tile) {
        volatile const result_t *peer =
            (volatile const result_t *)(TILE_BUFFER(tile) + 0x8000u);
        if (peer->magic != RESULT_MAGIC || peer->tile != tile ||
            peer->successful_jobs != JOBS || peer->cache_success != 1 ||
            peer->irq_count != 2 || peer->irq_events != 2 ||
            peer->published_phase < PH_IRQ) return ERR_PEER;
        for (unsigned slot = 0; slot < JOBS; ++slot)
            if (peer->submitted[slot] != slot + 1u ||
                peer->completed[slot] != slot + 1u ||
                (peer->status[slot] & 0xffu)) return ERR_PEER;
    }
    result->sync_success = NUM_TILES;
    scratch[8] = NUM_TILES;
    result->published_phase = PH_DONE;
    shared_dma_fence();
    set_phase(PH_DONE);
    return 0;
}

int main(void) {
    int code = workload();
    shared_dma_machine_irq_off();
    /* Preserve the stale cache line and pending DMA/PLIC evidence on negatives.
       CRT writes scratch2 = (return_code << 1) | 1. */
    return code;
}
