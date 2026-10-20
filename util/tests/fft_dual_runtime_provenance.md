# Dual-sample runtime FFT/IFFT arithmetic

Generated on 2026-10-19 from the original C++ generator at
`/home/user06/work/dblclockfft`, Git base
`3378b77d83a98b06184656a5cb9b54e50dfe4485`.
Existing edits in `Makefile`, `sw/Makefile`, `sw/bldstage.cpp`, `sw/bldstage.h`,
`sw/butterfly.cpp`, and `sw/fftgen.cpp` were preserved. The before-state diff is
`/tmp/cheshire-wide-fft-before.diff`, SHA-256
`f13d4f82f2ab280b8ba9e5c8b390f288a9259b66580ad5f19b38f3ec684218c3`.

The original `sw/fftgen -U -2 -f 4096 -n 16 -p 0` rejected this configuration:
`ERR: -U currently supports only the single-clock -1 datapath`.

This change edits only `sw/fftgen.cpp` in the original generator. It enables
`-U -2`, connects runtime direction to both generic stage lanes, and selects the
quarter-stage +/-j rotation from direction. The existing software multipliers
and bit reversal supply 4096 natural-order samples, two per enabled clock.
Direction must remain stable for a task and reset must separate direction changes.

The modified source SHA-256 is
`f668e834164e372edfb5b5c99a97b3cf0c8441a073240b306588d7643b9a8632`.
The complete after-state diff, including the preserved earlier work, is saved at
`/tmp/cheshire-dual-runtime-after.diff`, SHA-256
`e6a4b969dfe6aeb8fb993fac2c406b42cc7342cbeb02682898f8bd076d311816`.
The original generator source was downloaded before editing into
`C:/Users/C/AppData/Local/Temp/dblclockfft-dual-runtime-20261019/sw`.
Both before/after diff snapshots were also downloaded beside that directory.

Generation uses a new directory, never the historical generated core:

```sh
make -C /home/user06/work/dblclockfft/sw fftgen
/home/user06/work/dblclockfft/sw/fftgen -U -2 -f 4096 -n 16 -p 0 -S \
  -d /tmp/cheshire-dual-runtime-20261019 \
  -a /tmp/cheshire-dual-runtime-20261019/fftifftsize.h
```

Imported files are `fftifftmain.v`, `fftstage.v`, `butterfly.v`, `longbimpy.v`,
`bimpy.v`, `qtrstage.v`, `laststage.v`, `bitreverse.v`, `convround.v`, `hwbfly.v`,
`fftifftsize.h`, and 20 `cmem_e*.hex`/`cmem_o*.hex` files from size 8192 through 16.
The generated ROM names follow the upstream two-lane naming convention. Unused
historical single-lane ROM files remain. The only imported-top adaptations retain
`CHESHIRE_FFT_COEFF_ROOT` and document task-stable direction.

Interface: `fftifftmain(i_clk,i_reset,i_ce,i_inverse,i_left[31:0],i_right[31:0],`
`o_left[45:0],o_right[45:0],o_sync)`. Each complex input packs signed real16 above
imag16; output packs signed real23 above imag23. FFT uses negative exponent and
IFFT positive exponent; both have gain 1/32 relative to the unnormalized transform.
The first pair is captured with `o_sync` at enabled-cycle index 4292, before the
edge advancing the pipeline. Subsequent pairs are captured on every enabled edge.

Run independent arithmetic verification with:

```sh
bash util/tests/run_fft_dual_runtime_numeric.sh /home/user06/work/dblclockfft
```

The test freshly builds Verilator 5.052 from the generator's output. It compares
all 4096 complex bins with an independent double-precision radix-2 reference for
DC, shifted complex impulse, real multitone, and deterministic complex random
input, each in FFT and IFFT direction, with contiguous and paused enables.
It also requires paused results to be bit-identical and output/sync to hold during
pauses. All 16 frames passed. Maximum observed component error was 4.58595 output
units (acceptance limit 24); DC was exact. First-pair timing was identical across
all cases. No historical destructive verification scripts were used.

The final fresh runner directory was `/tmp/cheshire-fft-dual-numeric.CFZdl9`.
Its exit status was zero: all 16 frames passed, imported arithmetic and all 20
coefficient tables matched generation after ignoring generated filename comments,
and the imported top passed Verilator lint with the coefficient-root macro.

Read-only review found no issue in the requested synchronous-reset, 4096-point,
16-bit-input, software-multiply configuration. Both generic lanes conjugate the
forward ROM twiddle for IFFT; both quarter lanes receive task-stable direction,
with the odd quarter lane selecting the opposite +/-j rotation. CE gates data,
address, and sync progression. Direction changes while frames overlap are outside
the two-lane interface contract. The tests verify this exact generation; they do
not establish numeric coverage for every generator size, precision, rounding,
asynchronous-reset, or multiplier setting. `-U` continues to require `-p 0`.
