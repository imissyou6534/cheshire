# Ara ROM UART Self-Test

Update 2026-10-22: the Ara RTL defects found by this test have been fixed in the
prepared checkout. The unchanged ROM program now passes all 48 cases and 328
checks. Both lane profiles passed the new boundary regression. See
[Ara mask scalar fix](ara_mask_scalar_tail_fix.md) for the patch, verification
record and VFIRST latency tradeoff. The failure evidence below is historical.

The application is `sw/tests/ara_rom_selftest.c`. It uses the existing unified
ROM/SPM firmware flow: loader and application are embedded in the FPGA ROM;
on reset the loader checks/copies the application to private SPM and starts it.
No UART/JTAG/DDR program download is required. Program changes require a new
bitstream. The Hello application and default Make selections are preserved.

## FPGA Build and UART

Run in `/home/user06/work/xinkailai/cheshire` on the server:

```bash
# Firmware only: checks layout/checksum and generates ROM RTL, ELF and disassembly.
make chs-rom-autoboot CHS_ROM_APP=sw/tests/ara_rom_selftest.c

# Complete embedded-ROM VCU118 bitstream, with the existing wide bus/4-lane profile.
make chs-xilinx-multi-tile-rom-vcu118 \
  CHS_ROM_APP=sw/tests/ara_rom_selftest.c \
  CHS_NUM_TILES=1 CHS_NUM_DMAS=1 CHS_XILINX_SYNTH_ONLY=0 \
  VIVADO=/opt/Xilinx/Vivado/2024.2/bin/vivado
```

The bitstream path is `target/xilinx/out/multi_tile_rom.vcu118.bit`.
Connect UART at **115200, 8N1, no flow control**, then reset the board.
The application explicitly disables modem flow control for TX/RX operation.
The FPGA exposes tile 0 UART; this initial self-test validation uses one tile.

Example actual-output format (integer values are hexadecimal bit patterns):

```text
[ARA] ROM selftest v1
[ARA] START vadd.vv e32 m1
[ARA] i=0 a=0xfffffff9 b=0x00000003 got=0xfffffffc exp=0xfffffffc PASS
...
[ARA] START vmacc.vv e32 m1
[ARA] accumulator=11
...
[ARA] START vfadd.vv e32 m1
[ARA] i=0 a=1.50 b=0.50 got=2.00 exp=2.00 got_bits=0x40000000 exp_bits=0x40000000 PASS
...
[ARA] SUMMARY cases=48 checks=328 failed=0
```

`a`/`b` come from the actual scalar-visible input buffers. `got` is read after
Ara stores the result to memory; `exp` is computed with scalar code. `.vx`/`.vi`
rows print the actual scalar/immediate operand in `b`. Slide rows print the
shift in `b`; gather rows print the source element index. Mask and accumulator
parameters are printed explicitly. The reduction prints all four inputs.
The bulk test validates all 145 elements but prints four example rows and its
checked length/guard status. Any mismatching element is always printed.

START is flushed before each case to locate a stalled operation. A mismatch
increments `failed`; final `main()` returns 1 on failure, 0 on success. The
project CRT/ROM publishes completion in the normal scratch/status registers.
A synchronous trap prints `mcause`, `mepc`, and `mtval` and halts with failure.

## Coverage

| Area | Cases |
| --- | --- |
| Integer, SEW=32 LMUL=1 | `vadd/vsub/vmul/vdiv/vdivu/vrem/vremu`, AND/OR/XOR, left/logical-right/arithmetic-right shifts, signed/unsigned min/max |
| Operand forms | vector-vector, vector-scalar, vector-immediate, integer multiply-accumulate |
| Mask/data manipulation | signed compare + merge, masked add with inactive preservation, slide up/down, gather, `vid`, scalar broadcast |
| Reduction/scalar result | sum reduction + `vmv.x.s`, mask population and first set index |
| VL/policy | `tu,mu`, preserved tails, VL=0, masked-off destination values |
| Load/store | contiguous 8/16/32/64-bit, stride=8 bytes, 32-bit indexed gather/scatter |
| Multi-strip | 145-element e32/m2 add; VLMAX=128 for VLEN=2048, partial final strip, checked VL and surrounding guards |
| Floating point | FP32/FP64 add/subtract/multiply/divide/multiply-accumulate; exact numeric and IEEE-bit comparisons |

Integer tests include negative values, zero, INT_MIN, INT_MAX, wraparound,
divide-by-zero, INT_MIN/-1 and truncated shift counts. FP tests use finite,
exactly representable values, including zero results. Scalar reference
loops cannot auto-vectorize. The test performs the existing CVA6 writeback
handoff and disables D-cache before initializing operands, then fences Ara
stores before scalar readback; it does not assume generic fences clean any CPU.

This is a representative functional self-test, not exhaustive RVV compliance.
It does not cover every SEW/LMUL combination, FP exceptional rounding/NaNs,
misaligned faults, segmented loads/stores, DDR traffic or concurrent DMA/FFT.

## Simulation and Independent Checks

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s util/tests -p test_ara_rom_reference.py -v
python3 util/run_ara_rom_selftest.py

# Corrupt the first stored vadd result. Require an element FAIL, failure count 1,
# and application return 1. The negative firmware stops after the first case.
python3 util/run_ara_rom_selftest.py \
  --out target/ara_rom_selftest/negative --inject-failure

# Reuse the negative firmware ROM and deliberately change the host expectation.
# Require the exact UART mismatch, independently of the injected arithmetic FAIL.
python3 util/run_ara_rom_selftest.py --out target/ara_rom_selftest/negative \
  --inject-failure --reuse-build --wrong-uart
```

The wrapper calls the supported `run_multitile_sim.py` with `--boot rom`, wide
buses, 4 Ara lanes, VLEN=2048, one tile and one DMA engine. It requires ROM
startup without external AXI program writes, actual Ara requests, exact UART
bytes from an independent Python oracle, exact 16-byte `ara_test_summary`
readback through AXI and the expected application return. The oracle does not
derive its expected results from the C program or simulator output.

Simulation normally links **only** `ara_rom_selftest_fast_uart.c` in addition
to the application. It requests 3 Mbaud; the driver's integer divisor 1 at
50 MHz produces an actual 3.125 Mbaud (320 ns/bit). The runner overrides the
VIP receiver parameter to 320 ns and records it in the build signature. This
accelerates serial transmission without changing DUT RTL, operands or RVV
instructions. `--board-baud` uses the normal 115200 build/timing and is much
slower. Do not add the fast UART or negative source to the FPGA build command.

Primary artifacts are under `target/ara_rom_selftest/sim/`: `firmware/`,
`uart_expected.bin`, `summary_expected.bin`, `run.log`, `result.csv` and
`result.json`. `run.log` contains UART bytes decoded from the simulated wire;
`firmware/firmware.dump` gives source/disassembly for trap-PC diagnosis.
The existing VIP prints cumulative UART text at each newline, so earlier
received lines may appear repeatedly in `run.log`.

Prepared `.bender` dependencies must already exist. The protected runner checks
dependency HEADs and hardware contents before/after simulation, does not apply
patches or reset dependencies, and rejects changed hardware state.

## Pre-Fix Verification Record (2026-10-21)

On 2026-10-21, GCC 15.2.0 built the normal board-baud ROM image in 12,512 bytes
(16 KiB available). Six independent oracle tests, five existing runner contract
tests, two CLI/fresh-evidence tests and one real firmware build test passed.
The build regression requires no FP instructions in `main` before FS enable:
the existing CRT leaves FS off, so `floating_point()` must remain out of line
to prevent early floating-point register saves in the `main` prologue.

The complete ROM-started wide-profile VCS run completed all 48 cases and 328
checks, reporting **327 matches and one failure**. The CPU returned 1, with no
trap and 314 Ara requests. The actual UART contained 16,174 bytes. Its complete
transcript was independently compared with the Python oracle: the only
differences were the failing `vcpop` row and final failure count.

```text
[ARA] START vcpop+vfirst e32 m1
[ARA] i=0 a=0x00000005 b=0x00000000 got=0x0000000e exp=0x00000002 FAIL
[ARA] i=1 a=0x00000005 b=0x00000000 got=0x00000000 exp=0x00000000 PASS
...
[ARA] SUMMARY cases=48 checks=328 failed=1
```

Before the RTL fix, the default simulation command exited nonzero because it
correctly detected this hardware error. Its TB stopped at the unexpected return before the
optional AXI summary/UART checks; the full UART comparison described above was
performed separately on the actual decoded stream. Do not interpret this as a
passing Ara regression or change the expected popcount to 14.

Both negative checks passed: corrupting the first stored add result produced
one element FAIL, summary failure count 1, return 1 and matching independent
UART/AXI summary checks; changing its host UART expectation was rejected at
byte 100. The earlier negative record/log are saved as
`negative/result_firmware_failure.json` and `negative/run_firmware_failure.log`.
The final `negative/result.json` records the intentional UART rejection.

Verification artifacts:

- `target/ara_rom_selftest/verification.json`: explicit hardware-failure verdict.
- `target/ara_rom_selftest/sim/uart_actual.txt`: one copy of the actual UART stream.
- `target/ara_rom_selftest/sim/uart_reference_diff.txt`: exact independent diff.
- `target/rom_autoboot/`: final normal 115200 board firmware, generated by Make.

Dependency HEADs/status and DUT hardware contents stayed unchanged. FPGA
synthesis/programming was not run. Simulation used the documented fast UART;
normal 115200 firmware was built and inspected, not validated on the board.

## Located Ara Popcount Defect (Before Fix)

The generated instruction sequence sets VL=4 explicitly and is correct:

```asm
vsetivli zero,4,e32,m1,tu,mu
vid.v v8
vand.vi v8,v8,1
vmseq.vi v0,v8,0
vcpop.m a3,v0
vfirst.m s1,v0
```

The trace records `a3=14` and `s1=0`. In the prepared Ara source
`hardware/src/masku/masku.sv`, `VcpopParallelism=16` at line 203. Line 638
selects a complete 16-bit slice; lines 859-860 forward it without masking bits
past VL. Line 1285 accumulates that full population, and lines 1300-1302 finish
the four-element request after one slice. The two active ones plus twelve
tail ones produce `2 + 12 = 14`. Mask comparison destination tails may be set
to ones even with `tu`, so the expected architectural answer remains 2.

The existing `mask_neighbors` regression uses VL=32, a multiple of 16, and
does not expose this partial-slice case. The initial firmware task did not
change dependency RTL. The retained case verified the subsequent 2026-10-22
RTL fix without changing the program or the expected result.
