#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
generator_dir=${1:-/home/user06/work/dblclockfft}
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/cheshire-fft-dual-numeric.XXXXXX")
printf 'Fresh arithmetic verification directory: %s\n' "$build_dir"
make -C "$generator_dir/sw" fftgen
"$generator_dir/sw/fftgen" -U -2 -f 4096 -n 16 -p 0 -S \
    -d "$build_dir" -a "$build_dir/fftifftsize.h"

cd "$build_dir"
verilator -Wno-fatal --cc --exe --build -j "${JOBS:-8}" \
    --top-module fftifftmain --Mdir obj_numeric \
    fftifftmain.v fftstage.v butterfly.v longbimpy.v bimpy.v \
    qtrstage.v laststage.v bitreverse.v convround.v \
    "$repo_dir/util/tests/fft_dual_runtime_numeric.cpp" \
    > build_numeric.log 2>&1 || { tail -80 build_numeric.log; exit 1; }
./obj_numeric/Vfftifftmain

# The imported top only adds the existing Cheshire coefficient-root macro and
# documents task-stable direction. Ignore generated absolute filename comments.
for source in fftstage.v butterfly.v longbimpy.v bimpy.v qtrstage.v \
        laststage.v bitreverse.v convround.v hwbfly.v cmem_[eo]*.hex; do
    cmp <(sed '/^\/\/ Filename:/d' "$source") \
        <(sed '/^\/\/ Filename:/d' "$repo_dir/hw/fft/rtl/$source")
done
printf 'PASS imported arithmetic modules and coefficient ROMs match original generator\n'

# Compile the imported top as well, resolving its root macro to the repo's ROMs.
verilator --lint-only -Wno-fatal --top-module fftifftmain \
    "+define+CHESHIRE_FFT_COEFF_ROOT=\"$repo_dir/hw/fft/rtl\"" \
    "$repo_dir/hw/fft/rtl/fftifftmain.v" fftstage.v butterfly.v \
    longbimpy.v bimpy.v qtrstage.v laststage.v bitreverse.v convround.v
