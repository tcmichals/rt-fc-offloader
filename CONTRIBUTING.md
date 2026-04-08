# Contributing to rt-fc-offloader

Thanks for contributing.

## 1) Branch and scope rules

- Keep each PR focused on one concern (RTL, simulation, documentation, or tooling).
- Avoid unrelated diffs in a single PR.
- Rebase/sync your branch before opening PR.

## 2) Commit message convention

Use subsystem-prefixed commit subjects:

- `rtl: ...`
- `sim: ...`
- `docs: ...`
- `build: ...`
- `ci: ...`
- `chore: ...`

Example:

- `rtl: add serial inactivity watchdog fallback in wb_serial_dshot_mux`

## 3) Required local verification before PR

From repo root:

- `bash scripts/check_docs_consistency.sh`

From `sim/` (with Python env active):

- `make test-fcsp-smoke-cocotb`
- `make test-serial-mux-cocotb`

Include commands and pass/fail summary in the PR description.

## 4) Docs contract

If you change architecture/protocol behavior:

- update `docs/FCSP_PROTOCOL.md`
- update `docs/SYSTEM_OVERVIEW.md`
- update `docs/TOP_LEVEL_BLOCK_DIAGRAM.md`

When relevant, document both absolute and relative register addresses.

## 5) Ownership and review

- CODEOWNERS enforces review ownership for `rtl/`, `sim/`, and `docs/`.
- PRs should not be merged unless required CI checks pass.

## 6) Branch protection (repository setting)

Configure GitHub branch protection for `main`:

- Require pull request before merge
- Require status checks to pass
- Require review from Code Owners
- Dismiss stale approvals when new commits are pushed

> Note: branch protection is configured in GitHub repository settings (not in-repo file).
