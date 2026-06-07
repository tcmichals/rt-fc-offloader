# Pico PIO / MSP Implementation Notes

This note records how the Pico-based MSP/PIO path was implemented differently from the FCSP offloader path.

The goal is not to argue that one is "better" in all cases. The goal is to preserve the reasoning behind why the Pico bring-up path was structured the way it was.

## Purpose of the Pico path

The Pico path exists to support:

- early ESC-config bring-up
- fast MSP-compatible workflow validation
- simple single-link passthrough experiments
- known-good hardware testing before the full FCSP offloader datapath is complete

This path has already been validated with a **single ESC + motor**.

## How the Pico path was done differently

### 1) It used MSP-style interaction first

The Pico bring-up path kept close to MSP-oriented workflows so GUI and ESC-config behavior could be exercised quickly.

That means the early implementation emphasis was on:

- compatibility
- quick validation
- minimizing moving parts

instead of building the full FCSP stream/routing architecture first.

### 2) PIO was used for timing-sensitive signal generation/capture

On RP2040/Pico, PIO is a natural place to put tightly timed bit-level behavior.

That makes sense for things like:

- DSHOT-style output timing
- waveform-oriented peripheral behaviors
- small deterministic IO engines tightly coupled to MCU control flow

So in the Pico design, PIO acts as a focused timing engine attached to an MCU-managed control path.

### 2a) PIO was also used for the ESC serial passthrough port

For ESC passthrough, the motor signal line was not treated as a normal always-on UART pin.

Instead, the Pico path used **PIO-based serial transport on the selected motor pin** after handing that pin over from the DSHOT path.

Typical sequence:

1. stop or quiesce DSHOT on the selected motor output
2. drive the ESC line low for the required break pulse
3. release the line high for a short recovery/idle interval
4. start the PIO serial engine on that same motor pin
5. bridge ESC serial / 4-way traffic through that PIO transport
6. on exit, stop PIO serial and return ownership to DSHOT

Why PIO was used here:

- the ESC serial path needed deterministic bit timing
- the same motor pin had to switch ownership cleanly between DSHOT and serial
- PIO reduced the fragility of bit-banged software UART handling during passthrough entry and bootloader traffic
- it fit the RP2040 model well because PIO was already central to motor-line timing control

So in practice, PIO was not just used for waveform generation; it also served as the **half-duplex serial engine for ESC passthrough on the motor line**.

### 3) The traffic model was simpler during bring-up

The Pico/MSP path was not trying to prove a fully multiplexed packet fabric first.

The early focus was more like:

- get commands through
- talk to an ESC
- validate motor/ESC control behavior
- confirm GUI-facing workflows

This is a very good bring-up strategy because it reduces integration complexity.

### 4) Control and timing lived closer together

In the Pico approach, the control logic and the timing engine are more tightly coupled.

That works well when:

- command volume is modest
- traffic classes are limited
- the immediate goal is feature validation, not a high-concurrency stream architecture

### 5) It was a bring-up-oriented architecture

The Pico path was optimized to get to a usable testable state quickly.

That means some choices were intentionally pragmatic:

- fewer layers
- simpler transport assumptions
- less emphasis on multi-channel interleaving
- less emphasis on parser/router/FIFO decomposition

Those are valid choices for a bring-up system.

## RP2040 startup and Pico debug note

Because the Pico firmware uses RP2040 core-local hardware and multicore startup logic, early bring-up can hit an RP2040 `SIO_IRQ_PROC1` mailbox interrupt before normal `main()` execution.

For this repo, that startup event was handled by a small early ISR that clears the SIO FIFO and disables `SIO_IRQ_PROC1` if the inter-core channel is not in use. Without that fix, attaching with GDB can stop in the interrupt handler and appear to hang before `main()` is reached.

Recommended Pico GDB flow for this firmware:

1. `target remote localhost:3333`
2. `monitor reset halt`
3. `break main`
4. `continue`

If the firmware reaches `main()`, the Pico LED startup indicator is visible and normal boot behavior is in progress.

## Why the FCSP offloader path is structured differently

The FCSP offloader path is trying to solve a different problem:

- continuous stream parsing
- interleaved command/log/telemetry traffic
- deterministic routing and buffering
- separation of datapath from control-plane policy
- scaling beyond a single simple command loop

So the internal structure differs because the runtime goals differ.

## Practical takeaway

The Pico PIO/MSP path should be remembered as:

- the **early validation / bring-up path**
- the path that proved ESC-config with a single ESC + motor
- the reference for initial workflow behavior

It should not be treated as a requirement that the FCSP FPGA internals must look the same.

## Pico Hardware Pin Reference

> **Canonical Pico pin source for the project.** All firmware modules reference these assignments.

### Physical Pin Mapping

| GPIO | Pin # | Signal             | Direction     | Function                                  | Source File       |
|------|-------|--------------------|---------------|-------------------------------------------|-------------------|
| 0    | 1     | PWM Ch1            | Input         | RC PWM input channel 1                    | `pwm_decode.h`    |
| 1    | 2     | PWM Ch2            | Input         | RC PWM input channel 2                    | `pwm_decode.h`    |
| 2    | 4     | PWM Ch3            | Input         | RC PWM input channel 3                    | `pwm_decode.h`    |
| 3    | 5     | PWM Ch4            | Input         | RC PWM input channel 4                    | `pwm_decode.h`    |
| 4    | 6     | PWM Ch5            | Input         | RC PWM input channel 5                    | `pwm_decode.h`    |
| 5    | 7     | PWM Ch6            | Input         | RC PWM input channel 6                    | `pwm_decode.h`    |
| 6    | 9     | Motor1             | Bidirectional | DShot output / ESC serial passthrough     | `dshot.h`         |
| 7    | 10    | Motor2             | Bidirectional | DShot output / ESC serial passthrough     | `dshot.h`         |
| 8    | 11    | Motor3             | Bidirectional | DShot output / ESC serial passthrough     | `dshot.h`         |
| 9    | 12    | Motor4             | Bidirectional | DShot output / ESC serial passthrough     | `dshot.h`         |
| 10   | 14    | NeoPixel           | Output        | WS2812/SK6812 RGBW data (16 LEDs)         | `neopixel.h`      |
| 16   | 21    | SPI0 MOSI          | Input         | SPI slave data in (from host)             | `spi_slave.cpp`   |
| 17   | 22    | SPI0 CS            | Input         | SPI slave chip select (from host)         | `spi_slave.cpp`   |
| 18   | 24    | SPI0 SCLK          | Input         | SPI slave clock (from host)               | `spi_slave.cpp`   |
| 19   | 25    | SPI0 MISO          | Output        | SPI slave data out (to host)              | `spi_slave.cpp`   |
| 20   | 26    | Debug UART1 TX     | Output        | Debug console output @ 115200 baud        | `debug_uart.cpp`  |
| 25   | —     | On-board LED       | Output        | Heartbeat blink (~1 Hz); internal, no header pin | `pico_main.cpp`   |

### Unassigned GPIOs

GPIOs 11–15, 21–24, and 26–28 are currently unused.

### Summary Diagram

```
GPIO  0  (Pin  1) ── PWM Ch1 (RC input)
GPIO  1  (Pin  2) ── PWM Ch2 (RC input)
GPIO  2  (Pin  4) ── PWM Ch3 (RC input)
GPIO  3  (Pin  5) ── PWM Ch4 (RC input)
GPIO  4  (Pin  6) ── PWM Ch5 (RC input)
GPIO  5  (Pin  7) ── PWM Ch6 (RC input)
GPIO  6  (Pin  9) ── Motor 1 (DShot / ESC passthrough)
GPIO  7  (Pin 10) ── Motor 2 (DShot / ESC passthrough)
GPIO  8  (Pin 11) ── Motor 3 (DShot / ESC passthrough)
GPIO  9  (Pin 12) ── Motor 4 (DShot / ESC passthrough)
GPIO 10  (Pin 14) ── NeoPixel data (WS2812/SK6812 RGBW)
GPIO 16  (Pin 21) ── SPI0 MOSI (host link)
GPIO 17  (Pin 22) ── SPI0 CS   (host link)
GPIO 18  (Pin 24) ── SPI0 SCLK (host link)
GPIO 19  (Pin 25) ── SPI0 MISO (host link)
GPIO 20  (Pin 26) ── Debug UART1 TX (115200 baud)
GPIO 25  (internal) ── On-board LED (heartbeat)
```

## Building the Pico Firmware

### Prerequisites

Source the project environment to set up toolchain paths:

```bash
source settings.sh
```

This exports `PICO_SDK_PATH`, `ARM_GCC_BIN`, and prepends them to `PATH`. Override before sourcing if your toolchains are in non-default locations:

```bash
export PICO_SDK_PATH=/path/to/pico-sdk
export ARM_GCC_BIN=/path/to/arm-none-eabi/bin
source settings.sh
```

### Configure and Build

```bash
cmake -B firmware/build -S firmware \
      -DPICO_SDK_PATH=${PICO_SDK_PATH} \
      -DPICO_TOOLCHAIN_PATH=${ARM_GCC_BIN}/..
cmake --build firmware/build
```

The output UF2 is at `firmware/build/rt_fc_pico.uf2`.

### CMake Parameters

These can be passed as `-D` flags or set as environment variables before running `cmake`:

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `PICO_SDK_PATH` | Yes (unless fetching from git) | env `PICO_SDK_PATH` | Path to the Pico SDK root |
| `PICO_TOOLCHAIN_PATH` | No | Auto-detected from `PATH` | Path to the ARM GNU toolchain root (parent of `bin/arm-none-eabi-gcc`) |
| `PICO_BOARD` | No | `pico` | Board variant (`pico`, `pico_w`, etc.) |
| `CMAKE_BUILD_TYPE` | No | SDK default | `Debug` or `Release` |
| `PICO_SDK_FETCH_FROM_GIT` | No | `OFF` | Set `ON` to download the SDK from GitHub instead of using a local copy |
| `PICO_SDK_FETCH_FROM_GIT_TAG` | No | `master` | Git tag/branch to fetch when `PICO_SDK_FETCH_FROM_GIT=ON` |
| `PICO_SDK_FETCH_FROM_GIT_PATH` | No | CMake fetch default | Local directory to download the SDK into |

### Flashing

Hold BOOTSEL, plug in USB, then copy the UF2:

```bash
cp firmware/build/rt_fc_pico.uf2 /media/$USER/RPI-RP2/
```

## Related docs

- `docs/FCSP_PROTOCOL.md`
- `docs/FPGA_BLOCK_DESIGN.md`
- `docs/ENGINEERING_LOG.md`
