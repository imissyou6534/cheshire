#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
root="$(pwd -P)"
out="$root/target/rom_autoboot"
app=""
negative=0
print_snapshot=0
print_record=0
while (($#)); do
  case "$1" in
    --out|--app)
      (($# >= 2)) || exit 2
      if [[ "$1" == --out ]]; then out="$2"; else app="$2"; fi
      shift 2 ;;
    --bad-checksum) negative=1; shift ;;
    --print-snapshot) print_snapshot=1; shift ;;
    --print-record) print_record=1; shift ;;
    *) printf 'Usage: bash util/build_rom_autoboot.sh [--out DIR] [--app ELF] [--bad-checksum] [--print-snapshot|--print-record]\n' >&2; exit 2 ;;
  esac
done
((print_snapshot + print_record <= 1)) || exit 2
mkdir -p "$out"
out="$(cd "$out" && pwd -P)"
exec 9>"$out/build.lock"
flock -n 9 || { printf 'ROM autoboot firmware builder already active\n' >&2; exit 2; }
cc="${RISCV_CC:-riscv64-unknown-elf-gcc}"
prefix="${cc%gcc}"
if [[ -z "$app" ]]; then
  ara_root="$(bender path ara)"
  "$cc" -march=rv64gcv_zifencei -mabi=lp64d -mcmodel=medany -O2 -g \
    -ffreestanding -fno-builtin -fno-common -ffunction-sections -fdata-sections \
    -nostdlib -nostartfiles -Isw/include -Isw/deps/printf -I"$ara_root/cheshire/sw/include" \
    -Wl,-Lsw/link -Wl,--no-relax -Wl,--gc-sections -Tsw/link/ara_hello_spm.ld \
    sw/lib/crt0.S sw/tests/vector_helloworld.c sw/lib/dif/clint.c sw/lib/dif/uart.c \
    sw/deps/printf/printf.c -o "$out/application.elf" > "$out/application.log" 2>&1
  app="$out/application.elf"
else
  app="$(realpath -e "$app")"
fi
python3 util/gen_rom_payload.py --elf "$app" --header "$out/rom_payload.h" \
  --manifest "$out/payload.json"
flags=(-DROM_AUTOBOOT_BAD_CHECKSUM=0)
if ((negative)); then flags=(-DROM_AUTOBOOT_BAD_CHECKSUM=1); fi
"$cc" -march=rv64gc_zifencei -mabi=lp64d -mcmodel=medany -Os -g -Wall -Wextra \
  -ffreestanding -fno-builtin -fno-common -fno-stack-protector \
  -ffunction-sections -fdata-sections -nostdlib -nostartfiles -I"$out" \
  "${flags[@]}" -Wl,-Lsw/link -Wl,--no-relax -Wl,--gc-sections \
  -Thw/bootrom/autoboot/autoboot.ld hw/bootrom/autoboot/start.S \
  hw/bootrom/autoboot/boot_main.c -o "$out/bootrom.elf" > "$out/bootrom.log" 2>&1
"${prefix}objcopy" -O binary "$out/bootrom.elf" "$out/bootrom.bin"
"${prefix}objdump" -d "$out/bootrom.elf" > "$out/bootrom.dump"
"${prefix}readelf" -l "$out/bootrom.elf" > "$out/bootrom.segments"
size="$(wc -c < "$out/bootrom.bin")"
((size <= 16384)) || { printf 'ROM image exceeds 16 KiB\n' >&2; exit 1; }
temporary="$(mktemp "$out/.rom_image.XXXXXXXX")"
trap 'rm -f -- "$temporary"; if [[ -n "${snapshot_temporary:-}" ]]; then rm -f -- "$snapshot_temporary"; fi' EXIT
python3 util/gen_bootrom.py --sv-module cheshire_bootrom "$out/bootrom.bin" > "$temporary"
digest="$(sha256sum "$temporary" | cut -d' ' -f1)"
mkdir -p "$out/snapshots"
snapshot="$out/snapshots/$digest.sv"
if [[ -e "$snapshot" ]]; then
  [[ "$(sha256sum "$snapshot" | cut -d' ' -f1)" == "$digest" ]] || {
    printf 'ROM snapshot was modified: %s\n' "$snapshot" >&2
    exit 1
  }
else
  snapshot_temporary="$(mktemp "$out/snapshots/.new.XXXXXXXX")"
  cp "$temporary" "$snapshot_temporary"
  chmod 444 "$snapshot_temporary"
  mv -- "$snapshot_temporary" "$snapshot"
fi
if ! cmp -s "$temporary" "$out/cheshire_bootrom.sv"; then
  mv -f -- "$temporary" "$out/cheshire_bootrom.sv"
fi
# Keep the test oracle paired with its exact ROM even after another build.
record="$(python3 - "$out/payload.json" "$snapshot" "$negative" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile

manifest, snapshot, negative = sys.argv[1:]
data = json.loads(Path(manifest).read_text())
data.update(rom_snapshot=snapshot, bad_checksum=bool(int(negative)))
content = (json.dumps(data, sort_keys=True, indent=2) + "\n").encode()
record = Path(snapshot).parent / (hashlib.sha256(content).hexdigest() + ".json")
if record.exists():
    if record.read_bytes() != content:
        raise SystemExit("ROM build record was modified: " + str(record))
else:
    fd, temporary = tempfile.mkstemp(prefix=".record.", dir=record.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
        os.chmod(temporary, 0o444)
        os.replace(temporary, record)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
print(record)
PY
)"
printf 'ROM autoboot image: %s (%s bytes, checksum-negative=%s)\n' "$out/cheshire_bootrom.sv" "$size" "$negative" >&2
if ((print_snapshot)); then printf '%s\n' "$snapshot"; fi
if ((print_record)); then printf '%s\n' "$record"; fi
