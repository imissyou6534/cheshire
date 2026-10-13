#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
idma_path="$(bender path idma)"
patch_path="$(pwd)/util/patches/idma-0.6.3-page-width.patch"
for source_file in target/rtl/idma_legalizer_rw_axi.sv \
    src/backend/tpl/idma_legalizer.sv.tpl target/rtl/idma_generated.sv; do
  if git -C "$idma_path" apply --include="$source_file" --reverse --check "$patch_path" 2>/dev/null; then
    continue
  fi
  git -C "$idma_path" apply --include="$source_file" --check "$patch_path"
  git -C "$idma_path" apply --include="$source_file" "$patch_path"
  printf 'Applied iDMA page-width fix to %s\n' "$source_file"
done
atomics_path="$(bender path axi_riscv_atomics)"
for patch_name in reservation-width sequential-state; do
  atomics_patch="$(pwd)/util/patches/axi-riscv-atomics-0.8.2-$patch_name.patch"
  if ! git -C "$atomics_path" apply --reverse --check "$atomics_patch" 2>/dev/null; then
    git -C "$atomics_path" apply --check "$atomics_patch"
    git -C "$atomics_path" apply "$atomics_patch"
    printf 'Applied shared LR/SC %s fix\n' "$patch_name"
  fi
done
