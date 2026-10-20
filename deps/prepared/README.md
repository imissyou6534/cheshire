# Prepared Dependency Snapshot

`2026-10-20/manifest.json` records the exact prepared state of all 26 packages
under `.bender/git/checkouts`, including their original `Bender.lock` revisions,
actual HEADs, tree IDs, source URLs, file hashes, and untracked-file inventories.

Seven packages have local development commits: Ara, CVA6, AXI RISC-V atomics,
AXI RT, CLINT, iDMA, and OpenTitan peripherals. Their incremental Git bundles
preserve the local commits, and binary-capable patches show the complete source
delta from each locked revision. Packages whose HEAD equals their locked
revision are identified in the manifest and need no incremental bundle.

The bundles require the history of the corresponding locked revision. They
preserve all local commits but are not full offline mirrors of upstream history.
The supplementary tar archive preserves every nonignored untracked dependency
file, including existing object files, generation stamps, debug source backups,
and the existing `.bender/.chs_deps` marker. These files remain untracked in the
live checkouts. Git metadata, ignored build caches, and upstream source trees
are not duplicated in this snapshot.

## Verification

Check each bundle from a repository containing its recorded locked revision:

```bash
git -C /path/to/package bundle verify /path/to/package.bundle
```

The manifest contains SHA-256 hashes for every bundle, patch, and archived file.
Snapshot export verified that dependency HEADs, status, and the complete
RTL/dependency fingerprint did not change.

## Explicit Recovery Into A New Checkout

Do not run recovery over the existing prepared checkout. Normal builds must
continue to use `python3 util/rom_bender.py` as documented in
`../../docs/dependency_protection.md`.

To reconstruct a package in a new, disposable directory, first obtain its
recorded locked revision from the source URL in the manifest. For a package
with local commits, import the bundle and select its recorded HEAD:

```bash
git -C /new/package fetch /absolute/path/package.bundle HEAD
git -C /new/package switch --detach RECORDED_HEAD
```

Verify `git rev-parse HEAD` and `git rev-parse 'HEAD^{tree}'` against the manifest.
Use the manifest's checkout paths when assembling a fresh project `.bender`
layout. The supplementary archive contains project-relative `.bender/...` paths
and may be extracted only into that new project after verifying its hash and
contents. Preserve the existing prepared checkouts throughout recovery.

The snapshot includes the current known VID behavior; it does not implement a
VID fix. See `../../docs/ara_mask_repro_diagnosis_2026-10-19.md`.
