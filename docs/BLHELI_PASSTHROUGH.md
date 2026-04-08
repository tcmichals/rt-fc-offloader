# Theory of Operation: ESC Passthrough (for Python Developers)

This document describes how the **ESC Configurator Python code** should interact with the Pure Hardware Offloader to configure or flash motor ESCs.

> **Quick start:** [BLHELI_QUICKSTART.md](BLHELI_QUICKSTART.md) — wiring and step-by-step usage.
> **Register map:** [DESIGN.md](DESIGN.md) §5 — complete per-peripheral register definitions.
> **Bootloader entry sequence:** [DESIGN.md](DESIGN.md) §6 — full hardware-level sequence.
> **ESC firmware internals:** [BLUEJAY_ESC_ANALYSIS.md](BLUEJAY_ESC_ANALYSIS.md) — Bluejay bootloader and DShot protocol.

## 1. Unified Transport (FCSP)
The offloader abstracts the physical USB connection using the **Flight Controller Serial Protocol (FCSP)**. All communication happens over two logical channels:
*   **Channel 0x01 (CONTROL)**: Used for Wishbone register writes (Configuration/Switching).
*   **Channel 0x05 (ESC_SERIAL)**: Used for high-speed serial data (Firmware/Telemetry).

## 2. The Step-by-Step Handshake

To successfully enter ESC Passthrough mode, the Python code follows this three-stage process:

### Stage A: Hardware Steering (Wishbone)
Before sending serial data, you must "steer" the hardware mux to the correct motor channel.
1.  **Select Motor**: Write to address `0x40000400` (Serial Mux).
    *   Set **Bit 0**: `0` (Serial Mode).
    *   Set **Bits 2:1**: `0-3` (Which motor channel to talk to).
2.  **Trigger Bootloader (Optional)**: If the ESC requires a "Break" signal to enter the bootloader:
    *   Set **Bit 4**: `1` (Force Pin Low).
    *   `time.sleep(0.25)` in Python.
    *   Set **Bit 4**: `0` (Release Pin).

### Stage B: Data Tunneling (Stream)
Once the mux is steered, the hardware provides a direct, low-latency tunnel between your Python code and the motor pin.
1.  **Send Data**: Package your 4-way protocol or MSP packets into FCSP frames on **Channel 0x05**.
    *   The hardware router extracts these bytes and feeds them to the UART engine.
    *   **Overhead**: Zero. You can send up to 512 bytes per FCSP frame.
2.  **Receive Data**: Responses from the ESC are automatically wrapped into FCSP frames on **Channel 0x05** and sent back to your Python `read()` loop.

### Stage C: Cleanup
After flashing is complete, restore the system for flight:
1.  **Restore DShot**: Write to address `0x40000400` with **Bit 0 = 1**.
2.  **Safety Watchdog**: If the Python process crashes, the hardware will automatically revert to DShot mode after **5 seconds** of inactivity.

## 3. Half-Duplex Arbitration
The hardware UART engine manages the **1-wire half-duplex** timing (standard for BLHeli):
*   By default, the pin is an **Input** (listening to ESC).
*   As soon as you send a byte over the `ESC_SERIAL` stream, the hardware automatically flips the pin to **Output**, drives the bits, then flips back to **Input** after a small guard period.
*   The Python code does not need to manage the "TX Enable" signal; the hardware handles it automatically.

## 4. Baud Rate Selection
Different ESC protocols or bootloaders may use different speeds.
*   **Default**: 19200 baud (standard for BLHeli).
*   **Custom**: Write the desired "Clocks-per-bit" divider to address `0x4000090C`.
    *   Example for 19200 @ 54MHz: `54000000 / 19200 = 2812`.

---

## Why This Implementation is Robust
1.  **Deterministic Switching**: Because the switch is in RTL (logic gates), the timing of the "Break" signal is accurate to the nanosecond.
2.  **High Throughput**: Bulk data (Channel 0x05) avoids the overhead of memory-mapped address headers, maximizing USB-UART bandwidth.
3.  **No CPU Jitter**: Unlike Betaflight, there is no software task scheduling that could cause a serial timeout during a sensitive firmware flash.
