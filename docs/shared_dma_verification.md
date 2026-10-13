# Shared iDMA verification, 2026-10-12

Authoritative RTL project: `/home/user06/work/xinkailai/cheshire` on
`user06@10.181.10.18:2022`. Local Windows copies of these documents describe that
server implementation. The existing single-tile FPGA top has not been switched to
the new multi-tile top.

## Results

All following runs completed with exit code zero on the final RTL and dependency fixes.

| Tool / configuration | Result | Completion events checked |
| --- | --- | --- |
| Verilator 5.052, 1 tile / 1 engine, address32 | PASS | 16 |
| Verilator 5.052, 2 tiles / 1 engine, address32 | PASS | 17 |
| Verilator 5.052, 2 tiles / 2 engines, address32 | PASS | 19 |
| Verilator 5.052, 4 tiles / 2 engines, address32 | PASS | 21 |
| Verilator 5.052, 3 tiles / 2 engines, address32 | PASS | 20 |
| Verilator 5.052, 2 tiles / 3 engines, address32 | PASS | 19 |
| Verilator 5.052, 4 tiles / 2 engines, address48, random AXI stalls | PASS | 21 |
| Synopsys VCS W-2024.09-SP1, 4 tiles / 2 engines, address32 | PASS | 21 |
| Four actual Cheshire SoCs plus shared subsystem, Verilator lint/elaboration | PASS | No CPU program executed |
| C driver host regression, gcc -std=c11 -Wall -Wextra -Werror | PASS | Validation and failed-submit behavior |
| Bash syntax, git diff --check, repeated dependency preparation | PASS | Idempotent patches |

The behavioral configurations use a 64-bit AXI data bus and a one-bit original USER
field. Actual SoC elaboration uses the configured 48-bit address and two-bit USER
field. The global internal atomic USER key adds source/hart identity without widening
the public DDR USER interface. DDR IDs are explicitly widened for all input masters.

## Real CPU System Addendum

The subsequent actual-CVA6 systembench has now passed independent four-CPU boot,
4x2 full workload (20 DMA jobs, peak two engines), 2x1 full workload (10 jobs), and
strict cache/IRQ negative controls. Firmware executes on each CVA6 and performs
all DMA/PLIC operations. Per-tile instruction retirement, real claim/complete,
cache writeback/drain, software AMO barriers and independent DDR byte/metadata
checks establish the result. See [shared_dma_system_verification.md](shared_dma_system_verification.md)
for exact configurations, addresses, commands and remaining platform limits.

The PLIC is now generated as 64 sources / two contexts; DMA IRQ is source 58 in
each tile's machine context zero. Fences on the selected standard WB target do
clean/invalidate, and its guard-load drain is validated. This supersedes earlier
statements that no real CPU software boot or cache maintenance was exercised.

## Unit Coverage

- Concurrent isolated CSR programming and simultaneous active engines.
- Immutable submitted snapshots despite later shadow edits.
- Native 1D mode, 2D repetitions and unequal strides, unaligned data and byte strobes.
- Poisoned destinations, exact byte comparisons and untouched destination boundary bytes.
- 6,000-byte unaligned transfers; every accepted AR/AW burst stays within a 4-KiB page.
- Final write-response backpressure prevents early ND completion.
- Invalid zero length/repetitions, high words, overflow, out-of-range and overlapping ranges.
- FIFO exhaustion with free completion capacity, queued ordering, completion reservations,
  failed-submit IDs, empty POP and level IRQ behavior.
- Short job completes while a multirow job from another tile remains active.
- Intermediate-row AXI R SLVERR and B DECERR survive to final completion; later rows drain.
- CPU DDR read/write ID routing and concurrent atomic increments.
- Different LR/SC transaction IDs with one reservation key, distinct tile keys, another
  tile's store and DMA writes invalidate SC, including a complete 256-beat DMA burst.
- Reset with active/queued jobs while DDR acceptance is blocked, then a fresh job restarts
  at ID 1 without stale completion or ownership.

## Dependency regressions

Dependencies remain at the pinned revisions. Tracked patches under `util/patches/`
are applied by `util/prepare_shared_dma_deps.sh` and the test/build entry points.

1. iDMA `c12caf59bb482fe44b27361f6924ad346b2d22fe`: replace page byte count with
   page-address bit width in the AXI legalizer, assembled `idma_generated.sv` and
   generator template. Before correction the cross-page regression skipped bytes
   and issued address jumps of 2,048 bytes with incorrect short burst lengths.
2. axi_riscv_atomics `0ac3a78fe342c5a5b9b10bff49d58897f773059e`: widen reservation-clear
   count so 256 beats do not wrap to zero. Before correction LR at the second beat
   followed by a full DMA burst incorrectly permitted successful SC.
3. The same atomic dependency: use nonblocking sequential register assignments.
   Blocking state updates allowed clear-count recomputation using the new state;
   the widened counter then underflowed and caused thousands of unnecessary cycles.

An independent reviewer identified the global atomic requirement, failed-submit driver
bug, weak unpoisoned data test and the 256-beat reservation issue. The implementation,
driver and test coverage were updated accordingly.

## Reproduce

```sh
cd /home/user06/work/xinkailai/cheshire
bash util/run_shared_dma_tests.sh
DMA_TEST_SHAPES=4:2 DMA_TEST_ADDR_WIDTH=48 DMA_TEST_RANDOM_STALLS=1 \
  DMA_TEST_BUILD_ROOT="$PWD/target/shared_dma_verify/addr48_random" \
  bash util/run_shared_dma_tests.sh
bash util/run_shared_dma_vcs.sh

bender script verilator -t rtl -t cva6 -t cv64a6_imafdchsclic_sv39_wb \
  -t exclude_first_pass_decoder --compilation-mode common \
  > target/shared_dma_verify/soc.f
verilator --lint-only --timing --assert -Wno-fatal --top-module tb_multi_tile_elab \
  -f target/shared_dma_verify/soc.f target/sim/src/tb_multi_tile_elab.sv \
  > target/shared_dma_verify/soc_lint.log 2>&1
```

The Verilator runner selects the installed GCC 11 toolset for C++20 timing support.
Logs: `target/shared_dma_verify/<NxM>_a32_r0/{build,run}.log`,
`target/shared_dma_verify/addr48_random/4x2_a48_r1/{build,run}.log`,
`target/shared_dma_verify/vcs/{build,run}.log`, and `soc_lint.log`.

## Limits

Lint runs use `-Wno-fatal`. Existing upstream width and combinational-path warnings
remain, including 64-bit address decode rules for narrower address buses. Internal
USER extension/stripping also generates intentional width warnings. Lint completion
does not mean a warning-free design or a closed synthesis timing report.

The VCS unit runner filters out unused `idma_error_handler.sv`, whose nested concurrent
assertion inside always_comb is rejected by VCS. Engines use NO_ERROR_HANDLING with
wrapper bus error capture; all explicit testbench and wrapper assertions remain enabled.

The upstream memory model does not flush accepted transactions on reset. The reset
regression therefore blocks DDR acceptance first; reset of transactions already accepted
by a physical DDR controller still requires platform verification. Independent tile or
engine reset, timeout cancellation and rollback are not implemented.

No FPGA synthesis, placement/routing, board DDR test or formal proof was performed.
Real multi-CPU boot and software cache maintenance are now validated by the separate
systembench. Hardware remains noncoherent; no snooping coherence is claimed.
