# Three Approaches to ESC Control and Programming: Bit-Banging, PICO/PIO, and FPGA RTL

This article explores three approaches to ESC communication and firmware flashing, comparing their strengths and weaknesses:

1. **Software Bit-Banging/DMA (STM32)** — The traditional approach used by Betaflight/Cleanflight on STM32 flight controllers, where the CPU uses DMA (Direct Memory Access) or manual GPIO toggling to generate UART timing. Fragile and timing-sensitive due to interrupt latency and scheduler jitter.

2. **PICO/PIO** — A proof-of-concept approach using the RP2040's Programmable I/O (PIO) state machines for deterministic timing. Demonstrated the hardware-based approach but hit resource limits.

3. **FPGA Offloader** — The production solution using RTL (Register Transfer Level) on an FPGA. Provides deterministic timing for all four motors simultaneously with zero CPU involvement.

The article also shows how AI can assist in translating PIO assembly to RTL, making the migration from proof-of-concept to production straightforward.

## Background: Understanding ESCs

### What Is an ESC?

An Electronic Speed Controller (ESC) is the small board that sits between your flight controller and each brushless motor. The flight controller does not drive the motor directly — it sends commands to the ESC, and the ESC converts those commands into the three-phase power pulses that spin the motor.

Every motor on a drone has its own dedicated ESC. On modern mini-quads the four ESCs are often combined onto a single board called a 4-in-1 ESC, but they are still four independent controllers internally.

The ESC runs its own firmware. The two most common open-source firmware families are:

BLHeli_S — the older, widely-used firmware. Runs on SiLabs EFM8 8051-class microcontrollers. Supports PWM, OneShot, and DShot input protocols. No longer actively developed but still found on millions of boards.

Bluejay — an open-source fork of BLHeli_S, also targeting SiLabs EFM8. Adds bidirectional DShot (eRPM telemetry back to the FC), Extended DShot Telemetry (temperature, current, voltage), and configurable PWM frequencies (24/48/96 kHz). This is the modern replacement for BLHeli_S.

BLHeli_32 — a separate, closed-source firmware for STM32-based ESCs. Not covered here.

### How the ESC Receives Commands

The flight controller talks to each ESC over a single wire plus ground. That one signal wire carries everything: throttle commands during flight, and serial configuration data during setup.

The three main input protocols used on that wire are:

PWM (Analog) — the oldest method. The FC sends a pulse between 1000 and 2000 microseconds wide, repeated ~400 times per second. Simple but slow and not very precise.

DShot — a fully digital protocol. The FC sends a 16-bit frame encoding a 0-2047 throttle value plus a CRC, at 150, 300, or 600 kbit/s. No calibration needed, immune to analog noise, and supports special commands (motor direction, save settings, enter bootloader). This is the standard on all modern builds.

Serial (UART) — used only for configuration and firmware flashing. The same signal wire switches to a 1-wire half-duplex UART at 19200 baud. The ESC configurator software on a PC communicates with the ESC bootloader over this link.

The key insight: during flight the wire carries DShot frames. During configuration it carries serial UART bytes. The flight controller has to switch the wire between these two uses.

## Approach 1: Software Bit-Banging/DMA (STM32 Traditional)

### The Problem: Software Bit-Banging/DMA is Fragile

Traditional STM32 flight controllers use software bit-banging or DMA (Direct Memory Access) to communicate with ESC bootloaders. The CPU manually toggles GPIO pins or configures DMA transfers to generate UART timing while simultaneously running flight tasks (sensor reads, PID loops, LED updates). This creates several problems:

- **Jitter**: Interrupts and task preemption introduce timing errors, even with DMA
- **Blocking**: The CPU is occupied during the entire flash operation or DMA setup
- **Risk**: A timing error mid-flash can corrupt the ESC firmware, bricking the motor
- **Slow**: Software overhead and DMA configuration limits the effective baud rate

### How STM32 Flight Controllers Do It

In Betaflight's `serial_4way_avrootloader.c`, the STM32 CPU handles the 19200 baud UART protocol using DMA transfers or tight `micros()` busy-wait loops. This blocks the CPU or requires complex DMA setup, and is highly sensitive to interrupt jitter. If the processor misses a bit-transition or DMA transfer timing due to a high-priority task, the serial frame is corrupted.

**The chain looks like:**
```
PC (ESC Configurator) --- USB/MSP ---> FC CPU ---> bit-bang UART ---> ESC signal pin ---> ESC bootloader
```

The weakness: the FC CPU is doing software bit-bang UART while also running its normal scheduler (sensor reads, PID loops, LED updates). Any interrupt or task preemption introduces jitter on the serial timing. During a firmware flash, this can cause byte framing errors, bootloader timeouts, or in the worst case, a partially-written flash that bricks the ESC.

## Approach 2: PICO/PIO (Proof of Concept)

### Proof of Concept: RP2040 Pico Implementation

Before moving to the FPGA, we first proved the concept using the RP2040 Pico. The Pico implementation served as an early validation platform, demonstrating that hardware-based timing could solve the jitter and blocking issues found in traditional software bit-banging approaches.

#### Harnessing the RP2040: Multi-Core Strategy

To solve the jitter and blocking issues found in traditional firmware, our Pico implementation leverages the dual-core architecture of the RP2040:

*   **Core 1: Background Tasks**: This core handles **debug UART logging** with a thread-safe queue. Core 1 performs the heavy snprintf formatting and writes to the debug UART, ensuring debug output never blocks the real-time core.
*   **Core 0: Real-Time Engine**: This is the "Master" core. It handles **MSP protocol over USB**, **DShot output via PIO**, and **ESC serial passthrough via PIO**. It manages all PIO state machines for motor control and ESC configurator communication.

#### The Multi-Core Logging Challenge: TLV to the Rescue
One of the hardest challenges in embedded systems is getting human-readable debug logs out of a real-time system without destroying its timing. String formatting functions like `snprintf` are incredibly slow—they can take thousands of CPU cycles. If Core 0 formats strings while managing DShot, it introduces unacceptable jitter. But if Core 0 simply passes pointers to local variables into a queue for Core 1 to print later, those variables will have been overwritten by the time Core 1 reads them, causing memory corruption.

Our solution was a lock-free **TLV (Type-Length-Value) encoded queue**. 
When Core 0 wants to log an event, it doesn't format anything. It simply writes a lightweight TLV packet into a lock-free queue. This packet contains:
1. A pointer to the format string literal (which lives safely in Flash memory).
2. The raw arguments (e.g., an integer for an ESC status code).

This takes only a handful of cycles. Core 1 then pulls these TLV packets from the queue, extracts the raw arguments, performs the heavy `snprintf` formatting, and bit-bangs it out to the debug UART. This completely isolates the real-time engine from the computational cost of logging.

**Example of the TLV approach:**
```c
// On Core 0 (Real-Time): Fast, lock-free enqueue (takes nanoseconds)
void log_esc_status_fast(int motor, int status) {
    uint32_t args[] = {motor, status};
    // Enqueue: Type (LOG), Length (2 words), Value (Format string pointer + arguments)
    tlv_queue_push(TYPE_LOG, "Motor %d status: 0x%02x\n", args, 2);
}

// On Core 1 (Background): Heavy formatting (takes microseconds)
void core1_worker_loop() {
    tlv_packet_t pkt;
    if (tlv_queue_pop(&pkt)) {
        if (pkt.type == TYPE_LOG) {
            char buffer[128];
            // Safe to take thousands of cycles here
            snprintf(buffer, sizeof(buffer), pkt.fmt_ptr, pkt.args[0], pkt.args[1]);
            uart_puts(DEBUG_UART, buffer);
        }
    }
}
```

> **Note:** PWM decoding and SPI slave functionality are now handled by the FPGA. The Pico focuses on MSP/USB, DShot, and ESC passthrough for early bring-up and ESC configurator workflows.

### Technical Showdown: PIO vs. Bit-Banging

The real innovation in the Pico implementation was moving away from the "software bit-banging" model used by traditional flight controllers like Betaflight.

**The Pico PIO Approach:**
On the RP2040, we offload the UART protocol to the PIO state machines. The CPU just drops bytes into a FIFO, and the PIO hardware handles the 8N1 framing (Start/Stop bits) with nanosecond-level precision. This is **non-blocking** and **deterministic**—the bit-timing is immune to whatever the CPU is doing.

```text
.program esc_uart_tx
.side_set 1 opt
pull        side 1 [7]   ; idle high / stop bit
set x, 7    side 0 [7]   ; start bit low
bitloop:
    out pins, 1          ; shift out 1 bit
    jmp x-- bitloop [6]  ; loop for 8 bits
    nop       side 1 [6] ; stop bit
```

**Hardware Half-Duplex:**
The Pico firmware explicitly manages the half-duplex transition. The PIO state machine is re-initialized the instant a TX frame finishes, ensuring it is ready to capture the ESC's response with zero latency.

### Why Move to an FPGA?

While the Pico PIO approach proved the protocol and the Python stack worked, we eventually hit a wall. The RP2040 has a hard limit of **32 PIO instructions** shared across all state machines. As we added features like NeoPixel status lights, 4-channel DShot, and ESC telemetry, we ran out of "instruction real estate."

The FPGA replaces PIO with hardwired RTL that does the same job—but for all four motors simultaneously, at higher link speeds, with zero CPU involvement and no resource contention.

## Approach 3: FPGA Offloader (Production Solution)

### The FPGA Architecture

The core of the offloader is a specialized RTL (Register Transfer Level) design that moves the entire timing-critical path into hardware gates.

```text
    [ SPI (Linux) ]   [ Serial (PC) ]
           |                 |
           v                 v
    +------------------------------+
    |      Host Ingress Mux        |
    +--------------+---------------+
                   |
                   v
    +------------------------------+
    |    FCSP Protocol Decoder     |
    |  (Header Sync, CRC16, Route) |
    +---+----------------------+---+
        |                      |
        v [ Channel Router ]   v
    +-------------+     +----------+
    | ESC Serial  |     | WB Master|
    | (Ch 0x05)   |     | (Ch 0x01)|
    +-----+-------+     +------+---+
          |                    |
          v                    v
    +-----------+   +---------------------------------+
    |  1-Wire   |   |          Wishbone Bus           |
    | UART Core |   +--+-----+-----+-----+-----+------+
    +-----+-----+      |     |     |     |     |
          |            v     v     v     v     v
          |        +-------+ +-------+ +-------+ +-------+
          |        | DShot | | NeoPX | | LED   | | PWM   |
          |        | Engine| | Engine| | Ctrl  | | Decode|
          |        +---+---+ +---+---+ +---+---+ +---+---+
          |            |         |         |         |
          v            v         v         v         v
    +-----------------------------------------------------+
    |                  Hardware Pin Mux                   |
    +--------------------------+--------------------------+
                               |
                               v
                       [ Physical Pins ]
```

### FPGA Deep Dive: Under the Hood

The FPGA implementation doesn't just replicate software; it fundamentally changes how data is processed by taking advantage of true hardware concurrency. Here are the specific technical implementations that make this possible:

**1. True Hardware Parallelism**
In a microcontroller, driving 4 DShot signals requires either an interrupt-heavy sequential loop or complex chained DMA channels. In the FPGA RTL, we literally instantiate four independent DShot state machines. They don't share execution time. Each motor gets its own dedicated silicon logic counting the exact 54MHz clock cycles required for DShot600, guaranteeing that motor 1 and motor 4 receive their pulses with zero relative phase jitter.

**2. Combinational Pin Muxing**
When switching a motor pin from DShot mode to ESC Serial passthrough mode, a microcontroller has to reconfigure GPIO registers, potentially causing brief glitches or floating states. In our FPGA (`fcsp_io_engines.sv`), the pin routing is a combinational logic multiplexer. When the Wishbone control register flips the mode bit, the physical pin routing switches from the DShot logic to the UART logic in less than one 18-nanosecond clock cycle, ensuring instantaneous, glitch-free handovers.

**3. On-The-Fly FCSP Parsing & Hardware CRC**
The flight controller speaks to the FPGA over a high-speed SPI bus using the FCSP protocol. Instead of buffering an entire packet into RAM and verifying it in software, the FPGA uses a streaming Finite State Machine (`fcsp_parser.sv`). It shifts bytes in, identifies the `0xAA` header, and pumps the payload through a parallel CRC-16 hardware calculator. The moment the final CRC byte is clocked in, the validation is ready. This reduces command latency from the flight controller to the motor from milliseconds down to microseconds.

**4. The Wishbone Backbone**
To make the architecture extensible, all internal engines (NeoPixel, DShot, PWM decoding) are hooked to a standardized 32-bit Wishbone bus. When the FCSP decoder receives a command on Channel `0x01` (CONTROL), it acts as a Wishbone Master. This means adding a new sensor or output protocol in the future simply requires hanging a new Wishbone slave module off the bus, without rewriting any routing logic.

**5. AXI-Stream Flow Control and Backpressure**
Moving data between the parser, the Wishbone master, and the UART streams requires managing data rates. The FPGA achieves this using AXI-Stream standard handshaking (`tvalid` and `tready`). If the downstream ESC UART cannot transmit fast enough (e.g., waiting for the 19200 baud transmission to complete), it lowers `tready`. This backpressure propagates natively back through the FPGA switch fabric, pausing the parser and flow-controlling the host automatically. No buffers overflow, and no data is lost during transport.

**6. Deterministic Hardware Turnaround**
In ESC passthrough mode, the protocol operates in half-duplex: the host sends a query, the ESC responds. Microcontrollers struggle with the exact timing of when to switch the transceiver from transmit to receive, often missing the first bit of the ESC's response. The FPGA UART core (`wb_esc_uart.sv`) transitions from TX to RX in exactly one clock cycle immediately following the stop bit of the transmitted byte, ensuring zero latency and 100% reliable frame capture.

### System Architecture

```
    [ Raspberry Pi Zero 2W ]
    (Betaflight/INAV Flight Controller)
                    |
                    | SPI / USB-UART
                    v
    +-----------------------------------------------+
    |           Tang Nano 9K FPGA                   |
    |                                               |
    |  +-----------------------------------------+  |
    |  |         FCSP Protocol Decoder           |  |
    |  |  (Header Sync, CRC16, Channel Router)   |  |
    |  +-------------------+---------------------+  |
    |                      |                        | 
    |          +-----------v-----------+            | 
    |          |   Channel 0x01       |             | 
    |          |   (CONTROL)          |             | 
    |          |   Wishbone Master    |             | 
    |          +-----------+-----------+            | 
    |                      |                        | 
    |          +-----------v-----------+            | 
    |          |   Wishbone Bus       |             | 
    |          +-----+-----+-----+-----+            |
    |                |     |     |                  | 
    |        +-------v-+ +-v-+ +-v-+                | 
    |        | DShot  | |LED| |PWM|                 | 
    |        | Engine | |   | |Dec|                 | 
    |        +---+----+ +---+ +---+                 | 
    |            |                                  | 
    |          +-----------v-----------+            | 
    |          |   Channel 0x05       |             | 
    |          |   (ESC_SERIAL)       |             |
    |          |   UART Core          |             |
    |          +-----------+-----------+            | 
    |                      |                        | 
    +----------------------+-----------------------+
                           |
                           | Motor Signal Wire
                           v
                    [ BLHeli/Bluejay ESC ]
```

### Overcoming the Routing Wall: The Transition to Gowin Tools and GAO

One of the most significant challenges in developing this architecture was routing density. Initially, the project relied exclusively on the open-source Yosys/Nextpnr toolchain. However, as the design grew to encompass four independent DShot engines, a Wishbone bus, NeoPixel drivers, and PWM decoders, the chip hit an 83% Logic Unit (LUT) utilization. 

At this density, the open-source Nextpnr algorithm hit a mathematical wall, falling into an infinite loop during the place-and-route phase. 

To overcome this, the project migrated to the official **Gowin EDA toolchain**. The proprietary Gowin router not only solved the complex physical placement puzzle with ease, but it dramatically optimized the logic mapping—shrinking the utilization from an overflowing 83% down to a highly efficient **56% LUT usage**, leaving plenty of room for future expansion!

#### The Ultimate Superpower: Gowin Analyzer Oscilloscope (GAO)
Migrating to the official Gowin toolchain unlocked a massive debugging superpower: the **Gowin Analyzer Oscilloscope (GAO)**.

GAO is a hardware-level Integrated Logic Analyzer (ILA) built directly into the Gowin IDE. Instead of writing custom Verilog to stream debug data over a serial port to the Raspberry Pi (which eats up logic gates and bandwidth), GAO allows you to passively tap into *any* internal wire, state machine, or bus in the design.

During runtime, GAO automatically captures these signals at the nanosecond level, buffers them in the FPGA's internal Block RAM (BSRAM), and streams them over the USB JTAG cable directly to the PC. This provides a live, real-time waveform of the physical hardware signals on your monitor—exactly like a real oscilloscope—making it trivial to hunt down microsecond-level timing glitches in protocols like DShot or SPI!

## The FCSP Protocol: The Glue That Makes It Work

The flight controller software (Betaflight/INAV) speaks the **MSP (MultiWii Serial Protocol)** for configuration and telemetry. However, MSP is complex and designed for direct FC-to-PC communication, not for hardware offloading.

To bridge this gap, rt-fc-offloader introduces **FCSP (Flight Controller Serial Protocol)** — a simplified, channel-based protocol that acts as a switch between MSP and the FPGA hardware:

**FCSP Design Principles:**
- **Channel-based routing** — Each function has a dedicated channel (CONTROL, ESC_SERIAL, TELEMETRY, etc.)
- **Simple framing** — Header + channel ID + payload + CRC16
- **Hardware-friendly** — Easy to decode in RTL with minimal state
- **Transparent to MSP** — MSP commands are translated to FCSP frames automatically

**Key FCSP Channels:**
- **Channel 0x01 (CONTROL)** — Wishbone register access for mode switching, baud rate configuration
- **Channel 0x05 (ESC_SERIAL)** — Raw byte tunnel to/from selected motor pad (ESC passthrough)
- **Channel 0x02 (TELEMETRY)** — ESC telemetry data (eRPM, temperature, voltage)
- **Channel 0x03 (PWM_INPUT)** — Decoded PWM values from receiver

**Protocol Flow:**
```
MSP Command (PC → FC)
    ↓
MSP Parser (FC software)
    ↓
FCSP Frame (FC → FPGA)
    ↓
FCSP Decoder (FPGA hardware)
    ↓
Hardware Engine (DShot/UART/PWM)
```

This layered approach keeps the flight controller software unchanged (it still speaks MSP), while the FPGA sees a simple, deterministic protocol optimized for hardware implementation. The translation layer is minimal and can be implemented in a few hundred lines of C code on the flight controller.

## The rt-fc-offloader Project

The **rt-fc-offloader** is an open-source project that enables a Raspberry Pi to function as a complete flight controller by offloading all timing-critical motor control functions to an FPGA. The project provides:

- **Deterministic motor control** — DShot output with nanosecond accuracy, no CPU jitter
- **ESC firmware flashing** — Hardware UART passthrough for safe, reliable ESC configuration
- **PWM input decoding** — Hardware edge detection for receiver signals
- **SPI slave interface** — High-speed communication with the flight controller software
- **FCSP protocol** — Flight Controller Serial Protocol for channel-based communication
- **Multi-motor support** — Simultaneous control of up to 4 ESCs
- **AI-assisted development** — PIO-to-RTL translation tools for rapid prototyping

The project targets the Tang Nano 9K FPGA (Gowin GW1NR-9) and is designed to work with Raspberry Pi Zero 2W running Betaflight or INAV firmware. The FPGA handles all real-time timing, allowing the Pi to focus on flight logic, sensor fusion, and control algorithms.

## Why This Matters: A Game-Changing Approach

Traditional flight controllers are limited by CPU timing constraints. Every microsecond spent bit-banging UART is a microsecond not spent on flight control, sensor fusion, or PID loops. The rt-fc-offloader approach changes everything:

**Unprecedented Reliability**
- Zero timing jitter on motor control — nanosecond accuracy guaranteed by hardware
- ESC firmware flashing is safe — no risk of bricking motors due to timing errors
- Deterministic behavior — no surprises from interrupt preemption or scheduler quirks

**Performance Gains**
- Higher link speeds — FPGA can handle baud rates that would choke a CPU
- Simultaneous multi-motor control — all 4 motors controlled in parallel
- CPU free for real work — Raspberry Pi can run complex flight algorithms without timing constraints

**Development Flexibility**
- Rapid prototyping with PIO — test protocols on Pico, migrate to FPGA
- AI-assisted development — translate PIO assembly to RTL automatically
- Future-proof architecture — add new protocols without CPU changes

**New Possibilities**
- Raspberry Pi as flight controller — run full Betaflight/INAV with hardware acceleration
- Advanced telemetry — bidirectional DShot, temperature, voltage, current monitoring
- Custom protocols — implement any motor control scheme in hardware

This isn't just an incremental improvement — it's a fundamental shift from CPU-bound timing to hardware-deterministic control, opening up possibilities that were previously impossible.

## Getting Started

### Hardware Requirements

- **Tang Nano 9K FPGA** (Gowin GW1NR-9 FPGA)
- **Raspberry Pi Zero 2W** (flight controller)
- **USB-to-TTL serial adapter** (for PC communication)
- **BLHeli/Bluejay ESC** (4-in-1 or individual ESCs)
- **Motor + Prop** (for testing)

### Software Requirements

- **Python 3.8+** with pyserial
- **Gowin EDA toolchain** (for FPGA synthesis)
- **ESC Configurator** (BLHeli Configurator or python-imgui-esc-configurator)

### Quick Start: Flash an ESC

A working example is available at `python/hw/example_esc_flash.py`. Here's the simplified workflow:

```python
from hwlib import FcspControlClient, make_mux_word, MODE_SERIAL, MODE_DSHOT, MUX_CTRL

with FcspControlClient(port='/dev/ttyUSB0', baud=115200) as fcsp:
    # Switch to serial mode on motor 0
    mux = make_mux_word(mode=MODE_SERIAL, channel=0, auto_passthrough_en=1)
    fcsp.write_u32(MUX_CTRL, mux)

    # Assert break to enter bootloader
    mux_break = make_mux_word(mode=MODE_SERIAL, channel=0, force_low=1, auto_passthrough_en=1)
    fcsp.write_u32(MUX_CTRL, mux_break)
    time.sleep(0.050)  # Hold 50ms

    # Release break
    fcsp.write_u32(MUX_CTRL, mux)

    # Send BLHeli commands via FCSP Channel 0x05
    flasher.send_esc_bytes(b"BLHeli")
    response = flasher.recv_esc_bytes()

    # Restore DShot mode
    mux_dshot = make_mux_word(mode=MODE_DSHOT, channel=0, auto_passthrough_en=0)
    fcsp.write_u32(MUX_CTRL, mux_dshot)
```

Run the example:
```bash
python3 python/hw/example_esc_flash.py --port /dev/ttyUSB0 --motor 0
```

### Key Registers

| Address | Register | Description |
|---------|----------|-------------|
| `0x40000400` | Serial/DShot Mux | Controls motor pin mode (DShot/Serial/Break) |
| `0x40000404` | Baud Rate Div | UART baud rate divider |
| `0x40000408` | Motor Select | Which motor to configure (0-3) |

### Mode Bits (Serial/DShot Mux)

| Bits | Mode | Effect |
|------|------|--------|
| `0x01` | DShot | Motor driven by DShot engine (default) |
| `0x00` | Serial | Motor routed to ESC serial (FCSP Ch 0x05) |
| `0x14` | Break | Motor forced LOW (for bootloader entry) |

## Technical Details

### How ESC Bootloaders Are Entered

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

### Flashing ESC Firmware

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

### Safety

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

## Appendix: PIO to RTL Translation Guide

This appendix shows how RP2040 PIO assembly translates to SystemVerilog RTL, using actual examples from the rt-fc-offloader project. The translation is deterministic and mechanical, making it an excellent candidate for AI-assisted automation.

### DShot: PIO vs RTL

### PIO Implementation (dshot.pio)

```asm
.program dshot_600
start:
    set    pins, 0                [31]      ; drive pin LOW - inter-frame gap
    nop                           [20]      ; min 2us gap before next frame
    pull   block                            ; wait for CPU to push a packet
    out    y, 16                            ; discard top 16 bits (only need 16-bit packet)
bitloop:
    out    y, 1                             ; shift next bit into y
    jmp    !y, outzero                      ; branch on bit value
    set    pins, 1                [26]      ; '1': HIGH for 27 cycles
    set    pins, 0                [9]       ;      LOW  for 13 cycles (total 40)
    jmp    !osre, bitloop                   ; loop until all bits sent
    jmp    start
outzero:
    set    pins, 1                [12]      ; '0': HIGH for 13 cycles
    set    pins, 0                [22]      ;      LOW  for 27 cycles (total 40)
    jmp    !osre, bitloop         [1]       ; loop until all bits sent (+ 1 alignment)
```

**Key PIO Features:**
- `pull block` → Blocking wait for data (AXI-Stream ready/valid)
- `out y, n` → Shift register operation
- `jmp !y, label` → Conditional branch
- `set pins, val [n]` → Output with delay
- `jmp !osre, label` → Loop until shift register empty
- Timing: 40 cycles per bit at DSHOT600 (1.667us)

### RTL Implementation (dshot_out.sv)

```systemverilog
typedef enum logic [1:0] {
    ST_IDLE     = 2'd0,
    ST_INIT     = 2'd1,
    ST_HIGH     = 2'd2,
    ST_LOW      = 2'd3
} state_t;

// DSHOT600 timing (54MHz clock)
localparam logic [15:0] T0H_600   = 16'((64'(CLK_FREQ_HZ) * 625) / 1_000_000_000);  // 34 cycles
localparam logic [15:0] T0L_600   = 16'((64'(CLK_FREQ_HZ) * 104) / 100_000_000);   // 6 cycles
localparam logic [15:0] T1H_600   = 16'((64'(CLK_FREQ_HZ) * 125) / 100_000_000);   // 7 cycles
localparam logic [15:0] T1L_600   = 16'((64'(CLK_FREQ_HZ) * 42) / 100_000_000);    // 2 cycles

always_ff @(posedge clk) begin
    case (state)
        ST_IDLE: begin
            if (i_write && guard_count == 16'd0) begin
                dshot_command <= i_dshot_value;  // pull block equivalent
                bits_to_shift <= 5'd15;
                state <= ST_INIT;
            end
        end

        ST_INIT: begin
            // out y, 1 equivalent - check bit value
            if (dshot_command[15]) begin
                counter_high <= t1h_clocks;
                counter_low  <= t1l_clocks;
            end else begin
                counter_high <= t0h_clocks;
                counter_low  <= t0l_clocks;
            end
            state <= ST_HIGH;
        end

        ST_HIGH: begin
            pwm_reg <= 1'b1;  // set pins, 1
            if (counter_high == 16'd0) begin
                state <= ST_LOW;
            end else begin
                counter_high <= counter_high - 16'd1;
            end
        end

        ST_LOW: begin
            pwm_reg <= 1'b0;  // set pins, 0
            if (counter_low == 16'd0) begin
                if (bits_to_shift == 5'd0) begin
                    state <= ST_IDLE;  // jmp start equivalent
                end else begin
                    bits_to_shift <= bits_to_shift - 5'd1;
                    dshot_command <= {dshot_command[14:0], 1'b0};  // out y, 1 equivalent
                    state <= ST_INIT;
                end
            end else begin
                counter_low <= counter_low - 16'd1;
            end
        end
    endcase
end
```

**Key RTL Features:**
- State machine replaces PIO instruction flow
- Counters replace PIO delay cycles
- Shift register (`dshot_command`) replaces PIO Y register
- `i_write` signal replaces `pull block`
- Timing calculated from clock frequency

## SPI Master: PIO vs RTL

### PIO Implementation (spi_master.pio)

```asm
.program spi_master
.side_set 1

; SPI mode 0, CPOL=0, CPHA=0
pull block
out x, 8              ; bit counter
bitloop:
    out pins, 1       ; MOSI
    set pins, 1 side 0 [1]  ; SCK rising edge
    in pins, 1        ; MISO
    set pins, 0 side 1 [1]  ; SCK falling edge
    jmp x-- bitloop
```

**Key PIO Features:**
- `side_set` for clock edge control
- `out pins, 1` for MOSI output
- `in pins, 1` for MISO input
- `set pins, 1/0` for clock generation

### RTL Implementation (spi_master.sv)

```systemverilog
typedef enum logic [1:0] {
    SPI_IDLE,
    SPI_TRANSFER
} spi_state_t;

always_ff @(posedge clk) begin
    case (state)
        SPI_IDLE: begin
            sck <= 1'b0;  // CPOL=0
            if (start_transfer) begin
                shift_reg <= tx_data;
                bit_counter <= 3'd7;
                state <= SPI_TRANSFER;
            end
        end
        SPI_TRANSFER: begin
            mosi <= shift_reg[7];  // out pins, 1
            sck <= 1'b0;  // rising edge
            rx_data <= {rx_data[6:0], miso};  // in pins, 1
            sck <= 1'b1;  // falling edge
            shift_reg <= {shift_reg[6:0], 1'b0};
            if (bit_counter == 0) begin
                state <= SPI_IDLE;
                done <= 1'b1;
            end else begin
                bit_counter <= bit_counter - 1;
            end
        end
    endcase
end
```

## PWM Generation: PIO vs RTL

### PIO Implementation (pwm.pio)

```asm
.program pwm
.side_set 1

set x, 31            ; duty cycle counter
set y, 255           ; period counter
loop:
    set pins, 1 side 1
    jmp x--, loop side 0
    set pins, 0 side 1
    jmp y--, loop side 0
```

**Key PIO Features:**
- Two counters (X for duty, Y for period)
- `jmp x--` for duty cycle
- `jmp y--` for period
- `side_set` for pin control

### RTL Implementation (pwm_generator.sv)

```systemverilog
typedef enum logic [1:0] {
    PWM_HIGH,
    PWM_LOW
} pwm_state_t;

always_ff @(posedge clk) begin
    case (state)
        PWM_HIGH: begin
            pwm_out <= 1'b1;
            if (duty_counter == 0) begin
                state <= PWM_LOW;
                duty_counter <= duty_cycle;
            end else begin
                duty_counter <= duty_counter - 1;
            end
        end
        PWM_LOW: begin
            pwm_out <= 1'b0;
            if (period_counter == 0) begin
                state <= PWM_HIGH;
                period_counter <= period;
                duty_counter <= duty_cycle;
            end else begin
                period_counter <= period_counter - 1;
            end
        end
    endcase
end
```

## UART: PIO vs RTL

### PIO Implementation (esc_pio_uart.pio)

```asm
.program esc_uart_tx
.side_set 1 opt

; 8N1 transmit, LSB first, 8 clocks per bit
pull        side 1 [7]   ; idle high / stop bit
set x, 7    side 0 [7]   ; start bit low
bitloop:
    out pins, 1
    jmp x-- bitloop [6]
    nop       side 1 [6] ; stop bit
```

**Key PIO Features:**
- `side_set` → Pin direction control + timing
- `set x, 7` → Initialize bit counter
- `out pins, 1` → Shift out bit
- `jmp x--` → Decrement and loop
- 8 cycles per bit at 19200 baud

### RTL Implementation (wb_esc_uart.sv)

```systemverilog
typedef enum logic [2:0] {
    TX_IDLE,
    TX_START,
    TX_DATA,
    TX_STOP,
    TX_GUARD
} tx_state_t;

localparam int DEFAULT_BAUD = 19_200;
localparam int DEFAULT_CLKDIV = int'(64'(CLK_FREQ_HZ) / 64'(DEFAULT_BAUD));

always_ff @(posedge clk) begin
    case (tx_state)
        TX_IDLE: begin
            tx_out <= 1'b1;  // idle high (side 1)
            if (tx_data_valid) begin
                tx_shift <= tx_data_reg;
                tx_state <= TX_START;
                tx_counter <= clks_per_bit - 16'd1;
                tx_out <= 1'b0;  // start bit low (side 0)
            end
        end

        TX_START: begin
            if (tx_counter == 16'd0) begin
                tx_state <= TX_DATA;
                tx_counter <= clks_per_bit - 16'd1;
                tx_out <= tx_shift[0];  // out pins, 1
                tx_bit_idx <= 3'd0;
            end else begin
                tx_counter <= counter - 16'd1;
            end
        end

        TX_DATA: begin
            if (tx_counter == 16'd0) begin
                tx_shift <= {1'b0, tx_shift[7:1]};  // shift
                if (tx_bit_idx == 3'd7) begin
                    tx_state <= TX_STOP;
                    tx_counter <= clks_per_bit - 16'd1;
                    tx_out <= 1'b1;  // stop bit (side 1)
                end else begin
                    tx_bit_idx <= tx_bit_idx + 3'd1;
                    tx_counter <= clks_per_bit - 16'd1;
                    tx_out <= tx_shift[1];  // out pins, 1
                end
            end else begin
                tx_counter <= tx_counter - 16'd1;
            end
        end

        TX_STOP: begin
            if (tx_counter == 16'd0) begin
                tx_state <= TX_GUARD;  // half-duplex turnaround
            end else begin
                tx_counter <= tx_counter - 16'd1;
            end
        end
    endcase
end
```

**Key RTL Features:**
- 5-state machine replaces PIO instruction sequence
- `clks_per_bit` replaces PIO clock divider
- `tx_shift` replaces PIO OSR (Output Shift Register)
- `tx_bit_idx` replaces PIO X register counter
- TX_GUARD state for half-duplex turnaround (not in PIO)

## PIO to RTL Mapping Patterns

### Instruction Mapping

| PIO Instruction | RTL Equivalent | Notes |
|----------------|----------------|-------|
| `pull block` | AXI-Stream ready/valid handshake | Blocking data input |
| `pull` | Register assignment | Non-blocking data input |
| `out x, n` | Shift register operation | `data <= {data[n-1:0], new_bit}` |
| `out pins, n` | Output register assignment | `pin <= data[0]` |
| `set pins, val` | Output register | Direct pin control |
| `set pindirs, val` | Direction register | GPIO direction control |
| `jmp label` | State transition | `state <= NEXT_STATE` |
| `jmp !x, label` | Conditional state transition | `if (!x) state <= NEXT_STATE` |
| `jmp x--, label` | Counter + loop | `if (counter-- != 0) state <= LOOP` |
| `wait pin` | Edge detection logic | `if (edge_detected) state <= NEXT` |
| `in pins, n` | Input shift register | `data <= {new_bit, data[n-1:0]}` |
| `push block` | AXI-Stream valid/ready handshake | Blocking data output |
| `mov x, y` | Register assignment | `x <= y` |
| `mov pins, x` | Output from register | `pins <= x` |

### Timing Translation

**PIO Delay Cycles to RTL Counters:**

```systemverilog
// PIO: side_set [n] or delay [n]
// At 150MHz PIO clock: 1 cycle = 6.67ns

// RTL: Calculate counter value from target clock
localparam int CLK_FREQ = 54_000_000;  // RTL clock
localparam int PIO_CLK = 150_000_000;   // PIO clock
localparam int TARGET_NS = n * 6.67;    // PIO delay in ns

// RTL counter value
localparam int COUNTER = (CLK_FREQ * TARGET_NS) / 1_000_000_000;
```

**Example: DSHOT600 T0H (PIO: [26] cycles)**

```systemverilog
// PIO: 26 cycles at 150MHz = 173.33ns
// RTL at 54MHz: (54MHz * 173.33ns) / 1ns = 9.36 cycles ≈ 9 cycles

localparam logic [15:0] T0H_600 = 16'((64'(CLK_FREQ_HZ) * 625) / 1_000_000_000);
```

### State Machine Translation

**PIO Flow:**
```asm
label1:
    instruction1
    instruction2
    jmp label2
label2:
    instruction3
    jmp label1
```

**RTL Equivalent:**
```systemverilog
typedef enum logic [1:0] {
    ST_LABEL1,
    ST_LABEL2
} state_t;

always_ff @(posedge clk) begin
    case (state)
        ST_LABEL1: begin
            // instruction1
            // instruction2
            state <= ST_LABEL2;
        end
        ST_LABEL2: begin
            // instruction3
            state <= ST_LABEL1;
        end
    endcase
end
```

### Register Translation

**PIO Registers:**
- **X/Y**: General-purpose registers → RTL logic registers
- **OSR**: Output Shift Register → RTL shift register
- **ISR**: Input Shift Register → RTL shift register
- **FIFO**: TX/RX FIFO → AXI-Stream interface

## AI Prompt Examples for PIO to RTL

### Basic Prompt Template

```
Convert this RP2040 PIO assembly program to SystemVerilog RTL:

[PASTE PIO CODE HERE]

Context:
- Target clock: [specify, e.g., 54MHz]
- PIO clock: [specify, e.g., 150MHz]
- Function: [brief description]

Requirements:
- Generate synthesizable SystemVerilog
- Map PIO instructions to RTL state machine
- Convert PIO delay cycles to RTL counters using timing formula:
  RTL_counter = (RTL_CLK * PIO_delay_cycles * PIO_period) / 1_000_000_000
- Handle pull block as AXI-Stream ready/valid handshake
- Implement shift registers for out/in instructions
- Include proper reset and initialization
- Add status outputs (busy, done, ready)
- Provide usage example in comments
- Explain any assumptions made
```

### DShot Example Prompt

```
Convert this RP2040 PIO assembly program to SystemVerilog RTL:

.program dshot_600
    set    pindirs, 1
start:
    set    pins, 0                [31]
    nop                           [20]
    pull   block
    out    y, 16
bitloop:
    out    y, 1
    jmp    !y, outzero
    set    pins, 1                [26]
    set    pins, 0                [9]
    jmp    !osre, bitloop
    jmp    start
outzero:
    set    pins, 1                [12]
    set    pins, 0                [22]
    jmp    !osre, bitloop         [1]

Context:
- Target clock: 54MHz (RTL)
- PIO clock: 150MHz (PIO)
- Function: DSHOT600 motor control protocol (16-bit packet with CRC)

Requirements:
- Generate synthesizable SystemVerilog
- Map PIO instructions to RTL state machine
- Convert PIO delay cycles to RTL counters:
  - [31] = 31 * 6.67ns = 207ns → (54MHz * 207ns) = 11 cycles
  - [26] = 26 * 6.67ns = 173ns → (54MHz * 173ns) = 9 cycles
  - [22] = 22 * 6.67ns = 147ns → (54MHz * 147ns) = 8 cycles
  - [12] = 12 * 6.67ns = 80ns → (54MHz * 80ns) = 4 cycles
  - [9] = 9 * 6.67ns = 60ns → (54MHz * 60ns) = 3 cycles
- Handle pull block as simple handshake (clk, rst, i_write, i_dshot_value, o_pwm, o_ready)
- Implement shift register for out y, 1
- Include proper reset and initialization
- Add busy/ready status outputs
- Provide usage example in comments
```

### UART Example Prompt

```
Convert this RP2040 PIO assembly program to SystemVerilog RTL:

.program esc_uart_tx
.side_set 1 opt

; 8N1 transmit, LSB first, 8 clocks per bit
pull        side 1 [7]   ; idle high / stop bit
set x, 7    side 0 [7]   ; start bit low
bitloop:
    out pins, 1
    jmp x-- bitloop [6]
    nop       side 1 [6] ; stop bit

Context:
- Target clock: 54MHz (RTL)
- PIO clock: 150MHz (PIO)
- Function: Half-duplex UART transmitter at 19200 baud 8N1
- Baud rate: 19200

Requirements:
- Generate synthesizable SystemVerilog
- Map PIO instructions to RTL state machine
- Convert side_set timing:
  - [7] = 7 * 6.67ns = 47ns → (54MHz * 47ns) = 3 cycles
  - [6] = 6 * 6.67ns = 40ns → (54MHz * 40ns) = 2 cycles
- Calculate clks_per_bit: 54MHz / 19200 = 2812 cycles
- Handle pull block as data input (tx_data_valid, tx_data_reg)
- Implement shift register for out pins, 1
- Include proper reset and initialization
- Add TX_GUARD state for half-duplex turnaround
- Provide usage example in comments
```

### SPI Master Example Prompt

```
Convert this RP2040 PIO assembly program to SystemVerilog RTL:

.program spi_master
.side_set 1

; SPI mode 0, CPOL=0, CPHA=0
pull block
out x, 8              ; bit counter
bitloop:
    out pins, 1       ; MOSI
    set pins, 1 side 0 [1]  ; SCK rising edge
    in pins, 1        ; MISO
    set pins, 0 side 1 [1]  ; SCK falling edge
    jmp x-- bitloop

Context:
- Target clock: 54MHz (RTL)
- PIO clock: 150MHz (PIO)
- Function: SPI master mode 0 (CPOL=0, CPHA=0)
- Data width: 8 bits

Requirements:
- Generate synthesizable SystemVerilog
- Map PIO instructions to RTL state machine
- Convert side_set timing:
  - [1] = 1 * 6.67ns = 6.67ns → (54MHz * 6.67ns) = 0 cycles (use 1 for margin)
- Handle pull block as transfer start signal
- Implement shift register for out pins, 1 (MOSI)
- Implement shift register for in pins, 1 (MISO)
- Generate SCK clock edges (rising on MOSI, falling on MISO)
- Include proper reset and initialization
- Add done status output
- Provide usage example in comments
```

### PWM Example Prompt

```
Convert this RP2040 PIO assembly program to SystemVerilog RTL:

.program pwm
.side_set 1

set x, 31            ; duty cycle counter
set y, 255           ; period counter
loop:
    set pins, 1 side 1
    jmp x--, loop side 0
    set pins, 0 side 1
    jmp y--, loop side 0

Context:
- Target clock: 54MHz (RTL)
- PIO clock: 150MHz (PIO)
- Function: PWM generation with configurable duty cycle and period
- Default duty: 31/255 (12%)
- Default period: 255 cycles

Requirements:
- Generate synthesizable SystemVerilog
- Map PIO instructions to RTL state machine
- Convert side_set timing:
  - [1] = 1 * 6.67ns = 6.67ns → (54MHz * 6.67ns) = 0 cycles (use 1 for margin)
- Implement two counters: duty_counter and period_counter
- Map jmp x-- to duty cycle counter
- Map jmp y-- to period counter
- Make duty cycle and period configurable parameters
- Include proper reset and initialization
- Add status output (optional)
- Provide usage example in comments
```

### Complex Protocol Prompt

```
Convert this RP2040 PIO assembly program to SystemVerilog RTL:

[PASTE COMPLEX PIO CODE]

Context:
- Target clock: [specify]
- PIO clock: [specify]
- Function: [detailed description]
- Protocol: [protocol name, link to spec if available]
- Timing requirements: [specific timing constraints]

Requirements:
- Generate synthesizable SystemVerilog
- Map PIO instructions to RTL state machine
- Convert all PIO delay cycles to RTL counters
- Handle all side_set instructions with proper timing
- Implement all shift registers (OSR, ISR)
- Handle pull/push with AXI-Stream interfaces
- Include proper reset and initialization
- Add comprehensive status outputs
- Include timing diagram in comments (mermaid format)
- Provide detailed usage example
- Explain any assumptions made about timing or protocol
- Add parameterization for configurable values
```

### Verification Prompt

```
Analyze this PIO assembly program and the corresponding RTL implementation:

[PASTE PIO CODE]

[PASTE RTL CODE]

Check for:
1. Correct instruction-to-state mapping
2. Accurate timing translation (compare PIO cycles with RTL counters)
3. Proper handling of pull/pull block
4. Correct shift register implementation
5. Complete reset logic
6. Missing edge cases

Provide:
- Line-by-line comparison
- Timing calculation verification
- Any discrepancies found
- Suggestions for improvement
```

## AI Prompt Template for PIO to RTL

### Basic Template

```
Convert this RP2040 PIO assembly program to SystemVerilog RTL:

[PASTE PIO CODE HERE]

Context:
- Target clock: [specify, e.g., 54MHz]
- PIO clock: [specify, e.g., 150MHz]
- Function: [brief description]

Requirements:
- Generate synthesizable SystemVerilog
- Map PIO instructions to RTL state machine
- Convert PIO delay cycles to RTL counters using timing formula:
  RTL_counter = (RTL_CLK * PIO_delay_cycles * PIO_period) / 1_000_000_000
- Handle pull block as AXI-Stream ready/valid handshake
- Implement shift registers for out/in instructions
- Include proper reset and initialization
- Add status outputs (busy, done, ready)
- Provide usage example in comments
- Explain any assumptions made
```

### Example with DShot PIO

```
Convert this RP2040 PIO assembly program to SystemVerilog RTL:

.program dshot_600
    set    pindirs, 1
start:
    set    pins, 0                [31]
    nop                           [20]
    pull   block
    out    y, 16
bitloop:
    out    y, 1
    jmp    !y, outzero
    set    pins, 1                [26]
    set    pins, 0                [9]
    jmp    !osre, bitloop
    jmp    start
outzero:
    set    pins, 1                [12]
    set    pins, 0                [22]
    jmp    !osre, bitloop         [1]

Context:
- Target clock: 54MHz (RTL)
- PIO clock: 150MHz (PIO)
- Function: DSHOT600 motor control protocol

Requirements:
- Generate synthesizable SystemVerilog
- Map PIO instructions to RTL state machine
- Convert PIO delay cycles to RTL counters:
  - [31] = 31 * 6.67ns = 207ns → (54MHz * 207ns) = 11 cycles
  - [26] = 26 * 6.67ns = 173ns → (54MHz * 173ns) = 9 cycles
  - [22] = 22 * 6.67ns = 147ns → (54MHz * 147ns) = 8 cycles
  - [12] = 12 * 6.67ns = 80ns → (54MHz * 80ns) = 4 cycles
  - [9] = 9 * 6.67ns = 60ns → (54MHz * 60ns) = 3 cycles
- Handle pull block as simple handshake (clk, rst, i_write, i_dshot_value, o_pwm, o_ready)
- Implement shift register for out y, 1
- Include proper reset and initialization
- Add busy/ready status outputs
- Provide usage example in comments
```

## Common Patterns

### Blocking Data Input (pull block)

**PIO:**
```asm
pull block
```

**RTL:**
```systemverilog
input wire i_write,
input wire [15:0] i_data,
output wire o_ready,

always_ff @(posedge clk) begin
    if (i_write && ready) begin
        data_reg <= i_data;
        ready <= 1'b0;
    end
end
```

### Shift Register (out y, n)

**PIO:**
```asm
out y, 1
```

**RTL:**
```systemverilog
logic [15:0] shift_reg;
always_ff @(posedge clk) begin
    shift_reg <= {shift_reg[14:0], new_bit};
end
```

### Conditional Branch (jmp !x, label)

**PIO:**
```asm
jmp !x, outzero
```

**RTL:**
```systemverilog
if (!x) begin
    state <= ST_OUTZERO;
end
```

### Counter Loop (jmp x--, label)

**PIO:**
```asm
set x, 7
bitloop:
    jmp x-- bitloop
```

**RTL:**
```systemverilog
logic [2:0] counter;
always_ff @(posedge clk) begin
    if (counter == 0) begin
        state <= ST_NEXT;
    end else begin
        counter <= counter - 1;
    end
end
```

## Tips for AI Conversion

1. **Provide clock frequencies** - Essential for timing translation
2. **Specify interface style** - AXI-Stream, Wishbone, or simple
3. **Include context** - What the module does, protocol details
4. **Request comments** - Ask AI to explain the translation
5. **Verify timing** - Check that RTL counters match PIO delays
6. **Test incrementally** - Start with simple PIO, move to complex
7. **Use existing RTL as reference** - Compare AI output with hand-written RTL

## Verification

After AI generation, verify:
1. Timing matches PIO specification
2. State machine covers all PIO paths
3. Reset logic is complete
4. Interface signals are correct
5. No inferred latches
6. Synthesizable code style

## References

- PIO Assembly Guide: https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf#section3
- rt-fc-offloader PIO: `firmware/pico/*.pio`
- rt-fc-offloader RTL: `rtl/io/*.sv`
