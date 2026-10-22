# Ara ROM UART Self-Test Implementation Plan

> **For agentic workers:** Execute tasks in this session with verification at each step.

**Goal:** Add a ROM-resident Ara self-test with inspectable operands and results.

**Architecture:** One bare-metal firmware, an independent Python result oracle
and a wrapper around the existing protected multi-tile simulation runner.

**Tech Stack:** RV64 GCC, RVV inline assembly, UART printf, Python unittest, VCS.

## Tasks

- [x] Add oracle tests for modular arithmetic, signed division edge cases,
  floating-point bit patterns, UART contents and summary serialization. Run red.
- [x] Implement `util/ara_rom_reference.py` and run oracle tests green.
- [x] Implement `sw/tests/ara_rom_selftest.c`, keeping reference calculations
  scalar and result readback ordered. Build using `util/build_rom_firmware.py`;
  inspect ROM capacity, instructions and application memory layout.
- [x] Add `util/run_ara_rom_selftest.py` using the existing ROM runner and wide
  profile, exact expected UART, AXI summary readback and required Ara activity.
- [x] Execute ROM simulation and a deliberately incorrect UART expectation;
  require success and rejection respectively. Preserve dependency HEAD/status.
  Also inject a firmware result corruption and require one FAIL, summary=1 and
  return=1. The bulk case spans VLMAX and a partial final strip with guard checks.
  To keep VCS runtime practical, use a separate simulation-only UART baud source
  and a VIP parameter override. The default FPGA firmware remains 115200 baud.
- [x] Document build, FPGA selection, UART output, tested scope and limitations
  in `docs/ara_rom_selftest.md`. Mirror new sources to the local workspace.

## Observed Outcome

ROM firmware is 12,512 bytes. Fourteen host/build tests passed. The complete
ROM VCS run reports 48 cases, 328 checks, one actual Ara `vcpop.m` failure
(VL4, mask5, got14, expected2); its default command correctly returns failure.
The full decoded UART was compared independently and differs only in that
element and the final failure count. Both deliberate negative regressions
passed their intended checks. This completes test implementation/verification,
not repair of the protected Ara dependency or FPGA synthesis/programming.

## Validation Commands

`python3 -m unittest discover -s util/tests -p test_ara_rom_reference.py -v`

`python3 util/run_ara_rom_selftest.py --out target/ara_rom_selftest`

`make chs-rom-autoboot CHS_ROM_APP=sw/tests/ara_rom_selftest.c`

FPGA: use the existing `chs-xilinx-multi-tile-rom-vcu118` Make target with
`CHS_ROM_APP=sw/tests/ara_rom_selftest.c`, one tile and one DMA engine.
