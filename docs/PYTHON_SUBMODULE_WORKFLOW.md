# Python Companion Submodule Workflow (Optional)

Use this when you want protocol code/tests to be validated against the companion repo in one workspace.

## Goal

- Keep FCSP protocol spec/RTL ownership in this repo.
- Reuse Python FCSP simulator artifacts during adapter validation in `python-imgui-esc-configurator`.

## Recommended layout

- `sim/python_fcsp/` remains the FCSP Python golden-model source in this repo.
- Optional companion checkout path:
  - `external/python-imgui-esc-configurator/` (git submodule)

## Typical workflow

1. Update protocol simulator code/tests in `sim/python_fcsp/`.
2. Run local simulator + cocotb benches in this repo.
3. Pull or update companion repo via submodule.
4. Run companion adapter tests that consume the protocol simulator behavior.
5. Record parity results and any deltas before merge.

## One-command workflow (recommended)

Use:

- `scripts/fcsp_companion_sync.sh`

This performs, in order:

1. submodule update/init for `external/python-imgui-esc-configurator`
2. canonical FCSP simulator tests in this repo
3. cocotb parser smoke in this repo
4. focused FCSP-facing companion tests

This keeps protocol ownership canonical while still validating companion consumption in one pass.

## Notes

- Prefer importing protocol behavior through stable module APIs.
- Avoid duplicating FCSP protocol-spec files in companion repos.
- If submodule setup is not desired, a sibling checkout with scripted test paths is acceptable.
