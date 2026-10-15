#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
root="$(pwd -P)"
tiles="${SCRATCH_TEST_TILES:-4}"
engines="${SCRATCH_TEST_ENGINES:-2}"
[[ "$tiles" =~ ^[1-9][0-9]*$ && "$engines" =~ ^[1-9][0-9]*$ ]] || exit 2
((tiles >= 2 && tiles <= 64)) || exit 2
out="$root/target/scratch_multitile/${tiles}x${engines}"
mkdir -p "$out/elf"
exec 9>"$out/runner.lock"
flock -n 9 || { printf 'SCRATCH runner already active\n' >&2; exit 2; }
for tool in bender vlogan vcs timeout flock; do command -v "$tool" >/dev/null; done
cc="${RISCV_CC:-riscv64-unknown-elf-gcc}"
bender script vcs --no-default-target -t rtl -t cva6 -t cv64a6_imafdchsclic_sv39_wb \
  -t exclude_first_pass_decoder -D VCS -D SYNTHESIS \
  --vlogan-args="-full64 -timescale=1ns/1ps -assert svaext" > "$out/compile_deps.sh"
bash util/prepare_shared_dma_deps.sh
bash util/prepare_shared_dma_plic.sh --regenerate
for ((t=0;t<tiles;t++)); do
  "$cc" -march=rv64gc_zifencei -mabi=lp64d -mcmodel=medany -O2 -g -Wall -Wextra -Werror \
    -ffreestanding -fno-builtin -fno-common -nostdlib -nostartfiles -Isw/include \
    -DTILE_ID="$t" -DNUM_TILES="$tiles" -Wl,-Lsw/link -Wl,--no-relax \
    -Tsw/link/scratch_multitile.ld sw/lib/crt0.S sw/tests/scratch_multitile.c \
    -o "$out/elf/tile$t.elf"
done
axi_root="$(bender path axi)"
reg_root="$(bender path register_interface)"
cd "$out"
bash compile_deps.sh > build.log 2>&1
vlogan -full64 -sverilog -timescale=1ns/1ps -assert svaext +define+VCS +define+SYNTHESIS \
  +incdir+"$axi_root/include" +incdir+"$reg_root/include" +incdir+"$root/hw/include" \
  "$axi_root/src/axi_sim_mem.sv" "$root/target/sim/src/tb_cheshire_pkg.sv" \
  "$root/target/sim/src/tb_scratch_multitile.sv" >> build.log 2>&1
vcs -full64 -timescale=1ns/1ps -assert svaext -top tb_scratch_multitile \
  -pvalue+tb_scratch_multitile.NumTiles="$tiles" -pvalue+tb_scratch_multitile.NumDmas="$engines" \
  -CFLAGS "-std=c++11 -I$root/target/sim/src" \
  "$root/target/sim/src/private_spm_elfloader.cpp" -o simv >> build.log 2>&1
if grep -Eq 'Fatal:|Error:|Error-\[' build.log; then exit 1; fi
# Prove that malformed real CPU stores are rejected before accepting the positive run.
for negative in data address none; do
  case "$negative" in data) id=1;; address) id=2;; none) id=0;; esac
  log="run_$negative.log"
  status=0
  timeout --signal=TERM --kill-after=10s "${SCRATCH_TEST_WALL_TIMEOUT:-900}s" \
    ./simv +ELF_DIR="$out/elf" +NEGATIVE="$id" > "$log" 2>&1 || status=$?
  if [[ "$negative" == none ]]; then
    ((status == 0)) || { tail -n 25 "$log"; exit 1; }
    if grep -Eq 'Fatal:|Error:|Error-\[' "$log"; then tail -n 25 "$log"; exit 1; fi
    grep -E '^SCRATCH evidence |^PASS SCRATCH real CVA6 ' "$log"
    grep -q "^PASS SCRATCH real CVA6 $tiles tiles x $engines engines$" "$log"
  else
    [[ "$status" != 124 && "$status" != 137 ]] || { tail -n 25 "$log"; exit 1; }
    grep -q "SCRATCH $negative mismatch tile=1 write=7" "$log" || { tail -n 25 "$log"; exit 1; }
    if grep -q '^PASS SCRATCH real CVA6 ' "$log"; then exit 1; fi
    printf 'PASS SCRATCH negative %s: checker rejected tile 1 write 7\n' "$negative"
  fi
done
