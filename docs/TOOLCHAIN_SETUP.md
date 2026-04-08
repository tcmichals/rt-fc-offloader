# Toolchain Setup Guide (Linux + Windows Git Bash)

This guide explains how to install and configure the toolchains used by `rt-fc-offloader`:

- OSS FPGA tools (`yosys`, `nextpnr-himbaechel`, `gowin_pack`, `openFPGALoader`)
- Arm GNU Toolchain (`arm-none-eabi-gcc`)
- RISC-V GNU Toolchain (`riscv64-unknown-elf-gcc`)
- Raspberry Pi Pico SDK (`pico_sdk_init.cmake`)

Official download pages used by this project:

- Arm GNU Toolchain (Arm Developer downloads):
   - https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads
- RISC-V GNU Toolchain (xPack releases):
   - https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases
- Raspberry Pi Pico SDK:
   - https://github.com/raspberrypi/pico-sdk/releases

## Automatic install (latest releases)

From repository root:

```sh
bash scripts/install_latest_tools.sh          # check and update all tools
bash scripts/install_latest_tools.sh arm riscv  # check/update specific tools
bash scripts/install_latest_tools.sh --force    # force-reinstall everything
bash scripts/install_latest_tools.sh --help     # show full usage
```

On re-run the script compares each installed version (stored in
`~/.tools/<tool>/.installed-version`) against the latest GitHub release
tag and **skips download if already current**. Use `--force` to bypass
the check and reinstall regardless.

This installs latest versions into `~/.tools` using this layout:

- `~/.tools/oss-cad-suite`
- `~/.tools/gcc-arm-none-eabi`
- `~/.tools/gcc-riscv-none-eabi`
- `~/.tools/pico-sdk`

Supported hosts for automatic install:

- Linux x86_64
- Linux aarch64
- Windows x86_64 (Git Bash/MSYS2)

After install, run:

- `source settings.sh`

Notes:

- RISC-V is pulled from xPack releases and compatibility symlinks for
   `riscv64-unknown-elf-*` are created if needed.
- Installer validates `nano.specs` support for both:
   - `arm-none-eabi-gcc`
   - `riscv64-unknown-elf-gcc` (or `riscv-none-elf-gcc` fallback)
- Arm GNU is resolved from Arm Developer downloads. If auto-detection fails,
   set `ARM_GNU_URL` to the exact host-appropriate archive URL and rerun.
- Pico SDK is cloned via `git clone --recurse-submodules` to handle its
   submodule dependencies correctly.
- On Windows Git Bash/MSYS2, install `unzip` (or provide `bsdtar`) so `.zip`
  archives can be extracted.

## Recommended directory layout

Use a consistent tools directory:

- `~/.tools/oss-cad-suite/bin`
- `~/.tools/gcc-arm-none-eabi/bin`
- `~/.tools/gcc-riscv-none-eabi/bin`
- `~/.tools/pico-sdk`  ← set `PICO_SDK_PATH` to this path

## 1) Install OSS CAD Suite

1. Create tools directory:
   - `mkdir -p ~/.tools`
2. Download the latest Linux x64 archive from:
   - `https://github.com/YosysHQ/oss-cad-suite-build/releases`
3. Extract under `~/.tools` and ensure resulting path is:
   - `~/.tools/oss-cad-suite/bin`

## 2) Install Arm GCC

### Recommended: Arm GNU Toolchain release archive (Arm Developer)

1. Download a Linux x86_64 Arm GNU Toolchain release from:
   - https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads
2. Extract to:
   - `~/.tools/gcc-arm-none-eabi`
3. Ensure compiler binary is available at:
   - `~/.tools/gcc-arm-none-eabi/bin/arm-none-eabi-gcc`

### Optional fallback: distribution package (not preferred)

- Ubuntu/Debian:
  - `sudo apt-get update`
  - `sudo apt-get install -y gcc-arm-none-eabi`

Why not preferred: distro packages can differ in bundled libraries/specs vs
official Arm releases, which may cause target-profile mismatches in embedded
flows.

Required check if you choose apt fallback:

- `arm-none-eabi-gcc -print-file-name=nano.specs`

If output is exactly `nano.specs` (not an absolute path), treat that toolchain
as unsupported for this repo flow.

## 3) Install RISC-V GCC

### Recommended: xPack prebuilt toolchain archive

1. Download a prebuilt RISC-V GNU toolchain archive from:
   - https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases
2. Extract to:
   - `~/.tools/gcc-riscv-none-eabi`
3. Ensure compiler binary is available at:
   - `~/.tools/gcc-riscv-none-eabi/bin/riscv64-unknown-elf-gcc`

### Optional fallback: distribution package (not preferred)

- Ubuntu/Debian:
  - `sudo apt-get update`
  - `sudo apt-get install -y gcc-riscv64-unknown-elf`

Why not preferred: distro RISC-V packages may not match the exact embedded
profile/multilib expectations used in this repo's Tang Nano flow.

Required check if you choose apt fallback:

- `riscv64-unknown-elf-gcc -print-file-name=nano.specs`

If output is exactly `nano.specs` (not an absolute path), treat that toolchain
as unsupported for this repo flow.

## 4) Install Pico SDK

### Recommended: automatic installer

The installer (`scripts/install_latest_tools.sh` or `pico-sdk` tool selector)
clones the latest tagged release recursively:

```sh
bash scripts/install_latest_tools.sh pico-sdk
```

### Manual clone

```sh
git clone --recurse-submodules --depth=1 \
  https://github.com/raspberrypi/pico-sdk.git \
  ~/.tools/pico-sdk
```

Note: `--recurse-submodules` is required (TinyUSB and other deps are submodules).

## 5) Configure environment for this repository

From repository root:

- `source settings.sh`

`settings.sh` configures:

- `RT_FC_OFFLOADER_ROOT`
- `OSS_TOOLS_BIN`
- `ARM_GCC_BIN`
- `RISCV_GCC_BIN`
- `PICO_SDK_PATH`

and prepends any detected toolchain `bin` directories to `PATH`.

### Optional explicit overrides

Set these before sourcing if your install paths differ:

- `export OSS_TOOLS_BIN=/your/path/oss-cad-suite/bin`
- `export ARM_GCC_BIN=/your/path/arm/bin`
- `export RISCV_GCC_BIN=/your/path/gcc-riscv-none-eabi/bin`
- `export PICO_SDK_PATH=/your/path/pico-sdk`
- `source settings.sh`

## 6) Verify installation

- `command -v yosys`
- `command -v nextpnr-himbaechel`
- `command -v gowin_pack`
- `command -v openFPGALoader`
- `command -v arm-none-eabi-gcc`
- `command -v riscv64-unknown-elf-gcc`

## 7) Build Tang Nano 9K bitstream

Important notes before compile:

- Use the CMake target flow for Tang9K builds (do **not** use shell build scripts):
   - `cmake --build build/cmake --target tang9k-build`
- You do **not** need to activate the project `.venv` to compile FPGA bitstreams.
   - `.venv` is for simulation/tests and Python tooling in this repo.
   - Tang9K compile tools run from OSS CAD Suite (`yosys`, `nextpnr-himbaechel`, `gowin_pack`).
- If `gowin_pack` warns that `numpy`, `msgspec`, or `fastcrc` are missing,
   install them into OSS CAD Suite's Python runtime (`py3bin`), not project `.venv`:
   - `~/.tools/oss-cad-suite/py3bin/python3 -m pip install numpy msgspec fastcrc`
   - (equivalently) `~/.tools/oss-cad-suite/py3bin/pip3 install numpy msgspec fastcrc`

- `cmake -S . -B build/cmake`
- `cmake --build build/cmake --target tang9k-build`

Expected artifact:

- `build/tang9k_oss/hardware.fs`
