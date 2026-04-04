# rt-fc-offloader

Real-time flight-controller offloader repository for FPGA/RTL-centered transport, framing, and deterministic I/O paths.

## Quick start (setup + build)

- Toolchain install/download/extract guide:
	- `docs/TOOLCHAIN_SETUP.md`
- Tang Nano 9K build/program guide:
	- `docs/TANG9K_PROGRAMMING.md`
- Environment setup script:
	- `settings.sh`

Minimal bring-up from repository root:

- `source settings.sh`
- `cmake -S . -B build/cmake`
- `cmake --build build/cmake --target tang9k-build`

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

- **FCSP path** is the required runtime transport for this repository.
- Architecture is **small-FPGA-first** (Tang9K-class target), not "large FPGA required".
- Any MSP/Pico references are legacy/compatibility context only.

Current practical validation status:

- FCSP parser/CRC/router/top-level simulation path is active and under continuous test.
- Legacy Pico/MSP bring-up notes remain available as historical migration context.

## Protocol role split (explicit)


- **FPGA offloader project (`rt-fc-offloader`)**: uses **FCSP** as the runtime protocol and does not depend on Pico.
	- **Primary transport**: SPI
	- **Secondary/alternate transport**: Serial

- **Legacy Pico/MSP path**: optional reference path only (not a blocker/gate for FCSP progress).

Where legacy comparisons are useful, user-facing behavior should remain equivalent; FCSP remains the canonical runtime transport model for deployment.

Canonical spec:

- `docs/FCSP_PROTOCOL.md` (**single source of truth; no duplicated copies in companion repos**)

## Repository requirements and GitHub TODO

- `REQUIREMENTS.md` — clear offloader/FCSP requirements and quality gates
- `GITHUB_TODO.md` — active GitHub task list for this repository
- `docs/ENGINEERING_LOG.md` — running history of issues encountered, design decisions, and validation milestones
- `docs/FPGA_BLOCK_DESIGN.md` — FCSP FPGA block architecture and module boundaries
- `docs/PICO_PIO_IMPLEMENTATION_NOTES.md` — notes on how the Pico MSP/PIO bring-up path was structured and why
- `docs/TEACHING_GUIDE.md` — small reusable design/test patterns for engineers and reviewers
- `docs/PATTERN_SNIPPETS.md` — tiny copyable RTL/test patterns for nearby designs
- `docs/TANG9K_FIT_GATE.md` — objective Tang9K-class fit/timing gate and reporting template
- `docs/TANG9K_PROGRAMMING.md` — Tang Nano 9K build/program flow for this repository
- `docs/TOP_LEVEL_BLOCK_DIAGRAM.md` — quick-reference top-level FPGA datapath/control diagram
- `docs/PYTHON_SUBMODULE_WORKFLOW.md` — companion Python-submodule workflow and FCSP sync pattern
- `docs/FCSP_SPI_TRANSPORT.md` — synchronous SPI transport profile for FCSP framing/resync/buffering
- `scripts/fcsp_companion_sync.sh` — one-command canonical+companion FCSP verification

In short: FCSP is the required runtime path here, with a small-FPGA-first implementation target.

## Environment setup (professional workflow)

Use a source-based setup flow similar to common FPGA/SDK frameworks:

- `source settings.sh`

Then use CMake targets directly:

- `cmake -S . -B build/cmake`
- `cmake --build build/cmake --target tang9k-build`

This keeps toolchain path setup consistent and explicit per shell session.

Additional references:

- Full toolchain setup: `docs/TOOLCHAIN_SETUP.md`
- Tang9K programming flow: `docs/TANG9K_PROGRAMMING.md`

## FPGA sizing constraint (explicit)

This project is intentionally constrained for **small FPGA devices**.

- Target class: **Tang9K-class** devices.
- Design rule: avoid assumptions that require a large FPGA.
- Preferred trade: spend area on deterministic RTL datapaths (parser/CRC/router/FIFO/IO engines), keep control CPU minimal.

Final fit is always validated by synthesis/place-and-route reports; architectural decisions should preserve small-device viability by default.

## Why the interfaces matter

This repo is also meant to help engineers learn and adapt the design for nearby
targets, not just preserve one exact implementation.

That is an important project requirement:

- people should be able to **read it quickly**
- understand the design in small chunks
- lift ideas, patterns, and small code snippets into related projects
- retarget nearby designs without reverse-engineering the whole repository first

The current interface direction is therefore deliberate:

- **AXIS-style streams** for the FCSP packet/stream datapath
- **Wishbone** for device/register-style peripherals and control windows

That split makes the project easier to:

- reuse on similar boards or SoC layouts
- retarget when transport or CPU choices change
- teach in a classroom or lab setting as a practical example of
	stream-fabric-plus-device-bus design

Testing should follow the same structure:

- stream blocks get independent block-level cocotb tests
- Wishbone-attached devices should get per-device unit tests around their
	register maps and side effects

## Readability and classroom requirement

This project should stay useful as a **classroom / lab / reference design**.

That means docs and code should prefer:

- small understandable modules
- stable named interfaces
- short focused examples over giant monolithic explanations
- comments that explain *why* a seam exists, not just what the signals are
- unit tests that demonstrate one device or one stream block at a time

The goal is that an engineer can open the repo, read a small section, and lift:

- a parser pattern
- a CRC-wrapper pattern
- an AXIS-style stream seam
- a Wishbone device wrapper idea
- a cocotb test pattern

without needing to adopt the entire system unchanged.
