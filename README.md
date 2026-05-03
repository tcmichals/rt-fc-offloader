# rt-fc-offloader

Real-time flight-controller offloader repository for FPGA/RTL-centered transport, framing, and deterministic I/O paths.

## Quick start (setup + build)

- Toolchain install/download/extract guide:
	- `docs/TOOLCHAIN_SETUP.md`
- Tang Nano 9K build/program guide:
	- `docs/TANG9K_PROGRAMMING.md`
- Environment setup script:
	- `settings.sh`

### Setup docs map (read this first)

- **Master RTL architecture reference (modules, buses, registers, datapaths, known gaps):**
	- `docs/DESIGN.md`
- **Open tasks, feature backlog, integration milestones:**
	- `GITHUB_TODO.md`
- **Project requirements & quality gates:**
	- `REQUIREMENTS.md`
- **AI prompt guide (mission, guardrails, canonical sources):**
	- `PROMPT.md`
- Full toolchain installation and verification:
	- `docs/TOOLCHAIN_SETUP.md`
- Tang Nano 9K build/program workflow:
	- `docs/TANG9K_PROGRAMMING.md`
- Simulation harness usage and targets:
	- `sim/README.md`
- Python utilities and script usage:
	- `python/README.md`

For AI/automation workflows: start with `PROMPT.md` for mission context, then `docs/DESIGN.md` for architecture, then `GITHUB_TODO.md` for open work.

Minimal bring-up from repository root:

- `bash scripts/install_latest_tools.sh` *(optional one-shot install into `~/.tools`)*
- `source settings.sh`
- `cmake -S . -B build/cmake`
- `cmake --build build/cmake --target tangnano9k-build`
  or `cmake --build build/cmake --target tangnano20k-build`
- `cmake --build build/cmake --target tangnano9k-program-sram`
  or `cmake --build build/cmake --target tangnano20k-program-sram`
  *(Note: uses `openFPGALoader` to write to volatile SRAM; use `-program-flash` for persistent flash)*

## Run all simulations

From repository root, run the full simulation regression suite with:

- `cmake --build build/cmake --target sim-test-all`

Recommended one-time setup (if `build/cmake` does not exist yet):

- `source settings.sh`
- `cmake -S . -B build/cmake`

All simulation-related CMake targets:

- Full simulation regression:
	- `cmake --build build/cmake --target sim-test-all`
- Strict full regression (includes top-level + experimental integration + serial mux):
	- `cmake --build build/cmake --target sim-test-all-strict`
- Python protocol/unit tests:
	- `cmake --build build/cmake --target sim-test-python`
- Parser cocotb suite:
	- `cmake --build build/cmake --target sim-test-cocotb`
- Top-level cocotb suite:
	- `cmake --build build/cmake --target sim-test-top-cocotb`
- Experimental top-level cocotb integration:
	- `cmake --build build/cmake --target sim-test-top-cocotb-experimental`
- Teaching/example cocotb suite:
	- `cmake --build build/cmake --target sim-test-teaching-examples`

Simulation-adjacent verification/evidence targets:

- Fit-evidence snapshot:
	- `cmake --build build/cmake --target sim-fit-evidence`
- Live fit-evidence snapshot (runs simulation gate first):
	- `cmake --build build/cmake --target sim-fit-evidence-live`

### Python environment note (human + AI automation)

- Use the project virtual environment at `./.venv` for Python commands in this repository.
- Preferred interpreter path:
	- `./.venv/bin/python`
- Preferred test runner path:
	- `./.venv/bin/pytest`
- The simulation Python target (`make -C sim test-python`) is configured to prefer `.venv` automatically when present.
- `.venv` is for Python simulation/tests/scripts only; FPGA compile/program flows still use OSS toolchain paths from `settings.sh`.

### Hardware test scripts (`python/hw/`)

Live hardware validation scripts that talk to the FPGA over USB-serial using the FCSP protocol. Run from `python/hw/` with the `.venv` activated.

**Prerequisites:**
- FPGA programmed and connected via USB-serial
- `.venv` activated (`source .venv/bin/activate`)
- Default baud is 2 Mbaud (Tang Nano 20K); use `--baud 1000000` for Tang Nano 9K

**Available scripts:**

| Script | Purpose |
|--------|---------|
| `test_hw_version_poll.py` | Poll WHO_AM_I register, measure round-trip time |
| `test_hw_onboard_led_walk.py` | Walk onboard LEDs via Wishbone LED controller |
| `test_hw_switching.py` | Test serial/DShot mux switching across motor channels |
| `test_hw_neopixel.py` | Drive NeoPixel outputs via Wishbone registers |
| `test_hw_esc_passthrough.py` | BLHeli ESC passthrough: enter bootloader, read version/settings via 4-way protocol |

**Common options** (all scripts):
```
--port /dev/ttyUSB1    # Serial port (default: auto-detect)
--baud 2000000         # FCSP baud rate (default: 2000000)
```

**Examples:**
```bash
cd python/hw

# Poll WHO_AM_I with RTT measurement
python test_hw_version_poll.py --port /dev/ttyUSB1

# Flood mode — back-to-back requests, no delay
python test_hw_version_poll.py --port /dev/ttyUSB1 --flood

# Walk LEDs
python test_hw_onboard_led_walk.py --port /dev/ttyUSB1

# Mux switching test
python test_hw_switching.py --port /dev/ttyUSB1

# ESC passthrough — read version on motor 0
python test_hw_esc_passthrough.py --port /dev/ttyUSB1 --motor 0

# ESC passthrough — also read EEPROM settings
python test_hw_esc_passthrough.py --port /dev/ttyUSB1 --motor 0 --read-settings
```

**DShot note:** The FPGA DShot output is auto-repeating (last throttle value is re-sent every 1ms). This ensures ESCs remain armed and responsive even when the host software is not sending constant updates.

### Pico firmware build (`firmware/`)

The RP2040 (Pico) firmware lives under `firmware/`. It requires the Pico SDK and an ARM cross-compiler.

**Prerequisites:**
- `arm-none-eabi-gcc` (e.g. in `~/.tools/gcc-arm-none-eabi/bin/`)
- Pico SDK (e.g. in `~/.tools/pico-sdk/`)
- Environment variable `PICO_SDK_PATH` set (done by `source settings.sh`)

**Build:**
```bash
source settings.sh
mkdir -p build/firmware
cd build/firmware
cmake ../../firmware \
    -DPICO_SDK_PATH=$PICO_SDK_PATH \
    -DPICO_TOOLCHAIN_PATH=$HOME/.tools/gcc-arm-none-eabi/bin
make -j$(nproc)
```

Output: `build/firmware/rt_fc_pico.uf2`

**Flash:** Hold BOOTSEL on the Pico, plug USB, then copy the UF2:
```bash
cp build/firmware/rt_fc_pico.uf2 /media/$USER/RPI-RP2/
```

Tang9K build notes:

- Build via CMake target (`tang9k-build`) — this is the supported compile path.
- If a build gets stuck, stop the full process tree with `cmake --build build/cmake --target tang9k-stop`.
- Build uses a single timeout for the full `tang9k-build` target by default (900 seconds) to avoid indefinite hangs.
- Configure timeout at CMake configure time with `-DTANG9K_BUILD_TIMEOUT_SEC=<seconds>`.
- Set `-DTANG9K_BUILD_TIMEOUT_SEC=0` to disable timeout enforcement.
- Project `.venv` activation is **not required** for FPGA compile.
- If `gowin_pack` warns about missing `numpy`, `msgspec`, or `fastcrc`, install
	them into OSS CAD Suite's Python runtime (not project `.venv`):
	- `~/.tools/oss-cad-suite/py3bin/python3 -m pip install numpy msgspec fastcrc`
- Each successful `tang9k-build` now emits a compile summary to:
	- `build/tang9k_oss/compile_summary_latest.md`
	- `build/tang9k_oss/compile_summary_<timestamp>.md`
- By default, `tang9k-build` also auto-updates the auto-generated compile snapshot
	section in `docs/TIMING_REPORT.md` and prints that update in build output.
- To skip doc updates while keeping summary artifacts:
	- `UPDATE_TIMING_REPORT=0 cmake --build build/cmake --target tang9k-build`

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
- For this architecture and validation goals, FCSP is currently the better fit for deterministic high-rate runtime transport
- FCSP gives a single canonical wire model optimized for offloader deployment

Current evidence in this repository supporting that decision:

- strict simulation regression target passes (`sim-test-all-strict`)
- parser/CRC/router/top-level cocotb coverage is active and mapped in `docs/VALIDATION_MATRIX.md`
- Tang9K compile snapshots report positive post-route timing margin in `docs/TIMING_REPORT.md`

## Timing report highlights (what to look at)

Use `docs/TIMING_REPORT.md` as the canonical timing summary for:

- switch-over timing behavior for ESC bootloader entry flows
- current post-route `sys_clk` FMAX and margin vs target
- utilization/resource snapshot from latest build
- current worst-path location and optimization focus

Teaching/review angle:

- Control software remains **pure register writes + ACK** on Wishbone-style interfaces.
- Timing-critical behavior (pin transitions, protocol pulse windows, latch gaps) is implemented in RTL timing engines.
- This separation is intentional: it keeps control-plane code simple while preserving deterministic hardware timing.

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
- `CONTRIBUTING.md` — branch/commit/test contribution workflow and review expectations
- `CHANGELOG.md` — tracked protocol/simulation/documentation change history
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
- `docs/VALIDATION_MATRIX.md` — reproducible validation gates and evidence template
- `docs/RELEASE_PROCESS.md` — milestone tag policy for simulation/protocol releases
- `scripts/fcsp_companion_sync.sh` — one-command canonical+companion FCSP verification

In short: FCSP is the required runtime path here, with a small-FPGA-first implementation target.

## Environment setup (professional workflow)

Use a source-based setup flow similar to common FPGA/SDK frameworks:

- `source settings.sh`

Then use CMake targets directly:

- `cmake -S . -B build/cmake`
- `cmake --build build/cmake --target tang9k-build`

For Tang9K compile, you do not need to activate project `.venv`; only toolchain
paths from `settings.sh` are required.

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
