// SPDX-License-Identifier: Apache-2.0
#include <stddef.h>
#include <stdint.h>

#define SPM_BASE UINT64_C(0x10000000)
#define SPM_LIMIT UINT64_C(0x10010000)
#define SPM_ALIAS_DELTA UINT64_C(0x04000000)
#define ROM_BASE UINT64_C(0x02000000)
#define ROM_LIMIT UINT64_C(0x02004000)
#define ROM_LOADING UINT32_C(0x524f4d4c)
#define ROM_READY UINT32_C(0x524f4d52)
#define ROM_FAILED UINT32_C(0x524f4d46)

extern const uint8_t __app_load_start[], __app_start[], __app_copy_size[], __app_mem_size[];
extern const uint32_t __rom_app_checksum[];
extern void _start(void);
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

void rom_boot_main(void) {
    uintptr_t source = (uintptr_t)__app_load_start;
    uintptr_t address = (uintptr_t)__app_start;
    uintptr_t entry = (uintptr_t)_start;
    size_t file_size = (uintptr_t)__app_copy_size;
    size_t mem_size = (uintptr_t)__app_mem_size;
    scratch[2] = 0;
    scratch[14] = 0;
    scratch[15] = ROM_LOADING;
    if (address != SPM_BASE || !file_size || file_size > mem_size ||
        mem_size > SPM_LIMIT - address || source < ROM_BASE || source >= ROM_LIMIT ||
        file_size > ROM_LIMIT - source || entry < address || entry - address >= file_size ||
        (entry & 1)) fail(1);
    uint32_t expected = *__rom_app_checksum;
#if ROM_AUTOBOOT_BAD_CHECKSUM
    expected ^= 1;
#endif
    if (checksum(__app_load_start, file_size) != expected) fail(2);

    volatile uint8_t *destination = (volatile uint8_t *)(address + SPM_ALIAS_DELTA);
    for (size_t b = 0; b < file_size; ++b) destination[b] = __app_load_start[b];
    for (size_t b = file_size; b < mem_size; ++b) destination[b] = 0;
    __asm__ volatile ("fence iorw, iorw" ::: "memory");
    if (checksum(destination, file_size) != expected) fail(3);
    for (size_t b = file_size; b < mem_size; ++b)
        if (destination[b] != 0) fail(3);
    scratch[15] = ROM_READY;
    rom_autoboot_enter(entry);
}
