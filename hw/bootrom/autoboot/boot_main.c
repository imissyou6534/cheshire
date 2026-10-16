// SPDX-License-Identifier: Apache-2.0
#include <stddef.h>
#include <stdint.h>
#include "rom_payload.h"

#define SPM_BASE UINT64_C(0x10000000)
#define SPM_LIMIT UINT64_C(0x10010000)
#define SPM_ALIAS_DELTA UINT64_C(0x04000000)
#define ROM_LOADING UINT32_C(0x524f4d4c)
#define ROM_READY UINT32_C(0x524f4d52)
#define ROM_FAILED UINT32_C(0x524f4d46)

extern void rom_autoboot_enter(uintptr_t entry) __attribute__((noreturn));
static volatile uint32_t *const scratch = (volatile uint32_t *)UINT64_C(0x03000000);

static uint32_t checksum(const volatile uint8_t *data, size_t length) {
    uint32_t hash = UINT32_C(2166136261);
    for (size_t i = 0; i < length; ++i)
        hash = (hash ^ data[i]) * UINT32_C(16777619);
    return hash;
}

static void fail(uint32_t error) __attribute__((noreturn));
static void fail(uint32_t error) {
    scratch[14] = error;
    scratch[15] = ROM_FAILED;
    scratch[2] = (error << 1) | 1;
    for (;;) __asm__ volatile ("wfi");
}

int main(void) {
    int entry_loaded = 0;
    scratch[2] = 0;
    scratch[14] = 0;
    scratch[15] = ROM_LOADING;
    if (!ROM_PAYLOAD_NUM_SEGMENTS || ROM_PAYLOAD_NUM_SEGMENTS > 8 ||
        ROM_PAYLOAD_ENTRY < SPM_BASE || ROM_PAYLOAD_ENTRY >= SPM_LIMIT ||
        (ROM_PAYLOAD_ENTRY & 1)) fail(1);

    for (size_t i = 0; i < ROM_PAYLOAD_NUM_SEGMENTS; ++i) {
        const rom_payload_segment_t *segment = &rom_payload_segments[i];
        if (segment->load_addr < SPM_BASE || segment->load_addr >= SPM_LIMIT ||
            !segment->mem_size || segment->file_size > segment->mem_size ||
            segment->mem_size > SPM_LIMIT - segment->load_addr) fail(1);
        for (size_t j = 0; j < i; ++j) {
            const rom_payload_segment_t *prior = &rom_payload_segments[j];
            if (segment->load_addr < prior->load_addr + prior->mem_size &&
                prior->load_addr < segment->load_addr + segment->mem_size) fail(1);
        }
        uint32_t expected = segment->checksum;
#if ROM_AUTOBOOT_BAD_CHECKSUM
        if (i == 0) expected ^= 1;
#endif
        if (checksum(segment->data, segment->file_size) != expected) fail(2);
        if (ROM_PAYLOAD_ENTRY >= segment->load_addr &&
            ROM_PAYLOAD_ENTRY - segment->load_addr < segment->file_size) entry_loaded = 1;
    }
    if (!entry_loaded) fail(1);

    for (size_t i = 0; i < ROM_PAYLOAD_NUM_SEGMENTS; ++i) {
        const rom_payload_segment_t *segment = &rom_payload_segments[i];
        volatile uint8_t *destination = (volatile uint8_t *)(segment->load_addr + SPM_ALIAS_DELTA);
        for (size_t b = 0; b < segment->file_size; ++b) destination[b] = segment->data[b];
        for (size_t b = segment->file_size; b < segment->mem_size; ++b) destination[b] = 0;
        __asm__ volatile ("fence iorw, iorw" ::: "memory");
        if (checksum(destination, segment->file_size) != segment->checksum) fail(3);
        for (size_t b = segment->file_size; b < segment->mem_size; ++b)
            if (destination[b] != 0) fail(3);
    }
    scratch[15] = ROM_READY;
    rom_autoboot_enter((uintptr_t)ROM_PAYLOAD_ENTRY);
}
