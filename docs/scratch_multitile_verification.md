# Multi-tile SCRATCH path verification

Authoritative simulation workspace: `/home/user06/work/xinkailai/cheshire`.

## Files and execution

- `sw/tests/scratch_multitile.c`: one real CVA6 firmware ELF per tile.
- `sw/link/scratch_multitile.ld`: SPM code/data below `0x10010000`, separate
  application stack at `0x10010000..0x10017fff`.
- `target/sim/src/tb_scratch_multitile.sv`: dedicated top and independent checker.
- `util/run_scratch_multitile.sh`: fresh ELF/RTL build and negative/positive runs.

```bash
cd /home/user06/work/xinkailai/cheshire
bash util/run_scratch_multitile.sh
SCRATCH_TEST_TILES=2 SCRATCH_TEST_ENGINES=1 bash util/run_scratch_multitile.sh
```

The default is four tiles and two DMA engines. The engines are instantiated but
this test does not submit DMA jobs. Supported tile counts are 2 through 64.
Outputs are under `target/scratch_multitile/<tiles>x<engines>/`: `elf/tileN.elf`,
`compile_deps.sh`, `build.log`, `simv`, `run_data.log`, `run_address.log`, and
`run_none.log`. The runner always rebuilds; run configurations must not compile
shared Bender dependencies concurrently with other project runners.

## Boot and independent completion

The test retains configuration 5 (CVA6, Ara, FFT, private SPM and shared DMA).
Every CPU executes the existing Boot ROM, which initializes all-way SPM. The TB
loads ELF PT_LOAD segments through each tile's external AXI master using the
uncached SPM alias, then supplies the existing scratch entry/start handshake.
`sw/lib/crt0.S` establishes the application's stack, trap vector and BSS and
calls `main`. No PC forcing or hierarchical deposit is used to launch software.

Monitoring begins when the application entry at `0x10000000` retires. Boot ROM
and loader scratch writes before this point do not count as test writes. After
launch the loader performs no further transactions. Each tile completes by
writing an uncached DDR mailbox at `0x84000000 + tile*0x10000`, then parks in
`wfi`. `main` does not return, so the CRT's scratch-based exit is not involved.
TB success is not inferred from any scratch success flag.

| Mailbox Word | Meaning |
| --- | --- |
| 0 | Done: `0x53435250` success, `0x53435246` failure |
| 1 | Compiled tile ID |
| 2 | Successful full-word stores (1120) |
| 3 | Partial-store attempts (96) |
| 4 | Firmware readback checks (2336) |
| 5 | Firmware error code |
| 6 | Unexpected trap cause |
| 7 | TB-supplied negative selector, 0/1/2 |
| 8/9 | Unexpected trap value/PC |

## Coverage and oracle

Each tile tests all 16 standard SCRATCH words at `0x03000000 + 4*index`:

- 70 full-word rounds: zero, all ones, alternating bits, all 32 walking-one
  positions, all 32 walking-zero positions, tile/register identity, its inverse.
- One CPU readback after every store plus a full-bank readback after each round.
- 64 byte stores, covering all four byte lanes of each word.
- 32 halfword stores, covering both aligned halfwords of each word.

The generated system register block requires all four write strobes for these
32-bit fields (`CHESHIRE_PERMIT=4'b1111`). Partial writes must return an error
and leave the word unchanged. Firmware issues SB/SH and follows each rejected
store with a full-word readback. The selected CVA6 WB AXI adapter does not
propagate ordinary-store B errors as software access faults: the TB independently
requires all 96 SLVERR handshakes at the CPU AXI port. Any actual CPU trap fails
the firmware and records its cause, value and PC in the DDR mailbox.

The TB derives expected patterns independently from tile/round/word and checks
each accepted register-interface request: standard address, write data, byte
strobes and error response. It maintains a separate 16-word model per tile and
compares every RTL scratch value against that model after each clock update,
including words and tiles that did not write that cycle. Read responses must
match the model. Final CPU mailbox counts, CPU SLVERRs and actual instruction retirement
must agree with observed transactions. All tiles must finish before PASS.

## Negative controls and limits

The same compiled firmware is run three times. Negative mode 1 flips one data
bit in tile 1, round 0, word 7 (write index 7). Mode 2 adds `0x80` to that
address: the generated decoder aliases this address, but the TB must reject
the incorrect full address. The runner accepts only the exact respective
data/address mismatch at that tile/write, rejects timeouts and unexpected
positive PASS markers, then runs mode 0 for the positive result.

This validates CPU-to-SCRATCH write routing, stored values, readback, byte-mask
rejection and tile isolation in RTL simulation. It does not validate accelerator
computation, DMA transfers, independent resets/clocks, FPGA timing or hardware
cache coherence. Upstream Ara/Bender compile and time-zero warnings may remain.

## Verified results (2026-10-14, Asia/Shanghai)

Both commands above completed with exit status zero after compiling firmware,
RTL and the dedicated TB on the server. Both shapes rejected injected data and
address errors at exactly tile 1, write index 7, then passed their normal run:

```text
PASS SCRATCH negative data: checker rejected tile 1 write 7
PASS SCRATCH negative address: checker rejected tile 1 write 7
PASS SCRATCH real CVA6 4 tiles x 2 engines
PASS SCRATCH real CVA6 2 tiles x 1 engines
```

Every tile observed 1120 full-word writes, 64 rejected byte writes, 32 rejected
halfword writes, 96 CPU-side SLVERR responses and 4672 register read handshakes.
Firmware reports 2336 readback checks: the 64-to-32 bridge issues two register
reads per CPU word read. Tile 1 retired 42470 instructions; every other tile
retired 40916. No original SoC RTL, register specification or register generator
output was changed by this test.

The existing CVA6 whole-beat `a_invalid_read_data` warning occurs on the initial
narrow DDR control read. The AXI memory model leaves unrequested byte lanes X;
this is not a SCRATCH register read mismatch. SCRATCH transactions are checked
for unknown request/response values and all positive model comparisons passed.
No warning-free or general CPU memory-error handling claim is made.
