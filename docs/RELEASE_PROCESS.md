# Release Process

This project uses lightweight milestone tags for simulation/protocol progression.

## Tag format

Use annotated tags with one of these prefixes:

- `sim-v<major>.<minor>.<patch>` for simulation milestone releases
- `proto-v<major>.<minor>.<patch>` for FCSP protocol milestone releases

Examples:

- `sim-v0.1.0`
- `proto-v1.0.0`

## When to cut a tag

### Simulation milestone (`sim-v*`)

Create after:

- `sim/test-fcsp-smoke-cocotb` passes
- `sim/test-serial-mux-cocotb` passes
- docs consistency gate passes

### Protocol milestone (`proto-v*`)

Create after:

- protocol/channel/address docs are updated
- changelog entry added
- simulation gates pass

## Commands

Create annotated tag:

- `git tag -a sim-v0.1.0 -m "sim milestone: mux watchdog + core smoke stable"`
- `git tag -a proto-v1.0.0 -m "protocol milestone: channel/address map stabilized"`

Push tag:

- `git push origin sim-v0.1.0`
- `git push origin proto-v1.0.0`

## Changelog requirement

Every milestone tag must have a corresponding `## [Unreleased]` entry promoted in `CHANGELOG.md`.
