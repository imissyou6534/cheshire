# Prepared Dependency Protection

The `.bender` checkouts contain local development commits and changes.
`Bender.yml` and `Bender.lock` pin the maintained IP forks and the unchanged
upstream packages. Their revisions must not be used to reset existing working
copies automatically. Normal builds consume the prepared checkouts.

## Maintained IP Revisions

Seven IPs are hosted under `imissyou6534` on GitHub. The root manifest pins full
commit SHAs; root `.bender.yml` repeats these choices as transitive overrides so
that dependencies such as Ara cannot select a different upstream CVA6.

| Package | Repository | Development branch | Pinned commit |
| --- | --- | --- | --- |
| ara | imissyou6534/ara | dsa/ara-v0 | a51caad9302cbf74ff4119f4ebac28a835b4ae3b |
| cva6 | imissyou6534/cva6 | dsa/cva6-v0 | 8c12cc603ac0feda3fde4c2f464f5d4a085052dd |
| idma | imissyou6534/iDMA | dsa/idma-v0 | 122eea2cc6576fee60c6cd8e7161c967eab6e2d9 |
| axi_riscv_atomics | imissyou6534/axi_riscv_atomics | dsa/axi_riscv_atomics-v0 | b80a8f92a6d9f16b49c3a13cbae5262525408c45 |
| opentitan_peripherals | imissyou6534/opentitan_peripherals | dsa/opentitan_peripherals-v0 | 1d5ff8b7c99a58aacc128e8d3248bd1577f5e377 |
| clint | imissyou6534/clint | dsa/clint-v0 | 0d93c54b7669cd0f17f4194e2a6f093ede31a08b |
| axi_rt | imissyou6534/axi_rt | dsa/axi_rt-v0 | 3239986094107a3c71ed3568ade86e51d5c29d17 |

The remaining 19 Bender packages retain their previous locked source,
revision and dependency list. FPnew's old `version: 0.2.3` metadata is corrected
to `null`: it is selected by `pulp-v0.2.3`, not a `v0.2.3` semantic-version tag;
its commit remains unchanged. SSH access to GitHub is needed to fetch
the maintained repositories. No private key path is committed in these files;
configure SSH for the machine performing a fresh fetch.

The protected build interface still resolves prepared paths by package name;
it does not assert that their HEADs or dirty source match the lock. Check those
explicitly during releases. Moving these existing Git checkouts to new cache
directory names is not necessary for this migration.

The older inventory in `docs/prepared_dependency_commits.json` and the snapshot
under `deps/prepared/2026-10-20/` are historical provenance records. They predate
the Ara VID repair and are not automatic replacements for the current lock.

## Fresh Environment Limitations

Pinning Git revisions does not reproduce all prepared artifacts. Builds require
the actual RTL and software headers, not untracked `.generated` completion
markers. Software submodules, external simulation models and tool versions must
also be provisioned.
Successful source-list and dependency-protection checks do not establish that
a clean network checkout can build every target. See
`owned_dependency_migration_2026-10-21.md` for the migration validation scope.

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
Dependency generator Make fragments are not imported; missing required generated
RTL stops the build rather than regenerating local dependencies. The five
`.generated` markers formerly required for CLINT, OpenTitan, AXI RT, AXI VGA and
serial_link are no longer hardware or software prerequisites. OpenTitan header
prerequisites name the four actual register headers. Local IP commits and
worktree modifications remain allowed; ordinary builds do not enforce equality
with the locked revision. Existing markers need not be removed.
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
