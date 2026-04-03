# rt-fc-offloader

Real-time flight-controller offloader repository for FPGA/RTL-centered transport, framing, and deterministic I/O paths.

## What this project is

`rt-fc-offloader` is the hardware/RTL side of an offload architecture for flight stacks such as **INAV** and **Betaflight**.

Goal:

- keep high-level flight-control software and operator tooling flexible
- move strict real-time transport/parsing/I/O timing work into deterministic FPGA logic

In this project model, the **Linux-based flight-controller side** (host software side) handles high-level control logic and UX-facing behavior, while this repository implements the deterministic offloader datapath and control-plane plumbing.

## Offload intent (INAV/Betaflight)

The project is designed so INAV/Betaflight-style command intents can be translated into FCSP control operations and executed through a predictable offloader pipeline.

Examples of what we offload or make deterministic:

- framed byte-stream parsing/resynchronization
- CRC verification and frame routing
- bounded queueing/backpressure behavior
- hardware-timed output engines (DSHOT/PWM/NeoPixel paths)

This keeps timing-critical behavior stable even when host-side software load varies.

## What FCSP is and why

**FCSP** (Flight Control Serial/Stream Protocol) is the runtime protocol used by this offloader project.

Conceptually, FCSP is a **switch-based packet fabric idea** for flight-control offload:

- packetized frames with explicit boundaries and integrity checks
- channel-oriented routing (like a small deterministic switch fabric)
- structure that maps cleanly onto FPGA parser/router/FIFO pipelines

At a high level FCSP provides:

- explicit framing (`sync`, header, payload length, CRC)
- deterministic parser behavior under noise and split bursts
- channelized traffic model (`CONTROL`, `TELEMETRY`, `FC_LOG`, `DEBUG_TRACE`, `ESC_SERIAL`)
- implementation-friendly semantics for FPGA/RTL pipelines
- stream/multiplex semantics (multiple packets on wire, not strict send-and-wait)
- safe intermixing of CONTROL with telemetry/log/debug channels on the same link

Why FCSP here instead of relying only on MSP end-to-end:

- MSP is great for rapid ecosystem compatibility and GUI feature validation
- FCSP is better suited for deterministic high-rate runtime transport in this architecture
- FCSP gives a single canonical wire model optimized for offloader deployment

Canonical FCSP specification:

- `docs/FCSP_PROTOCOL.md`
- SPI profile details: `docs/FCSP_SPI_TRANSPORT.md`

## Companion repository

The Python ESC configurator and host-side GUI tooling live in the companion repo:

- `python-imgui-esc-configurator`: `git@github.com:tcmichals/python-imgui-esc-configurator.git`

This repo (`rt-fc-offloader`) and the Python repo are intended to be developed in parallel.

## Protocol direction

Current project strategy:

- **MSP path** is used first to validate GUI workflows, UX parity, and ESC feature behavior quickly.
- **FCSP path** is the target runtime transport for deterministic FPGA-friendly framing/performance.

Current practical validation status:

- there is a **Pico-based MSP implementation** available for early ESC-config and workflow testing
- that Pico/MSP path has already been tested with a **single ESC + motor**
- this gives us a known-good bring-up path while the FCSP/FPGA offloader path is expanded

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
- `docs/ENGINEERING_LOG.md` — running history of issues encountered, design decisions, and validation milestones
- `docs/FPGA_BLOCK_DESIGN.md` — FCSP FPGA block architecture and module boundaries
- `docs/PICO_PIO_IMPLEMENTATION_NOTES.md` — notes on how the Pico MSP/PIO bring-up path was structured and why
- `docs/TOP_LEVEL_BLOCK_DIAGRAM.md` — quick-reference top-level FPGA datapath/control diagram
- `docs/PYTHON_SUBMODULE_WORKFLOW.md` — companion Python-submodule workflow and FCSP sync pattern
- `docs/FCSP_SPI_TRANSPORT.md` — synchronous SPI transport profile for FCSP framing/resync/buffering
- `scripts/fcsp_companion_sync.sh` — one-command canonical+companion FCSP verification

In short: MSP validates features quickly; FCSP is the long-term high-performance path.
