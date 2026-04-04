# rt-fc-offloader: Pure Hardware Flight Controller Offloader

This repository implements a high-performance, **CPU-less** flight controller offloader designed for the **Tang Nano 9K** and **Pico 2**. 

The architecture moves the entire real-time datapath—parsing, routing, motor control, and diagnostics—into deterministic **SystemVerilog RTL**, eliminating all software/firmware dependencies within the FPGA.

## 🚀 Key Features: Pure Hardware Design

- **Zero-CPU Architecture**: No RISC-V or MIPS cores. Dedicated hardware state machines handle all protocol logic at **54 MHz**.
- **Hardware-Native Passthrough**: A deterministic "Hard Switch" allows sub-microsecond toggling between flight mode (DShot) and ESC configuration (Serial Tunnel).
- **Wishbone Control Plane**: FCSP commands are translated directly into 32-bit Wishbone bus cycles by a hardware master.
- **Unified Ingress**: Automatic arbitration between **SPI (Linux FC)** and **USB-UART (PC Configurator)** links.
- **Hardware Debug Trace (Soft-ILA)**: Real-time hardware probes streamed over FCSP Channel `0x04` for non-intrusive debugging.

## 🛠️ Quick Start

### 1. Setup Toolchain
See [docs/TOOLCHAIN_SETUP.md](docs/TOOLCHAIN_SETUP.md). (Note: RISC-V GCC is no longer required).

### 2. Build & Program
```sh
source settings.sh
cmake -S . -B build/cmake
cmake --build build/cmake --target tang9k-build
cmake --build build/cmake --target tang9k-program-flash
```

## 🏗️ Architecture Overview

The system operates as a high-speed hardware switch:
1. **Ingress**: SPI/USB frames are parsed and CRC-verified in the pipelined `fcsp_parser`.
2. **Routing**: 
   - **Channel 0x01 (CONTROL)**: Updated internal DShot/NeoPixel registers via the Wishbone Master.
   - **Channel 0x05 (ESC_SERIAL)**: Bridged directly to the motor pins for configuration.
3. **Actuation**: Hardware engines generate DShot150/300/600 and WS2812 bitstreams with nanosecond precision.

## 📖 Key Documentation

- **[TOP_LEVEL_BLOCK_DIAGRAM.md](docs/TOP_LEVEL_BLOCK_DIAGRAM.md)**: Canonical architectural view.
- **[FCSP_PROTOCOL.md](docs/FCSP_PROTOCOL.md)**: Wire-format and register-map specification.
- **[TIMING_REPORT.md](docs/TIMING_REPORT.md)**: Detailed analysis of the DShot-to-Serial switchover timing.
- **[TANG9K_PROGRAMMING.md](docs/TANG9K_PROGRAMMING.md)**: Physical pinout and synthesis targets.

## 🧪 Verification
The design is verified using **cocotb** for block-level simulation and **hardware-in-the-loop** testing with the companion [python-imgui-esc-configurator](https://github.com/tcmichals/python-imgui-esc-configurator).

---
*Developed by the Antigravity AI Assistant & tcmichals.*
