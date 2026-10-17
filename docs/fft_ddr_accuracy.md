# Multi-Tile FFT DDR Accuracy Test

`tb_fft_ddr` is a dedicated copy of `tb_multitile` using the same unmodified
`multi_tile_top` and `vip_multitile`. It adds DDR input initialization/readback,
FFT command/write-response counting and post-completion DDR output dumps.
The common `tb_multitile` remains unchanged. No design RTL or dependency patch
is needed. This tests an AXI DDR memory model, not board-level MIG timing.

## Workloads and Memory

Each tile runs three 4096-point real-input cases: an amplitude-8192 cosine at
bin 7, an amplitude-8192 sine at bin 123, and deterministic random integers in
[-12000, 12000]. The random seed defaults to `2026 + tile`; sine/cosine samples
are rounded to signed int16. Complex-input testing is outside this test's scope.

The TB loads a small scalar application into private SPM through the existing
passive-ROM protocol. It writes the exact Python-generated int16 input bytes to
DDR through AXI and reads every input beat back before releasing any CPU.
No sample vectors are embedded in ROM or the application's ELF.

| Region | Address/Size |
|---|---|
| Tile DDR allocation | `0x80000000 + tile * 0x100000` |
| Case allocation | Tile base + `case * 0x10000` |
| Input | Case base, 8192 bytes of little-endian int16 |
| Output | Case base + `0x4000`, 32768 bytes |

Scratch3 gives the program its tile index and scratch6 selects FFT/IFFT.
Scratch4/5 remain reserved for the passive ROM's boot address handoff.
Every CPU issues START and WAIT for each case, then returns zero. FFT engines
perform actual AXI DDR reads and writes. CPUs do not access the DDR buffers,
avoiding CPU cache visibility issues. Tiles use disjoint output regions.

After all CPUs complete, the TB requires six accepted FFT instructions and
12288 FFT AXI write responses per tile. It then reads every output word through
the tile's external AXI port and writes one raw CSV per tile/case. These are
memory readbacks, not UART parsing or an internal FFT-output tap.

## Run

The reference interpreter needs NumPy. The build interpreter needs the existing
PyYAML and pyelftools packages, RISC-V GCC, prepared dependencies and VCS.
`--build-python` defaults to `python3`; it can differ from the NumPy interpreter.
The server already has NumPy in `/opt/anaconda3/bin/python`.

```bash
cd /home/user06/work/xinkailai/cheshire
make chs-fft-ddr-test CHS_FFT_PYTHON=/opt/anaconda3/bin/python \
  CHS_FFT_ARGS="--tiles 2 --dmas 2"

# Repeat with unchanged hardware/TB; firmware and inputs are still rebuilt.
make chs-fft-ddr-test CHS_FFT_PYTHON=/opt/anaconda3/bin/python \
  CHS_FFT_ARGS="--tiles 2 --dmas 2 --reuse-build"

# Optional real-input IFFT, using the same compiled hardware.
/opt/anaconda3/bin/python util/run_fft_ddr_test.py \
  --tiles 2 --dmas 2 --mode ifft --reuse-build
```

The common runner's `--testbench fft-ddr` selects this dedicated top and its
mode-specific source target. It requires external SPM loading. The FFT wrapper
always uses that mode. Application returns, synchronous exceptions, timeouts,
coefficient-file availability and hardware/dependency checks remain mandatory.

## Numerical Contract

NumPy consumes the exact quantized int16 input, not the pre-quantization wave.
For FFT the reference is `numpy.fft.fft(input) / 32`. For IFFT it is
`numpy.fft.ifft(input) * 4096 / 32`, matching the core's unnormalized positive-sign
transform and fixed hardware scaling. Outputs must be in natural frequency order.
The low/high 32 bits of each DDR word are signed real/imaginary values, each a
sign extension of the FFT core's signed 23-bit output.

With `reference = r`, `actual = y` and `error = y-r`:

- `RMSE = sqrt(mean(abs(error)**2))`, in output integer units.
- `max_abs_error = max(abs(error))`, complex magnitude in output integer units.
- `SNR = 10*log10(sum(abs(r)**2) / sum(abs(error)**2))`; larger is better.
- `relative_rms_error_db = -SNR`; more negative is better.
- `relative_error_percent = 100*sqrt(sum(abs(error)**2)/sum(abs(r)**2))`.

Acceptance uses the fixed reference directly. Gain fitting is diagnostic only;
no automatic rescaling, bin reordering or conjugation is allowed to make a case
pass. Defaults require SNR >= 40 dB and maximum absolute error <= 128. Override
with `--min-snr-db` and `--max-abs-error` to impose a different specification.
These are digital arithmetic error metrics, not an ADC ENOB measurement.

## Artifacts

Default output is `target/sim/build/fft_ddr/`:

- `sim/`: compiled VCS executable/cache, application ELF/disassembly, logs and
  common per-tile result report.
- `fft/` or `ifft/`: `tileN.input.bin`, three `tileN.jobJ.csv` DDR dumps per tile,
  `tileN.CASE.comparison.csv`, and NumPy `.npz` arrays containing input, actual,
  reference and error.
- Each direction has `summary.json`, `summary.csv`, `simulation.log` and a copy
  of `sim_result.json`. Input/output hashes and the NumPy version are recorded.

The parser rejects partial dumps, duplicate/misordered bins, wrong addresses,
unknown data and invalid output sign extension. Numerical regressions also
reject doubled gain, reversed bins and conjugated FFT results.

```bash
PYTHONDONTWRITEBYTECODE=1 /opt/anaconda3/bin/python -m unittest discover \
  -s util/tests -p test_fft_ddr.py -v
```

## FFT Verification Record (2026-10-17)

The Make entry passed with two tiles and two shared DMA engines. Each tile
completed all three FFT cases, six accelerator command handshakes and 12288
FFT AXI write responses. The TB then read back all 12288 output words per tile.
The measured FFT results use the fixed reference and default limits above:

| Tile | Case | SNR (dB) | Relative RMS Error (dB) | RMSE | Maximum Absolute Error |
|---:|---|---:|---:|---:|---:|
| 0 | Cosine | 83.0904 | -83.0904 | 0.8117 | 4.5634 |
| 0 | Sine | 83.0571 | -83.0571 | 0.8148 | 5.7537 |
| 0 | Random real | 78.4917 | -78.4917 | 1.6348 | 4.7081 |
| 1 | Cosine | 83.0904 | -83.0904 | 0.8117 | 4.5634 |
| 1 | Sine | 83.0571 | -83.0571 | 0.8148 | 5.7537 |
| 1 | Random real | 78.6394 | -78.6394 | 1.6152 | 4.9802 |

All seven NumPy/parser tests passed. The system Python suite also passed its
34 other tests (the seven NumPy tests are skipped there because that interpreter
does not have NumPy). A fresh common SPM Hello simulation passed after adding
the specialized runner option. Dependency HEADs/status remain unchanged and
the simulation reports confirm hardware content was unchanged during execution.
The same two-tile matrix also passed real-input IFFT using `--reuse-build`,
verifying direction selection through scratch6 and reuse of the compiled TB.
Its six case reports are saved separately under `ifft/summary.json`.
