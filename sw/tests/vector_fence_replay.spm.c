// Copyright 2026
// SPDX-License-Identifier: Apache-2.0

#include <stdint.h>
#include <stddef.h>
#include <riscv_vector.h>

#include "regs/cheshire.h"
#include "dif/clint.h"
#include "dif/uart.h"
#include "params.h"
#include "util.h"
#include "cheshire_util.h"

#define N 64
#define SPM_UNCACHED_ALIAS 0x04000000ull

static uint8_t src[N] __attribute__((aligned(64)));
static uint8_t dst[N] __attribute__((aligned(64)));

static inline uintptr_t uncached_alias(const void *ptr) {
    return ((uintptr_t)ptr) | SPM_UNCACHED_ALIAS;
}

static void prepare(uint8_t seed) {
    volatile uint8_t *src_uc = (volatile uint8_t *)uncached_alias(src);
    volatile uint8_t *dst_uc = (volatile uint8_t *)uncached_alias(dst);
    for (size_t i = 0; i < N; ++i) {
        src_uc[i] = (uint8_t)(seed + i);
        dst_uc[i] = 0;
    }
}

static void rvv_copy(void) {
    const uint8_t *src_uc = (const uint8_t *)uncached_alias(src);
    uint8_t *dst_uc = (uint8_t *)uncached_alias(dst);
    size_t vl = __riscv_vsetvl_e8m1(N);
    vuint8m1_t v = __riscv_vle8_v_u8m1(src_uc, vl);
    __riscv_vse8_v_u8m1(dst_uc, v, vl);
}

static int check(uint8_t seed) {
    volatile uint8_t *dst_uc = (volatile uint8_t *)uncached_alias(dst);
    int errors = 0;
    for (size_t i = 0; i < N; ++i) {
        uint8_t exp = (uint8_t)(seed + i);
        if (dst_uc[i] != exp) {
            ++errors;
        }
    }
    return errors;
}

static inline void enable_rvv_local(void) {
    asm volatile ("li t0, 0x600" ::: "t0");
    asm volatile ("csrs mstatus, t0" ::: "t0", "memory");
}

int main(void) {
    cheshire_start();
    enable_rvv_local();

    prepare(0x10);
    asm volatile ("fence rw, rw" ::: "memory");
    rvv_copy();
    asm volatile ("fence rw, rw" ::: "memory");
    int errors = check(0x10);

    prepare(0x40);
    asm volatile ("fence rw, rw" ::: "memory");
    rvv_copy();
    asm volatile ("fence rw, rw" ::: "memory");
    errors |= check(0x40);

    if (errors == 0) {
        uart_write_str(&__base_uart, "RVV FENCE REPLAY PASS\r\n", 23);
    } else {
        uart_write_str(&__base_uart, "RVV FENCE REPLAY FAIL\r\n", 23);
    }
    uart_write_flush(&__base_uart);
    cheshire_end();
    return errors ? 1 : 0;
}
