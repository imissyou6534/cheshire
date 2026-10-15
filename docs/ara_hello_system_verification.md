# Ara Hello: Private-SPM System Simulation

## Hardware and Test Selection

- RTL top: `multi_tile_top` (`hw/shared_dma/multi_tile_top.sv`).
- Simulation top: `tb_private_spm_system`
  (`target/sim/src/tb_private_spm_system.sv`); procedural SystemVerilog, not UVM.
- Configuration: `gen_cheshire_ara_fft_spm_cfg()`, the private-SPM derivative
  of the Ara + FFT profile (simulation configuration 5).
- Each tile has one CVA6, Ara (2 lanes, VLEN 2048), FFT, Boot ROM and private
  128 KiB SPM. Tiles share DDR and the DMA engine pool.
- `NumTiles` and `NumDmas` are elaboration parameters of the existing RTL.
  The runner forwards its count variables to these parameters; neither is
  hardcoded to one in the testbench hello checks.
- `AraHello=1` selects testbench checkers only. It does not change RTL.
  `AraHello=0` retains the original atomic/DMA regression checks.
- FFT remains enabled but idle. DMA engines are instantiated but the hello
  program submits no DMA jobs. This test does not validate FFT arithmetic,
  DMA transfers, IRQ/PLIC delivery, or concurrent DMA submission.

```text
tb_private_spm_system
  |-- AXI ELF loader --> tile external master --> local crossbar --> private SPM
  |-- multi_tile_top
  |     |-- tile[t]: Boot ROM --> CVA6 --> Ara / FFT
  |     |                      |          |
  |     |                      +-- local crossbar -- private SPM
  |     +-- shared DMA subsystem / global DDR fabric
  +-- axi_sim_mem (DDR model)
```

## Run on the Server

Prerequisites: Bender, VCS/vlogan, GNU RISC-V tools with RVV intrinsics support
(tested compiler: GCC 15.2.0), `flock`, and `timeout` in the SSH login environment.

```bash
ssh -p 2022 user06@10.181.10.18
cd /home/user06/work/xinkailai/cheshire
ARA_HELLO_TILES=1 ARA_HELLO_ENGINES=1 bash util/run_ara_hello_system.sh
```

The script compiles firmware, resolves dependency sources, applies the existing
dependency/PLIC preparations, compiles and elaborates VCS, and runs both the
positive workload and two deliberately failing checker tests. The final script
exit status must be zero. A simulator exit status of zero alone is insufficient:
the script also rejects fatal/error messages and requires the expected PASS.

Counts default to 1 and 1. Other count values use the same elaboration path,
for example `ARA_HELLO_TILES=2 ARA_HELLO_ENGINES=1`; this is not evidence that
every count combination has been simulated. `RISCV_CC` overrides the compiler;
`ARA_HELLO_WALL_TIMEOUT` sets the wall timeout per simulation, default 900 seconds.

Logs and artifacts for the requested configuration:

```text
target/ara_hello_system/1x1/
  firmware.log                 compiler diagnostics
  build.log                    RTL compile and elaboration
  elf/tile0.elf                loaded executable
  elf/tile0.dump               disassembly, including vle8.v and vse8.v
  elf/tile0.segments           PT_LOAD layout
  run.log                     positive simulation
  run_checker_negative.log    expected buffer-checker rejection
  run_uart_negative.log       expected UART-string-checker rejection
```

## Boot and Success Criteria

The program is `sw/tests/vector_helloworld.c`, not a synthetic AXI CPU driver.
`sw/link/ara_hello_spm.ld` links its entry at `0x10000000`; image/BSS occupy the
first 64 KiB, with a separate application stack below `0x10018000`. The upper
32 KiB remain available to the Boot ROM. For multiple tiles, the same ELF is
loaded at the same virtual/physical local address in each independent SPM.

The Boot ROM first configures all SPM ways. The TB waits for initialization,
loads ELF PT_LOAD contents and zero fill through real AXI writes, and verifies
both SPM aliases. It then writes the entry and boot flag to scratch registers.
CVA6 executes the normal ROM handoff and CRT; no forced PC or SRAM deposit is used.

The firmware enables RVV, copies the string with RVV load/store intrinsics,
fences before consuming the result, compares the copied bytes and NUL, prints
the buffer, flushes UART, and returns. CRT publishes `(return_code << 1) | 1`
in scratch2; only `1` is success. The `%s` argument is the buffer pointer, not
the original vector value. Cache maintenance here follows this project's
CVA6/Ara integration; a generic RISC-V `fence` is not a portable cache-clean API.

The TB independently requires:

1. CPU success, SPM instruction retirements, and known retired load values.
2. Actual Ara request/response handshakes and AXI reads/writes.
3. Exactly `Hello Vector World!` followed by CR/LF on UART (21 bytes).
4. AXI readback of all 64 buffer bytes: string, NUL, and remaining zero bytes.
5. No FFT instruction requests and no accepted/popped DMA jobs.

After CPU exit, the UART monitor gets at most one additional frame to finish
sampling the last stop bit; missing or corrupt output still fails.

Each tile accumulates actual decoded UART bytes in its own `uart_received`
string. On LF, the TB prints that received string as `ARA UART tile=N: ...`,
then independently compares it with the expected message and emits
`PASS ARA UART tile=N bytes=21` or a fatal `FAIL ARA UART ...`. A partial line
is printed before an incomplete-line failure. Expected text is never used as
the source of the normal UART output log.

The negative run changes only the TB's expected buffer byte 1, not the firmware
or memory. It must report `ARA hello buffer mismatch tile=0 byte=1`, without a
positive PASS or a timeout. This checks that independent buffer validation is active.

A second negative run (`+ARA_HELLO_UART_NEGATIVE=1`) changes only tile 0's
expected UART character 1 from `e` to `d`. It must still print the actual
`Hello Vector World!` line, then report `FAIL ARA UART tile=0: string mismatch`
and no UART/system PASS. This distinguishes the observed output from the
reference string without changing the program or its UART transmission.

## Observed Hello Result

On 2026-10-15, the 1-tile/1-engine run reported:

```text
ARA UART tile=0: Hello Vector World!
PASS ARA UART tile=0 bytes=21
ARA evidence tile=0 retired=37556 spm_retired=34668 requests=11 responses=11 reads=4 writes=2 fft=0 uart_bytes=21 dma_jobs=0
PASS Ara hello real CVA6 1 tiles x 1 DMA engines
PASS Ara hello negative: independent buffer checker rejected byte 1
PASS Ara hello UART negative: actual output printed, wrong expectation rejected
```

The negative simulation specifically reported byte 1 `got=65 expected=64`.
The positive log also contains an Ara `unique case` warning at reset and a
CVA6 `a_invalid_instruction_fetch` warning (`vaddr=10001510`, data X). These
warnings were not suppressed or resolved in this test-only change. Loaded
PT_LOAD bytes and retired scalar load values are checked, but the smoke test
is not a proof that all speculative instruction-fetch behavior is X-free.

## Preserve the Atomic Regression

```bash
cd /home/user06/work/xinkailai/cheshire
PRIVATE_SPM_TILES=1 PRIVATE_SPM_ENGINES=1 bash util/run_private_spm_system.sh
```

This selects the original atomic firmware/checkers (`AraHello=0`), including
private-SPM/DDR atomics, external reservation conflicts, cache maintenance and
the DDR-to-DDR DMA smoke test. Its logs are under `target/private_spm_system/1x1/`.
The fresh 2026-10-15 regression completed with
`PASS private SPM real CVA6 1 tiles x 1 engines`.
