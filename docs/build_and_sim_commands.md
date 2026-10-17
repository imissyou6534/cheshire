# Simulation and VCU118 Build Commands

Current command reference, checked against the Make recipes on 2026-10-17.
Commands below run on the server. They consume prepared dependencies; do not
run system Bender checkout/update/script commands or old preparation scripts.

## Environment

```bash
ssh -p 2022 user06@10.181.10.18
cd /home/user06/work/xinkailai/cheshire
```

VCS/vlogan and RISC-V GCC are already available in the server login PATH.
The FPGA examples explicitly select `/opt/Xilinx/Vivado/2024.2/bin/vivado`.
FFT reference calculations use the server's NumPy interpreter,
`/opt/anaconda3/bin/python`; their build subprocess uses system `python3`,
which has the required PyYAML and pyelftools packages.

Both flows use the same `multi_tile_top`: one CVA6 + Ara + FFT and 128 KiB
private SPM per tile, shared DDR and a shared DMA pool. Ara defaults to two
lanes and VLEN 2048. Tile/DMA counts are independent: explicitly set equal
counts to instantiate one shared DMA engine per tile in total. Engines are
still pooled rather than statically assigned to tiles.

## Common VCS Simulation

The top is `tb_multitile`. Without a custom application it runs Ara Hello and
checks returns, actual Ara requests, UART and the SPM result buffer.

ROM-embedded application, one tile and one DMA:

```bash
make chs-multitile-sim \
  CHS_SIM_BOOT=rom CHS_SIM_TILES=1 CHS_SIM_DMAS=1 \
  CHS_SIM_ARGS="--uart-tiles all"
```

ROM-embedded application, two tiles sharing two DMA engines:

```bash
make chs-multitile-sim \
  CHS_SIM_BOOT=rom CHS_SIM_TILES=2 CHS_SIM_DMAS=2 \
  CHS_SIM_ARGS="--uart-tiles all"
```

External AXI loading into SPM, two tiles and two DMA engines:

```bash
make chs-multitile-sim \
  CHS_SIM_BOOT=spm CHS_SIM_TILES=2 CHS_SIM_DMAS=2 \
  CHS_SIM_ARGS="--uart-tiles all"
```

To reuse a matching compiled executable, add `--reuse-build` to `CHS_SIM_ARGS`.
The initial run after cleaning must omit it. To compile without simulating,
add `--build-only`. ROM reuse additionally requires the same ROM image;
external-SPM mode can reuse compiled hardware for different applications.
The command rejects mismatched caches rather than silently using them.

A custom standalone FFT/IFFT SPM impulse smoke test:

```bash
make chs-multitile-sim \
  CHS_SIM_BOOT=spm CHS_SIM_TILES=2 CHS_SIM_DMAS=2 \
  CHS_SIM_ARGS="--app sw/tests/fft_accel_smoke.spm.c --app-march rv64gc_zifencei --require-fft"
```

Changing `CHS_SIM_DMAS=1` gives two tiles sharing one engine. Instantiation
does not itself test DMA transfers, cache maintenance, IRQ or atomic operations;
those need appropriate software and result checks.

Outputs: `target/sim/build/multitile/<rom|spm>/<tiles>x<dmas>/`, including
`firmware/firmware.elf`, disassembly, `build.log`, `run.log`, `result.csv` and
`result.json`. ROM mode runs the copied application in SPM after ROM loading;
it does not execute the application text in place in ROM.

## FFT DDR Accuracy

The dedicated top is `tb_fft_ddr`, with external SPM application loading.
The TB writes and verifies DDR inputs, CPUs issue FFT/WAIT, then the TB reads
DDR outputs into files. NumPy compares every bin using the fixed 1/32 scale.
Cases are 4096-point cosine, sine and random real data on every tile.

```bash
make chs-fft-ddr-test \
  CHS_FFT_PYTHON=/opt/anaconda3/bin/python \
  CHS_FFT_ARGS="--tiles 2 --dmas 2"
```

Repeat with a matching compiled cache:

```bash
make chs-fft-ddr-test \
  CHS_FFT_PYTHON=/opt/anaconda3/bin/python \
  CHS_FFT_ARGS="--tiles 2 --dmas 2 --reuse-build"
```

Real-input IFFT using the same hardware cache:

```bash
make chs-fft-ddr-test \
  CHS_FFT_PYTHON=/opt/anaconda3/bin/python \
  CHS_FFT_ARGS="--tiles 2 --dmas 2 --mode ifft --reuse-build"
```

Optional limits are `--min-snr-db 40 --max-abs-error 128` (the defaults).
The default wall timeout is 1800 seconds per build/run tool and the simulated
watchdog is 200 ms. `CHS_FFT_ARGS` controls FFT counts; `CHS_SIM_TILES` and
`CHS_SIM_DMAS` do not control this separate Make entry.

Outputs: `target/sim/build/fft_ddr/sim/` for build artifacts and
`target/sim/build/fft_ddr/fft/` or `ifft/` for `summary.json`, `summary.csv`,
raw `tileN.jobJ.csv`, per-bin comparisons and NumPy arrays. Changing counts
requires recompilation unless selecting a separate compatible output directory.

`target/sim/sw/fft_ddr.c` requires TB-provided DDR data and scratch parameters.
It is not a standalone FPGA test. Use the SPM impulse smoke program above for
a standalone FFT workload. See [FFT accuracy details](fft_ddr_accuracy.md).

## Build ROM Firmware Only

This compiles loader/application objects, links one firmware ELF, patches its
checksum and emits ROM binary/SV plus disassembly. It does not run Vivado.

```bash
make chs-rom-autoboot CHS_ROM_APP=sw/tests/vector_helloworld.c
```

Outputs: `target/rom_autoboot/firmware.elf`, `firmware.bin`, `firmware.dis`,
`firmware.dump`, `firmware.map`, `application.bin`, `payload.json`,
`cheshire_bootrom.sv` and immutable `snapshots/<hash>.sv`.

## VCU118 ROM-Embedded Bitstream

Top: `multi_tile_rom_top_xilinx` -> `multi_tile_top_xilinx` -> `multi_tile_top`.
This Make entry builds firmware itself; a separate firmware command is optional.

One tile, one DMA, embedded Ara Hello:

```bash
make chs-xilinx-multi-tile-rom-vcu118 \
  CHS_NUM_TILES=1 CHS_NUM_DMAS=1 \
  CHS_ROM_APP=sw/tests/vector_helloworld.c \
  CHS_XILINX_SYNTH_ONLY=0 \
  VIVADO=/opt/Xilinx/Vivado/2024.2/bin/vivado
```

Two tiles, two DMA engines, embedded Ara Hello:

```bash
make chs-xilinx-multi-tile-rom-vcu118 \
  CHS_NUM_TILES=2 CHS_NUM_DMAS=2 \
  CHS_ROM_APP=sw/tests/vector_helloworld.c \
  CHS_XILINX_SYNTH_ONLY=0 \
  VIVADO=/opt/Xilinx/Vivado/2024.2/bin/vivado
```

Standalone FFT/IFFT impulse smoke instead of Ara Hello:

```bash
make chs-xilinx-multi-tile-rom-vcu118 \
  CHS_NUM_TILES=1 CHS_NUM_DMAS=1 \
  CHS_ROM_APP=sw/tests/fft_accel_smoke.spm.c \
  CHS_ROM_APP_MARCH=rv64gc_zifencei \
  CHS_XILINX_SYNTH_ONLY=0 \
  VIVADO=/opt/Xilinx/Vivado/2024.2/bin/vivado
```

The hardware still contains both Ara and FFT when selecting a scalar program.
`CHS_ROM_EXTRA_SRCS` can provide additional C/assembly source paths.
FPGA UART is connected to tile0; other tiles' UARTs are internal.

Full builds run synthesis, implementation, bitstream generation and timing
checking. Final successful outputs:

- `target/xilinx/out/multi_tile_rom.vcu118.bit`
- `target/xilinx/out/multi_tile_rom.vcu118.ltx`
- Build project: `target/xilinx/build/vcu118.multi_tile_rom/`
- Log: `target/xilinx/build/multi_tile_rom.vcu118.log`

Counts/programs share these output paths. A new successful build replaces the
old bit/LTX; the filename alone does not identify tile count or firmware.

## VCU118 Passive-ROM Bitstream

This retains the original passive Boot ROM. It embeds no test application;
software must be loaded afterward through an available board debug/boot path.
The TB's extra AXI loader is not connected to an external board connector.

```bash
make chs-xilinx-multi-tile-vcu118 \
  CHS_NUM_TILES=1 CHS_NUM_DMAS=1 \
  CHS_XILINX_SYNTH_ONLY=0 \
  VIVADO=/opt/Xilinx/Vivado/2024.2/bin/vivado
```

Top: `multi_tile_top_xilinx`. Outputs:
`target/xilinx/out/multi_tile.vcu118.bit` and `.ltx`.

## Dry Run and Synthesis Only

Print the ROM FPGA build commands without starting Vivado:

```bash
make -n chs-xilinx-multi-tile-rom-vcu118 \
  CHS_NUM_TILES=1 CHS_NUM_DMAS=1 \
  VIVADO=/opt/Xilinx/Vivado/2024.2/bin/vivado
```

Run synthesis/report generation, stopping before implementation and bit output:

```bash
make chs-xilinx-multi-tile-rom-vcu118 \
  CHS_NUM_TILES=1 CHS_NUM_DMAS=1 CHS_XILINX_SYNTH_ONLY=1 \
  VIVADO=/opt/Xilinx/Vivado/2024.2/bin/vivado
```

Synthesis-only mode does not replace a previous bit file; any old file remains
old. These build targets do not program the FPGA. Old specialized DMA/SPM Make
entries that mutate dependencies are blocked; see
[dependency protection](dependency_protection.md).
