# Prepared Dependency Protection

The `.bender` checkouts contain local development commits and changes.
`Bender.lock` identifies package names, but its revisions must not be used to
reset these working copies. Normal builds consume the prepared checkouts.

The version inventory in `docs/prepared_dependency_commits.json` records the
prepared dependency HEADs for this source revision. It is a provenance record,
not a checkout instruction or an automatic replacement for `Bender.lock`.

## Make Behavior

- `Makefile` and `cheshire.mk` resolve the project root without Bender.
- `cheshire.mk` overrides and exports `BENDER` as `util/rom_bender.py`, including
  when a caller supplies `make BENDER=bender`.
- `path PACKAGE` and `check` inspect existing directories without invoking
  Bender. Missing or ambiguous checkouts fail before build recipes run.
- `script TOOL` uses a temporary manifest/database, `--local` and path overrides
  for every existing locked package. Bender may print `Updating ... -> path`;
  these messages refer to temporary dependency resolution, not Git checkout.
- `checkout`, `update`, other raw commands and directory/configuration override
  options are rejected by this interface.

The `.bender/.chs_deps` stamp is no longer included or automatically rebuilt.
An explicit request for it fails, even when the stamp already exists.
`chs-clean-deps` and its `clean-deps` alias also fail before deleting anything.
Dependency generator Make fragments are not imported; missing generated RTL or
preparation stamps stop the build rather than regenerating local dependencies.
CLINT, OpenTitan, AXI RT and AXI VGA regeneration targets explicitly fail.

The legacy `chs-shared-dma-test`, `chs-shared-dma-system-test` and
`chs-private-spm-system-test` entries stop with a protection diagnostic because
their scripts perform raw Bender calls, patching or regeneration. These entries
are not aliases for the common tests: specialized DMA/cache/IRQ checks have not
all been migrated. Their scripts remain historical tools and must not be run
directly against this checkout without explicit dependency-change authorization.

## Supported Builds

Existing commands for `chs-multitile-sim`, `chs-rom-autoboot` and the VCU118
multi-tile FPGA targets remain available. Vivado, VCS and Questa source-list
recipes use the protected interface; automatic dependency patching was removed.
The existing PLIC `--check` is read-only and remains enabled.

```bash
make help
python3 util/rom_bender.py path cva6
make chs-multitile-sim CHS_SIM_BOOT=spm CHS_SIM_TILES=2 CHS_SIM_DMAS=2
make -n chs-xilinx-multi-tile-rom-vcu118 CHS_NUM_TILES=1 CHS_NUM_DMAS=1
```

This protects the project Make entry points. It does not intercept a manually
invoked system `bender`, a separate dependency repository's own Makefile, or
arbitrary shell commands. There is no dependency-reset opt-out Make variable;
intentional dependency changes require a separate, explicit maintenance action.

Protection regressions run in disposable fixtures with a fake Bender, never
against the real dependency repositories:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s util/tests \
  -p test_make_dependency_guard.py -v
```
