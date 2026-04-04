# Toolchain Setup Guide (Linux)

This guide explains how to install and configure the toolchains used by `rt-fc-offloader`:

- OSS FPGA tools (`yosys`, `nextpnr-himbaechel`, `gowin_pack`, `openFPGALoader`)
- Arm GNU Toolchain (`arm-none-eabi-gcc`)
- RISC-V GNU Toolchain (`riscv64-unknown-elf-gcc`)

## Recommended directory layout

Use a consistent tools directory:

- `~/.tools/oss-cad-suite/bin`
- `~/.tools/gcc-arm-none-eabi/bin`
- `~/.tools/riscv/bin`

## 1) Install OSS CAD Suite

1. Create tools directory:
   - `mkdir -p ~/.tools`
2. Download the latest Linux x64 archive from:
   - `https://github.com/YosysHQ/oss-cad-suite-build/releases`
3. Extract under `~/.tools` and ensure resulting path is:
   - `~/.tools/oss-cad-suite/bin`

## 2) Install Arm GCC

### Option A: distribution package

- Ubuntu/Debian:
  - `sudo apt-get update`
  - `sudo apt-get install -y gcc-arm-none-eabi`

### Option B: Arm GNU Toolchain release archive

1. Download a Linux x86_64 Arm GNU Toolchain release.
2. Extract to:
   - `~/.tools/gcc-arm-none-eabi`
3. Ensure compiler binary is available at:
   - `~/.tools/gcc-arm-none-eabi/bin/arm-none-eabi-gcc`

## 3) Install RISC-V GCC

### Option A: distribution package

- Ubuntu/Debian:
  - `sudo apt-get update`
  - `sudo apt-get install -y gcc-riscv64-unknown-elf`

### Option B: prebuilt toolchain archive

1. Download a prebuilt RISC-V GNU toolchain archive.
2. Extract to:
   - `~/.tools/riscv`
3. Ensure compiler binary is available at:
   - `~/.tools/riscv/bin/riscv64-unknown-elf-gcc`

## 4) Configure environment for this repository

From repository root:

- `source settings.sh`

`settings.sh` configures:

- `RT_FC_OFFLOADER_ROOT`
- `OSS_TOOLS_BIN`
- `ARM_GCC_BIN`
- `RISCV_GCC_BIN`

and prepends any detected toolchain `bin` directories to `PATH`.

### Optional explicit overrides

Set these before sourcing if your install paths differ:

- `export OSS_TOOLS_BIN=/your/path/oss-cad-suite/bin`
- `export ARM_GCC_BIN=/your/path/arm/bin`
- `export RISCV_GCC_BIN=/your/path/riscv/bin`
- `source settings.sh`

## 5) Verify installation

- `command -v yosys`
- `command -v nextpnr-himbaechel`
- `command -v gowin_pack`
- `command -v openFPGALoader`
- `command -v arm-none-eabi-gcc`
- `command -v riscv64-unknown-elf-gcc`

## 6) Build Tang Nano 9K bitstream

- `cmake -S . -B build/cmake`
- `cmake --build build/cmake --target tang9k-build`

Expected artifact:

- `build/tang9k_oss/hardware.fs`
