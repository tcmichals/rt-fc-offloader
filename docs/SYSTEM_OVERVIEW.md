# FCSP Offloader: Theory of Operation

The system is a high-speed FPGA offloader designed to bridge a Flight Controller (Linux via SPI) or an ESC Configurator (PC via USB) to motor and LED actuators. It leverages the **Flight Controller Serial Protocol (FCSP)** to provide a deterministic, hardware-native transport seam.

## 0. Current Implementation Status (Important)

- **Current top-level integration uses `fcsp_serv_bridge`** (`fcsp_offloader_top.sv`) for Channel `0x01` command/response handling.
- `fcsp_wishbone_master.sv` exists in the repo, but is not the active control-plane path in the current top-level.
- Router channels `0x02/0x03/0x04` are recognized, and currently tied-off (`tready=1`) in top-level integration (intentionally dropped in this revision).

## 1. Architectural Strategy: The Dual-Plane Switch

The offloader functions as a hardware-level switch fabric, separating low-latency control logic from high-bandwidth configuration streams.

### A. The Control Plane (Channel 0x01)
*   **Purpose**: Register-mapped IO control (DShot commands, LED colors, Mux steering).
*   **Mechanism (current)**: `fcsp_serv_bridge` converts FCSP control payload stream to SERV command stream and maps SERV responses back to FCSP frames.
*   **Mechanism (target)**: direct Wishbone execution by `fcsp_wishbone_master`.
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

## 3. Production Address Map (32-bit Wishbone)

Peripherals are mapped into a 32-bit address space.

**Addressing note:** docs sometimes use absolute bus addresses (e.g., `0x40000400`) and sometimes peripheral-relative register offsets (e.g., `0x0020`). They refer to the same register space with base + offset mapping.

| Absolute Address | Relative Offset | Peripheral | Register Function |
|------------------|-----------------|------------|-------------------|
| `0x40000300` | `0x0000` | DShot      | Motor Duty Cycles (1-4) |
| `0x40000400` | `0x0020` | Serial Mux | Mode Select, Channel Select, Force-Low |
| `0x40000600` | `0x0010` | NeoPixel   | RGB Color Buffer |
| `0x40000900` | N/A      | ESC UART   | TX/RX Data (Wishbone fallback) |
| `0x4000090C` | N/A      | Baud Rate  | Bits/sec Divider (Configurable) |

## 4. Outbound Telemetry Arbitration

The offloader must multiplex responses from the Wishbone Master (ACKs) and telemetry from the ESCs (serial bytes) back over the USB link.
*   **Priority Logic**: The **Priority Arbiter** gives precedence to **Channel 0x01** (Control Responses) to ensure the control link remains responsive under high serial load.
*   **Flow Control**: Hardware FIFOs on the outbound path prevent data loss during channel switching or USB-serial congestion.

## 5. Comparison to CPU-Based Designs

| Feature | Legacy RISC-V Design | Current Integration |
|---------|-----------------------|-------------------------|
| **Control Path** | SW-heavy | SERV stream bridge seam |
| **Baud Rate** | Limited by CPU ISR | Hardware serial engines |
| **Resources** | CPU + memory overhead | Moderate LUT + BRAM FIFO usage |
| **Jitter** | Variable (SW interrupts) | Deterministic at stream seams |

---
*Document Revision: 2.2 (Current RTL-aligned integration view)*
