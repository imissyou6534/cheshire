#!/usr/bin/env bash
set -euo pipefail
if [[ -f /opt/rh/devtoolset-11/enable ]]; then
  source /opt/rh/devtoolset-11/enable
fi
cd "$(dirname "$0")/.."
bash util/prepare_shared_dma_deps.sh
build_root="${DMA_TEST_BUILD_ROOT:-$(pwd)/target/shared_dma_verify}"
mkdir -p "$build_root"
gcc -std=c11 -Wall -Wextra -Werror -Isw/include \
  target/sim/src/shared_dma_driver_test.c -o "$build_root/driver_test"
"$build_root/driver_test"
bender script verilator -p idma -p register_interface -p axi_riscv_atomics -t rtl -t simulation \
  --compilation-mode common > "$build_root/deps.f"
test_shapes="${DMA_TEST_SHAPES:-1:1 2:1 2:2 4:2 3:2 2:3}"
for shape in $test_shapes; do
  [[ "$shape" =~ ^[1-9][0-9]*:[1-9][0-9]*$ ]] || { printf 'Invalid shape: %s\n' "$shape" >&2; exit 2; }
  tiles="${shape%:*}"
  engines="${shape#*:}"
  addr_width="${DMA_TEST_ADDR_WIDTH:-32}"
  random_stalls="${DMA_TEST_RANDOM_STALLS:-0}"
  out="$build_root/${tiles}x${engines}_a${addr_width}_r${random_stalls}"
  mkdir -p "$out"
  verilator --binary --timing --assert -j 4 -CFLAGS -std=c++20 -Wno-fatal --top-module tb_shared_dma \
    -GNumTiles="$tiles" -GNumDmas="$engines" -GAddrWidth="$addr_width" \
    -GRandomStalls="$random_stalls" --Mdir "$out/obj" \
    -f "$build_root/deps.f" \
    hw/shared_dma/cheshire_dma_pkg.sv hw/shared_dma/dma_tile_frontend.sv \
    hw/shared_dma/dma_job_scheduler.sv hw/shared_dma/dma_engine_wrap.sv \
    hw/shared_dma/shared_dma_pool.sv hw/shared_dma/global_ddr_fabric.sv \
    hw/shared_dma/cheshire_shared_dma_subsystem.sv \
    target/sim/src/tb_shared_dma.sv > "$out/build.log" 2>&1
  "$out/obj/Vtb_shared_dma" > "$out/run.log" 2>&1
  grep 'PASS shared DMA' "$out/run.log"
done
