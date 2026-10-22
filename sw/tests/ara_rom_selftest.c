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

/* Written only after all cases; also read independently by the simulator. */
volatile uint32_t ara_test_summary[4] __attribute__((aligned(64)));
extern const uint32_t ara_selftest_corrupt __attribute__((weak));
extern const uint32_t ara_selftest_baud __attribute__((weak));
static const volatile uint64_t cache_guard = UINT64_C(0x123456789abcdef0);
static volatile uint32_t a[160] __attribute__((aligned(64)));
static volatile uint32_t b[8] __attribute__((aligned(64)));
static volatile uint32_t result[162] __attribute__((aligned(64)));
static volatile uint8_t input_bytes[64] __attribute__((aligned(64)));
static volatile uint8_t output_bytes[64] __attribute__((aligned(64)));
static const uint32_t aa[4] = {0xfffffff9, 0x80000000, 0x7fffffff, 0};
static const uint32_t bb[4] = {3, 0xffffffff, 2, 0};
static unsigned cases, checks, failures;
static unsigned corrupt;

static void sync_vector(void) {
    __asm__ volatile ("fence iorw, iorw" ::: "memory");
}

static void start(const char *name, unsigned bits, unsigned lmul) {
    ++cases;
    printf("[ARA] START %s e%u m%u\r\n", name, bits, lmul);
    uart_write_flush(&__base_uart);
}

static void row(unsigned i, uint64_t x, uint64_t y, uint64_t got,
                uint64_t expected, unsigned bits, int show) {
    int ok = got == expected;
    ++checks;
    failures += !ok;
    if (show || !ok)
        printf("[ARA] i=%u a=0x%0*llx b=0x%0*llx got=0x%0*llx exp=0x%0*llx %s\r\n",
               i, bits/4, (unsigned long long)x, bits/4, (unsigned long long)y,
               bits/4, (unsigned long long)got, bits/4, (unsigned long long)expected,
               ok ? "PASS" : "FAIL");
}

static void guard(int ok) {
    if (!ok) {
        ++failures;
        printf("[ARA] FAIL memory guard or vector length\r\n");
    }
}

/* Explicit unsigned wrapping; signed divide avoids C's INT_MIN/-1 UB. */
static uint32_t reference(unsigned op, uint32_t x, uint32_t y) {
    int32_t sx = (int32_t)x, sy = (int32_t)y;
    switch (op) {
    case 0: return x + y;
    case 1: return x - y;
    case 2: return x * y;
    case 3: return !y ? UINT32_MAX : (x == 0x80000000 && y == UINT32_MAX) ? x : (uint32_t)(sx / sy);
    case 4: return !y ? UINT32_MAX : x / y;
    case 5: return !y ? x : (x == 0x80000000 && y == UINT32_MAX) ? 0 : (uint32_t)(sx % sy);
    case 6: return !y ? x : x % y;
    case 7: return x & y;
    case 8: return x | y;
    case 9: return x ^ y;
    case 10: return x << (y & 31);
    case 11: return x >> (y & 31);
    case 12: return (uint32_t)(sx >> (y & 31));
    case 13: return sx < sy ? x : y;
    case 14: return sx > sy ? x : y;
    case 15: return x < y ? x : y;
    default: return x > y ? x : y;
    }
}

static const char *const names[] = {
    "vadd.vv", "vsub.vv", "vmul.vv", "vdiv.vv", "vdivu.vv", "vrem.vv", "vremu.vv",
    "vand.vv", "vor.vv", "vxor.vv", "vsll.vv", "vsrl.vv", "vsra.vv",
    "vmin.vv", "vmax.vv", "vminu.vv", "vmaxu.vv",
    "vadd.vx", "vadd.vi", "vmacc.vv", "vmslt+vmerge", "vadd.masked",
    "vslideup.vi", "vslidedown.vi", "vrgather.vv", "vid.v", "vmv.v.x"
};

#define BINARY_ASM(instruction) \
    __asm__ volatile (instruction " v12,v8,v10\n\tvse32.v v12,(%0)" \
                      :: "r"(&result[1]) : "v12", "memory")

static void arithmetic(void) {
    for (unsigned op = 0; op < sizeof(names)/sizeof(names[0]); ++op) {
        start(names[op], 32, 1);
        if (op == 19) printf("[ARA] accumulator=11\r\n");
        if (op == 21) printf("[ARA] mask=0x5 inactive=0x55\r\n");
        if (op == 22) printf("[ARA] old_destination=0x55\r\n");
        for (unsigned i = 0; i < 4; ++i) { a[i] = aa[i]; b[i] = bb[i]; }
        /* The slide-down source element just beyond VL is deliberately known. */
        a[4] = 0x55;
        result[0] = result[5] = 0xdeadbeef;
        __asm__ volatile ("vsetivli zero,5,e32,m1,tu,mu\n\tvle32.v v8,(%0)\n\t"
                          "vsetivli zero,4,e32,m1,tu,mu\n\tvle32.v v10,(%1)\n\t"
                          "vmv.v.i v12,11"
                          :: "r"(a), "r"(b) : "v8", "v10", "v12", "memory");
        switch (op) {
        case 0: BINARY_ASM("vadd.vv"); break;
        case 1: BINARY_ASM("vsub.vv"); break;
        case 2: BINARY_ASM("vmul.vv"); break;
        case 3: BINARY_ASM("vdiv.vv"); break;
        case 4: BINARY_ASM("vdivu.vv"); break;
        case 5: BINARY_ASM("vrem.vv"); break;
        case 6: BINARY_ASM("vremu.vv"); break;
        case 7: BINARY_ASM("vand.vv"); break;
        case 8: BINARY_ASM("vor.vv"); break;
        case 9: BINARY_ASM("vxor.vv"); break;
        case 10: BINARY_ASM("vsll.vv"); break;
        case 11: BINARY_ASM("vsrl.vv"); break;
        case 12: BINARY_ASM("vsra.vv"); break;
        case 13: BINARY_ASM("vmin.vv"); break;
        case 14: BINARY_ASM("vmax.vv"); break;
        case 15: BINARY_ASM("vminu.vv"); break;
        case 16: BINARY_ASM("vmaxu.vv"); break;
        case 17:
            __asm__ volatile ("vadd.vx v12,v8,%0\n\tvse32.v v12,(%1)"
                              :: "r"((uintptr_t)5), "r"(&result[1]) : "v12", "memory"); break;
        case 18:
            __asm__ volatile ("vadd.vi v12,v8,-3\n\tvse32.v v12,(%0)"
                              :: "r"(&result[1]) : "v12", "memory"); break;
        case 19: BINARY_ASM("vmacc.vv"); break;
        case 20:
            __asm__ volatile ("vmslt.vv v0,v8,v10\n\tvmerge.vvm v12,v10,v8,v0\n\t"
                              "vse32.v v12,(%0)" :: "r"(&result[1]) : "v0", "v12", "memory"); break;
        case 21:
            __asm__ volatile ("vid.v v14\n\tvand.vi v14,v14,1\n\tvmseq.vi v0,v14,0\n\t"
                              "vmv.v.x v12,%0\n\tvadd.vv v12,v8,v10,v0.t\n\tvse32.v v12,(%1)"
                              :: "r"((uintptr_t)0x55), "r"(&result[1]) : "v0", "v12", "v14", "memory"); break;
        case 22:
            __asm__ volatile ("vmv.v.x v12,%0\n\tvslideup.vi v12,v8,1\n\tvse32.v v12,(%1)"
                              :: "r"((uintptr_t)0x55), "r"(&result[1]) : "v12", "memory"); break;
        case 23:
            __asm__ volatile ("vslidedown.vi v12,v8,1\n\tvse32.v v12,(%0)"
                              :: "r"(&result[1]) : "v12", "memory"); break;
        case 24:
            __asm__ volatile ("vid.v v14\n\tvrsub.vi v14,v14,3\n\tvrgather.vv v12,v8,v14\n\t"
                              "vse32.v v12,(%0)" :: "r"(&result[1]) : "v12", "v14", "memory"); break;
        case 25:
            __asm__ volatile ("vid.v v12\n\tvse32.v v12,(%0)" :: "r"(&result[1]) : "v12", "memory"); break;
        default:
            __asm__ volatile ("vmv.v.x v12,%0\n\tvse32.v v12,(%1)"
                              :: "r"((uintptr_t)9), "r"(&result[1]) : "v12", "memory"); break;
        }
        sync_vector();
        if (op == 0 && corrupt) result[1] ^= 1;
        guard(result[0] == 0xdeadbeef && result[5] == 0xdeadbeef);
        for (unsigned i = 0; i < 4; ++i) {
            uint32_t x = a[i], y = b[i], expected;
            if (op < 17) expected = reference(op, x, y);
            else switch (op) {
            case 17: expected = x + 5; break;
            case 18: expected = x - 3; break;
            case 19: expected = x * y + 11; break;
            case 20: expected = (int32_t)x < (int32_t)y ? x : y; break;
            case 21: expected = (i & 1) ? 0x55 : x + y; break;
            case 22: expected = i ? a[i-1] : 0x55; break;
            case 23: expected = a[i+1]; break;
            case 24: expected = a[3-i]; break;
            case 25: expected = i; break;
            default: expected = 9; break;
            }
            uint32_t shown_a = x, shown_b = y;
            if (op == 17) shown_b = 5;
            if (op == 18) shown_b = UINT32_MAX-2;
            if (op == 22 || op == 23) shown_b = 1;
            if (op == 24) shown_b = 3-i;
            if (op == 25) shown_a = shown_b = 0;
            if (op == 26) { shown_a = 9; shown_b = 0; }
            row(i, shown_a, shown_b, result[i+1], expected, 32, 1);
        }
        if (corrupt) return;
    }
}

static void masks_and_reduction(void) {
    uintptr_t sum, population, first;
    start("vredsum+vmv.x.s", 32, 1);
    printf("[ARA] input=0x%08x,0x%08x,0x%08x,0x%08x initial=11\r\n",
           a[0], a[1], a[2], a[3]);
    __asm__ volatile ("vsetivli zero,4,e32,m1,tu,mu\n\tvle32.v v8,(%1)\n\t"
                      "vmv.v.i v10,11\n\tvredsum.vs v12,v8,v10\n\tvmv.x.s %0,v12"
                      : "=r"(sum) : "r"(a) : "v8", "v10", "v12", "memory");
    uint32_t expected = 11;
    for (unsigned i = 0; i < 4; ++i) expected += a[i];
    row(0, a[0], 11, (uint32_t)sum, expected, 32, 1);
    start("vcpop+vfirst", 32, 1);
    __asm__ volatile ("vsetivli zero,4,e32,m1,tu,mu\n\tvid.v v8\n\tvand.vi v8,v8,1\n\tvmseq.vi v0,v8,0\n\t"
                      "vcpop.m %0,v0\n\tvfirst.m %1,v0"
                      : "=r"(population), "=r"(first) :: "v0", "v8", "memory");
    row(0, 5, 0, population, 2, 32, 1);
    row(1, 5, 0, first, 0, 32, 1);
    for (unsigned zero = 0; zero < 2; ++zero) {
        start(zero ? "vl-zero" : "tail-undisturbed", 32, 1);
        __asm__ volatile ("vsetivli zero,4,e32,m1,tu,mu\n\tvle32.v v8,(%0)\n\t"
                          "vle32.v v10,(%1)\n\tvmv.v.x v12,%2\n\t"
                          "mv t0,%3\n\tvsetvli zero,t0,e32,m1,tu,mu\n\tvadd.vv v12,v8,v10\n\t"
                          "vsetivli zero,4,e32,m1,tu,mu\n\tvse32.v v12,(%4)"
                          :: "r"(a), "r"(b), "r"((uintptr_t)0x55),
                             "r"((uintptr_t)(zero ? 0 : 3)), "r"(&result[1])
                          : "t0", "v8", "v10", "v12", "memory");
        sync_vector();
        for (unsigned i = 0; i < 4; ++i)
            row(i, a[i], b[i], result[i+1], !zero && i < 3 ? a[i]+b[i] : 0x55, 32, 1);
    }
}

static void put_bits(volatile uint8_t *p, uint64_t value, unsigned bytes) {
    for (unsigned j = 0; j < bytes; ++j) p[j] = value >> (j*8);
}
static uint64_t get_bits(const volatile uint8_t *p, unsigned bytes) {
    uint64_t value = 0;
    for (unsigned j = 0; j < bytes; ++j) value |= (uint64_t)p[j] << (j*8);
    return value;
}

#define MEMORY_COPY(bits) \
    __asm__ volatile ("vsetivli zero,4,e" #bits ",m1,tu,mu\n\t" \
                      "vle" #bits ".v v8,(%0)\n\tvse" #bits ".v v8,(%1)" \
                      :: "r"(&input_bytes[8]), "r"(&output_bytes[8]) : "v8", "memory")

static void memory_tests(void) {
    unsigned before = failures;
    for (unsigned bits = 8; bits <= 64; bits *= 2) {
        start("load-store", bits, 1);
        unsigned bytes = bits/8;
        uint64_t values[] = {0, 1, UINT64_C(1) << (bits-1), UINT64_MAX >> (64-bits)};
        for (unsigned j = 0; j < 64; ++j) output_bytes[j] = 0xa5;
        for (unsigned i = 0; i < 4; ++i) put_bits(&input_bytes[8+i*bytes], values[i], bytes);
        switch (bits) {
        case 8: MEMORY_COPY(8); break;
        case 16: MEMORY_COPY(16); break;
        case 32: MEMORY_COPY(32); break;
        default: MEMORY_COPY(64); break;
        }
        sync_vector();
        for (unsigned j = 0; j < 64; ++j)
            if (j < 8 || j >= 8+4*bytes) guard(output_bytes[j] == 0xa5);
        for (unsigned i = 0; i < 4; ++i)
            row(i, get_bits(&input_bytes[8+i*bytes], bytes), 0,
                get_bits(&output_bytes[8+i*bytes], bytes), values[i], bits, 1);
    }
    for (unsigned indexed = 0; indexed < 2; ++indexed) {
        start(indexed ? "vluxei32+vsuxei32" : "vlse32+vsse32", 32, 1);
        static const unsigned order[] = {3, 0, 2, 1};
        for (unsigned i = 0; i < 12; ++i) { a[i] = 0xa5a5a5a5; result[i] = 0xdeadbeef; }
        for (unsigned i = 0; i < 4; ++i) { a[1+i*2] = 21+i; b[i] = order[i]*8; }
        if (indexed) {
            __asm__ volatile ("vsetivli zero,4,e32,m1,tu,mu\n\tvle32.v v10,(%0)\n\t"
                              "vluxei32.v v8,(%1),v10\n\tvid.v v12\n\tvsll.vi v12,v12,3\n\t"
                              "vsuxei32.v v8,(%2),v12"
                              :: "r"(b), "r"(&a[1]), "r"(&result[1])
                              : "v8", "v10", "v12", "memory");
        } else {
            __asm__ volatile ("vsetivli zero,4,e32,m1,tu,mu\n\tvlse32.v v8,(%0),%1\n\t"
                              "vsse32.v v8,(%2),%1" :: "r"(&a[1]), "r"((uintptr_t)8), "r"(&result[1])
                              : "v8", "memory");
        }
        sync_vector();
        for (unsigned i = 0; i < 12; ++i)
            if (!(i & 1) || i > 7) guard(result[i] == 0xdeadbeef);
        for (unsigned i = 0; i < 4; ++i) {
            unsigned source = indexed ? order[i] : i;
            row(i, a[1+source*2], i*8, result[1+i*2], 21+source, 32, 1);
        }
    }
    start("stripmine-add", 32, 2);
    enum { N = 145 };
    result[0] = result[N+1] = 0xdeadbeef;
    for (unsigned i = 0; i < N; ++i) { a[i] = i*3+1; result[i+1] = 0x55; }
    size_t maximum;
    __asm__ volatile ("vsetvli %0,zero,e32,m2,tu,mu" : "=r"(maximum));
    guard(maximum > 0 && maximum < N);
    for (size_t offset = 0; offset < N;) {
        size_t vl;
        __asm__ volatile ("vsetvli %0,%3,e32,m2,tu,mu\n\tvle32.v v8,(%1)\n\t"
                          "vadd.vi v10,v8,7\n\tvse32.v v10,(%2)"
                          : "=&r"(vl) : "r"(&a[offset]), "r"(&result[offset+1]), "r"((size_t)N-offset)
                          : "v8", "v9", "v10", "v11", "memory");
        if (!vl || vl > maximum || vl > N-offset) { guard(0); break; }
        offset += vl;
    }
    sync_vector();
    guard(result[0] == 0xdeadbeef && result[N+1] == 0xdeadbeef);
    for (unsigned i = 0; i < N; ++i) row(i, a[i], 7, result[i+1], i*3+8, 32, i < 4);
    printf("[ARA] checked=145 guards=%s\r\n", failures != before ? "FAIL" : "PASS");
}

typedef union { float f; uint32_t u; } fp32;
typedef union { double f; uint64_t u; } fp64;
static volatile fp32 fa32[4], fb32[4], fr32[4];
static volatile fp64 fa64[4], fb64[4], fr64[4];

#define FLOAT_ASM(bits, instruction) \
    __asm__ volatile ("vsetivli zero,4,e" #bits ",m1,tu,mu\n\t" \
                      "vle" #bits ".v v8,(%0)\n\tvle" #bits ".v v10,(%1)\n\t" \
                      "vle" #bits ".v v12,(%2)\n\t" instruction " v12,v8,v10\n\t" \
                      "vse" #bits ".v v12,(%2)" \
                      :: "r"(fa##bits), "r"(fb##bits), "r"(fr##bits) \
                      : "v8", "v10", "v12", "memory")

/* CRT leaves FS off. Keep FP register saves after main explicitly enables FS. */
static __attribute__((noinline)) void floating_point(void) {
    static const double x[] = {1.5, -2.0, 4.0, 0.0}, y[] = {0.5, 2.0, -2.0, 4.0};
    static const char *const fpnames[] = {"vfadd.vv", "vfsub.vv", "vfmul.vv", "vfdiv.vv", "vfmacc.vv"};
    for (unsigned bits = 32; bits <= 64; bits *= 2) {
        for (unsigned op = 0; op < 5; ++op) {
            start(fpnames[op], bits, 1);
            if (op == 4) printf("[ARA] accumulator=1.00\r\n");
            for (unsigned i = 0; i < 4; ++i) {
                fa32[i].f = x[i]; fb32[i].f = y[i]; fr32[i].f = 1.0f;
                fa64[i].f = x[i]; fb64[i].f = y[i]; fr64[i].f = 1.0;
            }
            if (bits == 32) switch (op) {
            case 0: FLOAT_ASM(32, "vfadd.vv"); break;
            case 1: FLOAT_ASM(32, "vfsub.vv"); break;
            case 2: FLOAT_ASM(32, "vfmul.vv"); break;
            case 3: FLOAT_ASM(32, "vfdiv.vv"); break;
            default: FLOAT_ASM(32, "vfmacc.vv"); break;
            } else switch (op) {
            case 0: FLOAT_ASM(64, "vfadd.vv"); break;
            case 1: FLOAT_ASM(64, "vfsub.vv"); break;
            case 2: FLOAT_ASM(64, "vfmul.vv"); break;
            case 3: FLOAT_ASM(64, "vfdiv.vv"); break;
            default: FLOAT_ASM(64, "vfmacc.vv"); break;
            }
            sync_vector();
            for (unsigned i = 0; i < 4; ++i) {
                double lhs = bits == 32 ? fa32[i].f : fa64[i].f;
                double rhs = bits == 32 ? fb32[i].f : fb64[i].f;
                double expected;
                switch (op) {
                case 0: expected = lhs + rhs; break;
                case 1: expected = lhs - rhs; break;
                case 2: expected = lhs * rhs; break;
                case 3: expected = lhs / rhs; break;
                default: expected = lhs * rhs + 1.0; break;
                }
                fp32 e32 = {.f = (float)expected};
                fp64 e64 = {.f = expected};
                uint64_t got = bits == 32 ? fr32[i].u : fr64[i].u;
                uint64_t exp = bits == 32 ? e32.u : e64.u;
                double got_float = bits == 32 ? fr32[i].f : fr64[i].f;
                ++checks;
                failures += got != exp;
                printf("[ARA] i=%u a=%.2f b=%.2f got=%.2f exp=%.2f got_bits=0x%0*llx exp_bits=0x%0*llx %s\r\n",
                       i, lhs, rhs, got_float, expected, bits/4, (unsigned long long)got,
                       bits/4, (unsigned long long)exp, got == exp ? "PASS" : "FAIL");
            }
        }
    }
}

void trap_vector(void) {
    uintptr_t cause, pc, value;
    __asm__ volatile ("csrr %0,mcause\n\tcsrr %1,mepc\n\tcsrr %2,mtval"
                      : "=r"(cause), "=r"(pc), "=r"(value));
    printf("[ARA] TRAP cause=0x%llx pc=0x%llx value=0x%llx\r\n",
           (unsigned long long)cause, (unsigned long long)pc, (unsigned long long)value);
    uart_write_flush(&__base_uart);
    *reg32(&__base_regs, CHESHIRE_SCRATCH_2_REG_OFFSET) = 3;
    for (;;) __asm__ volatile ("wfi");
}

int main(void) {
    uint32_t rtc = *reg32(&__base_regs, CHESHIRE_RTC_FREQ_REG_OFFSET);
    uint32_t baud = &ara_selftest_baud ? ara_selftest_baud : __BOOT_BAUDRATE;
    uart_init(&__base_uart, clint_get_core_freq(rtc, 2500), baud);
    /* Standalone board testing uses only TX/RX, with no CTS requirement. */
    *reg8(&__base_uart, UART_MODEM_CONTROL_REG_OFFSET) = 0;
    shared_dma_cva6_wb_disable(&cache_guard);
    corrupt = &ara_selftest_corrupt && ara_selftest_corrupt;
    __asm__ volatile ("csrs mstatus,%0\n\tcsrw fcsr,zero" :: "r"((uintptr_t)0x6600) : "memory");
    printf("[ARA] ROM selftest v1\r\n");
    arithmetic();
    if (!corrupt) {
        masks_and_reduction();
        memory_tests();
        floating_point();
    }
    ara_test_summary[0] = 0x41524131;
    ara_test_summary[1] = cases;
    ara_test_summary[2] = checks;
    ara_test_summary[3] = failures;
    sync_vector();
    printf("[ARA] SUMMARY cases=%u checks=%u failed=%u\r\n", cases, checks, failures);
    uart_write_flush(&__base_uart);
    return failures ? 1 : 0;
}
