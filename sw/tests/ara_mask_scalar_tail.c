// SPDX-License-Identifier: Apache-2.0
#include <stddef.h>
#include <stdint.h>
#include "regs/cheshire.h"
#include "dif/clint.h"
#include "dif/uart.h"
#include "params.h"
#include "util.h"
#include "printf.h"
#include "shared_dma_cva6_wb.h"

#pragma GCC optimize ("no-tree-vectorize", "no-tree-slp-vectorize", "Os")

enum { MAX_CASES = 2048, WORDS = 8 };
struct record {
    uint32_t magic, cases, failures, reserved;
    struct { uint32_t population; int32_t first; } result[MAX_CASES];
};
volatile struct record mask_scalar_report __attribute__((aligned(64)));
static volatile uint64_t source[WORDS] __attribute__((aligned(64)));
static volatile uint64_t predicate[WORDS] __attribute__((aligned(64)));
static const volatile uint64_t cache_guard = UINT64_C(0x123456789abcdef0);
extern const uint32_t ara_selftest_baud __attribute__((weak));

static unsigned population(uint64_t x) {
    x -= (x >> 1) & UINT64_C(0x5555555555555555);
    x = (x & UINT64_C(0x3333333333333333)) + ((x >> 2) & UINT64_C(0x3333333333333333));
    x = (x + (x >> 4)) & UINT64_C(0x0f0f0f0f0f0f0f0f);
    return (x * UINT64_C(0x0101010101010101)) >> 56;
}

static void operands(unsigned pattern, unsigned count, unsigned mode) {
    for (unsigned w = 0; w < WORDS; ++w) {
        uint64_t x = 0;
        if (pattern == 1) x = UINT64_MAX;
        if (pattern == 2) x = UINT64_C(0x5555555555555555);
        if (pattern == 3 && w == 0) x = 1;
        if (pattern == 4 && count < WORDS*64 && w == count/64) x = UINT64_C(1) << (count%64);
        if (pattern == 5) {
            if (w*64 >= count) x = UINT64_MAX;
            else if ((w+1)*64 > count) x = UINT64_MAX << (count%64);
            if (w == 0) x |= 5;
        }
        if (pattern == 6 && count && w == (count-1)/64) x = UINT64_C(1) << ((count-1)%64);
        source[w] = x;
        predicate[w] = mode == 2 ? 0 : mode == 3 ? UINT64_C(0xaaaaaaaaaaaaaaaa) : UINT64_MAX;
    }
}

#define EXECUTE(bits, lmul, suffix) \
    __asm__ volatile ("vsetvli t0,zero,e8,m2,tu,mu\n\t" \
                      "vlm.v v8,(%[source])\n\tvlm.v v0,(%[predicate])\n\t" \
                      "mv t1,%[count]\n\tvsetvli %[actual],t1,e" #bits "," #lmul ",tu,mu\n\t" \
                      "vcpop.m %[pop],v8" suffix "\n\tvfirst.m %[first],v8" suffix \
                      : [pop] "=&r"(got_pop), [first] "=&r"(got_first), [actual] "=&r"(actual) \
                      : [source] "r"(source), [predicate] "r"(predicate), [count] "r"((uintptr_t)count) \
                      : "t0", "t1", "v0", "v8", "memory")

static int one(unsigned profile, unsigned pattern, unsigned count, unsigned mode) {
    operands(pattern, count, mode);
    uintptr_t got_pop, got_first, actual;
    if (mode) switch (profile) {
    case 0: EXECUTE(8, m2, ",v0.t"); break;
    case 1: EXECUTE(16, m1, ",v0.t"); break;
    case 2: EXECUTE(32, m1, ",v0.t"); break;
    default: EXECUTE(64, m1, ",v0.t"); break;
    } else switch (profile) {
    case 0: EXECUTE(8, m2, ""); break;
    case 1: EXECUTE(16, m1, ""); break;
    case 2: EXECUTE(32, m1, ""); break;
    default: EXECUTE(64, m1, ""); break;
    }
    uint32_t expected_pop = 0;
    int32_t expected_first = -1;
    for (unsigned w = 0; w < WORDS && w*64 < count; ++w) {
        uint64_t x = source[w] & (mode ? predicate[w] : UINT64_MAX);
        if (count-w*64 < 64) x &= (UINT64_C(1) << (count-w*64))-1;
        expected_pop += population(x);
        if (expected_first < 0 && x) {
            unsigned bit = 0;
            while (!(x & 1)) { x >>= 1; ++bit; }
            expected_first = (int32_t)(w*64+bit);
        }
    }
    unsigned index = mask_scalar_report.cases;
    if (index >= MAX_CASES) return 1;
    mask_scalar_report.result[index].population = (uint32_t)got_pop;
    mask_scalar_report.result[index].first = (int32_t)got_first;
    mask_scalar_report.cases = index+1;
    int ok = actual == count && got_pop == expected_pop && (intptr_t)got_first == expected_first;
    if (!ok && mask_scalar_report.failures < 8)
        printf("[MASK] FAIL sew=%u vl=%u pattern=%u mode=%u pop=%u/%u first=%d/%d actual_vl=%u\r\n",
               8u << profile, count, pattern, mode, (unsigned)got_pop, expected_pop,
               (int)got_first, expected_first, (unsigned)actual);
    mask_scalar_report.failures += !ok;
    return 0;
}

int main(void) {
    uint32_t rtc = *reg32(&__base_regs, CHESHIRE_RTC_FREQ_REG_OFFSET);
    uart_init(&__base_uart, clint_get_core_freq(rtc, 2500),
              &ara_selftest_baud ? ara_selftest_baud : __BOOT_BAUDRATE);
    *reg8(&__base_uart, UART_MODEM_CONTROL_REG_OFFSET) = 0;
    shared_dma_cva6_wb_disable(&cache_guard);
    __asm__ volatile ("csrs mstatus,%0" :: "r"((uintptr_t)0x600) : "memory");
    printf("[MASK] scalar tail regression\r\n");
    uart_write_flush(&__base_uart);
    static const unsigned lengths[] = {0,1,4,7,8,15,16,17,31,32,33,63,64,65,127,128,129,255,256,257,511,512};
    static const unsigned limits[] = {512,128,64,32};
    mask_scalar_report.magic = 0x4d534b31;
    for (unsigned profile = 0; profile < 4; ++profile)
        for (unsigned length = 0; length < sizeof(lengths)/sizeof(lengths[0]); ++length)
            if (lengths[length] <= limits[profile])
                for (unsigned pattern = 0; pattern < 7; ++pattern)
                    for (unsigned mode = 0; mode < 4; ++mode)
                        if (one(profile, pattern, lengths[length], mode)) return 2;
    __asm__ volatile ("fence iorw,iorw" ::: "memory");
    printf("[MASK] cases=%u checks=%u failed=%u\r\n", mask_scalar_report.cases,
           mask_scalar_report.cases*2, mask_scalar_report.failures);
    uart_write_flush(&__base_uart);
    return mask_scalar_report.failures ? 1 : 0;
}
