#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
root="$(pwd -P)"
[[ -s target/xilinx/src/multi_tile_rom_top_xilinx.sv ]] || {
  printf 'FAIL: missing ROM-autoboot FPGA top\n' >&2
  exit 1
}
out="$root/target/rom_autoboot_test/1x1"
mkdir -p "$out"
exec 9>"$out/runner.lock"
flock -n 9 || exit 2
record="$(bash util/build_rom_autoboot.sh --print-record)"
snapshot="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["rom_snapshot"])' "$record")"
negative_snapshot="$(bash util/build_rom_autoboot.sh --out "$out/negative" --bad-checksum --print-snapshot)"
buffer="$(python3 -c 'import json, sys; print(format(json.load(open(sys.argv[1]))["symbols"]["buf"], "x"))' "$record")"
python3 util/rom_bender.py script vcs --no-default-target -t rtl -t simulation -t test -t cva6 -t rom_autoboot \
  -t cv64a6_imafdcv_sv39 -t exclude_first_pass_decoder -D VCS -D SYNTHESIS \
  --vlogan-args="-full64 -timescale=1ns/1ps -assert svaext" > "$out/compile_deps.sh"
# Dependency patches and generated RTL must be prepared before this test.
bash util/prepare_shared_dma_plic.sh --check
axi_root="$(bender path axi)"
reg_root="$(bender path register_interface)"
common_root="$(bender path common_cells)"
cd "$out"
bash compile_deps.sh > build.log 2>&1
vlogan -full64 -sverilog -timescale=1ns/1ps -assert svaext \
  +define+VCS+SYNTHESIS+TARGET_VCU118+ARA+FFT_ACCEL+NR_LANES=2+VLEN=2048 \
  +incdir+"$axi_root/include" +incdir+"$reg_root/include" +incdir+"$common_root/include" \
  +incdir+"$root/hw/include" +incdir+"$root/target/xilinx/src" \
  "$snapshot" \
  "$root/target/sim/src/xilinx_multitile_test_models.sv" \
  "$root/target/xilinx/src/dram_wrapper_xilinx.sv" \
  "$root/target/xilinx/src/multi_tile_top_xilinx.sv" \
  "$root/target/xilinx/src/multi_tile_rom_top_xilinx.sv" \
  "$root/target/sim/src/tb_rom_autoboot.sv" >> build.log 2>&1
check_run() {
  local executable="$1" log="$2" expected="$3" status=0
  timeout --signal=TERM --kill-after=10s 1200s "./$executable" +BUF="$buffer" > "$log" 2>&1 || status=$?
  if ((status)) || grep -Eq 'Fatal:|Error:|Error-\[|Cannot open file' "$log"; then
    tail -n 40 "$log"
    exit 1
  fi
  grep -q "$expected" "$log"
  grep -E '^ROM UART|^ROM evidence|^PASS ROM' "$log"
}
vcs -full64 -timescale=1ns/1ps -assert svaext -top tb_rom_autoboot \
  "$root/target/sim/src/elfloader.cpp" -o simv >> build.log 2>&1
check_run simv run.log '^PASS ROM autoboot real CVA6 1 tiles x 1 DMA no external program load$'
vcs -full64 -timescale=1ns/1ps -assert svaext -top tb_rom_autoboot \
  -pvalue+tb_rom_autoboot.NumTiles=2 \
  "$root/target/sim/src/elfloader.cpp" -o simv_two >> build.log 2>&1
check_run simv_two run_two.log '^PASS ROM autoboot real CVA6 2 tiles x 1 DMA no external program load$'
vlogan -full64 -sverilog "$negative_snapshot" >> build.log 2>&1
vcs -full64 -timescale=1ns/1ps -assert svaext -top tb_rom_autoboot \
  -pvalue+tb_rom_autoboot.ExpectFailure=1 \
  "$root/target/sim/src/elfloader.cpp" -o simv_negative >> build.log 2>&1
check_run simv_negative run_negative.log '^PASS ROM autoboot checksum negative rejected before application$'
