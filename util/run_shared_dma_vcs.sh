#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
project_root="$(pwd)"
bash util/prepare_shared_dma_deps.sh
out="$project_root/target/shared_dma_verify/vcs"
mkdir -p "$out"
bender script flist-plus -p idma -p register_interface -p axi_riscv_atomics \
  -t rtl -t simulation -D VCS --compilation-mode common > "$out/deps_all.f"
# This unused ERROR_HANDLING module embeds a concurrent assertion in always_comb,
# which VCS rejects. The tested engines use NO_ERROR_HANDLING and bus error capture.
sed '\|/src/backend/idma_error_handler.sv$|d' "$out/deps_all.f" > "$out/deps.f"
sources=(cheshire_dma_pkg dma_tile_frontend dma_job_scheduler dma_engine_wrap \
  shared_dma_pool global_ddr_fabric cheshire_shared_dma_subsystem)
rtl=()
for module in "${sources[@]}"; do rtl+=("$project_root/hw/shared_dma/$module.sv"); done
cd "$out"
vcs -full64 -sverilog -timescale=1ns/1ps -top tb_shared_dma -f deps.f \
  "${rtl[@]}" "$project_root/target/sim/src/tb_shared_dma.sv" -o simv > build.log 2>&1
./simv > run.log 2>&1
grep 'PASS shared DMA' run.log
