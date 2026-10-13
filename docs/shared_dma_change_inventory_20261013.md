# Shared DMA Change Inventory (2026-10-13)

Authoritative workspace: `/home/user06/work/xinkailai/cheshire`.
Main repository branch: `ara-vcu118`; starting commit: `d17b180`.

## Main Repository

### Existing Board Configuration

`hw/cheshire_pkg.sv` disables I2C, SPI host, GPIO, SerialLink and VGA in
`DefaultCfg`. `target/sim/vcs/mode.sh` preserves an existing standalone
simulation environment preset for `helloworld.spm.elf`. These existing
workspace changes are committed separately from shared DMA implementation.

### Shared DMA RTL

`hw/shared_dma/` adds nine source files: configuration and register packages,
per-tile frontend, round-robin scheduler, engine wrapper, engine pool,
global DDR fabric, subsystem and multi-tile top.

- Tile count and engine count are independently configurable.
- Each tile has a job FIFO, local job IDs, reserved completion capacity and IRQ.
- Each tile and engine executes at most one job at a time; jobs can queue.
- Jobs carry immutable ND descriptors and software IDs through dispatch.
- Completion records identify the job, engine and error status.
- The DDR fabric merges tile and engine masters before global AMO/LRSC handling.
- AXI errors are captured while responses are drained.

`hw/cheshire_soc.sv` adds an opt-in shared-atomics path requiring LLC bypass,
and zero-extends PLIC sources to the generated source vector width.
The original atomics path remains the default for other integrations.

`hw/rv_plic.cfg.hjson` increases PLIC sources from 58 to 64, retaining two
M/S contexts and covering the external DMA interrupt at source ID 58.

`Bender.yml` registers the new RTL and testbench targets. `cheshire.mk` adds
regression targets and invokes dependency preparation before relevant builds.

### Software, Testbenches and Utilities

- `sw/include/shared_dma.h`: shared DMA CSR driver.
- `sw/include/shared_dma_cva6_wb.h`: selected CVA6 WB cache handoff and AMO helpers.
- `sw/link/shared_dma_system.ld`: per-tile DDR code/data/stack linker layout.
- `sw/tests/shared_dma_system_entry.S`: bare-metal entry wrapper.
- `sw/tests/shared_dma_system.c`: real CPU boot smoke workload.
- `sw/tests/shared_dma_system_workload.c`: concurrent DMA, ND, cache, IRQ/PLIC
  and software synchronization workload.
- `target/sim/src/tb_shared_dma.sv`: request-driven DMA unit verification.
- `target/sim/src/tb_multi_tile_elab.sv`: real tile integration elaboration check.
- `target/sim/src/tb_shared_dma_system.sv`: actual CVA6 bare-metal system test.
- `target/sim/src/shared_dma_driver_test.c`: host-side driver checks.
- `util/run_shared_dma_tests.sh`, `run_shared_dma_vcs.sh` and
  `run_shared_dma_system.sh`: build/run entry points.
- `util/prepare_shared_dma_deps.sh`: idempotent dependency patch preparation.
- `util/prepare_shared_dma_plic.sh`: generated PLIC validation/regeneration.
- `util/patches/`: three tracked iDMA/AXI atomics patches.
- `docs/cheshire_idma_scheme_b_architecture_rtl_design.html` and existing
  `docs/shared_dma*.md`: architecture, implementation and verification reports.

Private per-tile SPM has only been discussed. It is not implemented in this
snapshot. System programs still execute from per-tile regions of simulated DDR.

## Dependency Repositories

| Dependency | Original revision | Source changes |
| --- | --- | --- |
| iDMA 0.6.3 | `c12caf59bb482fe44b27361f6924ad346b2d22fe` | Correct page splitter parameter from byte page size to page address width in the legalizer template, standalone RTL and assembled generated RTL. |
| AXI RISC-V atomics 0.8.2 | `0ac3a78fe342c5a5b9b10bff49d58897f773059e` | Widen LRSC write-burst reservation invalidation count and use nonblocking assignments for sequential state. |
| OpenTitan peripherals 0.4.0 | `cd3153de2783abd3d03d0595e6c4b32413c62f14` | Regenerate PLIC for 64 sources, two contexts, priority 7 and standard registers, including matching HJSON, RTL and C header. |

The PLIC dependency commit includes seven generated/configuration files. Other
unchanged PLIC generator outputs are not included as redundant modifications.

CVA6 has no tracked source modifications; four debug backup files remain
untracked. AXI LLC, AXI RT, AXI VGA, CLINT and SerialLink have only untracked
build objects or `.generated` markers. These are not source commits.

`.bender/` is ignored by the main repository. Dependency commits are separate
Git commits, not automatically included in the Cheshire commit.
`Bender.lock` remains unchanged and pins the upstream revisions. Fresh
checkouts reproduce the dependency source changes using:

```bash
bash util/prepare_shared_dma_deps.sh
bash util/prepare_shared_dma_plic.sh --regenerate
```

Local dependency commits are not pushed upstream. Replacing a Bender checkout
can remove its local Git references; tracked patches and PLIC generation are
the source-level reproduction mechanism.

## Excluded Artifacts

No simulation output directories, executables, ELF files, object files,
waveforms, Verdi state, Python bytecode, `.generated` markers or debug backups
are committed. Existing FFT verification output is also left untouched.
These files remain on the server; this task does not delete them.

## Verification and Commit Record

Fresh checks performed for this snapshot:

```bash
git diff --cached --check -- . ':!util/patches/*.patch'
bash -n util/prepare_shared_dma_deps.sh util/prepare_shared_dma_plic.sh \
  util/run_shared_dma_system.sh util/run_shared_dma_tests.sh util/run_shared_dma_vcs.sh
bash -n target/sim/vcs/mode.sh
bash util/prepare_shared_dma_plic.sh --check
DMA_TEST_SHAPES=4:2 bash util/run_shared_dma_tests.sh
DMA_SYSTEM_TILES=2 DMA_SYSTEM_ENGINES=1 bash util/run_shared_dma_system.sh
```

All commands completed successfully. Dependency staged diffs also passed
`git diff --cached --check` before commit. Patch files were checked separately
for applicability: the reservation-width patch ends in a unified-diff blank
context line containing the required space prefix. A blanket whitespace check
flags that patch-data line, so it is excluded from the source whitespace check.

```text
PASS shared DMA 4 tiles x 2 engines addr=32 random=0; 21 completions
PASS real CVA6 system 2 tiles x 1 engines peak=1 jobs=10
```

Each real CPU accepted/popped five jobs and claimed/completed two PLIC
interrupts. Requested live read bytes and retired load results were known;
`live_unknown=0` on both tiles. The log still contains full-beat X assertion
messages for unrequested lanes on narrow reads. The build also reports RWX
ELF segment and Bender file-type warnings; this is not warning-free validation.
The 4x2 full-system and negative tests documented elsewhere are historical
results, not rerun for this commit operation.

| Repository / purpose | Commit |
| --- | --- |
| Cheshire existing configuration | `2bec66f04763aab62c6c00f13d6512de2a3d2b9b` |
| iDMA page-width fix | `48435a67f5915d13669a3d8c8c933564b0203bdb` |
| AXI RISC-V atomics fixes | `8d07df370bb2e8c8bc62d66ce06e02a3495f4145` |
| OpenTitan generated PLIC | `00477b12168ea498d9ac2639a52c7ff645ae88ae` |

Dependency commits are on local branch `codex/shared-dma-20261013` in each
checkout. The main shared DMA implementation commit includes this report;
retrieve its hash with `git log --oneline -- docs/shared_dma_change_inventory_20261013.md`.
Author identity is `Your Name <you@example.com>`, as explicitly requested.
No commits are pushed by this task.
