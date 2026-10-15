#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
project_root="$(pwd)"
[[ "${DMA_SYSTEM_SKIP_BUILD:-0}" != 1 ]] || {
  printf 'Build reuse is unsupported; run a fresh RTL build.\n' >&2
  exit 2
}
tiles="${DMA_SYSTEM_TILES:-4}"
engines="${DMA_SYSTEM_ENGINES:-2}"
smoke="${DMA_SYSTEM_SMOKE:-0}"
negative="${DMA_SYSTEM_NEGATIVE:-none}"
case "$negative" in
  none) negative_id=0; cache_negative=0; irq_negative=0 ;;
  cache) negative_id=1; cache_negative=1; irq_negative=0 ;;
  irq) negative_id=2; cache_negative=0; irq_negative=1 ;;
  *) printf 'Invalid DMA_SYSTEM_NEGATIVE\n' >&2; exit 2 ;;
esac
if [[ "$smoke" == 1 ]]; then
  [[ "$negative" == none ]] || exit 2
  mode=boot
  firmware=sw/tests/shared_dma_system.c
else
  mode="$negative"
  firmware=sw/tests/shared_dma_system_workload.c
fi
out="$project_root/target/shared_dma_system/${tiles}x${engines}/$mode"
mkdir -p "$out/elf"
cc="${RISCV_CC:-riscv64-unknown-elf-gcc}"
for ((t=0;t<tiles;t++)); do
  base=$((0x80000000+t*0x100000))
  "$cc" -march=rv64gc_zifencei -mabi=lp64d -mcmodel=medany -O2 -g -Wall -Wextra \
    -ffreestanding -fno-builtin -fno-common -nostdlib -nostartfiles -Isw/include \
    -DTILE_ID="$t" -DNUM_TILES="$tiles" -DCACHE_NEGATIVE="$cache_negative" \
    -DIRQ_NEGATIVE="$irq_negative" -DDMA_TIMEOUT_CYCLES="${DMA_SYSTEM_TIMEOUT_CYCLES:-200000}" \
    -Wl,-Lsw/link -Wl,--no-relax \
    -Wl,--defsym=__tile_base="$base" -Tsw/link/shared_dma_system.ld \
    sw/tests/shared_dma_system_entry.S sw/lib/crt0.S "$firmware" \
    -o "$out/elf/tile$t.elf"
done
axi_root="$(bender path axi)"
reg_root="$(bender path register_interface)"
bender script vcs --no-default-target -t rtl -t cva6 -t cv64a6_imafdchsclic_sv39_wb \
  -t exclude_first_pass_decoder -D VCS -D SYNTHESIS --vlogan-args="-full64 -timescale=1ns/1ps" \
  > "$out/compile_deps.sh"
# Bender can restore lockfile revisions while generating the source list.
bash util/prepare_shared_dma_deps.sh
bash util/prepare_shared_dma_plic.sh --regenerate
cd "$out"
{
  bash compile_deps.sh > build.log 2>&1
  vlogan -full64 -sverilog -timescale=1ns/1ps +define+VCS +define+SYNTHESIS +incdir+"$axi_root/include" \
    +incdir+"$reg_root/include" +incdir+"$project_root/hw/include" "$axi_root/src/axi_sim_mem.sv" \
    "$project_root/target/sim/src/tb_shared_dma_system.sv" >> build.log 2>&1
  vcs -full64 -timescale=1ns/1ps tb_shared_dma_system \
    -pvalue+tb_shared_dma_system.NumTiles="$tiles" -pvalue+tb_shared_dma_system.NumDmas="$engines" \
    -pvalue+tb_shared_dma_system.BootSmoke="$smoke" -pvalue+tb_shared_dma_system.NegativeCase="$negative_id" \
    "$project_root/target/sim/src/elfloader.cpp" -o simv >> build.log 2>&1
}
./simv +ELF_DIR="$out/elf" > run.log 2>&1
if grep -E 'Fatal:|Error:' run.log; then exit 1; fi
grep 'PASS real CVA6' run.log
