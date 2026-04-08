# Tang Nano 9K Programming Guide

This guide provides a direct build/program path for `rt-fc-offloader` on Tang Nano 9K.

For complete download/install instructions (OSS CAD + Arm GCC + RISC-V GCC), see:

- `docs/TOOLCHAIN_SETUP.md`

## Inputs added in this repository

- Board wrapper RTL:
  - `rtl/fcsp/boards/tangnano9k/fcsp_tangnano9k_top.sv`
- Constraints:
  - `rtl/fcsp/boards/tangnano9k/tang9k.cst`
  - `rtl/fcsp/boards/tangnano9k/tang9k.sdc`
- Build script wrapper (optional OSS flow helper):
  - `scripts/build_tang9k_oss.sh`
- Program script wrapper (optional helper):
  - `scripts/program_tang9k.sh`

## Tool prerequisites

Install and ensure these are on `PATH`:

- `yosys`
- `nextpnr-himbaechel`
- `gowin_pack`
- `openFPGALoader`

## Professional environment setup (recommended)

Use the repository-level settings file (SDK-style workflow):

- `source settings.sh`

This configures:

- `RT_FC_OFFLOADER_ROOT`
- `OSS_TOOLS_BIN` (default: `~/.tools/oss-cad-suite/bin`)
- `PATH` update when `OSS_TOOLS_BIN` exists

Optional custom toolchain path:

- `export OSS_TOOLS_BIN=/your/tools/bin`
- `source settings.sh`

If your OSS tools are installed under `~/.tools/oss-cad-suite/bin`, CMake targets also pick them up automatically.

For script-only ad-hoc usage, you can still source:

- `source scripts/oss_tools_env.sh`

Optional override for custom install path:

- `export OSS_TOOLS_BIN=/your/tools/bin`
- `source scripts/oss_tools_env.sh`

## Build bitstream

Quick start (recommended):

- `cmake -S . -B build/cmake`
- `cmake --build build/cmake --target tang9k-build`

`tang9k-build` applies both board pin constraints (`tang9k.cst`) and timing constraints (`tang9k.sdc`) during place-and-route.

No manual `export PATH=...` is required for the CMake targets when using the default `~/.tools/oss-cad-suite/bin` install location.

Build timeout controls (recommended for unattended/autopilot runs):

- CMake target default: `TANG9K_BUILD_TIMEOUT_SEC=900` (applies per stage: `yosys`, `nextpnr-himbaechel`, `gowin_pack`)
- Override timeout at configure time:
  - `cmake -S . -B build/cmake -DTANG9K_BUILD_TIMEOUT_SEC=1200`
- Disable timeout enforcement:
  - `cmake -S . -B build/cmake -DTANG9K_BUILD_TIMEOUT_SEC=0`

Optional wrapper script (it sources `scripts/oss_tools_env.sh`):

- `bash scripts/build_tang9k_oss.sh`

Optional wrapper script timeout override:

- `TANG9K_BUILD_TIMEOUT_SEC=1200 bash scripts/build_tang9k_oss.sh`
- `TANG9K_BUILD_TIMEOUT_SEC=0 bash scripts/build_tang9k_oss.sh` (disable timeout)

Expected artifact:

- `build/tang9k_oss/hardware.fs`

## Program board

### SRAM (temporary until power cycle)

- `cmake --build build/cmake --target tang9k-program-sram`

Optional wrapper script (it sources `scripts/oss_tools_env.sh`):

- `bash scripts/program_tang9k.sh`

### Flash (persistent)

- `cmake --build build/cmake --target tang9k-program-flash`

Optional wrapper script (it sources `scripts/oss_tools_env.sh`):

- `bash scripts/program_tang9k.sh build/tang9k_oss/hardware.fs flash`

## Pin map source

Tang9K pin assignments in `tang9k.cst` were transcribed from prior project Tang9K pinout/constraints references to preserve known wiring conventions for:

- SPI host link
- PWM inputs
- motor outputs
- NeoPixel output
- LEDs/debug
- USB UART pins

## Current wrapper scope

The wrapper is intended to make board programming and basic SPI/parser bring-up possible now.

Known interim limits in this board wrapper revision:

- SPI TX egress is disabled — all responses exit via USB-UART only.

> **Current integration status and remaining gaps:** [DESIGN.md](DESIGN.md) §12

These are integration follow-ups, not blockers for generating/programming a Tang9K bitstream.