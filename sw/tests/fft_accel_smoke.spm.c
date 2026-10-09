// Copyright 2026
// SPDX-License-Identifier: Apache-2.0

#include <stdint.h>
#include <stddef.h>

#include "regs/cheshire.h"
#include "dif/clint.h"
#include "dif/uart.h"
#include "params.h"
#include "util.h"

#define FFT_N 4096
#define SPM_UNCACHED_ALIAS 0x04000000ull

static int16_t fft_in[FFT_N] __attribute__((aligned(64)));
static int64_t fft_out[FFT_N] __attribute__((aligned(64)));

static inline uintptr_t uncached_alias(const void *ptr) {
    return ((uintptr_t)ptr) | SPM_UNCACHED_ALIAS;
}

static inline void fft_exec(uintptr_t src, uintptr_t dst) {
    asm volatile (".insn r 0x0b, 0x5, 0x0c, x0, %0, %1"
                  :
                  : "r"(src), "r"(dst)
                  : "memory");
}

static inline void ifft_exec(uintptr_t src, uintptr_t dst) {
    asm volatile (".insn r 0x0b, 0x5, 0x4c, x0, %0, %1"
                  :
                  : "r"(src), "r"(dst)
                  : "memory");
}

static inline void fft_wait(void) {
    asm volatile (".word 0x0000002b" ::: "memory");
}

static void uart_hex64(uint64_t value) {
    static const char hex[] = "0123456789abcdef";
    char buf[19];
    buf[0] = '0';
    buf[1] = 'x';
    for (int i = 0; i < 16; ++i) {
        buf[2 + i] = hex[(value >> (60 - 4 * i)) & 0xf];
    }
    buf[18] = '\r';
    uart_write_str(&__base_uart, buf, sizeof(buf));
    uart_write_str(&__base_uart, "\n", 1);
}

static int check_impulse_result(volatile int64_t *out) {
    int errors = 0;
    for (size_t i = 0; i < FFT_N; ++i) {
        int32_t real = (int32_t)(out[i] & 0xffffffffu);
        int32_t imag = (int32_t)((uint64_t)out[i] >> 32);
        if (real < 900 || real > 1100 || imag < -2 || imag > 2) {
            if (errors < 8) {
                uart_write_str(&__base_uart, "FFT smoke mismatch\r\n", 20);
                uart_hex64((uint64_t)out[i]);
            }
            ++errors;
        }
    }
    return errors;
}

static void prepare_impulse(volatile int16_t *in, volatile int64_t *out) {
    for (size_t i = 0; i < FFT_N; ++i) {
        in[i] = (i == 0) ? 32767 : 0;
        out[i] = 0;
    }
}

int main(void) {
    uint32_t rtc_freq = *reg32(&__base_regs, CHESHIRE_RTC_FREQ_REG_OFFSET);
    uint64_t reset_freq = clint_get_core_freq(rtc_freq, 2500);
    uart_init(&__base_uart, reset_freq, __BOOT_BAUDRATE);

    volatile int16_t *in = (volatile int16_t *)uncached_alias(fft_in);
    volatile int64_t *out = (volatile int64_t *)uncached_alias(fft_out);
    uintptr_t src = uncached_alias(fft_in);
    uintptr_t dst = uncached_alias(fft_out);

    prepare_impulse(in, out);
    asm volatile ("fence rw, rw" ::: "memory");
    fft_exec(src, dst);
    fft_wait();
    asm volatile ("fence rw, rw" ::: "memory");
    int fft_errors = check_impulse_result(out);

    prepare_impulse(in, out);
    asm volatile ("fence rw, rw" ::: "memory");
    ifft_exec(src, dst);
    fft_wait();
    asm volatile ("fence rw, rw" ::: "memory");
    int ifft_errors = check_impulse_result(out);

    if (fft_errors == 0 && ifft_errors == 0) {
        uart_write_str(&__base_uart, "FFT ACCEL SMOKE PASS\r\n", 22);
        uart_write_flush(&__base_uart);
        return 0;
    }

    uart_write_str(&__base_uart, "FFT ACCEL SMOKE FAIL\r\n", 22);
    uart_write_flush(&__base_uart);
    return 1;
}
