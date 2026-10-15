#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(pwd)"
out="$root/target/private_spm_fixture"
mkdir -p "$out"
bender script vcs --no-default-target -t rtl -t simulation -t test -t cva6 \
  -t cv64a6_imafdchsclic_sv39_wb -t exclude_first_pass_decoder -D VCS -D SYNTHESIS \
  --vlogan-args="-full64 -timescale=1ns/1ps" > "$out/compile_deps.sh"
bash util/prepare_shared_dma_deps.sh
bash util/prepare_shared_dma_plic.sh --regenerate
cd "$out"
bash compile_deps.sh > build.log 2>&1
vlogan -full64 -sverilog -timescale=1ns/1ps \
  "$root/target/sim/src/tb_private_spm_fixture.sv" >> build.log 2>&1
for config in ${PRIVATE_SPM_FIXTURE_CONFIGS:-0 1 2 3 4 5}; do
  [[ "$config" =~ ^[0-5]$ ]] || exit 2
  vcs -full64 -timescale=1ns/1ps -top tb_private_spm_fixture \
    -pvalue+tb_private_spm_fixture.SelectedCfg="$config" \
    "$root/target/sim/src/elfloader.cpp" -o "simv$config" >> build.log 2>&1
  timeout --signal=TERM --kill-after=5s 120s "./simv$config" > "run$config.log" 2>&1
  if grep -E 'Fatal:|Error:' "run$config.log"; then exit 1; fi
  grep "PASS Cheshire fixture config=$config " "run$config.log"
done
