# FCSP Offloader: Theory of Operation

The system is a high-speed FPGA offloader designed to bridge a Flight Controller (Linux via SPI) or an ESC Configurator (PC via USB) to motor and LED actuators. It leverages the **Flight Controller Serial Protocol (FCSP)** to provide a deterministic, hardware-native transport seam.

## 0. Current Implementation Status (Important)

- **Active control-plane handler:** `fcsp_wishbone_master` in `fcsp_offloader_top.sv`.
- **Channel 0x05 (ESC_SERIAL):** Full TX/RX path wired through `fcsp_io_engines`.
- **SPI TX egress:** Disabled (`spi_tx_valid = 1'b0`). All responses exit via USB-UART.
- Channels 0x02/0x03/0x04 ingress: tied off (intentionally dropped).
- `fcsp_serv_bridge` is legacy dead code — no longer instantiated.

> **Detailed implementation status and gap tracking:** [DESIGN.md](DESIGN.md) §12

## 1. Architectural Strategy: The Dual-Plane Switch

The offloader functions as a hardware-level switch fabric, separating low-latency control logic from high-bandwidth configuration streams.

### A. The Control Plane (Channel 0x01)
*   **Purpose**: Register-mapped IO control (DShot commands, LED colors, Mux steering).
*   **Mechanism**: `fcsp_wishbone_master` decodes FCSP CONTROL payloads (READ_BLOCK / WRITE_BLOCK) and drives the internal Wishbone bus directly. Responses are framed and returned via the TX arbiter/framer.
*   **Determinism**: Stream handling is deterministic at RTL seam boundaries.

### B. The Passthrough Stream (Channel 0x05)
*   **Purpose**: High-volume serial tunneling for ESC configuration and firmware flashing.
*   **Mechanism**: The `fcsp_router` extracts payloads from **Channel 0x05** and bridges them directly to a hardware **UART Engine**.
*   **Efficiency**: By bypassing the Wishbone master, bulk data (telemetry/firmware) moves at 100% link bandwidth without the 8-byte framing overhead of register writes.

## 2. Integrated Hardware Sniffing (Auto-Passthrough)

A key innovation in the Pure Hardware design is the **Packet Sniffer** integrated into the Serial Mux.
1.  **Sniffing**: The Mux engine monitors the extracted stream on Channel 0x05.
2.  **Recognition**: It looks for MSP headers (`$M<`) or 4-way protocol markers.
3.  **Auto-Trigger**: If an `MSP_SET_PASSTHROUGH` (0xF5) command is detected, the hardware **automatically** flips the physical pin mux from DShot to Serial, eliminating the need for the host to send manual "Set Mux" register writes.

## 3. Address Map

Peripherals are mapped into a 32-bit Wishbone address space starting at `0x40000000`.

> **Canonical address map and per-peripheral register definitions:** [DESIGN.md](DESIGN.md) §4–5

**Key peripherals:** DShot controller (`0x40000300`), Serial/DShot mux (`0x40000400`), NeoPixel (`0x40000600`), ESC UART (`0x40000900`).

---
*Document Revision: 4.0 (Updated: CH 0x05 wired, duplicate details moved to DESIGN.md, Apr 2026)*
