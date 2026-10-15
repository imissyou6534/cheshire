// SPDX-License-Identifier: Apache-2.0
/* Build with sw/lib/crt0.S and sw/link/private_spm.ld, rv64gc_zifencei/lp64d.
   Required link flags: -Wl,-Lsw/link -Wl,--no-relax. The legacy CRT loads
   its stack before initializing gp; do not allow relaxation of that load.
   One ELF per TILE_ID, identical physical addresses in each private tile.
   Boot ROM owns all-way SPM initialization. TB loads PT_LOAD segments via AXI,
   then writes scratch0=ELF entry low, scratch1=entry high, scratch2=2.

   Before releasing any tile, TB must zero READY_ADDR (including on reruns).
   Tile 0 initializes DDR counters/error slots and publishes READY_MAGIC.
   No cached C loads/stores are used for this shared synchronization state.

   Scratch ABI (u32 words at 0x03000000):
     0 tile; 1 phase; 3 failure code; 6 success = 0x53504d00 | TILE_ID.
     2 is left to CRT: (main return << 1) | 1, success exactly 1.
     4 trap mtval or handshake address; 5/8 handshake payload low/high;
     7 external-write acknowledgement; 9 injection SC status;
     10 trap mcause; 11 trap mepc; 12 original DDR-owner SC status
     (0xffffffff until attempted); 13 cached SPM test passed (1);
     14 cross-memory LR/SC test passed (1).
     Failure retains the failing phase.
   Phases: 1 boot, 2 AMO, 3 LR/SC, 4 alias, 5 injection armed,
     6 injection complete, 7 optional DMA, 8 final barrier, 9 success,
     10 DDR ownership armed, 11 DDR ownership complete, 14 cached SPM,
     15 cross-memory LR/SC.
     Phases 10/11 run
     after phase 6 (or 4 if injection disabled), before 7/8; final stays 9.
     Phases 15 then 14 run after optional DMA and before the final barrier.

   PRIVATE_SPM_EXTERNAL_WRITE=1 (default) enables a bounded AXI handshake:
     On phase 5 LR.D has completed on 0x1000f100. TB must write the full
     little-endian 64-bit payload scratch[8:5] to scratch4 in this tile's
     private SPM THROUGH THE OTHER ALIAS 0x1400f100, wait for its AXI B
     response, then write scratch7=0x49574f4b. scratch4 publishes this alias.
     Firmware attempts SC.D, requires failure AND exact injected data, then
     retries a fresh LR/SC until success. No other TB writes to this word.
     A failed SC alone is insufficient evidence because spurious failure is
     allowed. Define PRIVATE_SPM_EXTERNAL_WRITE=0 only for a reduced smoke
     test with a TB that does not implement this handshake.

   PRIVATE_SPM_DDR_OWNER=1 (default) checks global reservation ownership:
     Each CPU initializes only its DDR word at 0x84000800 + TILE_ID*0x10000
     to 0x8123456700001800 + TILE_ID*0x101, with local D-cache off.
     It publishes scratch4=address, scratch5/8=desired payload low/high,
     scratch7=0, completes LR.D, then publishes phase 10. TB sends a loader
     exclusive write to this address (AW.lock=1, USER=0, 8-byte single beat,
     all byte strobes) with NO preceding loader LR and data scratch[8:5].
     TB requires B.RESP=OKAY (failed exclusive, not EXOKAY), reads back the
     unchanged initial value, then writes scratch7=0x49574f4b. It must not
     issue an ordinary write to this word. CPU polls MMIO/mcycle only, then
     attempts its ORIGINAL SC.D exactly once and requires success. This
     is a target-specific reservation-preservation check, not a portable
     architectural promise against spurious SC failure. There is no retry
     to hide loss of the original reservation. Scratch12 records SC status.
     After verifying LR data and final payload it publishes phase 11.
     No peer or DMA phase accesses another tile's ownership word. Define
     PRIVATE_SPM_DDR_OWNER=0 only for a reduced test without this handshake.

   PRIVATE_SPM_DMA=1 copies 64 bytes in shared DDR with the existing polled
   driver. Each tile owns 0x84000000 + TILE_ID*0x10000: source +0, dest +0x100.
   This smoke phase does not replace the separate shared DMA workload/IRQ test.

   Phase 14 uses only probe indices 8/9 (0x1000f040/48), initially zero.
   With D-cache enabled it dirties a cached private word before AMOADD.D,
   then dirties the adjacent word before bounded LR/SC. There is no software
   fence/handoff between those stores and atomics: CVA6's WB atomic flush
   must expose the dirty values and invalidate the cached copies. Ordinary
   cached C loads verify the updated values. A final alias AMOADD.D through
   0x1400f040 checks the same behavior after another canonical dirty store.
   The existing WB disable helper drains writes, then cache-off stores restore
   both words to zero. Scratch13 becomes 1 only after successful restoration.

   Phase 15 needs no TB handshake. With cache off it uses probe index 8 and
   only this tile's DDR word at TILE_BUFFER+0x900. For both memory orders,
   LR(A), LR(B), SC(A), SC(B) must fail both SCs without changing either
   word: only the most recent LR is eligible and every SC consumes that
   eligibility, including a failed SC in the other domain. Fresh bounded
   LR/SC then succeeds in each domain. Probe 8 is restored to zero; DDR
   +0x900 ends at SEED64+0x9009. Scratch14 is 1 only after all checks pass.
*/
#include <stdint.h>
#include "shared_dma.h"
#include "shared_dma_cva6_wb.h"

#ifndef TILE_ID
#define TILE_ID 0
#endif
#ifndef NUM_TILES
#define NUM_TILES 4
#endif
#ifndef PRIVATE_SPM_EXTERNAL_WRITE
#define PRIVATE_SPM_EXTERNAL_WRITE 1
#endif
#ifndef PRIVATE_SPM_DMA
#define PRIVATE_SPM_DMA 0
#endif
#ifndef PRIVATE_SPM_DDR_OWNER
#define PRIVATE_SPM_DDR_OWNER 1
#endif
#ifndef PRIVATE_SPM_TIMEOUT_CYCLES
#define PRIVATE_SPM_TIMEOUT_CYCLES 4000000UL
#endif
#ifndef PRIVATE_SPM_LRSC_RETRIES
#define PRIVATE_SPM_LRSC_RETRIES 1024
#endif
#if NUM_TILES < 1 || NUM_TILES > 64 || TILE_ID < 0 || TILE_ID >= NUM_TILES
#error Invalid private SPM tile configuration
#endif
#if PRIVATE_SPM_LRSC_RETRIES < 1 || PRIVATE_SPM_TIMEOUT_CYCLES < 1
#error Private SPM retry and timeout bounds must be positive
#endif
#if (PRIVATE_SPM_EXTERNAL_WRITE != 0 && PRIVATE_SPM_EXTERNAL_WRITE != 1) || \
    (PRIVATE_SPM_DMA != 0 && PRIVATE_SPM_DMA != 1) || \
    (PRIVATE_SPM_DDR_OWNER != 0 && PRIVATE_SPM_DDR_OWNER != 1)
#error Private SPM optional phases must be zero or one
#endif

enum {
    PH_BOOT = 1, PH_AMO = 2, PH_LRSC = 3, PH_ALIAS = 4,
    PH_INJECT_ARMED = 5, PH_INJECT_DONE = 6, PH_DMA = 7,
    PH_BARRIER = 8, PH_DONE = 9, PH_DDR_OWNER_ARMED = 10, PH_DDR_OWNER_DONE = 11,
    PH_CACHED_SPM = 14, PH_CROSS_MEMORY = 15,
    ERR_INIT = 0x11, ERR_AMO32 = 0x12, ERR_AMO64 = 0x13,
    ERR_LRSC32 = 0x14, ERR_LRSC64 = 0x15, ERR_REPLACED = 0x16,
    ERR_ALIAS = 0x17, ERR_INJECT_TIMEOUT = 0x18, ERR_INJECT_SC = 0x19,
    ERR_INJECT_DATA = 0x1a, ERR_INJECT_RETRY = 0x1b,
    ERR_READY = 0x21, ERR_BARRIER = 0x22, ERR_PEER = 0x23,
    ERR_DDR_OWNER_TIMEOUT = 0x24, ERR_DDR_OWNER_SC = 0x25,
    ERR_DDR_OWNER_DATA = 0x26,
    ERR_DMA_SUBMIT = 0x31, ERR_DMA_EVENT = 0x32, ERR_DMA_DATA = 0x33,
    ERR_STACK = 0x41, ERR_CACHE_INIT = 0x50, ERR_CACHE_AMO = 0x51,
    ERR_CACHE_LRSC = 0x52, ERR_CACHE_ALIAS = 0x53, ERR_CACHE_RESTORE = 0x54,
    ERR_CROSS_SPM_SC = 0x61, ERR_CROSS_DDR_AFTER_SC = 0x62,
    ERR_CROSS_DDR_SC = 0x63, ERR_CROSS_SPM_AFTER_SC = 0x64,
    ERR_CROSS_SPM_FRESH = 0x65, ERR_CROSS_DDR_FRESH = 0x66,
    ERR_CROSS_DATA = 0x67,
    ERR_TRAP = 0x70,
    READY_MAGIC = 0x53504d52, SUCCESS_MAGIC = 0x53504d00,
    INJECT_ACK = 0x49574f4b,
    P_AMO32 = 0, P_AMO64 = 1, P_LR32 = 2, P_LR64 = 3,
    P_REPLACE_A = 4, P_UPPER_AMO32 = 5, P_UPPER_LR32 = 6,
    P_CACHE_AMO = 8, P_CACHE_LRSC = 9,
    P_REPLACE_B = 16, P_INJECT = 32, P_ID = 33
};

#define READY_ADDR ((uintptr_t)0x88010000UL)
#define BARRIER_ADDR(index) ((uintptr_t)0x88010010UL + 4UL * (index))
#define ERROR_ADDR(tile) ((uintptr_t)0x88010100UL + 4UL * (tile))
#define TILE_BUFFER ((uintptr_t)0x84000000UL + (uintptr_t)TILE_ID * 0x10000UL)
#define SEED32 (UINT32_C(0x81230000) + (uint32_t)TILE_ID * 0x101u)
#define SEED64 (UINT64_C(0x8123456700001000) + (uint64_t)TILE_ID * 0x101u)
#define WORD_GUARD UINT64_C(0xcafebabe00000000)
#define LOW_GUARD UINT32_C(0xdecafbad)
#define UPPER_WORD(value) (((uint64_t)(uint32_t)(value) << 32) | LOW_GUARD)
#define INJECT_DATA (UINT64_C(0xee11223344550000) + (uint64_t)TILE_ID)
#define DDR_OWNER_ADDR (TILE_BUFFER + 0x800UL)
#define DDR_OWNER_INITIAL (SEED64 + 0x800)
#define DDR_OWNER_DATA (UINT64_C(0xddeeff0011220000) + (uint64_t)TILE_ID)

/* ELF initialization must differ per tile; do not overwrite before checking.
   .w probes occupy the low word, with an adjacent high-word guard. */
volatile uint64_t private_spm_probe[34]
    __attribute__((section(".private_spm_probe"), aligned(128), used)) = {
    [P_AMO32] = WORD_GUARD | SEED32,
    [P_AMO64] = SEED64,
    [P_LR32] = WORD_GUARD | SEED32,
    [P_LR64] = SEED64,
    [P_REPLACE_A] = SEED64 + 0x20,
    [P_UPPER_AMO32] = UPPER_WORD(SEED32),
    [P_UPPER_LR32] = UPPER_WORD(SEED32),
    [P_REPLACE_B] = SEED64 + 0x80,
    [P_INJECT] = SEED64 + 0x100,
    [P_ID] = UINT64_C(0x53504d4900000000) | TILE_ID
};

static volatile uint32_t *const scratch = (volatile uint32_t *)0x03000000UL;
static const uint64_t drain_guard[2] __attribute__((aligned(16), used)) = {
    UINT64_C(0x53504d4755415244), UINT64_C(0x123456789abcdef0)
};

static uint64_t sign_extend_word(uint32_t value) {
    return (uint64_t)(int64_t)(int32_t)value;
}

static uint64_t amo_add32(uintptr_t address, uint32_t value) {
    uint64_t old;
    __asm__ volatile ("amoadd.w.aqrl %0, %1, (%2)"
                      : "=r" (old) : "r" ((uintptr_t)value), "r" (address)
                      : "memory");
    return old;
}

static uint64_t amo_swap32(uintptr_t address, uint32_t value) {
    uint64_t old;
    __asm__ volatile ("amoswap.w.aqrl %0, %1, (%2)"
                      : "=r" (old) : "r" ((uintptr_t)value), "r" (address)
                      : "memory");
    return old;
}

static uint64_t amo_add64(uintptr_t address, uint64_t value) {
    uint64_t old;
    __asm__ volatile ("amoadd.d.aqrl %0, %1, (%2)"
                      : "=r" (old) : "r" (value), "r" (address) : "memory");
    return old;
}

static uint64_t amo_swap64(uintptr_t address, uint64_t value) {
    uint64_t old;
    __asm__ volatile ("amoswap.d.aqrl %0, %1, (%2)"
                      : "=r" (old) : "r" (value), "r" (address) : "memory");
    return old;
}

/* Keep each successful LR/SC attempt contiguous and free of intervening
   memory accesses. The bound is target-test liveness, not a portable promise
   that any individual SC (or unconstrained LR/SC sequence) must succeed. */
#define DEFINE_LRSC(name, width) \
static int name(uintptr_t address, uint64_t desired, uint64_t *old) { \
    uintptr_t status, tries = PRIVATE_SPM_LRSC_RETRIES; \
    uint64_t value; \
    __asm__ volatile ( \
        "1: lr." width ".aq %0, (%3)\n\t" \
        "sc." width ".rl %1, %4, (%3)\n\t" \
        "beqz %1, 2f\n\t" \
        "addi %2, %2, -1\n\t" \
        "bnez %2, 1b\n\t2:" \
        : "=&r" (value), "=&r" (status), "+&r" (tries) \
        : "r" (address), "r" (desired) : "memory"); \
    *old = value; \
    return status != 0; \
}
DEFINE_LRSC(lrsc32, "w")
DEFINE_LRSC(lrsc64, "d")

static int expired(uint64_t start) {
    return shared_dma_mcycle() - start >= PRIVATE_SPM_TIMEOUT_CYCLES;
}

static int barrier(unsigned index) {
    uintptr_t address = BARRIER_ADDR(index);
    shared_dma_fence();
    if (shared_dma_amo_add(address, 1) >= NUM_TILES) return ERR_BARRIER;
    uint64_t start = shared_dma_mcycle();
    for (;;) {
        uint32_t count = shared_dma_amo_load(address);
        if (count == NUM_TILES) {
            shared_dma_fence();
            return 0;
        }
        for (unsigned tile = 0; tile < NUM_TILES; ++tile)
            if (shared_dma_amo_load(ERROR_ADDR(tile))) return ERR_PEER;
        if (count > NUM_TILES || expired(start)) return ERR_BARRIER;
    }
}

static int initialize_barriers(void) {
    if (TILE_ID == 0) {
        shared_dma_amo_store(READY_ADDR, 0);
        for (unsigned i = 0; i < 2; ++i)
            shared_dma_amo_store(BARRIER_ADDR(i), 0);
        for (unsigned tile = 0; tile < NUM_TILES; ++tile)
            shared_dma_amo_store(ERROR_ADDR(tile), 0);
        shared_dma_amo_store(READY_ADDR, READY_MAGIC);
    } else {
        uint64_t start = shared_dma_mcycle();
        while (shared_dma_amo_load(READY_ADDR) != READY_MAGIC)
            if (expired(start)) return ERR_READY;
    }
    return barrier(0);
}

static int test_atomics(void) {
    uintptr_t w = (uintptr_t)&private_spm_probe[P_AMO32];
    uintptr_t d = (uintptr_t)&private_spm_probe[P_AMO64];
    uint32_t swap32 = UINT32_C(0xfedc0000) | TILE_ID;
    uint64_t swap64 = UINT64_C(0xfedcba9800000000) | TILE_ID;
    scratch[1] = PH_AMO;
    if (amo_add32(w, 7) != sign_extend_word(SEED32) ||
        private_spm_probe[P_AMO32] != (WORD_GUARD | (SEED32 + 7u)))
        return ERR_AMO32;
    /* A full-width unsigned add wraps only the selected 32-bit word. */
    if (amo_add32(w, UINT32_MAX) != sign_extend_word(SEED32 + 7u) ||
        private_spm_probe[P_AMO32] != (WORD_GUARD | (SEED32 + 6u)))
        return ERR_AMO32;
    if (amo_swap32(w, swap32) != sign_extend_word(SEED32 + 6u) ||
        private_spm_probe[P_AMO32] != (WORD_GUARD | swap32)) return ERR_AMO32;
    uintptr_t upper = (uintptr_t)&private_spm_probe[P_UPPER_AMO32] + 4;
    if (amo_add32(upper, 7) != sign_extend_word(SEED32) ||
        private_spm_probe[P_UPPER_AMO32] != UPPER_WORD(SEED32 + 7u) ||
        amo_swap32(upper, swap32) != sign_extend_word(SEED32 + 7u) ||
        private_spm_probe[P_UPPER_AMO32] != UPPER_WORD(swap32)) return ERR_AMO32;
    if (amo_add64(d, UINT64_C(0x100000007)) != SEED64 ||
        private_spm_probe[P_AMO64] != SEED64 + UINT64_C(0x100000007))
        return ERR_AMO64;
    if (amo_swap64(d, swap64) != SEED64 + UINT64_C(0x100000007) ||
        private_spm_probe[P_AMO64] != swap64) return ERR_AMO64;
    return 0;
}

static int test_lrsc(void) {
    uint64_t old;
    scratch[1] = PH_LRSC;
    if (lrsc32((uintptr_t)&private_spm_probe[P_LR32], SEED32 + 9u, &old) ||
        old != sign_extend_word(SEED32) ||
        private_spm_probe[P_LR32] != (WORD_GUARD | (SEED32 + 9u)))
        return ERR_LRSC32;
    if (lrsc32((uintptr_t)&private_spm_probe[P_UPPER_LR32] + 4,
               SEED32 + 9u, &old) || old != sign_extend_word(SEED32) ||
        private_spm_probe[P_UPPER_LR32] != UPPER_WORD(SEED32 + 9u))
        return ERR_LRSC32;
    if (lrsc64((uintptr_t)&private_spm_probe[P_LR64], SEED64 + 9, &old) ||
        old != SEED64 || private_spm_probe[P_LR64] != SEED64 + 9)
        return ERR_LRSC64;

    /* axi_res_tbl has one address per initiator; a second LR replaces it.
       The two addresses are in different 128-byte blocks. A failed SC is
       checked for both status and absence of a write. */
    uintptr_t a = (uintptr_t)&private_spm_probe[P_REPLACE_A];
    uintptr_t b = (uintptr_t)&private_spm_probe[P_REPLACE_B];
    uint64_t first, second;
    uintptr_t status;
    __asm__ volatile (
        "lr.d.aq %0, (%3)\n\t"
        "lr.d.aq %1, (%4)\n\t"
        "sc.d.rl %2, %5, (%3)"
        : "=&r" (first), "=&r" (second), "=&r" (status)
        : "r" (a), "r" (b), "r" (SEED64 + 0x99) : "memory");
    if (!status || first != SEED64 + 0x20 || second != SEED64 + 0x80 ||
        private_spm_probe[P_REPLACE_A] != SEED64 + 0x20 ||
        private_spm_probe[P_REPLACE_B] != SEED64 + 0x80) return ERR_REPLACED;
    /* Fresh LR is needed after SC; do not assume B's reservation survives. */
    if (lrsc64(b, SEED64 + 0x89, &old) || old != SEED64 + 0x80 ||
        private_spm_probe[P_REPLACE_B] != SEED64 + 0x89) return ERR_REPLACED;
    return 0;
}

static int test_alias(void) {
    scratch[1] = PH_ALIAS;
    volatile uint64_t *alias = (volatile uint64_t *)0x1400f000UL;
    uint64_t before = private_spm_probe[P_AMO64];
    if (alias[P_AMO64] != before) return ERR_ALIAS;
    alias[P_AMO64] = SEED64 + 0x400;
    shared_dma_fence();
    if (private_spm_probe[P_AMO64] != SEED64 + 0x400) return ERR_ALIAS;
    if (amo_add64((uintptr_t)&alias[P_AMO64], 3) != SEED64 + 0x400 ||
        private_spm_probe[P_AMO64] != SEED64 + 0x403) return ERR_ALIAS;
    if (amo_swap64((uintptr_t)&private_spm_probe[P_AMO64], before) !=
        SEED64 + 0x403 || alias[P_AMO64] != before) return ERR_ALIAS;
    uint32_t word = (uint32_t)private_spm_probe[P_AMO32];
    if (amo_add32((uintptr_t)&alias[P_AMO32], 1) != sign_extend_word(word) ||
        private_spm_probe[P_AMO32] != (WORD_GUARD | (word + 1u)))
        return ERR_ALIAS;
    if (amo_swap32((uintptr_t)&private_spm_probe[P_AMO32], word) !=
        sign_extend_word(word + 1u) || alias[P_AMO32] != (WORD_GUARD | word))
        return ERR_ALIAS;
    return 0;
}

#if PRIVATE_SPM_EXTERNAL_WRITE
static int test_external_write(void) {
    uintptr_t address = (uintptr_t)&private_spm_probe[P_INJECT];
    scratch[4] = (uint32_t)(address + 0x04000000UL);
    scratch[5] = (uint32_t)INJECT_DATA;
    scratch[8] = (uint32_t)(INJECT_DATA >> 32);
    scratch[7] = 0;
    shared_dma_fence();
    uint64_t old;
    __asm__ volatile ("lr.d.aq %0, (%1)" : "=r" (old) : "r" (address)
                      : "memory");
    scratch[1] = PH_INJECT_ARMED;
    uint64_t start = shared_dma_mcycle();
    while (scratch[7] != INJECT_ACK)
        if (expired(start)) return ERR_INJECT_TIMEOUT;
    uintptr_t status;
    __asm__ volatile ("sc.d.rl %0, %1, (%2)" : "=&r" (status)
                      : "r" (SEED64 + 0x199), "r" (address) : "memory");
    scratch[9] = (uint32_t)status;
    if (old != SEED64 + 0x100 || !status) return ERR_INJECT_SC;
    if (private_spm_probe[P_INJECT] != INJECT_DATA) return ERR_INJECT_DATA;
    if (lrsc64(address, INJECT_DATA + 1, &old) || old != INJECT_DATA ||
        private_spm_probe[P_INJECT] != INJECT_DATA + 1) return ERR_INJECT_RETRY;
    scratch[1] = PH_INJECT_DONE;
    return 0;
}
#endif

#if PRIVATE_SPM_DDR_OWNER
static int test_ddr_owner(void) {
    volatile uint64_t *word = (volatile uint64_t *)DDR_OWNER_ADDR;
    /* workload() disabled local D-cache before any shared-DDR access. This
       word is outside DMA ranges, barriers, and every other tile's slice. */
    *word = DDR_OWNER_INITIAL;
    scratch[4] = (uint32_t)DDR_OWNER_ADDR;
    scratch[5] = (uint32_t)DDR_OWNER_DATA;
    scratch[8] = (uint32_t)(DDR_OWNER_DATA >> 32);
    scratch[7] = 0;
    shared_dma_fence();
    uint64_t old;
    __asm__ volatile ("lr.d.aq %0, (%1)" : "=r" (old)
                      : "r" (DDR_OWNER_ADDR) : "memory");
    scratch[1] = PH_DDR_OWNER_ARMED;
    uint64_t start = shared_dma_mcycle();
    while (scratch[7] != INJECT_ACK)
        if (expired(start)) return ERR_DDR_OWNER_TIMEOUT;
    uintptr_t status;
    __asm__ volatile ("sc.d.rl %0, %1, (%2)" : "=&r" (status)
                      : "r" (DDR_OWNER_DATA), "r" (DDR_OWNER_ADDR) : "memory");
    scratch[12] = (uint32_t)status;
    if (status) return ERR_DDR_OWNER_SC;
    if (old != DDR_OWNER_INITIAL || *word != DDR_OWNER_DATA)
        return ERR_DDR_OWNER_DATA;
    scratch[1] = PH_DDR_OWNER_DONE;
    return 0;
}
#endif

#if PRIVATE_SPM_DMA
static int test_dma(void) {
    const uintptr_t base = 0x01000000UL;
    volatile uint8_t *src = (volatile uint8_t *)TILE_BUFFER;
    volatile uint8_t *dst = (volatile uint8_t *)(TILE_BUFFER + 0x100);
    scratch[1] = PH_DMA;
    shared_dma_write(base, SHDMA_IRQ_ENABLE, 0);
    for (unsigned i = 0; i < 64; ++i) {
        src[i] = (uint8_t)(0x31u + TILE_ID * 37u + i * 13u);
        dst[i] = 0xa5;
    }
    shared_dma_fence();
    shared_dma_job_t job = {TILE_BUFFER, TILE_BUFFER + 0x100, 64, 1, 0, 0};
    uint32_t id;
    uint64_t start = shared_dma_mcycle();
    int status;
    do {
        status = shared_dma_try_submit(base, &job, UINT64_C(0x84000000),
                                       UINT64_C(0x85000000), 32, &id);
        if (status == -2 || expired(start)) return ERR_DMA_SUBMIT;
    } while (status == -1);
    shared_dma_completion_t event;
    start = shared_dma_mcycle();
    while (!shared_dma_poll(base, &event))
        if (expired(start)) return ERR_DMA_EVENT;
    if (event.job_id != id || event.error_code) return ERR_DMA_EVENT;
    for (unsigned i = 0; i < 64; ++i) {
        uint8_t expected = (uint8_t)(0x31u + TILE_ID * 37u + i * 13u);
        if (src[i] != expected || dst[i] != expected) return ERR_DMA_DATA;
    }
    return 0;
}
#endif

static int test_cross_memory_lrsc(void) {
    volatile uint64_t *spm = &private_spm_probe[P_CACHE_AMO];
    volatile uint64_t *ddr = (volatile uint64_t *)(TILE_BUFFER + 0x900UL);
    const uint64_t spm_initial = SEED64 + 0x6000;
    const uint64_t ddr_initial = SEED64 + 0x9000;
    uint64_t first, second, old;
    uintptr_t first_status, second_status;
    int error = 0;
    scratch[1] = PH_CROSS_MEMORY;
    /* All earlier phases leave D-cache off. This DDR word is not shared
       with peers, DMA ranges, ownership handshakes, or barrier metadata. */
    *spm = spm_initial;
    *ddr = ddr_initial;
    shared_dma_fence();
    __asm__ volatile (
        "lr.d.aq %0, (%4)\n\t"
        "lr.d.aq %1, (%5)\n\t"
        "sc.d.rl %2, %6, (%4)\n\t"
        "sc.d.rl %3, %7, (%5)"
        : "=&r" (first), "=&r" (second), "=&r" (first_status),
          "=&r" (second_status)
        : "r" ((uintptr_t)spm), "r" ((uintptr_t)ddr),
          "r" (spm_initial + 1), "r" (ddr_initial + 1) : "memory");
    if (!first_status) error = ERR_CROSS_SPM_SC;
    else if (!second_status) error = ERR_CROSS_DDR_AFTER_SC;
    else if (first != spm_initial || second != ddr_initial ||
             *spm != spm_initial || *ddr != ddr_initial) error = ERR_CROSS_DATA;
    if (!error) {
        __asm__ volatile (
            "lr.d.aq %0, (%4)\n\t"
            "lr.d.aq %1, (%5)\n\t"
            "sc.d.rl %2, %6, (%4)\n\t"
            "sc.d.rl %3, %7, (%5)"
            : "=&r" (first), "=&r" (second), "=&r" (first_status),
              "=&r" (second_status)
            : "r" ((uintptr_t)ddr), "r" ((uintptr_t)spm),
              "r" (ddr_initial + 2), "r" (spm_initial + 2) : "memory");
        if (!first_status) error = ERR_CROSS_DDR_SC;
        else if (!second_status) error = ERR_CROSS_SPM_AFTER_SC;
        else if (first != ddr_initial || second != spm_initial ||
                 *spm != spm_initial || *ddr != ddr_initial)
            error = ERR_CROSS_DATA;
    }
    if (!error && (lrsc64((uintptr_t)spm, spm_initial + 7, &old) ||
                   old != spm_initial || *spm != spm_initial + 7))
        error = ERR_CROSS_SPM_FRESH;
    if (!error && (lrsc64((uintptr_t)ddr, ddr_initial + 9, &old) ||
                   old != ddr_initial || *ddr != ddr_initial + 9))
        error = ERR_CROSS_DDR_FRESH;
    *spm = 0;
    shared_dma_fence();
    if (!error && *spm) error = ERR_CROSS_DATA;
    if (!error) scratch[14] = 1;
    return error;
}

static int test_cached_spm(void) {
    const uintptr_t address = (uintptr_t)&private_spm_probe[P_CACHE_AMO];
    const uint64_t dirty = SEED64 + 0x2000, lr_dirty = SEED64 + 0x4000;
    uint64_t old;
    int error = 0;
    scratch[1] = PH_CACHED_SPM;
    shared_dma_dcache_set(1);
    /* These reads prime the shared 16-byte line before either dirty store. */
    if (private_spm_probe[P_CACHE_AMO] || private_spm_probe[P_CACHE_LRSC])
        error = ERR_CACHE_INIT;
    if (!error) {
        private_spm_probe[P_CACHE_AMO] = dirty;
        if (amo_add64(address, 7) != dirty ||
            private_spm_probe[P_CACHE_AMO] != dirty + 7)
            error = ERR_CACHE_AMO;
    }
    if (!error) {
        private_spm_probe[P_CACHE_LRSC] = lr_dirty;
        if (lrsc64((uintptr_t)&private_spm_probe[P_CACHE_LRSC], lr_dirty + 9,
                   &old) || old != lr_dirty ||
            private_spm_probe[P_CACHE_LRSC] != lr_dirty + 9 ||
            private_spm_probe[P_CACHE_AMO] != dirty + 7)
            error = ERR_CACHE_LRSC;
    }
    if (!error) {
        private_spm_probe[P_CACHE_AMO] = dirty + 0x20;
        if (amo_add64(address + 0x04000000UL, 3) != dirty + 0x20 ||
            private_spm_probe[P_CACHE_AMO] != dirty + 0x23 ||
            private_spm_probe[P_CACHE_LRSC] != lr_dirty + 9)
            error = ERR_CACHE_ALIAS;
    }
    /* Always restore cache-off execution and the established probe golden. */
    shared_dma_cva6_wb_disable(drain_guard);
    private_spm_probe[P_CACHE_AMO] = 0;
    private_spm_probe[P_CACHE_LRSC] = 0;
    shared_dma_fence();
    if (!error && (private_spm_probe[P_CACHE_AMO] ||
                   private_spm_probe[P_CACHE_LRSC])) error = ERR_CACHE_RESTORE;
    if (!error) scratch[13] = 1;
    return error;
}

static int workload(void) {
    uintptr_t sp;
    __asm__ volatile ("mv %0, sp" : "=r" (sp));
    if ((sp & 15u) || sp < 0x10010000UL || sp >= 0x10018000UL) return ERR_STACK;
    shared_dma_cva6_wb_disable(drain_guard);
    shared_dma_icache_set(0);
    if (private_spm_probe[P_ID] != (UINT64_C(0x53504d4900000000) | TILE_ID) ||
        private_spm_probe[P_AMO32] != (WORD_GUARD | SEED32) ||
        private_spm_probe[P_AMO64] != SEED64 ||
        private_spm_probe[P_LR32] != (WORD_GUARD | SEED32) ||
        private_spm_probe[P_UPPER_AMO32] != UPPER_WORD(SEED32) ||
        private_spm_probe[P_UPPER_LR32] != UPPER_WORD(SEED32) ||
        private_spm_probe[P_LR64] != SEED64 ||
        private_spm_probe[P_INJECT] != SEED64 + 0x100) return ERR_INIT;
    int error = initialize_barriers();
    if (error) return error;
    error = test_atomics();
    if (error) return error;
    error = test_lrsc();
    if (error) return error;
    error = test_alias();
    if (error) return error;
#if PRIVATE_SPM_EXTERNAL_WRITE
    error = test_external_write();
    if (error) return error;
#endif
#if PRIVATE_SPM_DDR_OWNER
    error = test_ddr_owner();
    if (error) return error;
#endif
#if PRIVATE_SPM_DMA
    error = test_dma();
    if (error) return error;
#endif
    error = test_cross_memory_lrsc();
    if (error) return error;
    error = test_cached_spm();
    if (error) return error;
    scratch[1] = PH_BARRIER;
    return barrier(1);
}

/* The existing CRT wraps this C trap handler. Unexpected traps cannot safely
   return to a faulting instruction, so publish failure EOC and park. */
void trap_vector(void) {
    uintptr_t pc;
    __asm__ volatile ("csrr %0, mepc" : "=r" (pc));
    shared_dma_machine_irq_off();
    scratch[3] = ERR_TRAP;
    scratch[4] = (uint32_t)shared_dma_mtval();
    scratch[10] = (uint32_t)shared_dma_mcause();
    scratch[11] = (uint32_t)pc;
    scratch[6] = 0;
    shared_dma_fence();
    scratch[2] = (ERR_TRAP << 1) | 1u;
    for (;;) __asm__ volatile ("wfi");
}

int main(void) {
    shared_dma_machine_irq_off();
    scratch[0] = TILE_ID;
    scratch[1] = PH_BOOT;
    scratch[3] = 0;
    scratch[6] = 0;
    scratch[7] = 0;
    scratch[9] = 0;
    scratch[10] = 0;
    scratch[11] = 0;
    scratch[12] = UINT32_MAX;
    scratch[13] = 0;
    scratch[14] = 0;
    int error = workload();
    scratch[3] = (uint32_t)error;
    if (error) {
        /* Peers use AMO reads to notice a failure while at the barrier. */
        shared_dma_amo_store(ERROR_ADDR(TILE_ID), (uint32_t)error);
    } else {
        scratch[1] = PH_DONE;
        scratch[6] = SUCCESS_MAGIC | TILE_ID;
    }
    shared_dma_fence();
    return error;
}
