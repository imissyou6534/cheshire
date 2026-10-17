# Preserve Prepared Dependencies

The `.bender` repositories contain required local development commits.
Do not reset them to the revisions in `Bender.lock`.

- Do not invoke the system `bender` directly, including `checkout`, `update`,
  `script`, `sources` or path queries.
- Use `python3 util/rom_bender.py path PACKAGE` for paths and its `script TOOL`
  interface for source lists. It resolves all dependencies as existing paths.
- Do not checkout, switch, reset, clean, pull, patch or regenerate dependency
  repositories unless the user explicitly requests the relevant dependency change.
- Do not bypass Make dependency protection or recreate `.chs_deps` to enable
  old bootstrap workflows. Missing prepared artifacts must be reported.
- Inspect old scripts before running them; several still mutate dependencies.
- Preserve unrelated worktree changes and compare dependency HEADs and status
  before and after build-tool changes.

See [docs/dependency_protection.md](docs/dependency_protection.md) for protected
Make behavior and its limits.
