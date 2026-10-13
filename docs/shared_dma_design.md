# Configurable shared iDMA for Cheshire

The default is four Cheshire tiles sharing two native iDMA engines. `NumTiles` and
`NumDmas` are independent positive elaboration parameters. No runtime hotplug is provided.
One engine owns one top-level ND job until the final write response and completion enqueue.
One tile may queue several jobs but has at most one executing job. Jobs from different
tiles can finish out of order; jobs from the same tile finish in submission order.

## Source map

| File under hw/shared_dma | Responsibility |
| --- | --- |
| cheshire_dma_pkg.sv | CSR offsets and completion type |
| dma_tile_frontend.sv | AXI MMIO, shadow registers, validation, submission credits, completions, IRQ |
| dma_job_scheduler.sv | Tile/engine round robin, one dispatch per cycle, active tile bitmap |
| dma_engine_wrap.sv | ND request holding, native midend/backend, job lifetime and bus error capture |
| shared_dma_pool.sv | Per-tile job FIFOs, engines and completion routing |
| global_ddr_fabric.sv | AXI crossbar and central AMO/LRSC adapter |
| cheshire_shared_dma_subsystem.sv | N control ports, N CPU DDR ports, M DMA masters, one DDR output |
| cheshire_shared_dma_cfg_pkg.sv | Standalone tile configuration with external DMA CSR mapping |
| multi_tile_top.sv | Actual N Cheshire instances, UART/JTAG, DMA IRQ inputs and DDR subsystem |

The existing single-DMA wrapper and default SoC configuration continue to exist.
`cheshire_soc.LlcSharedAtomics` defaults to zero. The new top sets it to one and
requires LLC bypass, exporting unresolved shared-memory atomics to the global fabric.

## Why the original proposal needed changes

Blocking SUBMIT when completion capacity is exhausted deadlocks the CPU that must POP
the events. Submission therefore fails immediately with SLVERR and a readable status.
IDs advance only on accepted submissions. Every accepted job reserves one completion
slot until software consumes the event. `CompletionDepth` bounds queued, active,
reporting and unread jobs together; `JobFifoDepth` independently bounds queued jobs.

The ND input ready signal belongs to the final child-request handshake. It does not mean
DDR writes are done. The wrapper holds the ND request throughout expansion, waits for
the final ND response, registers its report and releases ownership after enqueue.

The baseline backend has `NO_ERROR_HANDLING`. The wrapper records the first failing
AXI R/B response on an actual handshake throughout the ND job, drains all transfers and
reports the error once at final completion. Read wins if read/write errors coincide.
No retry, rollback, abort or automatic timeout recovery is provided. Error destination
data must not be used, and a software timeout does not cancel pending writes.

Independent private LLC atomic shims cannot implement shared-DDR atomics: they cannot
see another tile's stores or DMA writes. The global xbar supports ATOPs and feeds one
RISC-V atomic adapter. Its internal USER key combines the trusted xbar source prefix
and original local hart-domain USER bits. Public DDR USER width is unchanged; expanded
AXI IDs are preserved. CPU LR/SC may use different transaction IDs with the same key.

The locked iDMA 0.6.3 generated legalizer passed a byte count (`PageSize`) into the
bit-width parameter (`PageAddrWidth`). The tracked dependency patch corrects both the
standalone and assembled active AXI RTL and generator template. The shared LR/SC
monitor also needs a widened reservation-clear count for a full 256-beat burst, and
nonblocking assignments in its sequential state registers. Regressions reproduced
both an incorrectly successful SC and count underflow before these fixes.
The dependency preparation script is idempotent,
preserves unrelated checkout changes and fails if the patch cannot apply cleanly.

## CSR contract

Every tile uses its own physical control port at local `0x01000000..0x01001000`.
There is one software producer per tile, or a software lock covers configuration,
capacity check, submit and ID read. The B2 CSR is not binary-compatible with the old
NEXT_ID read-to-submit frontend; reserved reads return zero, unsupported writes SLVERR.
Use naturally aligned 32-bit accesses. Byte strobes are honored on both words of a
64-bit AXI beat; writes to command registers act only when byte zero and bit zero are set.

| Offset | Register | Meaning |
| --- | --- | --- |
| 0x000 | CONF | Original bits 0..10; higher bits rejected at submit |
| 0x004 | STATUS | bit0 executing/reporting, bit1 any accepted event not yet POPped |
| 0x0d0/0xd4 | DST | Address low/high |
| 0x0d8/0xdc | SRC | Address low/high |
| 0x0e0/0xe4 | LENGTH | Nonzero unsigned 32-bit length; high word must be zero |
| 0x0e8/0xec | DST_STRIDE | Unsigned 32-bit byte stride |
| 0x0f0/0xf4 | SRC_STRIDE | Unsigned 32-bit byte stride |
| 0x0f8/0xfc | REPS | Nonzero unsigned 32-bit row count when CONF bit10 is set |
| 0x100 | SUBMIT | Write bit0; success snapshots, queues and reserves capacity |
| 0x104 | Q_STATUS | bit0 can accept, bits15:8 accepted/unconsumed count, bits23:16 free credits |
| 0x108 | COMP_VALID | bit0 head valid |
| 0x10c | COMP_JOB_ID | Stable head ID until POP; starts at 1 and wraps at 32 bits |
| 0x110 | COMP_STATUS | bits7:0 error, bits31:16 engine; other bits zero |
| 0x114 | COMP_POP | Write bit0 consumes head; empty POP is harmless |
| 0x118 | IRQ_ENABLE | bit0 enables level IRQ while completion FIFO is nonempty |
| 0x11c | LAST_JOB_ID | Last accepted ID; unchanged after rejection |
| 0x120 | SUBMIT_STATUS | 0 accepted, 3 invalid, 4 no capacity |

Completion error codes: 0 success, 1 AXI read error, 2 AXI write error, 3 internal invalid
job. Invalid CSR submissions do not allocate an ID or completion. Full submissions
return SLVERR without blocking. The driver checks capacity and submission status.

Addresses are up to 64 bits; the instantiated AXI address width must match. Validate
the complete 2D bounding ranges using 128-bit arithmetic, against `[MemStart,MemEnd)`
and the AXI address limit. Source/destination bounding ranges must not overlap. This
conservative rule can reject nonoverlapping interleaved rows. Strides can be zero and
are unsigned; negative strides are unsupported. In 1D mode repetitions normalize to
one and the unused stride/repetition high words are ignored.

## Integration and software

`tile_cfg(DefaultCfg)` sets `Dma=0`, maps one external AXI slave to DMA MMIO, enables
LLC DDR output with bypass, and supplies one external IRQ input per tile. The standalone
top exposes per-tile UART and JTAG; it disables unexposed I2C/SPI/GPIO/USB/serial/VGA.
For an existing board top, connect `cheshire_shared_dma_subsystem` explicitly instead.
Preserve existing accelerator and peripheral configuration when adapting that board.

Define tile AXI types using `CHESHIRE_TYPEDEF_ALL(tile_, Cfg)`. DMA input IDs use the
same width as `tile_axi_llc_id_t`; CSR slave IDs use `tile_axi_slv_id_t`. Define DDR ID
width as `$bits(tile_axi_llc_id_t) + $clog2(NumTiles+NumDmas)` and construct DDR types
with `CHESHIRE_TYPEDEF_AXI_CT`. `tb_multi_tile_elab.sv` is a complete typedef/example
instantiation. Never truncate DDR IDs to fit an existing controller; use a proven ID
remapper with enough outstanding capacity if the controller cannot accept this width.

Each tile still has private hart numbering and boot resources. This is not a coherent
SMP Linux platform. LLC bypass does not disable CVA6's L1 cache. Shared buffers must
be uncached, or the application must clean source and dirty destination lines before
submit, then invalidate destination after completion. The selected standard CVA6 WB
target flushes its D-cache on fence, but flush acknowledgment can precede writeback B.
Use the validated guard-load drain in `shared_dma_cva6_wb.h`. Plain RISC-V fences are
not portable cache maintenance. Cacheline sharing still requires software coordination.

`TileBootStride` defaults to zero. The actual-CVA6 systembench disables Bootrom and
starts each tile's separate DDR ELF at PlatformRom + tile * TileBootStride. Its source
is `target/sim/src/tb_shared_dma_system.sv`; run `bash util/run_shared_dma_system.sh`.
It validates actual firmware, IRQ source 58 via the regenerated 64-source PLIC, cache
maintenance and software AMO barriers. See `docs/shared_dma_system_verification.md`.

`sw/include/shared_dma.h` provides nonblocking submit and event polling. Pass the
hardware DDR window and address width. Preserve every returned event instead of
discarding jobs other than the one currently awaited. The caller handles interrupt
registration, cache maintenance and synchronization.

All tiles, pool and fabric share one clock and reset. Coordinate reset with the DDR
controller's outstanding transactions, or drain them first. Epoch tags do not cancel
DDR writes. Independent tile/engine reset, CDC, memory firewalls, SMP coherence and
board-level DDR reset handling are outside this implementation.

## Reproduction

From `/home/user06/work/xinkailai/cheshire`:

```sh
bash util/prepare_shared_dma_deps.sh
bash util/run_shared_dma_tests.sh
DMA_TEST_SHAPES=4:2 DMA_TEST_ADDR_WIDTH=48 DMA_TEST_RANDOM_STALLS=1 \
  bash util/run_shared_dma_tests.sh
bash util/run_shared_dma_vcs.sh
gcc -std=c11 -Wall -Wextra -Werror -Isw/include \
  target/sim/src/shared_dma_driver_test.c -o target/shared_dma_verify/driver_test
target/shared_dma_verify/driver_test
```

Logs live under `target/shared_dma_verify`. See `docs/shared_dma_verification.md` for
the exact tested configurations, integration lint command, warnings and limitations.
