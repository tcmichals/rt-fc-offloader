# Repository Contract: rt-fc-offloader ↔ python-imgui-esc-configurator

This document defines how both repositories evolve FCSP in parallel.

## Canonical ownership

- **Protocol wire spec canonical source**: `rt-fc-offloader/docs/FCSP_PROTOCOL.md`
- **No duplicate protocol spec files** in other repos; consumers must reference the canonical source above.

## Directory contract (rt-fc-offloader)

- `rtl/fcsp/` — FCSP framing, CRC, channel routing RTL
- `rtl/io/` — DSHOT, PWM decode, LED/NeoPixel, SPI bridge RTL
- `firmware/serv8/` — SERV 8-bit control-plane firmware
- `sim/` — simulation and protocol verification harnesses
- `docs/` — protocol and integration docs

## Cross-repo compatibility rules

1. Python GUI behavior must not depend on MSP-only assumptions.
2. Transport selection is worker/offloader-side only; GUI flow remains unchanged.
3. SPI/FCSP wire transport is scoped to the offloader↔flight-controller link.
4. Channel IDs, flags, and CRC behavior must match FCSP/1 exactly.
5. Any FCSP wire change requires coordinated implementation updates in both repos and a single spec update in this repo only.

## Feature parity goals

Both paths (MSP and FCSP) must support:

- ESC passthrough control (enter/exit/scan)
- settings read/write
- firmware update workflows
- runtime telemetry/logging
- deterministic control-plane operation

## Bring-up order

1. FCSP frame parser/generator parity tests
2. FCSP CONTROL channel commands
3. FCSP ESC_SERIAL bridge path
4. FCSP telemetry/log channels
5. staged migration from MSP default to FCSP default
