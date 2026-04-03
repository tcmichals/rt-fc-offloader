# rt-fc-offloader

Real-time flight-controller offloader repository for FPGA/RTL-centered transport, framing, and deterministic I/O paths.

## Companion repository

The Python ESC configurator and host-side GUI tooling live in the companion repo:

- `python-imgui-esc-configurator`: `git@github.com:tcmichals/python-imgui-esc-configurator.git`

This repo (`rt-fc-offloader`) and the Python repo are intended to be developed in parallel.

## Protocol direction

Current project strategy:

- **MSP path** is used first to validate GUI workflows, UX parity, and ESC feature behavior quickly.
- **FCSP path** is the target runtime transport for deterministic FPGA-friendly framing/performance.

## Protocol role split (explicit)

- **PICO project**: remains on **MSP** for rapid GUI/feature validation and parity checks.
- **FPGA offloader project (`rt-fc-offloader`)**: uses **FCSP** as the runtime protocol.
	- **Primary transport**: SPI
	- **Secondary/alternate transport**: Serial

Both paths should preserve equivalent user-facing behavior while FCSP provides the deterministic transport model for offloader deployment.

Canonical spec:

- `docs/FCSP_PROTOCOL.md` (**single source of truth; no duplicated copies in companion repos**)

## Repository requirements and GitHub TODO

- `REQUIREMENTS.md` — clear offloader/FCSP requirements and quality gates
- `GITHUB_TODO.md` — active GitHub task list for this repository
- `docs/FPGA_BLOCK_DESIGN.md` — FCSP FPGA block architecture and module boundaries
- `docs/TOP_LEVEL_BLOCK_DIAGRAM.md` — quick-reference top-level FPGA datapath/control diagram

In short: MSP validates features quickly; FCSP is the long-term high-performance path.
