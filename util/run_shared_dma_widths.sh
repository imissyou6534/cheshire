#!/usr/bin/env bash
set -euo pipefail
if [[ -f /opt/rh/devtoolset-11/enable ]]; then source /opt/rh/devtoolset-11/enable; fi
cd "$(dirname "$0")/.."
root="$(pwd)"
out="${SHARED_WIDTH_BUILD_ROOT:-$root/target/shared_width_verify}"
mkdir -p "$out"
python3 util/rom_bender.py script verilator -p idma -p register_interface -p axi_riscv_atomics \
  -t rtl -t simulation --compilation-mode common > "$out/deps_all.f"
# The protected resolver includes the Cheshire root; retain only this unit's dependencies.
awk '/^[+]/ || /\/checkouts\/(axi-|axi_riscv_atomics-|idma-|common_cells-|common_verification-|register_interface-|tech_cells_generic-)/' \
  "$out/deps_all.f" > "$out/deps.f"
for widths in ${SHARED_WIDTH_SHAPES:-128:128:256 128:64:256 64:64:64}; do
  IFS=: read -r tile dma shared <<< "$widths"
  legacy=0
  if [[ "$widths" == 64:64:64 ]]; then legacy=1; fi
  build="$out/${tile}_${dma}_${shared}"
  mkdir -p "$build"
  verilator --binary --timing --assert -j 4 -CFLAGS -std=c++20 -Wno-fatal \
    --top-module tb_shared_dma_widths -GTileWidth="$tile" -GDmaWidth="$dma" \
    -GSharedWidth="$shared" -GLegacyDefaults="$legacy" --Mdir "$build/obj" \
    -f "$out/deps.f" \
    hw/shared_dma/cheshire_dma_pkg.sv hw/shared_dma/dma_tile_frontend.sv \
    hw/shared_dma/dma_job_scheduler.sv hw/shared_dma/dma_engine_wrap.sv \
    hw/shared_dma/shared_dma_pool.sv hw/shared_dma/global_ddr_fabric.sv \
    hw/shared_dma/cheshire_shared_dma_subsystem.sv target/sim/src/tb_shared_dma_widths.sv \
    > "$build/build.log" 2>&1
  "$build/obj/Vtb_shared_dma_widths" > "$build/run.log" 2>&1
  grep 'PASS shared widths' "$build/run.log"
done
