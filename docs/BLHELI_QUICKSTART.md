# Tang Nano 9K BLHeli Passthrough - Quick Reference

## What You Need

1. **Tang Nano 9K FPGA board** (programmed with latest bitstream)
2. **USB-to-TTL serial adapter** (internal Tang Nano USB or external)
3. **BLHeliSuite** or **BLHeliConfigurator** software

## Wiring (Critical!)

The motor signal wires (GND + Signal) should be connected to the Tang Nano pins. For quadcopters, these are:
- **Motor 1**: o_motor1
- **Motor 2**: o_motor2
- **Motor 3**: o_motor3
- **Motor 4**: o_motor4

## Quick Start (Using Hardware Switch)

### 1. Enable Passthrough
The host script must enable the hardware bridge:
```bash
# Write '1' into register 0x020 (The Switch)
# This instantly maps all motor pins to the ESC Serial stream (Channel 0x05).
```

### 2. Find Serial Port
The configurator should connect to the Tang Nano's USB-UART port (typically `/dev/ttyUSB0` or `/dev/ttyACM0`).

### 3. Configure BLHeli
- Open BLHeliSuite, [ESC Configurator](https://esc-configurator.com), etc.
- Set baud rate to **115200** for the USB Link.
- Click "Connect" or "Read Setup".

### 4. Done!
- Configure your ESC settings as needed.
- Write `0` back into register `0x020` when done to restore DShot flight mode.

## How It Works

```
Your PC → USB → FPGA Hardware Bridge (Channel 0x05) → ESC Pins
```

- **Hardware Handlers**: No software bridging is involved. Bits flow at the 54MHz system clock.
- **Protocol**: 4-Way passthrough is handled natively by the router.

## Common Mistake: Missing Common Ground

Ensure the ground (GND) of the FPGA and the ESC power source are tied together. Without a common ground, the serial signals will be corrupted.

## Mode Reference

| Mode   | Register 0x020 | Hardware Result |
|--------|----------------|-----------------|
| DShot  | `0` (Default)  | Motor pins are driven by the high-speed DShot Pulse Engine. |
| Serial | `1`            | Motor pins are wired directly to the ESC Configurator stream. |
