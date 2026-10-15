#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

check_log() {
  local log="$1"
  if grep -Eq 'Fatal:|Error:|Error-\[|(^|[[:space:]])FATAL([[:space:]:]|$)|Assertion.*(failed|failure)' "$log"; then
    printf 'Private SPM simulation reported a fatal/error: %s\n' "$log" >&2
    return 1
  fi
  grep -Eq '^PASS private SPM real CVA6 [0-9]+ tiles x [0-9]+ engines$' "$log" || {
    printf 'Private SPM PASS marker missing: %s\n' "$log" >&2
    return 1
  }
}
if [[ "${1:-}" == --check-log ]]; then
  [[ $# == 2 && -f "$2" ]] || exit 2
  check_log "$2"
  exit
fi
[[ $# == 0 ]] || { printf 'Usage: bash util/run_private_spm_system.sh [--check-log LOG]\n' >&2; exit 2; }
cd "$(dirname "${BASH_SOURCE[0]}")/.."
project_root="$(pwd -P)"
tiles="${PRIVATE_SPM_TILES:-2}"
engines="${PRIVATE_SPM_ENGINES:-1}"
expected_phase="${PRIVATE_SPM_EXPECTED_PHASE:-9}"
timeout_ns="${PRIVATE_SPM_TIMEOUT_NS:-50000000}"
wall_timeout="${PRIVATE_SPM_WALL_TIMEOUT:-900}"
external_write="${PRIVATE_SPM_EXTERNAL_WRITE:-1}"
ddr_owner="${PRIVATE_SPM_DDR_OWNER:-1}"
dma_smoke="${PRIVATE_SPM_DMA:-1}"
for value in "$tiles" "$engines" "$expected_phase" "$timeout_ns" "$wall_timeout"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || { printf 'Private SPM parameters must be positive decimal integers.\n' >&2; exit 2; }
done
[[ "$external_write" =~ ^[01]$ && "$dma_smoke" =~ ^[01]$ && "$ddr_owner" =~ ^[01]$ ]] || {
  printf 'PRIVATE_SPM_EXTERNAL_WRITE and PRIVATE_SPM_DMA must be zero or one.\n' >&2
  exit 2
}
[[ "${PRIVATE_SPM_SKIP_BUILD:-0}" == 0 ]] || {
  printf 'Build reuse is unsupported; private SPM always compiles every group.\n' >&2
  exit 2
}
out="$project_root/target/private_spm_system/${tiles}x${engines}"
mkdir -p "$out/elf"
exec 9>"$out/runner.lock"
flock -n 9 || { printf 'Private SPM runner already active: %s\n' "$out" >&2; exit 2; }
trap 'status=$?; if ((status)); then printf "Private SPM failed (%s); logs: %s\n" "$status" "$out" >&2; fi' EXIT
for command in bender vlogan vcs timeout; do command -v "$command" >/dev/null; done
for source in sw/tests/private_spm_atomic.c sw/link/private_spm.ld target/sim/src/tb_cheshire_pkg.sv; do
  [[ -s "$source" ]] || { printf 'Missing parent/firmware contract file: %s\n' "$source" >&2; exit 1; }
done
# Resolve lockfile checkouts before applying dependency-local fixes/generation.
bender script vcs --no-default-target -t rtl -t cva6 -t cv64a6_imafdchsclic_sv39_wb \
  -t exclude_first_pass_decoder -D VCS -D SYNTHESIS \
  --vlogan-args="-full64 -timescale=1ns/1ps -assert svaext" > "$out/compile_deps.sh"
bash util/prepare_shared_dma_deps.sh
bash util/prepare_shared_dma_plic.sh --regenerate
cc="${RISCV_CC:-riscv64-unknown-elf-gcc}"
for ((t=0;t<tiles;t++)); do
  "$cc" -march=rv64gc_zifencei -mabi=lp64d -mcmodel=medany -O2 -g -Wall -Wextra \
    -ffreestanding -fno-builtin -fno-common -nostdlib -nostartfiles -Isw/include \
    -DTILE_ID="$t" -DNUM_TILES="$tiles" -DNUM_DMAS="$engines" \
    -DPRIVATE_SPM_EXTERNAL_WRITE="$external_write" -DPRIVATE_SPM_DMA="$dma_smoke" \
    -DPRIVATE_SPM_DDR_OWNER="$ddr_owner" \
    -Wl,-Lsw/link -Wl,--no-relax -Tsw/link/private_spm.ld \
    sw/lib/crt0.S sw/tests/private_spm_atomic.c -o "$out/elf/tile$t.elf"
done
axi_root="$(bender path axi)"
reg_root="$(bender path register_interface)"

cd "$out"
bash compile_deps.sh > build.log 2>&1
vlogan -full64 -sverilog -timescale=1ns/1ps -assert svaext +define+VCS +define+SYNTHESIS \
  +incdir+"$axi_root/include" +incdir+"$reg_root/include" +incdir+"$project_root/hw/include" \
  "$axi_root/src/axi_sim_mem.sv" "$project_root/target/sim/src/tb_cheshire_pkg.sv" \
  "$project_root/target/sim/src/tb_private_spm_system.sv" >> build.log 2>&1
vcs -full64 -timescale=1ns/1ps -assert svaext -top tb_private_spm_system \
  -pvalue+tb_private_spm_system.NumTiles="$tiles" \
  -pvalue+tb_private_spm_system.NumDmas="$engines" \
  -pvalue+tb_private_spm_system.ExpectedPhase="$expected_phase" \
  -pvalue+tb_private_spm_system.ExternalWrite="$external_write" \
  -pvalue+tb_private_spm_system.DdrOwner="$ddr_owner" \
  -pvalue+tb_private_spm_system.DmaSmoke="$dma_smoke" \
  -CFLAGS "-std=c++11 -I$project_root/target/sim/src" \
  "$project_root/target/sim/src/private_spm_elfloader.cpp" -o simv >> build.log 2>&1
if grep -Eq 'Fatal:|Error:|Error-\[' build.log; then
  printf 'Private SPM build reported an error; see %s/build.log\n' "$out" >&2
  exit 1
fi
timeout --signal=TERM --kill-after=10s "${wall_timeout}s" \
  ./simv +ELF_DIR="$out/elf" +TIMEOUT_NS="$timeout_ns" > run.log 2>&1
check_log run.log
grep '^PASS private SPM real CVA6 ' run.log
