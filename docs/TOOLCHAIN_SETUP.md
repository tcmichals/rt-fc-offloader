# Toolchain Setup Guide (Linux + Windows Git Bash)

This guide explains how to install and configure the toolchains used for the Pure Hardware FCSP Offloader:

- **OSS FPGA tools**: `yosys`, `nextpnr-himbaechel`, `gowin_pack`, `openFPGALoader`.
- **Arm GNU Toolchain**: `arm-none-eabi-gcc` (for Pico 2 firmware).
- **Raspberry Pi Pico SDK**: `pico_sdk_init.cmake`.

> **Note**: A RISC-V toolchain is **no longer required**, as the offloader now uses a pure hardware architecture without an internal CPU.

---

## 1) Install OSS CAD Suite (FPGA Synthesis)

The OSS CAD Suite provides the open-source flow for the Tang Nano 9K.

1. **Download**: Get the latest Linux x64 archive from [YosysHQ/oss-cad-suite-build](https://github.com/YosysHQ/oss-cad-suite-build/releases).
2. **Extract**: Extract to `~/.tools/oss-cad-suite`.
3. **Python Deps**: The bitstream packer requires some Python libraries. Install them into the OSS suite's internal Python:
   ```sh
   ~/.tools/oss-cad-suite/py3bin/python3 -m pip install numpy msgspec fastcrc
   ```

## 2) Install Arm GCC (Pico 2 Firmware)

Required for compiling the flight controller code that talks to the FPGA.

1. **Download**: Download the "Arm GNU Toolchain" from [Arm Developer](https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads).
2. **Extract**: Extract to `~/.tools/gcc-arm-none-eabi`.

## 3) Install Pico SDK

1. **Clone**:
   ```sh
   git clone --recurse-submodules --depth=1 \
     https://github.com/raspberrypi/pico-sdk.git \
     ~/.tools/pico-sdk
   ```
2. **Set Variable**: Ensure `PICO_SDK_PATH` points to this directory.

---

## 4) Configure Environment

From the repository root, source the settings script to add the tools to your path:

```sh
source settings.sh
```

`settings.sh` will automatically detect tools in `~/.tools` and configure:
- `RT_FC_OFFLOADER_ROOT`
- `OSS_TOOLS_BIN`
- `ARM_GCC_BIN`
- `PICO_SDK_PATH`

## 5) Verify Installation

Run these commands to ensure the tools are ready:
- `command -v yosys`
- `command -v nextpnr-himbaechel`
- `command -v gowin_pack`
- `command -v arm-none-eabi-gcc`

## 6) Build the Bitstream

The build is managed via CMake. You don't need to manually run any synthesis scripts.

```sh
# Configure
cmake -S . -B build/cmake

# Build Tang Nano 9K target
cmake --build build/cmake --target tang9k-build
```

**Resulting Artifact**: `build/tang9k_oss/hardware.fs`
