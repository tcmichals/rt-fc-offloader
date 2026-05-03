## What Is an ESC?

An Electronic Speed Controller (ESC) is the small board that sits between your flight controller and each brushless motor. The flight controller does not drive the motor directly — it sends commands to the ESC, and the ESC converts those commands into the three-phase power pulses that spin the motor.

Every motor on a drone has its own dedicated ESC. On modern mini-quads the four ESCs are often combined onto a single board called a 4-in-1 ESC, but they are still four independent controllers internally.

The ESC runs its own firmware. The two most common open-source firmware families are:

BLHeli_S — the older, widely-used firmware. Runs on SiLabs EFM8 8051-class microcontrollers. Supports PWM, OneShot, and DShot input protocols. No longer actively developed but still found on millions of boards.

Bluejay — an open-source fork of BLHeli_S, also targeting SiLabs EFM8. Adds bidirectional DShot (eRPM telemetry back to the FC), Extended DShot Telemetry (temperature, current, voltage), and configurable PWM frequencies (24/48/96 kHz). This is the modern replacement for BLHeli_S.

BLHeli_32 — a separate, closed-source firmware for STM32-based ESCs. Not covered here.


How the ESC receives commands — the signal wire

The flight controller talks to each ESC over a single wire plus ground. That one signal wire carries everything: throttle commands during flight, and serial configuration data during setup.

The three main input protocols used on that wire are:

PWM (Analog) — the oldest method. The FC sends a pulse between 1000 and 2000 microseconds wide, repeated ~400 times per second. Simple but slow and not very precise.

DShot — a fully digital protocol. The FC sends a 16-bit frame encoding a 0-2047 throttle value plus a CRC, at 150, 300, or 600 kbit/s. No calibration needed, immune to analog noise, and supports special commands (motor direction, save settings, enter bootloader). This is the standard on all modern builds.

Serial (UART) — used only for configuration and firmware flashing. The same signal wire switches to a 1-wire half-duplex UART at 19200 baud. The ESC configurator software on a PC communicates with the ESC bootloader over this link.

The key insight: during flight the wire carries DShot frames. During configuration it carries serial UART bytes. The flight controller has to switch the wire between these two uses.


How a Flight Controller Uses MSP to Configure ESCs

MSP stands for MultiWii Serial Protocol. It is the command protocol used by Betaflight, Cleanflight, and similar flight controller firmware to talk to ground-station software (like Betaflight Configurator) over USB. When you plug a flight controller into your PC, you are speaking MSP over a virtual serial port.

MSP is a simple request-response protocol. The PC sends a framed command with a function code and optional payload. The FC processes it and sends back a response. Function codes cover everything from reading sensor data and PID values to saving settings and rebooting.

One of those function codes is the ESC passthrough command. When the PC (running BLHeli Configurator or ESC Configurator) wants to talk directly to a motor ESC, it sends a special MSP command to the FC asking it to enter passthrough mode for a specific motor.

What the flight controller does in passthrough mode:

The FC stops sending DShot frames on the selected motor output pin. It then takes every byte arriving on its USB serial port and bit-bangs it out to the motor signal pin as a raw UART byte (at 19200 baud, half-duplex). Responses from the ESC come back on the same pin and are forwarded back to the USB port. The PC software has no idea it is talking through an intermediary — from its perspective it is speaking directly to the ESC.

This chain looks like:

PC (ESC Configurator) --- USB/MSP ---> FC CPU ---> bit-bang UART ---> ESC signal pin ---> ESC bootloader

The weakness: the FC CPU is doing software bit-bang UART while also running its normal scheduler (sensor reads, PID loops, LED updates). Any interrupt or task preemption introduces jitter on the serial timing. During a firmware flash this can cause byte framing errors, bootloader timeouts, or in the worst case a partially-written flash that bricks the ESC.


How We Tested the Python ESC Configurator — Pico PIO Bring-Up

Before the full FPGA offloader datapath was complete, the ESC configurator Python code was validated on a Raspberry Pi Pico (RP2040) using its PIO (Programmable I/O) hardware.

The Pico bring-up path kept close to MSP-style workflows so the Python GUI and ESC configuration logic could be exercised quickly with minimal moving parts. The goal was not to replace the FPGA — it was to prove the Python side of the stack (4-way BLHeli protocol, settings read/write, firmware flash) against a real ESC before plugging in the more complex FPGA transport.

The Pico is small and cheap — about $4. But even PIO has limits: each RP2040 has two PIO blocks with four state machines each. Managing four motor outputs plus four half-duplex serial engines simultaneously, at high DShot rates, pushes against those limits. A small FPGA like the Tang Nano 9K gives you purpose-built RTL for each engine, all running in parallel, with no CPU at all. The trade-off is cost — the Tang Nano 9K is roughly $15-18 — but for a flight controller that needs deterministic timing on every motor output simultaneously, it is the cleaner architecture.

The DShot to ESC Serial transition on the Pico:

The key challenge was that DShot and ESC serial are fundamentally incompatible uses of the same motor signal pin. DShot is a continuous high-speed output. ESC serial is a half-duplex bidirectional link at a much lower baud rate. The motor pin has to stop being one thing and become the other — and the transition has to be clean or the ESC will not enter its bootloader.

On the Pico, ownership of the motor pin was handed between PIO state machines. The full transition sequence was:

Step 1 — Stop DShot output: The DShot PIO state machine was stopped and the motor pin released to a known idle-high state.

Step 2 — Assert the break pulse: A separate PIO program drove the pin LOW for at least 20 ms (50 ms used in practice for margin). This is the bootloader entry signal. The ESC is watching for this and will not enter bootloader mode if the pulse is too short.

Step 3 — Release and idle: The pin was released HIGH for a short recovery interval before serial communication began.

Step 4 — Start the PIO serial engine: The same motor pin was handed to a PIO-based half-duplex UART state machine configured for 19200 baud 8N1. PIO was used here — not software UART — specifically because the ESC bootloader is strict about timing. Any inter-byte gap caused by interrupt preemption or scheduler jitter can cause the bootloader to abort the session.

Step 5 — Run the 4-way BLHeli protocol: The Python ESC configurator sent BLHeli 4-way commands (test_alive, get_version, get_name, init_flash, read_eeprom) through the PIO UART. Responses came back on the same pin and were read by the same PIO state machine. The protocol used CRC-16/XMODEM framing and a sync byte (0x2F host → 0x2E ESC) on every frame.

Step 6 — Exit and restore DShot: On exit the PIO serial engine was stopped and pin ownership returned to the DShot state machine.

This was validated against a single ESC and motor. The test script is at python/hw/test_hw_esc_passthrough.py in the repo.

Why move to an FPGA: The Pico PIO approach proved the protocol and the Python stack worked. But it only handled one motor at a time, the PIO instruction memory limited how complex the state machines could get, and any future additions (telemetry, bidirectional DShot, logging) would compete for the same limited PIO resources. The FPGA replaced PIO with RTL that does the same job — but all four motors simultaneously, at higher link speed, with no CPU involvement and no resource contention.


## The Problem

When you want to tune a motor ESC — change timing, demag, or motor direction — you need to get a configurator talking directly to it. In stock Betaflight/Cleanflight setups this is done via **MSP passthrough**: the flight controller CPU intercepts the USB serial stream and bit-bangs it out to the motor signal pin.

That works, but it is fragile. The CPU has to drop flight tasks, the timing is subject to scheduler jitter, and if the configurator times out mid-flash you can brick an ESC.

We built something better.

## The Hardware

**rt-fc-offloader** is an open-source FPGA project (Tang Nano 9K, Gowin toolchain) that sits between a Raspberry Pi Zero 2W flight controller and up to four ESCs. During normal flight it generates DShot pulses deterministically in RTL — no CPU involvement. But when you need to configure an ESC, the same hardware switches modes.

The key register is at address `0x40000400` — the Serial/DShot Mux:

| Mode | Value | Effect |
|------|-------|--------|
| DShot (default) | `0x01` | Motor pads driven by DShot pulse engine |
| Serial passthrough | `0x00` | Motor pad routed to ESC serial (FCSP Ch 0x05) |
| Bootloader break | `0x14` | Selected pad forced LOW (hold 20+ ms, then release) |

## How ESC Bootloaders Are Entered

BLHeli/Bluejay ESCs enter their bootloader via a break sequence on the signal wire:

1. Force the motor signal pin **LOW** for at least 20 ms
2. Release the pin
3. Start 19200 baud half-duplex serial communication

In Betaflight this break is done in software — vulnerable to interrupt latency. In rt-fc-offloader the `force_low` bit is a single register write, and the RTL holds it for exactly as long as you ask. Nanosecond accurate.

```python
wb_write(0x40000400, 0x14)   # serial mode, motor 1, force LOW
time.sleep(0.025)            # hold 25 ms
wb_write(0x40000400, 0x00)   # release, stay in serial mode
# ESC is now in bootloader at 19200 baud
```

## The FCSP Transport Layer

The Pi talks to the FPGA over USB-UART using the **Flight Controller Serial Protocol (FCSP)**:

- **Channel 0x01 (CONTROL)** — Wishbone register reads/writes (switching, baud rate config)
- **Channel 0x05 (ESC_SERIAL)** — raw byte tunnel to/from the selected motor pad

Once in serial mode, all configurator traffic is just Channel 0x05 frames. No address headers, no overhead — up to 512 bytes per frame at 1 Mbaud link speed.

The hardware UART engine handles 1-wire half-duplex automatically: pin defaults to input (listening), flips to output the instant you send a byte, then flips back after a guard period. Python never touches a direction register.

## Flashing ESC Firmware

Once the ESC is in bootloader mode, the same FCSP Channel 0x05 tunnel carries the full BLHeli flash protocol. Same byte pipe, now speaking the bootloader command set at 19200 baud 8N1.

**BLHeli Bootloader Protocol:**

| Step | What Happens |
|------|-------------|
| Handshake | Host sends `"BLHeli"` string byte-by-byte |
| Ident | ESC replies with boot info, chip signature, bootloader version |
| Set address | Host sends `0xFF` + 16-bit address + CRC16 |
| Set buffer | Host sends `0xFE` + size + CRC16, then raw firmware bytes |
| Program flash | Host sends `0x01` + CRC16 — ESC writes buffer to flash |
| Erase page | Host sends `0x02` + CRC16 — ESC erases flash page |
| Read flash | Host sends `0x03` + count + CRC16 — ESC replies with data |
| Run app | Host sends `0x00 0x00` + CRC16 — ESC restarts firmware |

Each command returns a status byte: `0x30` = success, `0xC0`–`0xC5` = error. CRC is CRC-16/IBM (poly `0xA001`).

**Why this beats Betaflight passthrough:** In Betaflight the CPU relays bytes while also running flight tasks. If the scheduler delays a byte by even one UART frame time, the bootloader can time out and corrupt the flash. In rt-fc-offloader the FCSP to UART path is pure hardware — no task switching, no preemption, no jitter.

```python
# 1. Enter serial mode, select motor 2
wb_write(0x40000400, 0x00000004)

# 2. Assert break — hold 25 ms
wb_write(0x40000400, 0x00000014)
time.sleep(0.025)

# 3. Release — ESC bootloader now listening at 19200 baud
wb_write(0x40000400, 0x00000004)

# 4. BLHeli handshake
fcsp_send(CH_ESC_SERIAL, b"BLHeli")
ident = fcsp_recv(CH_ESC_SERIAL)

# 5. Flash loop
for addr, chunk in firmware_pages:
    fcsp_send(CH_ESC_SERIAL, cmd_set_address(addr))
    fcsp_send(CH_ESC_SERIAL, cmd_set_buffer(chunk))
    fcsp_send(CH_ESC_SERIAL, cmd_program_flash())
    assert fcsp_recv(CH_ESC_SERIAL)[0] == 0x30  # success

# 6. Restart ESC, restore DShot
fcsp_send(CH_ESC_SERIAL, cmd_run_app())
wb_write(0x40000400, 0x00000001)
```

The **python-imgui-esc-configurator** companion app wraps all of this into a GUI — select motor, click Flash, pick a `.hex` file, done.

## Safety

A watchdog in the MSP sniffer module reverts the mux to DShot mode after **5 seconds of inactivity** on the FCSP channel. If the configurator crashes mid-session, the motor pads go back to DShot without any intervention.

## Try It

- **Repo:** https://github.com/tcmichals/rt-fc-offloader
- **Passthrough doc:** https://github.com/tcmichals/rt-fc-offloader/blob/main/docs/BLHELI_PASSTHROUGH.md
- **Python ImGui configurator:** https://github.com/tcmichals/python-imgui-esc-configurator

## For More Details (rt-fc-offloader docs)

- **System overview:** https://github.com/tcmichals/rt-fc-offloader/blob/main/docs/SYSTEM_OVERVIEW.md
- **Master architecture/reference:** https://github.com/tcmichals/rt-fc-offloader/blob/main/docs/DESIGN.md
- **FCSP protocol:** https://github.com/tcmichals/rt-fc-offloader/blob/main/docs/FCSP_PROTOCOL.md
- **FCSP over SPI transport:** https://github.com/tcmichals/rt-fc-offloader/blob/main/docs/FCSP_SPI_TRANSPORT.md
- **Command translation (MSP/4-way path):** https://github.com/tcmichals/rt-fc-offloader/blob/main/docs/FCSP_COMMAND_TRANSLATION.md
- **BLHeli passthrough theory:** https://github.com/tcmichals/rt-fc-offloader/blob/main/docs/BLHELI_PASSTHROUGH.md
- **BLHeli quickstart/wiring:** https://github.com/tcmichals/rt-fc-offloader/blob/main/docs/BLHELI_QUICKSTART.md
- **Bluejay firmware analysis:** https://github.com/tcmichals/rt-fc-offloader/blob/main/docs/BLUEJAY_ESC_ANALYSIS.md
- **Validation matrix:** https://github.com/tcmichals/rt-fc-offloader/blob/main/docs/VALIDATION_MATRIX.md
