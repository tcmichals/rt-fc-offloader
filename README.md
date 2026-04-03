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

Canonical spec:

- `docs/FCSP_PROTOCOL.md` (**single source of truth; no duplicated copies in companion repos**)

In short: MSP validates features quickly; FCSP is the long-term high-performance path.
