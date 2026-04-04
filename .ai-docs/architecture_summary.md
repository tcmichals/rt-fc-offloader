# AI Architecture Summary: Pure Hardware FCSP Offloader

This document acts as a common source of truth for all AI coding assistants (Antigravity, Cursor, Cline, etc.) when working on this repository.

## Design Philosophy: Zero-CPU Mandate
This project implements a high-performance flight controller offloader specifically for the **Tang Nano 9K** and **Pico 2**. 

The core architectural decision is a **Pure Hardware RTL Switch/Router**. All software/firmware dependencies (previously provided by a SERV RISC-V CPU) have been REMOVED in favor of:

1. **Hardware-Native FCSP Parser**: Resynchronizes on `0xA5`, validates CRC16-XMODEM, and routes frames by channel.
2. **Hardware Wishbone Master**: Translates FCSP `WRITE_BLOCK` / `READ_BLOCK` directly to internal 32-bit Wishbone transactions.
3. **Deterministic Hardware Switch**: Nanosecond-accurate toggling between DShot (flight) and Serial (config) on the physical motor pins.

## Hardware Registers (Wishbone Map)

The `fcsp_wishbone_master` handles Channel `0x01` (CONTROL) and updates these registers:

| Address | Register | Description |
|---|---|---|
| `0x00` | DShot 0, 1 | 16-bit counts for Motors 0 and 1 |
| `0x04` | DShot 2, 3 | 16-bit counts for Motors 2 and 3 |
| `0x10` | NeoPixel | 24-bit RGB status led |
| `0x20` | Mode Select | **The Hard Switch**. Bit 0=Mode (0:DShot, 1:Serial); Bit 4=Force Low (Break). |

## Passthrough & Bootloader Entry
To trigger an ESC bootloader, use the **Hardware Break Signal**:
1. Enable Passthrough (`0x20[0]=1`).
2. Set Force Low (`0x20[4]=1`).
3. Wait 150ms.
4. Release Force Low (`0x20[4]=0`).
5. Communicate over Channel `0x05`.

## Link Performance Targets
- **Clock**: 54 MHz (Tang Nano 9K).
- **USB-Link**: 1.0 Mbaud (FCSP over USB).
- **Control Latency**: Sub-microsecond (Hardware execution).

---
*Any AI agent opening this project must prioritize RTL-based solutions and strictly avoid introducing firmware/software dependencies inside the FPGA.*
