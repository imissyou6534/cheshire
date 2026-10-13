# Shared iDMA implementation plan and design

Goal: configurable N tile frontends sharing M native iDMA engines, default 4 x 2.

Baseline: iDMA 0.6.3, c12caf59bb482fe44b27361f6924ad346b2d22fe.

## Architecture decisions

- One independent B2 CSR bank and immutable job FIFO per physical tile port.
- NumTiles and NumDmas are positive elaboration parameters, including one and odd counts.
- One active job per tile and engine; dispatch one job per cycle with round-robin tile
  and engine selection. Different tiles run concurrently; same-tile jobs retire in order.
- Every accepted submission reserves completion capacity until software pops that event.
  Full or invalid submissions return SLVERR without allocating an ID. Blocking submit
  is prohibited because the same CPU must be able to consume completions.
- Engine holds ND request until the LAST input handshake, then waits for the final ND
  response. A registered report survives completion backpressure. Ownership is released
  only after the event is enqueued.
- Keep upstream backend NO_ERROR_HANDLING; latch errors on actual AXI R/B handshakes
  throughout the ND job. Drain traffic normally and report the first error at final
  completion. Do not interpret intermediate errors as job completion. No abort/retry.
- Validate nonzero length/repetitions, high words, address width, whole 2D bounding ranges,
  and conservative source/destination overlap before dispatch. 1D normalizes repetitions
  to one. Strides and length are unsigned 32-bit; addresses are up to 64-bit.
- One clock and coordinated reset for tiles, pool, fabric and DDR transaction state.
  Independent resets are unsupported: generation tags alone cannot cancel DDR writes.
- N tile DDR ports and M DMA ports feed a PULP AXI crossbar. Use equal input ID widths
  and extend DDR IDs by ceil(log2(N+M)); no truncation. Tile LLC bypass is enabled;
  CPU caches still need software maintenance or uncached buffers.

## Work items

- [x] Add self-checking RTL testbench and reproducible Bender/Verilator runner; observe
  missing-module failure before implementation.
- [x] Add CSR frontend, scheduler, engine, completion queues and pool; test real ND copies.
- [x] Add DDR fabric, subsystem, configuration helper and multi-tile top; test CPU/DMA
  DDR coexistence and elaborate actual tiles.
- [x] Add C driver and correct HTML specification, including register and reset contracts.
- [x] Run parameter matrix, injected R/B errors, final-B stall, byte strobes, invalid jobs,
  FIFO/credit exhaustion, immutable snapshots, IRQ, ordering, fairness and reset checks.
- [x] Review diffs and publish exact verification evidence and limitations.
