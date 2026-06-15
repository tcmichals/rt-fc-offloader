# BLHeli ESC Passthrough — Quick Reference

> For the full passthrough theory of operation, see [BLHELI_PASSTHROUGH.md](BLHELI_PASSTHROUGH.md).
> For the register map and hardware details, see [DESIGN.md](DESIGN.md) §5–6.

## Prerequisites

1. **Tang Nano 9K FPGA board** — programmed with the latest bitstream
2. **USB-to-TTL serial adapter** — internal Tang Nano USB-UART or external adapter
3. **ESC configurator software** — [ESC Configurator](https://esc-configurator.com), BLHeliSuite, or BLHeli Configurator

## Wiring

Motor signal wires (Signal + GND) connect to the Tang Nano 9K bidirectional motor pads:

| Motor | Pin | Signal Name |
|-------|-----|-------------|
| Motor 1 | 51 | `pad_motor[0]` |
| Motor 2 | 42 | `pad_motor[1]` |
| Motor 3 | 41 | `pad_motor[2]` |
| Motor 4 | 35 | `pad_motor[3]` |

> **Important:** FPGA GND and ESC power supply GND must be connected. Without a common ground reference, serial signals will be corrupted.

> **Full pin table:** [HARDWARE_PINS.md](HARDWARE_PINS.md)

## Quick Start

### Step 1 — Enable Passthrough Mode

The host writes the Serial/DShot Mux register (`0x40000400`) to switch the target motor pad from DShot to serial mode:

```
WRITE_BLOCK 0x40000400 ← 0x00000000   # Serial mode, motor 1
```

This disconnects the DShot pulse engine and routes the ESC serial stream (Channel 0x05) to the selected motor pad.

### Step 2 — Connect Configurator

Open the ESC configurator and connect to the Tang Nano USB-UART port (typically `/dev/ttyUSB0` or `/dev/ttyACM0`). The USB link operates at 2 Mbaud (Tang Nano 20K) or 1 Mbaud (Tang Nano 9K).

### Step 3 — Configure ESC

Use the configurator's standard read/write operations. All serial traffic is tunneled through FCSP Channel 0x05 to the selected motor pad at hardware speed.

### Step 4 — Restore DShot

After configuration is complete, restore DShot mode:

```
WRITE_BLOCK 0x40000400 ← 0x00000001   # DShot mode (default)
```

If the Python process crashes or the configurator disconnects, the MSP sniffer watchdog automatically reverts to DShot mode after 5 seconds of inactivity.

## Mode Reference

| Mode | Register Value | Effect |
|------|---------------|--------|
| DShot (default) | `0x40000400 = 0x01` | Motor pads driven by DShot pulse engine |
| Serial passthrough | `0x40000400 = 0x00` | Motor pad routed to ESC serial stream |
| Bootloader break | `0x40000400 = 0x14` | Selected motor pad forced LOW (hold ≥20 ms, then release) |

> **Detailed passthrough sequence and bootloader entry:** [DESIGN.md](DESIGN.md) §6

## Python Example

A working Python example for ESC communication is available at `python/hw/example_esc_flash.py`. This script demonstrates:

- Switching to serial mode on a target motor
- Asserting break to enter ESC bootloader
- Sending BLHeli 4-way commands
- Restoring DShot mode

**Usage:**
```bash
python3 python/hw/example_esc_flash.py --port /dev/ttyUSB0 --motor 0
```

**Options:**
- `--port`: Serial port (default: `/dev/ttyUSB0`)
- `--baud`: FCSP baud rate (default: `115200`)
- `--motor`: Motor channel 0-3 (default: `0`)
- `--break-ms`: Break hold time in ms (default: `50`)

For full ESC passthrough testing with EEPROM reading, see `python/hw/test_hw_esc_passthrough.py`.
