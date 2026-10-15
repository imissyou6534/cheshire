# Private SPM Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement these steps with review checkpoints.

**Goal:** Give each ara+fft tile private executable SPM with local AMO/LRSC while retaining globally coordinated DDR atomics and shared DMA.

**Architecture:** An opt-in `LlcSpmPrivate` configuration splits existing crossbar targets. SPM aliases normalize before a local atomics adapter and the existing LLC array in all-SPM mode. DDR bypasses that adapter and array. A per-tile external AXI loader writes ELF through the actual fabric; Boot ROM initializes SPM and enters the program without PC forcing.

**Tech Stack:** SystemVerilog, PULP AXI/LLC/atomics, CVA6, Ara+FFT, VCS, RISC-V bare-metal GCC.

## Tasks

- [x] Write and run a failing map/isolation test for the currently unsupported shared-atomics plus physical-SPM combination.
- [x] Add the opt-in configuration flag and separate SPM crossbar target; keep original configurations unchanged.
- [x] Add SPM alias normalization and local atomics; isolate the array master with an error slave; guard configuration against clearing SPM ways.
- [x] Adapt DDR ID widths and expose optional existing per-tile external AXI master interfaces for real loader access.
- [x] Append configuration 5 derived from ara+fft configuration 4, including private SPM and shared-DMA integration settings.
- [x] Add bare-metal SPM atomic/alias/isolation workload and linker entry using Boot ROM handoff.
- [x] Add a VCS system runner/TB loading through AXI, checking SPM AMO/LRSC and aliases, DDR atomics, SRAM isolation, PC retirement, IRQ/DMA regression and ara+fft elaboration.
- [x] Run 2x1 and 4x2 SPM verification, existing shared-DMA regression and review the final diff.
- [x] Record exact commands, outcomes, limitations and file ownership; synchronize changed artifacts without overwriting unrelated local changes.

## Constraints

Programs and stacks are private SPM; DMA buffers and shared barriers remain DDR. Shared DMA cannot access private SPM. All-way SPM configuration cannot be cleared by software in private mode. Source code defaults and configurations 0-4 remain compatible. Independent tile reset and board loading are outside this change. No commits or pushes are requested in this turn.

## Review and Debugging Evidence

The original map test failed with SPM and DDR both targeting port 2, then passed
with opt-in private SPM and unchanged legacy mapping. A directed write through
the 0x80 LLC CSR alias reproduced clearing of the program SRAM way mask; the
guard now uses the actual downstream 7-bit decode. Reserved high words of the
32-bit COMMIT/BIST registers are read as zero because the existing 64-to-32
register bridge reads both words of each AXI beat.

An AXI counter assertion exposed stale response forwarding inside the new
always_comb block; forwarding now occurs after response conversion. The same
test progressed to the CSR-alias negative check with no counter underflow.

The new loader adds a distinct local master. Global DDR LRSC identity must
include both global tile/engine source and local crossbar source, not just
hart USER. A firmware/loader phase tests attempted reservation theft before
accepting the extended key implementation.

The new CPU cross-memory test reproduced a stale local reservation after a DDR
LR (error 0x61). A per-core eligibility guard before the crossbar now tracks the
latest LR across targets and consumes it on any SC; mismatching SCs are drained
with an unsuccessful-exclusive OKAY response. Target adapters still perform
atomic operations and track conflicting writes. Cache-enabled SPM atomic tests
are also required in the final verification run.

Bender source-list generation can restore upstream lockfile dependency
revisions. Runners generate the list first, then apply dependency patches and
prepare PLIC, before compiling. The original real-CPU 2x1 workload passed after
correcting this order, as did the 1x1, 2x1 and 4x2 request-driven DMA regressions.
