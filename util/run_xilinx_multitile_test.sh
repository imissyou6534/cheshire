#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
root="$(pwd -P)"
[[ -s target/xilinx/src/multi_tile_top_xilinx.sv ]] || {
  printf 'FAIL: missing FPGA multi-tile top\n' >&2
  exit 1
}
out="$root/target/xilinx_multitile_test/1x1"
mkdir -p "$out"
exec 9>"$out/runner.lock"
flock -n 9 || exit 2
bender script vcs --no-default-target -t rtl -t simulation -t test -t cva6 \
  -t cv64a6_imafdcv_sv39 -t exclude_first_pass_decoder -D VCS -D SYNTHESIS \
  --vlogan-args="-full64 -timescale=1ns/1ps -assert svaext" > "$out/compile_deps.sh"
bash util/prepare_shared_dma_deps.sh
bash util/prepare_shared_dma_plic.sh --regenerate
cc="${RISCV_CC:-riscv64-unknown-elf-gcc}"
ara_root="$(bender path ara)"
"$cc" -march=rv64gcv_zifencei -mabi=lp64d -mcmodel=medany -O2 -g \
  -ffreestanding -fno-builtin -fno-common -ffunction-sections -fdata-sections \
  -nostdlib -nostartfiles -Isw/include -Isw/deps/printf -I"$ara_root/cheshire/sw/include" \
  -Wl,-Lsw/link -Wl,--no-relax -Wl,--gc-sections -Tsw/link/ara_hello_spm.ld \
  sw/lib/crt0.S sw/tests/vector_helloworld.c sw/lib/dif/clint.c sw/lib/dif/uart.c \
  sw/deps/printf/printf.c -o "$out/hello.elf" > "$out/firmware.log" 2>&1
buffer="$("${cc%gcc}nm" --defined-only "$out/hello.elf" | awk '$3=="buf" {print $1}')"
[[ "$buffer" =~ ^[0-9a-fA-F]+$ ]] || exit 1
axi_root="$(bender path axi)"
reg_root="$(bender path register_interface)"
common_root="$(bender path common_cells)"
cd "$out"
bash compile_deps.sh > build.log 2>&1
vlogan -full64 -sverilog -timescale=1ns/1ps -assert svaext \
  +define+VCS+SYNTHESIS+TARGET_VCU118+ARA+FFT_ACCEL+NR_LANES=2+VLEN=2048 \
  +incdir+"$axi_root/include" +incdir+"$reg_root/include" \
  +incdir+"$common_root/include" \
  +incdir+"$root/hw/include" +incdir+"$root/target/xilinx/src" \
  "$root/target/sim/src/xilinx_multitile_test_models.sv" \
  "$root/target/xilinx/src/dram_wrapper_xilinx.sv" \
  "$root/target/xilinx/src/multi_tile_top_xilinx.sv" \
  "$root/target/sim/src/tb_xilinx_multitile.sv" >> build.log 2>&1
vcs -full64 -timescale=1ns/1ps -assert svaext -top tb_xilinx_multitile \
  "$root/target/sim/src/elfloader.cpp" -o simv >> build.log 2>&1
if grep -Eq 'Error:|Error-\[|Fatal:' build.log; then tail -n 35 build.log; exit 1; fi
status=0
timeout --signal=TERM --kill-after=10s 1200s ./simv +BINARY="$out/hello.elf" +BUF="$buffer" \
  > run.log 2>&1 || status=$?
if ((status)) || grep -Eq 'Error:|Error-\[|Fatal:|Cannot open file' run.log; then tail -n 45 run.log; exit 1; fi
grep -q '^PASS Xilinx multi-tile board smoke 1 tile x 1 DMA$' run.log
grep -q '^PASS FPGA UART passive ACK$' run.log
grep -E '^FPGA UART|^FPGA evidence|^PASS FPGA|^PASS Xilinx' run.log
vcs -full64 -timescale=1ns/1ps -assert svaext -top tb_xilinx_multitile \
  -pvalue+tb_xilinx_multitile.NumTiles=2 -pvalue+tb_xilinx_multitile.NumDmas=2 \
  "$root/target/sim/src/elfloader.cpp" -o simv_links >> build.log 2>&1
status=0
timeout --signal=TERM --kill-after=10s 120s ./simv_links +LINKS_ONLY > run_links.log 2>&1 || status=$?
if ((status)) || grep -Eq 'Error:|Error-\[|Fatal:|Cannot open file' run_links.log; then
  tail -n 35 run_links.log
  exit 1
fi
grep '^PASS Xilinx multi-tile JTAG/UART links 2 tiles x 2 DMA$' run_links.log
