# Unified Multi-Tile System Simulation

This is a procedural SystemVerilog environment, not UVM. It follows the original
`tb_cheshire_soc` / `vip_cheshire_soc` split: the testbench owns DUT configuration,
startup and checks; the VIP owns clock/reset/RTC, a shared AXI memory model,
external AXI transactions and independent per-tile UART sampling.

## Hardware and Boot Modes

`tb_multitile` instantiates one `multi_tile_top`. Each tile has one real CVA6,
Ara (2 lanes, VLEN 2048), FFT and 128 KiB private SPM. DDR and the DMA pool are
shared. Defaults are one tile and one shared DMA engine. The system clock is
50 MHz and RTC is 1 MHz. FPGA clock/MIG primitives and board pin timing are not
part of this system test; the existing board smoke test remains separate.

| Mode | ROM implementation | Program startup |
|---|---|---|
| `rom` | Immutable application/loader ROM snapshot | CPU copies ROM payload to SPM and starts it |
| `spm` | Original passive Cheshire Boot ROM | VIP writes SPM via AXI, verifies both aliases, then signals entry/start |

The same unified firmware builder supplies both modes. `application.bin` is
exactly the application PT_LOAD bytes from `firmware.elf`; `payload.json` supplies
the SPM VMA, application `_start`, file/memory sizes and checksum. The unified
ELF's ROM entry and physical ROM load address must not be used as the external
SPM load destination. BSS is zero-filled explicitly. Every tile currently runs
the same application in its own private SPM.

External loading waits for BIST, completed SPM-way flushing and all-SPM setup.
All tile images are loaded and read back before any tile is released. Entry
low/high go to scratch0/1, followed by scratch2=2. It uses normal AXI transactions,
not memory deposit or forced program counters. In ROM mode the TB rejects any
external AXI write and requires LOADING/READY/DONE transitions.

## Run

Prerequisites are prepared `.bender` dependencies, 64-source PLIC, Python
requirements, RISC-V GCC and VCS/vlogan in PATH. The runner does not download,
checkout or patch dependencies. It uses isolated Bender path overrides and
checks dependency HEADs and hardware/configuration/coefficient content before
and after each invocation. A mismatch is a failure.

```bash
cd /home/user06/work/xinkailai/cheshire
python3 util/run_multitile_sim.py --boot rom --tiles 1 --dmas 1
python3 util/run_multitile_sim.py --boot spm --tiles 2 --dmas 2 --uart-tiles all
```

Equivalent Make entry:

```bash
make chs-multitile-sim CHS_SIM_BOOT=spm CHS_SIM_TILES=2 CHS_SIM_DMAS=2 \
  CHS_SIM_ARGS="--uart-tiles all"
```

Without `--app`, the runner builds `vector_helloworld.c` and checks return zero,
actual Ara requests, the UART message and all 64 buffer bytes in every tile.
UART comparison defaults to tile0, matching the FPGA's one external UART. The
system VIP still samples each internal UART; `--uart-tiles all` validates all of
them. The FPGA RTL/UART wiring is unchanged.

Custom firmware uses the existing CRT and `main()` contract:

```bash
python3 util/run_multitile_sim.py --boot spm \
  --app target/sim/sw/return7.c --app-march rv64gc_zifencei --expected-return 7
```

`--app` disables the automatic Hello expectations. Optional checks are
`--uart-expected FILE` (exact bytes), `--check-buffer SYMBOL EXPECTED_BINARY`
(every tile), `--require-ara`, and `--require-fft`. `--extra-source` is repeatable.
The application ISA defaults to `rv64gcv_zifencei`; scalar workloads may select
`rv64gc_zifencei`, while vector workloads must initialize vector state as the
existing Hello program does. Custom code must initialize/flush UART if used.

`--build-only` compiles without running. `--reuse-build` requires an existing
executable with a matching signature; it never silently reuses an incompatible
build. The signature includes hardware/dependency state, Bender manifests,
TB/VIP and runner/resolver source, tool executable timestamps, mode and counts;
ROM mode additionally includes the ROM snapshot hash. SPM mode may reuse the
same compiled hardware for different application binaries. FFT coefficients
use an absolute root macro, independent of the run directory; missing files
are failures even if software later prints PASS.

## Results and Failure Semantics

Every tile must publish `(return_code << 1) | 1` in scratch2. ROM mode also waits
for ROM DONE. Unexpected returns, synchronous exceptions, loader/readback
errors, frame errors/X bits and watchdog expiration fail the simulation.
`--allow-traps` is reserved for workloads that deliberately handle synchronous
traps; it does not waive the return/timeout checks. Interrupts are not treated
as synchronous failures. Optional accelerator counters prove a request occurred;
they are not a numerical correctness proof.

UART is sampled from the actual wire, with independent frame and optional exact
byte checks. After CPU completion, capture has a bounded drain interval and a
final frame interval. UART checks run after memory readback so trailing activity
cannot be ignored. Software `printf` output alone cannot declare the TB passed.

The runner requires zero simulator status, an anchored TB PASS marker and a
complete, unique per-tile result set with exact expected returns. It rejects
simulator errors and missing-file messages. Stale CSV results are deleted before
each invocation. The simulation-time watchdog defaults to 100 ms; `--timeout`
sets the wall limit per tool/run (default 900 seconds). Timed-out tools and their
descendant processes are terminated as a process group.

Artifacts default to `target/sim/build/multitile/<mode>/<tiles>x<dmas>/`:

- `firmware/`: ELF, ROM and application binaries, disassembly, map and manifest.
- `compile_deps.sh`, `compile.json`, `build.log`: source selection and build record.
- `run.log`: firmware UART, TB diagnostics, simulator messages.
- `result.csv`: per-tile raw return, retirement/request counts, UART size and trap/PC.
- `result.json`: configuration, input hashes, dependency commits, status and results.

Different modes/counts have separate VCS libraries. A lock prevents two runs in
one output directory. `--out` selects a different directory. Failed builds/runs
also produce a failure report when the output directory can be created.

## Rejection Checks

These are deliberately failing commands; they must not produce a passed report:

```bash
# Wrong expected return (the firmware returns 7).
python3 util/run_multitile_sim.py --boot spm --reuse-build \
  --app target/sim/sw/return7.c --app-march rv64gc_zifencei
# An actual illegal instruction must report a synchronous trap, not just hang.
python3 util/run_multitile_sim.py --boot spm --reuse-build \
  --app target/sim/sw/trap.c --app-march rv64gc_zifencei
# No completion; a 10-ms simulated watchdog must reject it.
python3 util/run_multitile_sim.py --boot spm --reuse-build \
  --app target/sim/sw/spin.c --app-march rv64gc_zifencei --sim-timeout-ns 10000000
```

Host/build contracts can be checked with:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s util/tests -v
```

Historical specialized atomic, DMA, IRQ and board tests remain available. Their
results do not become current just because this common environment passes;
some older runners still have dependency preparation side effects.

## Verification Record (2026-10-17)

All 48 host/build tests passed. Real VCS runs passed with exact UART and Hello
buffer checking on every tile:

| Boot mode | Tiles | Shared DMA engines | Result |
|---|---:|---:|---|
| ROM | 1 | 1 | Passed |
| SPM | 1 | 1 | Passed |
| ROM | 2 | 1 | Passed |
| SPM | 2 | 2 | Passed |

The final Hello application and ROM hashes match all four reports. The Make
entry also passed for SPM, one tile and one DMA, using `--reuse-build`.
The scalar return-7 fixture passed with expected return 7. Wrong expected
return, illegal instruction, watchdog expiration, UART mismatch/truncation,
buffer mismatch and an unsatisfied FFT-request requirement were each rejected.
The existing `fft_accel_smoke.spm.c` passed its FFT/IFFT numerical checks with
`--require-fft`; Hello was restored and passed afterward. These extra results
are retained under `target/sim/build/multitile/validation/`.

Hardware-content and all 26 dependency-HEAD checks matched before and after
the runs. No design RTL or dependency checkout was changed by the new runner.
The existing FPGA bitstream was not rebuilt. This record covers the common
system environment, not every historical specialized regression or board timing.
