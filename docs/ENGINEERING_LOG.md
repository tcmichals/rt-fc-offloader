# Engineering Log

This file is a lightweight running history of what we ran into, what we decided, and what was verified.

Use it for:

- design decisions that should not get lost in chat history
- bring-up discoveries
- protocol/RTL gotchas
- validation milestones
- known pain points and why choices were made

Historical note:

- Older entries may reference SERV/SERV8 terms from prior exploration milestones.
- Those terms are intentionally preserved in this log for historical traceability.
- Current project direction is no active embedded soft-CPU dependency; treat SERV/SERV8 references here as legacy context, not current architecture requirements.

Newest entries should be added near the top.

---

## 2026-06-15 — Transition to Official Gowin Tools for Build

- **Observation**: The open-source `yosys`/`nextpnr` (OSS Suite) build flow for the Tang Nano 9K encountered integration/build issues, rendering it less reliable for the current RTL.
- **Resolution**: Pivoted to using the official Gowin toolchain (`gw_sh` CLI) for both Tang Nano 9K and Tang Nano 20K.
- **Tooling Updates**:
  - Re-wrote `scripts/build_gowin_cli.sh` to robustly detect `GOWIN_HOME` and bypass Wayland/GLX initialization crashes by forcing `QT_QPA_PLATFORM=minimal` and disabling GL integration.
  - Added new dedicated build scripts for Tang Nano 20K (`scripts/build_gowin_20k.tcl` and `scripts/build_gowin_20k_cli.sh`), explicitly setting the part number to `GW2AR-LV18QN88C8/I7`.

---

## 2026-04-26 — NeoPixel RGBW (SK6812) Hardware Verified

- **Hardware Target**: Adafruit NeoPixel Stick (8 x 5050 RGBW LEDs, Product ID [2869](https://www.adafruit.com/product/2869)).
- **RTL Configuration**:
  - Updated `fcsp_tangnano9k_top.sv` to set `NEO_LED_TYPE = 1` (SK6812/32-bit mode).
  - Verified 54MHz bit-timing (T0H ~300ns, T1H ~600ns) is within SK6812 spec.
- **Software Adjustments**:
  - Discovered and fixed bit-order mismatch: Hardware expects **GRBW**, but software was sending **RGBW**.
  - Updated `hwlib/registers.py:rgbw()` to swap R and G components.
- **Result**: Successful control of individual pixels and patterns on the physical 8-LED stick via FCSP.

---

## 2026-04-26 — Serial Link Stabilized and Wishbone Debug Fixed

- **Stabilized 115,200 Baud Link**:
  - Implemented a **10ms timeout** in `fcsp_parser.sv` to handle "garbage" bytes sent by the host (USB-Serial driver flush/init noise).
  - Fixed parser math to use integer-only scaling (removing `real` types) to satisfy Yosys/OSS synthesis requirements.
  - Successfully verified CRC-clean packets arriving on hardware via logic analyzer.
- **Wishbone Debug Visibility Fix**:
  - Discovered and fixed missing internal signal assignments in `fcsp_offloader_top.sv`. Diagnostic ports `o_wb_stb` and `o_wb_ack` were not previously connected to the internal `int_wb_*` bus.
  - Pivoted Tang Nano 9K debug pin mapping to "Bus Watcher" mode:
    - CH4 (70): `wb_stb` (Master Request)
    - CH5 (71): `wb_ack` (Slave Response)
    - CH6 (72): `crc_ok` (CRC Success Pulse)
- **Link Quality**:
  - Confirmed 100% CRC success rate once host-side noise is flushed.
  - Verified 54 MHz system clock stability (no changes made to PLL architecture).

---

## 2026-04-12 — Tang Nano 20K serial poll verified stable on hardware

- Ran hardware poll:
  - `python3 ./test_hw_version_poll.py --port /dev/ttyUSB1`
- Observed stable FCSP CONTROL response behavior at `1_000_000` baud:
  - CRC: 100% OK
  - Latency: < 2ms round-trip (Python side)
- Noted occasional dropped bytes on first port open; resolved by adding 10ms wait before first poll command.
