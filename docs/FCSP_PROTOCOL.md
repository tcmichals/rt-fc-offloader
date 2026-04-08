# FCSP Protocol Specification (FCSP/1)

**FCSP** = **Flight Controller Serial Protocol**

This document defines the FCSP protocol as implemented in the current FPGA offloader architecture. FCSP provides a unified and reliable communication link across SPI/USB ingress and stream-routed internal planes, with performance characteristics validated by this repository's simulation and build evidence.

## 1. Frame Format (Wire Level)

All multi-byte integers are **Big-Endian** on the wire.

| Field | Size | Description |
|---|---:|---|
| `sync` | 1 | `0xA5` |
| `version` | 1 | Protocol version, currently `1` |
| `flags` | 1 | Bitfield (0x01: ACK Req) |
| `channel` | 1 | Logical channel (Routing ID) |
| `seq` | 2 | Sequence number (for packet ordering) |
| `payload_len` | 2 | Payload byte length (Max 512) |
| `payload` | N | Data bytes |
| `crc16` | 2 | CRC16/XMODEM over `version..payload` |

---

## 2. Channel Architecture

The FCSP router directs incoming packets to dedicated hardware "planes" based on the channel ID:

| Channel | Name | Current Integration Handling |
|---|---|---|
| `0x01` | CONTROL | Routed to control-plane handler (`fcsp_serv_bridge` seam in current top-level) |
| `0x02` | TELEMETRY | Routed by `fcsp_router`, currently tied-off in top-level (accepted then dropped) |
| `0x03` | FC_LOG | Routed by `fcsp_router`, currently tied-off in top-level (accepted then dropped) |
| `0x04` | DEBUG_TRACE | Routed by `fcsp_router`, currently tied-off in top-level (accepted then dropped) |
| `0x05` | ESC_SERIAL | Routed to ESC serial stream path |

### 0x01: CONTROL PLANE
This channel is used for memory-mapped configuration and control semantics. In the current top-level it is forwarded through `fcsp_serv_bridge`; payload op semantics remain:

#### A. WRITE_BLOCK (0x11)
Writes data to the internal Wishbone bus.
*   `op_id`: `0x11`
*   `address`: 32-bit Wishbone Address.
*   `data`: Payload to write (multiple 32-bit words supported).

#### B. READ_BLOCK (0x10)
Reads data from the internal Wishbone bus.
*   `op_id`: `0x10`
*   `address`: 32-bit Wishbone Address.
*   The hardware returns an FCSP frame containing the register data.

### 0x05: STREAM PLANE (ESC Serial Bridge)
This channel is a binary "tunnel" for high-volume ESC configuration (MSP, 4-Way).
*   **Payload**: Raw binary bytes to be sent over the UART engine.
*   **Arbitration**: The hardware `fcsp_router` extracts bytes from this channel and bridges them directly to the serial engine, bypassing the Wishbone master.
*   **Response**: Bytes received from the ESC are autonomously wrapped in FCSP Channel `0x05` frames and returned to the host.

---

## 3. Production Memory Map (Wishbone)

**Addressing note:** this repo uses both absolute addresses (e.g., `0x40000400`) and relative register offsets (e.g., `0x0020`) in different docs. They refer to the same registers via base + offset mapping.

| Absolute Address | Relative Offset | Peripheral | Feature | Description |
|---|---|---|---|
| `0x40000300` | `0x0000` | **DShot RAW** | [31:0] | Write a complete 16-bit DShot word (Throttle, Telem, CRC). |
| `0x40000340` | N/A | **DShot SMART** | [15:0] | **Bridge Helper**: Write only (Throttle[15:5] + Telem[4]). FPGA calculates CRC[3:0] automatically. |
| `0x40000400` | `0x0020` | **Serial Mux** | [31:0] | Bit 0: Mode (0:Serial, 1:DShot). Bits 2:1: Channel. Bit 4: Force Low. |
| `0x40000600` | `0x0010` | **NeoPixel** | [23:0] | 24-bit RGB Color value for the status strip. |
| `0x40000800` | N/A | **USB UART** | [31:0] | Configuration and status for the host link. |
| `0x40000900` | N/A | **ESC UART** | [31:0] | Register access for serial bytes (if not using Stream Channel 0x05). |
| `0x4000090C` | N/A | **Baud Rate** | [31:0] | Programmable UART clock divider (default 19200). |

---

## 4. Theory of Operation: MSP-over-FCSP

To configure ESCs, the host configurator uses a "Nested Protocol" strategy:
1.  **Cargo (MSP)**: The configurator generates a standard MSP packet (e.g. `$M<F5...` for passthrough).
2.  **Carrier (FCSP)**: The Python code wraps that MSP byte-stream into an **FCSP Channel 0x05** frame.
3.  **Extraction**: The hardware router extracts the MSP cargo.
4.  **Execution**: The **Mux Sniffer** sees the `$M<` header in the extracted stream and automatically triggers the physical pin switch to Serial Mode.
5.  **DShot Update**: For flight, the Python code sends **FCSP Channel 0x01** packets to the **Smart DShot** registers (`0x40000340`), providing a low-overhead path for high-frequency throttle updates.

---
*Document Revision: 2.2 (Current RTL-aligned channel/address definition)*
