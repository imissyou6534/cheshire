# Mixed-Width Cheshire RTL Implementation Plan

> For agentic workers: apply subagent-driven-development to independent bounded modules and review integration.

**Goal:** Implement CPU64/Debug64, Ara128 with four lanes and VLEN2048, FFT128 dual-sample runtime FFT/IFFT with burst, Tile/SPM128 preserving 128KiB, DMA128, Shared256, MIG512.

**Architecture:** Width conversion at explicit AXI boundaries, existing ISA/CSR/byte layouts retained. Prepared .bender repositories are read-only. Original FFT generator working changes are preserved and extended in /home/user06/work/dblclockfft.

**Tech Stack:** SystemVerilog, C++ FFT generator, VCS, Verilator, Python unittest and NumPy.

Editing mirror: C:/Users/C/AppData/Local/Temp/cheshire-wide-20261019.
Authoritative checkout: /home/user06/work/xinkailai/cheshire, baseline 5838a51.
Do not overwrite local Windows repository RTL, which contains unrelated user changes.

## Task 1: Documentation and baseline
- [x] Read server AGENTS.md and record baseline statuses; protect dependencies.
- [x] Update design spec to four Ara lanes and explicit original FFT generator integration.
- [x] Finish baseline host tests; retain red/green evidence for changed behavioral contracts.

## Task 2: CPU, Ara, debug, peripherals and SPM
Files: hw/cheshire_pkg.sv, hw/cheshire_soc.sv, hw/shared_dma/cheshire_shared_dma_cfg_pkg.sv, project-owned width adapter if needed.
- [x] Add failing configuration/elaboration tests for mixed widths and preserved SPM size.
- [x] Separate CPU/debug/Ara widths from Tile width and insert typed conversion boundaries.
- [x] Keep CPU64 ID serialization, peripheral local AXI64/Reg32, debug64 both directions.
- [x] Enable target wide profile and preserve legacy64 profile.
- [x] Prove compilation and real CPU startup/byte writes/aliases.

## Task 3: Shared DMA and DDR fabric
Files: hw/shared_dma/multi_tile_top.sv, cheshire_shared_dma_subsystem.sv, shared_dma_pool.sv; owned new tests/runners.
- [x] Demonstrate target unequal Tile/DMA/Shared widths fail before change.
- [x] Separate control/native/shared AXI types, convert each physical source before xbar.
- [x] Preserve source IDs, USER, global atomic observation and completion semantics.
- [x] Test128-to256 narrow/burst traffic and real DMA transfers, plus legacy elaboration.

## Task 4: FFT generator and arithmetic
Files: /home/user06/work/dblclockfft/sw generator sources; project-generated hw/fft/rtl sources; provenance record and focused tests.
- [x] Run failing dual-sample runtime-direction generation/test.
- [x] Extend generator while preserving existing modifications and historical output directories.
- [x] Generate one isolated dual-sample runtime FFT/IFFT module set.
- [x] Numerically verify FFT/IFFT real and complex frames, pauses/reset/direction transitions.

## Task 5: FFT AXI burst datapath
Files: hw/fft/src/fft_accelerator_ip.sv, fft_task_ctrl.sv and owned project modules/tests.
- [x] Add failing128-bit burst behavioral test with randomized stalls, source/destination offsets0/8 and error injection.
- [x] Preserve START/WAIT contract and old64 support; add AXI INCR bursts, FIFOs, correct paired samples/results.
- [x] Drain asserted/accepted transactions after errors, wait for final B before completion.
- [x] Prove numeric output through the actual core/AXI model and real CPU DDR readback. A new dedicated CPU FFT-in-SPM numerical regression is not claimed.

## Task 6: Top-level, runners and verification
Files: Bender.yml, target/sim/src/tb_multitile.sv, tb_fft_ddr.sv, vip_multitile.sv, target/xilinx/src/multi_tile_top_xilinx.sv, related scripts.
- [x] Construct Shared256 DDR output types independently from Tile128.
- [x] Update result dumps, read sizes, burst completion checks and build signatures.
- [x] Run host tests and targeted VCS systems: ROM/SPM Hello, Ara4, FFT/IFFT, CPU DMA/PLIC and board-model JTAG.
- [x] Broaden to4x2 and boundary/error tests as risks demand.
- [x] Perform independent spec/code review, resolve findings, capture exact passing/failing evidence.
- [x] Aggregate current-hardware passing reports; check prepared dependency HEADs and record current status without deleting preexisting generated/object/backup files.

Implemented concurrency is one read and one write burst in flight, not four/four.
Known masked-vector overlap stalls on both wide4/128 and legacy2/64; the source and
failing evidence are retained separately and excluded from passing claims.
No FPGA synthesis, timing closure or physical-board validation was performed.

No commits, dependency reset, destructive cleanup or bitstream publishing are implicit in this plan.
