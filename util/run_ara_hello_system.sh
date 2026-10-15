#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
root="$(pwd -P)"
tiles="${ARA_HELLO_TILES:-1}"
engines="${ARA_HELLO_ENGINES:-1}"
[[ "$tiles" =~ ^[1-9][0-9]*$ && "$engines" =~ ^[1-9][0-9]*$ ]] || exit 2
((tiles <= 64 && engines <= 65536)) || exit 2
out="$root/target/ara_hello_system/${tiles}x${engines}"
mkdir -p "$out/elf"
exec 9>"$out/runner.lock"
flock -n 9 || { printf 'Ara hello runner is already active.\n' >&2; exit 2; }
bender script vcs --no-default-target -t rtl -t cva6 -t cv64a6_imafdchsclic_sv39_wb \
  -t exclude_first_pass_decoder -D VCS -D SYNTHESIS \
  --vlogan-args="-full64 -timescale=1ns/1ps -assert svaext" > "$out/compile_deps.sh"
bash util/prepare_shared_dma_deps.sh
bash util/prepare_shared_dma_plic.sh --regenerate
cc="${RISCV_CC:-riscv64-unknown-elf-gcc}"
prefix="${cc%gcc}"
ara_root="$(bender path ara)"
"$cc" -march=rv64gcv_zifencei -mabi=lp64d -mcmodel=medany -O2 -g -Wall -Wextra \
  -ffreestanding -fno-builtin -fno-common -ffunction-sections -fdata-sections \
  -nostdlib -nostartfiles -Isw/include -Isw/deps/printf \
  -I"$ara_root/cheshire/sw/include" \
  -Wl,-Lsw/link -Wl,--no-relax -Wl,--gc-sections -Tsw/link/ara_hello_spm.ld \
  sw/lib/crt0.S sw/tests/vector_helloworld.c sw/lib/dif/clint.c \
  sw/lib/dif/uart.c sw/deps/printf/printf.c -o "$out/elf/tile0.elf" \
  > "$out/firmware.log" 2>&1
for ((tile=1;tile<tiles;tile++)); do
  cp "$out/elf/tile0.elf" "$out/elf/tile$tile.elf"
done
"${prefix}objdump" -d "$out/elf/tile0.elf" > "$out/elf/tile0.dump"
"${prefix}readelf" -l "$out/elf/tile0.elf" > "$out/elf/tile0.segments"
buffer="$("${prefix}nm" --defined-only "$out/elf/tile0.elf" | awk '$3 == "buf" {print $1}')"
[[ "$buffer" =~ ^[0-9a-fA-F]+$ ]] || { printf 'ELF buf symbol missing.\n' >&2; exit 1; }
grep -q 'vle8.v' "$out/elf/tile0.dump"
grep -q 'vse8.v' "$out/elf/tile0.dump"
axi_root="$(bender path axi)"
reg_root="$(bender path register_interface)"
cd "$out"
bash compile_deps.sh > build.log 2>&1
vlogan -full64 -sverilog -timescale=1ns/1ps -assert svaext +define+VCS +define+SYNTHESIS \
  +incdir+"$axi_root/include" +incdir+"$reg_root/include" +incdir+"$root/hw/include" \
  "$axi_root/src/axi_sim_mem.sv" "$root/target/sim/src/tb_cheshire_pkg.sv" \
  "$root/target/sim/src/tb_private_spm_system.sv" >> build.log 2>&1
vcs -full64 -timescale=1ns/1ps -assert svaext -top tb_private_spm_system \
  -pvalue+tb_private_spm_system.NumTiles="$tiles" -pvalue+tb_private_spm_system.NumDmas="$engines" \
  -pvalue+tb_private_spm_system.AraHello=1 -pvalue+tb_private_spm_system.ExternalWrite=0 \
  -pvalue+tb_private_spm_system.DdrOwner=0 -pvalue+tb_private_spm_system.DmaSmoke=0 \
  -CFLAGS "-std=c++11 -I$root/target/sim/src" \
  "$root/target/sim/src/private_spm_elfloader.cpp" -o simv >> build.log 2>&1
if grep -E 'Fatal:|Error:|Error-\[' build.log; then exit 1; fi
status=0
timeout --signal=TERM --kill-after=10s "${ARA_HELLO_WALL_TIMEOUT:-900}s" \
  ./simv +ELF_DIR="$out/elf" +ARA_HELLO_BUF="$buffer" > run.log 2>&1 || status=$?
if ((status != 0)) || grep -Eq 'Fatal:|Error:|Error-\[' run.log; then
  tail -n 30 run.log
  exit 1
fi
grep -q "^PASS Ara hello real CVA6 $tiles tiles x $engines DMA engines$" run.log
for ((tile=0;tile<tiles;tile++)); do
  grep -q "^PASS ARA UART tile=$tile bytes=21$" run.log
done
grep -E '^ARA UART|^ARA evidence|^PASS ARA UART|^PASS Ara' run.log
status=0
timeout --signal=TERM --kill-after=10s "${ARA_HELLO_WALL_TIMEOUT:-900}s" \
  ./simv +ELF_DIR="$out/elf" +ARA_HELLO_BUF="$buffer" +ARA_HELLO_NEGATIVE=1 \
  > run_checker_negative.log 2>&1 || status=$?
[[ "$status" != 124 && "$status" != 137 ]] || exit 1
grep -q 'ARA hello buffer mismatch tile=0 byte=1' run_checker_negative.log
if grep -q '^PASS Ara hello' run_checker_negative.log; then exit 1; fi
printf 'PASS Ara hello negative: independent buffer checker rejected byte 1\n'
status=0
timeout --signal=TERM --kill-after=10s "${ARA_HELLO_WALL_TIMEOUT:-900}s" \
  ./simv +ELF_DIR="$out/elf" +ARA_HELLO_BUF="$buffer" +ARA_HELLO_UART_NEGATIVE=1 \
  > run_uart_negative.log 2>&1 || status=$?
[[ "$status" != 124 && "$status" != 137 ]] || exit 1
grep -q '^ARA UART tile=0: Hello Vector World!' run_uart_negative.log
grep -q 'FAIL ARA UART tile=0: string mismatch' run_uart_negative.log
if grep -Eq '^PASS ARA UART tile=0|^PASS Ara hello' run_uart_negative.log; then exit 1; fi
printf 'PASS Ara hello UART negative: actual output printed, wrong expectation rejected\n'
