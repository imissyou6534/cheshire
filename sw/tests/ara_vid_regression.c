// SPDX-License-Identifier: Apache-2.0
#include <stddef.h>
#include <stdint.h>
#include "shared_dma.h"
#include "shared_dma_cva6_wb.h"

static const volatile uint64_t guard = UINT64_C(0x123456789abcdef0);
volatile uint64_t vid_test_stage;
volatile uint64_t vid_test_cases;

static __attribute__((optimize("no-tree-vectorize"))) int repeated_vid(void) {
    static volatile uint64_t output[32] __attribute__((aligned(64)));
    for (unsigned iteration = 0; iteration < 16; iteration++) {
        __asm__ volatile("vsetvli t0,%0,e64,m1,tu,mu\n"
                         "vid.v v8\n"
                         "vadd.vi v10,v8,3\n"
                         "vse64.v v10,(%1)"
                         :: "r"((size_t)32), "r"(output)
                         : "t0", "v8", "v10", "memory");
        __asm__ volatile("fence iorw,iorw" ::: "memory");
        for (unsigned i = 0; i < 32; i++)
            if (output[i] != i + 3) return 1;
        vid_test_cases++;
    }
    return 0;
}

#define MASKED_VID(bits, lmul, policy) \
    __asm__ volatile("vsetvli t0,%[maximum],e" #bits "," #lmul ",tu,mu\n" \
                     "vle" #bits ".v v8,(%[input])\n" \
                     "mv t1,%[count]\n" \
                     "vsetvli t0,t1,e" #bits "," #lmul "," policy "\n" \
                     "vlm.v v0,(%[mask])\n" \
                     "vid.v v8,v0.t\n" \
                     "vsetvli t0,%[maximum],e" #bits "," #lmul ",tu,mu\n" \
                     "vse" #bits ".v v8,(%[output])" \
                     :: [maximum] "r"(maximum), [count] "r"(count), \
                        [input] "r"(input), [output] "r"(output), [mask] "r"(mask) \
                     : "t0", "t1", "v0", "v8", "v9", "memory")

#define WIDTH_CASE(bits, type, lmul) \
static __attribute__((optimize("no-tree-vectorize"))) int masked_##bits##_##lmul(void) { \
    static volatile type input[256] __attribute__((aligned(64))); \
    static volatile type output[256] __attribute__((aligned(64))); \
    static volatile uint8_t mask[32] __attribute__((aligned(64))); \
    static const uint8_t patterns[] = {0, 0xff, 0xaa, 0x81}; \
    size_t maximum; \
    __asm__ volatile("vsetvli %0,zero,e" #bits "," #lmul ",tu,mu" : "=r"(maximum)); \
    if (maximum < 4 || maximum > 256) return 1; \
    const size_t counts[] = {0, 1, 3, maximum - 1, maximum}; \
    for (unsigned i = 0; i < maximum; i++) input[i] = (type)0x35; \
    for (unsigned policy = 0; policy < 2; policy++) \
        for (unsigned pattern = 0; pattern < sizeof(patterns); pattern++) { \
            for (unsigned i = 0; i < sizeof(mask); i++) mask[i] = patterns[pattern]; \
            for (unsigned length = 0; length < sizeof(counts) / sizeof(counts[0]); length++) { \
                size_t count = counts[length]; \
                if (policy) { MASKED_VID(bits, lmul, "ta,ma"); } \
                else { MASKED_VID(bits, lmul, "tu,mu"); } \
                __asm__ volatile("fence iorw,iorw" ::: "memory"); \
                for (unsigned i = 0; i < maximum; i++) { \
                    int active = i < count && ((patterns[pattern] >> (i & 7)) & 1); \
                    type got = output[i]; \
                    if (active) { if (got != (type)i) return 2; } \
                    else if (!policy || count == 0) { if (got != (type)0x35) return 3; } \
                    else if (got != (type)0x35 && got != (type)~(type)0) return 4; \
                } \
                vid_test_cases++; \
            } \
        } \
    return 0; \
}

WIDTH_CASE(8, uint8_t, m1)
WIDTH_CASE(16, uint16_t, m1)
WIDTH_CASE(32, uint32_t, m1)
WIDTH_CASE(64, uint64_t, m1)
WIDTH_CASE(64, uint64_t, m2)

static __attribute__((optimize("no-tree-vectorize"))) int mask_neighbors(void) {
    static volatile uint64_t output[32] __attribute__((aligned(64)));
    static volatile uint8_t prefix[12] __attribute__((aligned(64)));
    uintptr_t population, first;
    __asm__ volatile("vsetvli t0,%2,e64,m1,tu,mu\n"
                     "vid.v v8\n"
                     "vand.vi v8,v8,1\n"
                     "vmsne.vi v0,v8,0\n"
                     "viota.m v10,v0\n"
                     "vse64.v v10,(%3)\n"
                     "vcpop.m %0,v0\n"
                     "vfirst.m %1,v0\n"
                     "vmsbf.m v1,v0\n"
                     "vsm.v v1,(%4)\n"
                     "addi t1,%4,4\n"
                     "vmsof.m v1,v0\n"
                     "vsm.v v1,(t1)\n"
                     "addi t1,%4,8\n"
                     "vmsif.m v1,v0\n"
                     "vsm.v v1,(t1)"
                     : "=&r"(population), "=&r"(first)
                     : "r"((size_t)32), "r"(output), "r"(prefix)
                     : "t0", "t1", "v0", "v1", "v8", "v10", "memory");
    __asm__ volatile("fence iorw,iorw" ::: "memory");
    if (population != 16 || first != 1) return 1;
    for (unsigned i = 0; i < 32; i++) if (output[i] != i / 2) return 2;
    for (unsigned i = 0; i < 12; i++) {
        uint8_t expected = i == 0 ? 1 : i == 4 ? 2 : i == 8 ? 3 : 0;
        if (prefix[i] != expected) return 3;
    }
    vid_test_cases++;
    return 0;
}

int main(void) {
    shared_dma_machine_irq_off();
    shared_dma_cva6_wb_disable(&guard);
    __asm__ volatile("li t0,0x600\ncsrs mstatus,t0" ::: "t0", "memory");
    vid_test_stage = 1;
    if (repeated_vid()) return 11;
    vid_test_stage = 2;
    if (masked_8_m1()) return 12;
    vid_test_stage = 3;
    if (masked_16_m1()) return 13;
    vid_test_stage = 4;
    if (masked_32_m1()) return 14;
    vid_test_stage = 5;
    if (masked_64_m1()) return 15;
    vid_test_stage = 6;
    if (masked_64_m2()) return 16;
    vid_test_stage = 7;
    if (mask_neighbors()) return 17;
    if (vid_test_cases != 217) return 18;
    vid_test_stage = 8;
    return 0;
}
