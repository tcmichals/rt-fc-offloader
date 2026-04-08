# FCSP Bus Strategy Decision (Tang9K)

Date: 2026-04-04
Status: Accepted (implemented)

> **Implementation details:** [DESIGN.md](DESIGN.md) §2 — Bus & Transport Architecture.
> **Master module hierarchy:** [DESIGN.md](DESIGN.md) §1.

## Decision

Adopt a **hybrid interconnect**:

- **AXIS-style switch/fabric** for FCSP frame traffic (`tvalid/tready/tdata/tlast`)
- **Wishbone** only for register/device control windows and status counters

This means we do **not** route FCSP payload hot paths through Wishbone.

## Why

1. FCSP parser/CRC/router already use stream semantics.
2. Stream backpressure and frame boundaries map naturally to switch/fabric logic.
3. Device-style configuration (DSHOT mode, LED config, counters, health bits) is easier to expose and test via Wishbone registers.
4. Keeps area/timing pressure lower than forcing a single monolithic bus model.

## Interface contract

### Stream plane (data path)

- Ingress: SPI/UART byte seam -> parser -> CRC gate -> router
- Channel handling: per-channel FIFO/seam, then scheduler/arbiter
- Egress: TX framer -> SPI/UART

### Control plane (device path)

- Wishbone slave windows for:
  - DSHOT configuration + shadow words
  - NeoPixel/LED state
  - Debug counters (drops, fifo overflows, frame seen)
  - Health/version/status registers

## Near-term implementation plan

1. Keep current stream seams and complete debug/control arbitration.
2. Add a small Wishbone status/control block for observability + knobs.
3. Bridge SERV command handlers to update stream producers and/or WB regs depending on operation type.
4. Add tests:
   - Stream arbitration and fairness/backpressure tests
   - Wishbone register read/write/error behavior tests
   - End-to-end FCSP command -> control effect -> response frame tests

## Non-goals (for now)

- Full replacement of stream fabric with Wishbone transactions.
- Full SoC-style shared bus for all datapath movement.

## Rule of thumb

- If bytes are **flowing through a pipeline** => stream/switch path.
- If software/firmware is **reading or writing registers** => Wishbone path.
