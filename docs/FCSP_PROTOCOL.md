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
| `0x01` | CONTROL | Routed to `fcsp_wishbone_master` — decodes READ_BLOCK/WRITE_BLOCK and drives WB bus directly |
| `0x02` | TELEMETRY | Routed by `fcsp_router`, currently tied-off in top-level (accepted then dropped) |
| `0x03` | FC_LOG | Routed by `fcsp_router`, currently tied-off in top-level (accepted then dropped) |
| `0x04` | DEBUG_TRACE | Routed by `fcsp_router`, currently tied-off in top-level (accepted then dropped) |
| `0x05` | ESC_SERIAL | Routed to ESC serial stream path |

### 0x01: CONTROL PLANE
This channel is used for memory-mapped configuration and control semantics. `fcsp_wishbone_master` decodes the payload and drives the Wishbone bus directly. Payload op semantics:

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
*   **Response**: Bytes received from the ESC are collected by `fcsp_stream_packetizer`, wrapped in FCSP Channel `0x05` frames, and returned to the host via the TX arbiter.
*   **Current status**: Full TX/RX path wired through `fcsp_io_engines`. Router → ESC UART TX → motor pad → RX → packetizer → TX arbiter. Verified in cocotb.

> **Datapath details and RTL module hierarchy:** [DESIGN.md](DESIGN.md) §1–3
> **ESC passthrough operating procedure:** [BLHELI_PASSTHROUGH.md](BLHELI_PASSTHROUGH.md)

---

## 3. Production Memory Map (Wishbone)

**Addressing note:** this repo uses both absolute addresses (e.g., `0x40000400`) and relative register offsets (e.g., `0x0020`) in different docs. They refer to the same registers via base + offset mapping.

| Absolute Address | Relative Offset | Peripheral | Feature | Description |
|---|---|---|---|
| `0x40000000` | N/A | **WHO_AM_I** | [31:0] | Read-only ID register. Returns `0xFC500002`. |
| `0x40000100` | N/A | **PWM Decoder** | [31:0] | 6-channel pulse width measurement (read-only). |
| `0x40000300` | `0x00–0x0C` | **DShot RAW** | [15:0] | Write a complete 16-bit DShot word per motor (1–4). |
| `0x40000310` | `0x10` | **DShot CONFIG** | [1:0] | DShot mode select (150/300/600). |
| `0x40000314` | `0x14` | **DShot STATUS** | [3:0] | Per-motor ready bits (read-only). |
| `0x40000400` | `0x00` | **Serial Mux** | [4:0] | Bit 0: Mode (0:Serial, 1:DShot). Bits 2:1: Channel. Bit 3: MSP mode. Bit 4: Force Low. |
| `0x40000600` | `0x00–0x1C` | **NeoPixel** | [23:0] | 8-pixel RGB color buffer. |
| `0x40000620` | `≥0x20` | **NeoPixel Trigger** | W | Any write triggers strip transmission. |
| `0x40000900` | `0x00` | **ESC UART TX** | [7:0] | Write byte to transmit. |
| `0x40000904` | `0x04` | **ESC UART STATUS** | [2:0] | [0]=tx_ready, [1]=rx_valid, [2]=tx_active. |
| `0x40000908` | `0x08` | **ESC UART RX** | [7:0] | Read received byte (clears rx_valid). |
| `0x4000090C` | `0x0C` | **ESC UART BAUD** | [15:0] | Clocks-per-bit divider (default 19200). |
| `0x40000C00` | `0x00–0x0C` | **LED Controller** | [5:0] | SET/CLEAR/TOGGLE/READ for 6 LEDs. |

> **Note:** `0x40000340` (DShot SMART throttle) and `0x40000800` (USB UART) appear in older docs but are **not implemented** in current RTL. See [DESIGN.md](DESIGN.md) §12.3 for implementation plan.

---

## 4. Theory of Operation: MSP-over-FCSP

To configure ESCs, the host configurator uses a "Nested Protocol" strategy:
1.  **Cargo (MSP)**: The configurator generates a standard MSP packet (e.g. `$M<F5...` for passthrough).
2.  **Carrier (FCSP)**: The Python code wraps that MSP byte-stream into an **FCSP Channel 0x05** frame.
3.  **Extraction**: The hardware router extracts the MSP cargo.
4.  **Execution**: The **Mux Sniffer** sees the `$M<` header in the extracted stream and automatically triggers the physical pin switch to Serial Mode.
5.  **DShot Update**: For flight, the Python code sends **FCSP Channel 0x01** packets with `WRITE_BLOCK` to the DShot registers (`0x40000300–0x4000030C`), writing raw 16-bit DShot words per motor.

---
*Document Revision: 4.0 (Updated: CH 0x05 wired, fcsp_wishbone_master active, Apr 2026)*
