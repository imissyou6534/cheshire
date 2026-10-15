# Private SPM Design and Verification

Authoritative workspace: `/home/user06/work/xinkailai/cheshire`.

## Configuration and RTL

`target/sim/src/tb_cheshire_pkg.sv` retains configurations 0-4 and appends
configuration 5, `gen_cheshire_ara_fft_spm_cfg()`, derived from configuration 4
(Ara + FFT). Ara remains enabled with two lanes and VLEN 2048; FFT remains
enabled. The new profile sets one CVA6 per tile, physical LLC/SPM present,
private SPM mode, Boot ROM and UART, one external loader master, one external
DMA CSR slave and no internal DMA. The dedicated multi-tile TB uses this
profile with the shared engine pool. The original single-SoC fixture provides
a one-master global DDR fabric for this profile; its external DMA CSR slave
is not a shared-pool model, so use the dedicated runner for DMA validation.

`Cfg.LlcSpmPrivate` defaults to zero. When enabled, `gen_axi_out()` allocates
a separate SPM target while preserving the original two alias address rules.
Legacy configurations continue to use the original common SPM/DDR target.

```text
CVA6 -> per-core latest-LR eligibility guard -> tile AXI crossbar
Debug / external loader --------------------------^
  SPM target -> alias normalization -> local AMO/LRSC adapter -> cut -> SPM array
  DDR target -> ID padding -> global crossbar -> global AMO/LRSC adapter -> DDR
DMA engines ---------------------------------------------------^
```

The physical array is the existing `axi_llc_reg_wrap`, configured entirely as
SPM. Its external memory master is terminated with a protocol-complete error
slave and checked for unexpected traffic. Shared DDR never enters this array
or the local SPM atomic adapter. Shared DMA cannot access private SPM.

SPM aliases normalize before reservation tracking. Local reservation identity
combines trusted tile-crossbar source with local hart USER. Global reservation
identity combines global tile/engine source, local source and hart USER, so an
external loader cannot consume a CPU reservation despite using USER=0 too.
Software attempts to clear any valid SPM way are rejected with SLVERR, including
all 0x80-spaced aliases of the underlying 7-bit register decoder. Reserved high
words at offsets 0x14 and 0x4c read as zero, accommodating the existing 64-to-32
register bridge without accepting arbitrary unmapped reads or writes.

Independent target adapters do not enforce the CPU rule that a second LR in
another memory replaces the previous reservation. `cheshire_core_lrsc_guard`
therefore tracks the latest canonical LR address/size/length per core/hart before
the tile crossbar. Any SC consumes eligibility. A nonmatching SC is drained by
an AXI sink returning OKAY (unsuccessful exclusive), without a memory write.
Actual interference and atomic execution remain in the target adapters. Debug,
Ara/FFT and external loader masters do not pass through this CPU-specific guard.

## Memory and Boot

Each tile has separate physical 128 KiB SPM, with identical local addresses:

| Region | Address |
| --- | --- |
| Boot ROM | `0x02000000` |
| LLC/SPM configuration MMIO | `0x03001000` |
| Cacheable SPM alias | `0x10000000-0x1001ffff` |
| Uncached SPM alias | `0x14000000-0x1401ffff` |
| Application ELF segments | First 64 KiB of SPM |
| Fixed atomic probes | `0x1000f000-0x1000f10f` |
| Application stack | `0x10010000-0x10017fff` |
| Reserved Boot ROM context | Upper 32 KiB of SPM |
| Shared data/DMA/synchronization | DDR, `0x80000000` and above |

The existing Boot ROM executes on each real CPU, waits for BIST, sets all ways
to SPM and enters its passive loader loop. The TB supplies a 1 MHz RTC with a
matching RTC frequency setting. It waits for the actual completed SPM state,
writes ELF PT_LOAD segments through each tile's external AXI master using the
uncached alias, and reads every loaded byte back through both aliases. It then
writes the original passive boot scratch handshake with the ELF entry.
No PC forcing, hierarchical SRAM deposit, or fabricated CPU DMA request is used.

`sw/link/private_spm.ld` bounds ELF segments and reserves separate application
and Boot ROM stacks. The application initializes its own stack; the pointer is
adjusted for the existing CRT's 24-byte save frame and 16-byte C ABI alignment.
`private_spm_elfloader.cpp` resets iterator state per ELF, checks PT_LOAD bounds
and overlap, and includes zero-only segments.

## Commands

On the configured server:

```bash
cd /home/user06/work/xinkailai/cheshire

# Actual CVA6 SPM boot, local atomics, alias conflict, DDR ownership and DMA.
bash util/run_private_spm_system.sh
PRIVATE_SPM_TILES=4 PRIVATE_SPM_ENGINES=2 bash util/run_private_spm_system.sh

# Compatibility of standard fixtures, configurations 0-5 (elaboration/reset).
bash util/run_private_spm_fixture_tests.sh

# Existing real-CPU DDR workload: cache, DMA, IRQ/PLIC and synchronization.
DMA_SYSTEM_TILES=2 DMA_SYSTEM_ENGINES=1 bash util/run_shared_dma_system.sh

# Request-driven DMA regression.
DMA_TEST_SHAPES='1:1 2:1 4:2' bash util/run_shared_dma_tests.sh
```

Make target: `make chs-private-spm-system-test`.
RTL top: `hw/shared_dma/multi_tile_top.sv`.
System TB: `target/sim/src/tb_private_spm_system.sv`.
Firmware: `sw/tests/private_spm_atomic.c`.
Outputs: `target/private_spm_system/<tiles>x<engines>/`, containing per-tile
ELFs, `compile_deps.sh`, `build.log`, `run.log` and `simv`.

Runners generate the Bender source list before applying dependency patches and
preparing PLIC, because Bender may restore lockfile checkout revisions. They
compile source groups and reject fatal/error logs even when VCS exits zero.
No unchecked build reuse is supported.

## Test Coverage

- Original map fails target-separation assertion; private mode passes while
  retaining legacy mapping and rule count.
- Each CPU executes its own ELF in physically private SPM at the same address.
- Word/doubleword AMOADD and AMOSWAP, word sign extension, wrap and byte-lane guards.
- LR/SC success and replacement, with per-tile isolation and alias readback.
- External ordinary write through the opposite alias invalidates CPU reservation;
  failed SC cannot overwrite injected data, and a new LR/SC succeeds.
- Loader exclusive write without loader LR fails even while CPU holds DDR LR;
  the original CPU SC succeeds and the data is checked.
- Cross-memory LR replacement is checked in both directions, including a second
  SC without a new LR and successful fresh LR/SC recovery.
- Cache-enabled SPM dirty stores, AMO/LRSC and an alias AMO verify the selected
  CVA6 WB cache flush/handoff behavior, then restore cache-off execution.
- All 32 low-register aliases reject clearing the all-SPM configuration.
- Shared DDR atomic barriers and one real-CPU DMA copy per tile.
- Routing checks prohibit SPM traffic at global DDR and unconverted atomic
  requests at SRAM; retired integer load results must contain no unknown bits.
- Standard fixture configuration 0-5 elaboration/reset compatibility.
- Separate existing DDR workload covers cache handoff and IRQ/PLIC behavior.

## Results and Limits

Fresh final results:

```text
PASS private SPM real CVA6 2 tiles x 1 engines
PASS private SPM real CVA6 4 tiles x 2 engines
PASS Cheshire fixture config=0..5 elaboration and reset (six separate runs)
PASS real CVA6 system 2 tiles x 1 engines peak=1 jobs=10
PASS shared DMA 1 tiles x 1 engines addr=32 random=0; 16 completions
PASS shared DMA 2 tiles x 1 engines addr=32 random=0; 17 completions
PASS shared DMA 4 tiles x 2 engines addr=32 random=0; 21 completions
```

All four CPUs report `cache=1` and `cross_memory_lrsc=1`. In the final 4x2
run, SPM instruction retirements are 1884/1947/1951/1946; each CPU emits three
actual D-cache writebacks during the cache-enabled SPM phase. Enabled cache
cycles are 3711/3856/3771/3822. Every CPU completes a real DDR DMA copy, and
both local and global atomic traffic are independently observed. The separate
DDR system regression completes five jobs and two PLIC claim/complete events
per CPU, with zero live unknown read data.

Independent review found no remaining blocking defect. The eligibility guard
is intended for the selected CVA6's serialized atomic issue path, not arbitrary
external AXI masters with concurrently issued same-hart atomics. No new commits
or pushes are made by this implementation task.

This is RTL simulation with real CVA6 execution and simulated DDR. Ara/FFT are
instantiated and retained in the profile; these workloads do not validate
accelerator computation. Independent reset, asynchronous clocks, board loading,
FPGA resource/timing closure and hardware cache snoop coherence are not covered.
The SPM workload uses polled DMA completion; IRQ/PLIC is covered separately by
the existing DDR-program workload, not by a new SPM interrupt workload.
The standard fixture checks are short reset/elaboration tests, not complete
bare-metal workload runs. Upstream Ara time-zero unique-case and Bender file-type
warnings remain; verification is not claimed to be warning-free.
