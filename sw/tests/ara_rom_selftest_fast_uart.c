// SPDX-License-Identifier: Apache-2.0
// Simulation only: request 3 MHz with measurement margin. The driver's integer
// divisor is 1 at 50 MHz, giving an actual 3.125 Mbaud (320 ns/bit).
#include <stdint.h>
const uint32_t ara_selftest_baud = 3000000;
