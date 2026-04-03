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

## Related docs

- `docs/FCSP_PROTOCOL.md`
- `docs/FPGA_BLOCK_DESIGN.md`
- `docs/ENGINEERING_LOG.md`
