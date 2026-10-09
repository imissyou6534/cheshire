// Copyright 2026
// SPDX-License-Identifier: Apache-2.0

#include <stdint.h>
#include <stddef.h>

#include "regs/cheshire.h"
#include "dif/clint.h"
#include "dif/uart.h"
#include "params.h"
#include "util.h"

#include "fft_accel_vectors.h"

#define FFT_N 4096
#define SPM_UNCACHED_ALIAS 0x04000000ull

#ifndef FFT_VERIFY_UART_DUMP
#define FFT_VERIFY_UART_DUMP 0
#endif

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

static void uart_put_u32_hex(uint32_t value) {
    static const char hex[] = "0123456789abcdef";
    char buf[8];
    for (int i = 0; i < 8; ++i) {
        buf[i] = hex[(value >> (28 - 4 * i)) & 0xfu];
    }
    uart_write_str(&__base_uart, buf, sizeof(buf));
}

static void uart_put_u64_hex(uint64_t value) {
    uart_put_u32_hex((uint32_t)(value >> 32));
    uart_put_u32_hex((uint32_t)value);
}

static void uart_put_u32_dec(uint32_t value) {
    char buf[10];
    size_t pos = sizeof(buf);
    do {
        buf[--pos] = (char)('0' + value % 10u);
        value /= 10u;
    } while (value != 0u);
    uart_write_str(&__base_uart, &buf[pos], sizeof(buf) - pos);
}

static void run_case(size_t case_id, int inverse) {
    volatile int16_t *in = (volatile int16_t *)uncached_alias(fft_in);
    volatile int64_t *out = (volatile int64_t *)uncached_alias(fft_out);
    uintptr_t src = uncached_alias(fft_in);
    uintptr_t dst = uncached_alias(fft_out);

    for (size_t i = 0; i < FFT_N; ++i) {
        in[i] = fft_verify_vectors[case_id][i];
        out[i] = 0;
    }

    asm volatile ("fence rw, rw" ::: "memory");
    if (inverse) {
        ifft_exec(src, dst);
    } else {
        fft_exec(src, dst);
    }
    fft_wait();
    asm volatile ("fence rw, rw" ::: "memory");

    uart_write_str(&__base_uart, "FFT_DUMP_BEGIN case=", 20);
    uart_write_str(&__base_uart, fft_verify_case_names[case_id],
                   fft_verify_case_name_lens[case_id]);
    uart_write_str(&__base_uart, " mode=", 6);
    uart_write_str(&__base_uart, inverse ? "ifft" : "fft", inverse ? 4 : 3);
    uart_write_str(&__base_uart, " n=", 3);
    uart_put_u32_dec(FFT_N);
    uart_write_str(&__base_uart, "\r\n", 2);

#if FFT_VERIFY_UART_DUMP
    for (size_t i = 0; i < FFT_N; ++i) {
        uart_write_str(&__base_uart, "FFT_DUT ", 8);
        uart_write_str(&__base_uart, (void *)fft_verify_case_names[case_id],
                       fft_verify_case_name_lens[case_id]);
        uart_write_str(&__base_uart, " ", 1);
        uart_write_str(&__base_uart, inverse ? "ifft " : "fft ", inverse ? 5 : 4);
        uart_put_u32_hex((uint32_t)i);
        uart_write_str(&__base_uart, " ", 1);
        uart_put_u64_hex((uint64_t)out[i]);
        uart_write_str(&__base_uart, "\r\n", 2);
    }
#endif

    uart_write_str(&__base_uart, "FFT_DUMP_END case=", 18);
    uart_write_str(&__base_uart, fft_verify_case_names[case_id],
                   fft_verify_case_name_lens[case_id]);
    uart_write_str(&__base_uart, " mode=", 6);
    uart_write_str(&__base_uart, inverse ? "ifft" : "fft", inverse ? 4 : 3);
    uart_write_str(&__base_uart, "\r\n", 2);
}

int main(void) {
    uint32_t rtc_freq = *reg32(&__base_regs, CHESHIRE_RTC_FREQ_REG_OFFSET);
    uint64_t reset_freq = clint_get_core_freq(rtc_freq, 2500);
    uart_init(&__base_uart, reset_freq, __BOOT_BAUDRATE);

    uart_write_str(&__base_uart, "FFT_VERIFY_START\r\n", 18);
    for (size_t case_id = 0; case_id < FFT_VERIFY_NUM_CASES; ++case_id) {
#if FFT_VERIFY_RUN_FFT
        run_case(case_id, 0);
#endif
#if FFT_VERIFY_RUN_IFFT
        run_case(case_id, 1);
#endif
    }
    uart_write_str(&__base_uart, "FFT_VERIFY_DONE\r\n", 17);
    uart_write_flush(&__base_uart);
    return 0;
}
