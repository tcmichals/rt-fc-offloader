# BLHeli Passthrough Configuration Guide

## Overview

The Tang9K FPGA uses a finalized hardware-only architecture to bridge BLHeli ESC configuration between a PC and the ESCs. The system manages the 4-Way Interface protocol and UART bridging directly in RTL, providing a transparent link for ESC configurators.

## Architecture

```
PC (BLHeliSuite / ESC Configurator)
        ↓ USB (115200 baud)
   USB UART → Hardware Router → ESC UART
                                   ↓ (19200 baud, half-duplex)
                               Motor Pin [mux_ch]
                                   ↓
                                  ESC
```

### How It Works

1. **Hardware Router monitors the USB UART** for FCSP or 4-Way protocol frames.
2. The hardware responds to **MSP_BATTERY_STATE** (CMD 130) requests if integrated (or relies on the host FC for MSP responses).
3. When a **Passthrough Mode** is enabled via a control register (0x020):
   - The motor pin mux switches to UART mode.
   - 4-Way binary frames from the PC are forwarded to the ESC at 19200 baud.
4. ESC responses are captured and returned to the PC.
5. When complete, the host restores DSHOT mode via the same register.

### Key Registers (Control Plane)

| Address       | Register       | Description                                  |
|---------------|----------------|----------------------------------------------|
| 0x0000        | DShot Words L  | Motors 0, 1 data                             |
| 0x0004        | DShot Words H  | Motors 2, 3 data                             |
| 0x0020        | Mode Register  | `0`: DShot Mode, `1`: Serial Passthrough Mode |

### 4-Way Interface Protocol

Modern configurators wrap commands in the **Betaflight 4-Way Interface Protocol**:

| Byte  | Value  | Name    | Description                 |
|-------|--------|---------|-----------------------------|
| 0     | `0x2F` | Sync    | Header (PC → FC)            |
| 1     | `CMD`  | Command | 4-way command ID            |
| 2-3   | `ADDR` | Address | Target address              |
| 4     | `LEN`  | Length  | Length of parameters        |
| 5..   | `DATA` | Params  | Command parameters          |
| N-1..N| `CRC`  | CRC16   | CRC16-XMODEM checksum       |

### Bootloader Software UART Timing

The BLHeli bootloader uses **bit-banged (software) UART** at 19200 baud on the motor signal wire.

**Critical Timing:**
- **Break Signal**: Hold the motor pin LOW for ~100-250ms to trigger bootloader entry.
- **Send BootInit**: Send 8 zeros + 0x0D + "BLHeli" + CRC16.
- **Byte Frame Format (19200 8N1)**: 52µs per bit.

## Practical Usage with Pure Hardware Switch

Because the switch is now in hardware, the host script (Python) has precise control over the "Break" timing:
1. Write `1` to register `0x020` (Enables Passthrough Mode).
2. Wait 100ms (Hardware holds output at IDLE/HIGH by default or follows the serial stream).
3. Send the 4-way frames via the ESC_SERIAL channel (0x05).

## Safety Notes

⚠️ **IMPORTANT**:
- **Remove propellers** before configuring ESCs.
- **Passthrough mode disables DSHOT**: Motors will not respond during configuration.
- Restore DSHOT mode (Register `0x020` = `0`) before attempting flight.
