# Real CVA6 shared DMA system verification plan

Goal: execute real RV64 bare-metal programs on every tile and verify concurrent
submission, all copied bytes, machine external IRQ/PLIC, WB cache maintenance and
software synchronization. Default 4 tiles x 2 engines, plus a 2 x 1 configuration.

## Approach

- Keep the existing unit tests. Add a separate VCS systembench with actual
  multi_tile_top, actual CVA6 WB caches, shared DDR fabric and native DMA engines.
- LLC bypass does not expose the legacy SPM. Link each tile firmware image and its
  stack at a separate DDR base. Preload using the existing ELF DPI loader while all
  CPUs are held in reset, then let each CPU fetch from its own reset entry.
- Add a default-zero TileBootStride parameter to multi_tile_top. Only the system
  test configuration disables Bootrom and sets PlatformRom in DDR. Existing tops
  retain their reset behavior.
- Firmware performs all DMA MMIO and PLIC operations. Testbench never issues DMA
  commands, injects CPU IRQs, changes PC or forces completion.
- Software completion and synchronization must use actual CPU accesses, with
  architecture-specific verified WB cache maintenance or genuinely uncached memory.
- Monitor actual CPU instruction retirement, DMA overlap, IRQ assertion, trap/PLIC
  transactions and cache flush/ack signals. CPU-written results must agree with
  independent DDR memory checks, not just a final PASS mailbox.
- Positive scenarios include polling, IRQ completion, ND/unaligned/cross-page,
  immutable snapshots, per-tile FIFO capacity and concurrent shared-memory barriers.
- Negative controls omit cache maintenance and suppress an IRQ to prove the
  corresponding checks fail; avoid reusing timeout buffers while DMA is active.

## Steps

- [x] Add the systembench, ELF firmware build/run script and boot smoke firmware.
- [x] Observe the smoke failing before adding per-tile boot entry support.
- [x] Implement minimal boot support; prove all real CPUs retire instructions and exit.
- [x] Add concurrent DMA firmware and explicit data/ownership checks.
- [x] Add actual trap/PLIC handling and cache/synchronization tests with negative controls.
- [x] Run 4x2 and 2x1 systems, relevant unit regression, independent review and final report.

Actual PLIC generation and routing needed correction to 64 sources/two contexts.
Review findings were addressed with selective MEIE masking and removal of unchecked
build reuse. Upstream raw full-word assertions warn on unused AXI read lanes; the
systembench validates selected bytes and all retired load results instead. All
functional positive and negative cases pass; the original warnings remain visible.

## Scope

This is RTL full-system simulation using an AXI DDR memory model, not FPGA or physical
DDR verification. Existing dirty changes and unrelated accelerator tests remain intact.
