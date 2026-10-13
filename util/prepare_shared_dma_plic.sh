#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Regenerate only after the main verification owner authorizes it and all
# consumers of the generated PLIC (including the VCS compile) have stopped.
set -euo pipefail

usage() {
  printf 'Usage: bash util/prepare_shared_dma_plic.sh [--check|--regenerate]\n'
  printf 'Default: read-only validation. --regenerate requires build-owner authorization.\n'
}

fail() {
  printf 'PLIC: %s\n' "$*" >&2
  exit 1
}

[[ $# -le 1 ]] || { usage >&2; exit 2; }
mode="${1:---check}"
case "$mode" in
  --check|--regenerate) ;;
  --help|-h) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

cd "$(dirname "${BASH_SOURCE[0]}")/.."
root="$(pwd -P)"
config="$root/hw/rv_plic.cfg.hjson"
export PYTHONDONTWRITEBYTECODE=1
command -v bender >/dev/null || fail 'bender is required; dependencies must already be checked out.'
command -v python3 >/dev/null || fail 'python3 with hjson is required.'

python3 - "$config" <<'PY'
import sys
import hjson

with open(sys.argv[1], encoding="utf-8") as stream:
    config = hjson.load(stream)
expected = {"src": 64, "target": 2, "prio": 7, "nonstd_regs": 0}
if config.get("instance_name") != "rv_plic" or config.get("param_values") != expected:
    sys.exit("PLIC: root config must specify rv_plic, src=64, target=2, prio=7, nonstd_regs=0.")
PY

otp_path="$(bender path opentitan_peripherals)"
plic_path="$otp_path/src/rv_plic"
header="$otp_path/sw/include/rv_plic_regs.h"
plic_files=(
  data/rv_plic.hjson data/rv_plic.ipconfig.hjson
  rtl/rv_plic.sv rtl/rv_plic_gateway.sv rtl/rv_plic_target.sv
  rtl/rv_plic_reg_pkg.sv rtl/rv_plic_reg_top.sv
)

validate_plic() {
  local file
  for file in "${plic_files[@]}"; do
    [[ -s "$1/$file" ]] || { printf 'PLIC: missing %s\n' "$1/$file" >&2; return 1; }
  done
  python3 - "$1" "$2" <<'PY'
from pathlib import Path
import re
import sys
import hjson


def require_number(text, pattern, expected, label):
    values = re.findall(pattern, text, flags=re.MULTILINE)
    if len(values) != 1 or int(values[0], 0) != expected:
        raise ValueError(f"{label}: expected {expected}, found {values}")


try:
    ip_path = Path(sys.argv[1])
    package = (ip_path / "rtl/rv_plic_reg_pkg.sv").read_text(encoding="utf-8")
    package = re.sub(r"/\*.*?\*/|//[^\n]*", "", package, flags=re.DOTALL)
    header = Path(sys.argv[2]).read_text(encoding="utf-8")
    for name, expected in (("NumSrc", 64), ("NumTarget", 2), ("PrioWidth", 3), ("BlockAw", 26)):
        require_number(package, rf"^\s*parameter\s+int\s+{name}\s*=\s*(\d+)\s*;",
                       expected, f"rv_plic_reg_pkg::{name}")
    defines = {
        "PARAM_NUM_SRC": 64, "PARAM_NUM_TARGET": 2, "PARAM_PRIO_WIDTH": 3,
        "PRIO58_REG_OFFSET": 0xE8, "PRIO63_REG_OFFSET": 0xFC,
        "IP_0_REG_OFFSET": 0x1000, "IP_1_REG_OFFSET": 0x1004,
        "IE0_0_REG_OFFSET": 0x2000, "IE0_1_REG_OFFSET": 0x2004,
        "IE1_0_REG_OFFSET": 0x2080, "IE1_1_REG_OFFSET": 0x2084,
        "THRESHOLD0_REG_OFFSET": 0x200000, "CC0_REG_OFFSET": 0x200004,
        "THRESHOLD1_REG_OFFSET": 0x201000, "CC1_REG_OFFSET": 0x201004,
        "MSIP0_REG_OFFSET": 0x3FFFFF8, "ALERT_TEST_REG_OFFSET": 0x3FFFFFC,
    }
    for name, expected in defines.items():
        require_number(header, rf"^\s*#define\s+RV_PLIC_{name}\s+(0[xX][0-9a-fA-F]+|\d+)\s*$",
                       expected, f"RV_PLIC_{name}")
    with (ip_path / "data/rv_plic.ipconfig.hjson").open(encoding="utf-8") as stream:
        config = hjson.load(stream)
    expected = {"src": 64, "target": 2, "prio": 7, "nonstd_regs": 0}
    if config.get("instance_name") != "rv_plic" or config.get("param_values") != expected:
        raise ValueError("generated ipconfig does not match the root PLIC configuration")
except (OSError, ValueError) as error:
    sys.exit(f"PLIC: {error}")
PY
}

if validate_plic "$plic_path" "$header"; then
  printf 'PLIC: already valid (64 sources, M/S contexts 0/1); no regeneration.\n'
  exit 0
fi
[[ "$mode" == --regenerate ]] || fail 'stale generated PLIC; use --regenerate only after build-owner review/authorization.'

command -v flock >/dev/null || fail 'flock is required.'
command -v mktemp >/dev/null || fail 'mktemp is required.'
ipgen="$otp_path/util/ipgen.py"
regtool="$(bender path register_interface)/vendor/lowrisc_opentitan/util/regtool.py"
[[ -f "$ipgen" && -f "$regtool" ]] || fail 'existing OpenTitan ipgen.py and register_interface regtool.py are required.'
[[ -f "$otp_path/.generated" ]] || fail 'initialize normal OpenTitan dependencies first (.generated marker missing).'
export PYTHONPATH="$(dirname "$regtool")${PYTHONPATH:+:$PYTHONPATH}"

# Share the existing make lock without creating a success marker on failure.
exec 9<"$otp_path/.generated"
flock -x 9
if validate_plic "$plic_path" "$header"; then
  printf 'PLIC: another preparer generated the required PLIC; no regeneration.\n'
  exit 0
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/cheshire-shared-dma-plic.XXXXXXXX")"
printf 'PLIC: generation scratch retained at %s\n' "$scratch"
cp "$config" "$scratch/rv_plic.cfg.hjson"

# Use the otp.mk generator entry directly, limited to PLIC. The fresh output
# path avoids --force and otp.mk's deletion of its dependency-local gen folder.
python3 "$ipgen" generate -C "$plic_path/tpl/rv_plic" \
  -o "$scratch/rv_plic" -c "$scratch/rv_plic.cfg.hjson"
python3 "$regtool" --cdefines "$scratch/rv_plic/data/rv_plic.hjson" \
  > "$scratch/rv_plic_regs.h"
validate_plic "$scratch/rv_plic" "$scratch/rv_plic_regs.h"
cmp -s "$config" "$scratch/rv_plic.cfg.hjson" || fail 'root PLIC config changed during generation; rerun after review.'

for file in "${plic_files[@]}"; do
  cp --no-preserve=mode "$scratch/rv_plic/$file" "$plic_path/$file"
done
cp --no-preserve=mode "$scratch/rv_plic.cfg.hjson" "$plic_path/rv_plic.cfg.hjson"
cp --no-preserve=mode "$scratch/rv_plic_regs.h" "$header"
validate_plic "$plic_path" "$header"
# Dependencies were already initialized; keep the normal make stamp current.
touch "$otp_path/.generated"
printf 'PLIC: prepared 64 sources, M/S contexts 0/1, DMA ID 58, and matching SW header.\n'
