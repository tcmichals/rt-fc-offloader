# Tang Nano 9K Programming Guide

This guide describes how to build and program the **Pure Hardware FCSP Offloader** on the Tang Nano 9K.

## Prerequisites

Ensure you have the **OSS CAD Suite** installed. No RISC-V or ARM compilers are needed for the bitstream itself.

- **Recommended path**: `~/.tools/oss-cad-suite/bin`
- **Setup**: `source settings.sh`

## Project Files

- **Top-level Wrapper**: `rtl/fcsp/boards/tangnano9k/fcsp_tangnano9k_top.sv`
- **Constraints**: `rtl/fcsp/boards/tangnano9k/tang9k.cst`
- **Timing**: `rtl/fcsp/boards/tangnano9k/tang9k.sdc`

## Build Bitstream

The build is fully managed by CMake.

```sh
# 1. Configure the build system
cmake -S . -B build/cmake

# 2. Build the Tang Nano 9K target
cmake --build build/cmake --target tang9k-build
```

**Output**: `build/tang9k_oss/hardware.fs`

## Program the Board

Ensure your Tang Nano 9K is connected via USB.

### SRAM (Temporary - lost on power cycle)
```sh
cmake --build build/cmake --target tang9k-program-sram
```

### Flash (Persistent)
```sh
cmake --build build/cmake --target tang9k-program-flash
```

## Hardware Status

This bitstream implements the **Complete Pure Hardware Architecture**:
- ✅ **SPI Link**: Resynchronizing parser at 54 MHz.
- ✅ **USB-UART Link**: Bridged directly to the FCSP ingress.
- ✅ **Hardware Switch**: Deterministic DShot-to-Serial passthrough.
- ✅ **Wishbone Master**: Hardware execution of `WRITE_BLOCK` / `READ_BLOCK`.

## Troubleshooting

- **Timeout**: If synthesis takes longer than 15 minutes, you can increase the timeout:
  `cmake -S . -B build/cmake -DTANG9K_BUILD_TIMEOUT_SEC=1200`
- **Cable**: If the board isn't detected, check your permissions for `openFPGALoader` (udev rules).