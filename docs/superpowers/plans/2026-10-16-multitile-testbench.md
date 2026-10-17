# Unified Multi-Tile Testbench Implementation Plan

**Goal:** One procedural SV system environment supporting embedded ROM and passive-ROM external SPM loading, with identical application bytes and prepared dependency RTL.

**Architecture:** `tb_multitile` instantiates one `multi_tile_top` with Ara, FFT, private SPM and shared DDR. `vip_multitile` provides clock/reset/RTC, AXI memory and external-loader transactions, plus independent UART sampling. Python builds firmware and mode-specific VCS executables, checks immutable dependency state, and writes structured results. FPGA primitive smoke tests stay separate.

## Tasks

- [x] Add failing tests for application binary export and simulation result acceptance/rejection.
- [x] Export `application.bin` from the unified firmware ELF; retain the existing one-link ROM build and manifests.
- [x] Implement reusable VIP with correctly independent AW/W handshakes, initialization polling, binary load/zero/readback and scratch handoff.
- [x] Implement common TB with per-tile return/trap/timeouts, optional UART/memory/accelerator checkers, ROM no-external-write assertions and result output.
- [x] Validate the mode-specific VCS runner and Make entry using only prepared dependency paths; document commands and artifacts.
- [x] Run software tests, both boot modes for one and two tiles, and expected return/UART/timeout rejection checks. Compare hardware/dependency baselines before and after.
- [x] Review the implementation and resolve actionable findings. Do not commit or synthesize FPGA unless requested.

## Contracts Confirmed in Review

- VCS libraries/output directories are separate per boot mode and tile/DMA configuration. ROM mode replaces the generated file-list entry with its immutable snapshot; SPM mode compiles only the original passive ROM.
- External loading polls BIST and flushed ways, verifies the all-SPM configuration, loads/zero-fills and verifies all tiles before handoff, then writes entry low/high to scratch0/1 and value 2 to scratch2.
- Software completion is `(return_code << 1) | 1`; ROM mode additionally waits for DONE and rejects ROM FAILED. The app binary is exactly the application PT_LOAD file bytes; manifest values supply VMA, entry and memory extent.
- Independent UART sampling starts after reset, checks frames/unknown bits and supports exact optional byte comparison. Completion includes bounded draining plus a final frame interval.
- Result files are removed before each run. Rejection coverage includes duplicate/out-of-range/missing/unfinished tiles, simulator errors despite PASS, return mismatches, UART mismatch/truncation, timeout and a real synchronous trap.
