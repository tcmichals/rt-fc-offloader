# Repository Contract: rt-fc-offloader ↔ python-imgui-esc-configurator

This document defines how both repositories evolve FCSP in parallel.

## Canonical ownership

- **Protocol wire spec canonical source**: `rt-fc-offloader/docs/FCSP_PROTOCOL.md`
- **No duplicate protocol spec files** in other repos; consumers must reference the canonical source above.

## Directory contract (rt-fc-offloader)

- `rtl/fcsp/` — FCSP framing, CRC, channel routing RTL
- `rtl/io/` — DSHOT, PWM decode, LED/NeoPixel, SPI bridge RTL
- `firmware/serv8/` — legacy-named control-plane firmware scaffold (name retained for compatibility; does not imply active embedded soft-CPU usage)
- `sim/` — simulation and protocol verification harnesses
- `docs/` — protocol and integration docs

## Cross-repo compatibility rules

1. Python GUI behavior must not depend on MSP-only assumptions.
2. Transport selection is worker/offloader-side only; GUI flow remains unchanged.
3. SPI/FCSP wire transport is scoped to the offloader↔flight-controller link.
4. Channel IDs, flags, and CRC behavior must match FCSP/1 exactly.
5. Any FCSP wire change requires coordinated implementation updates in both repos and a single spec update in this repo only.
6. Discovery compatibility must be preserved: `HELLO` + `GET_CAPS` are required; mDNS is optional for IP-exposed transports only.
7. FPGA-side protocol/IO implementation code must be written in **SystemVerilog**.
8. FPGA simulation/testbench verification stack is standardized on **Verilator + cocotb**.
9. FCSP Python protocol simulator/golden-model artifacts in this repo must be reusable by companion Python adapter tests.
10. A git submodule link to `python-imgui-esc-configurator` may be used for cross-repo protocol validation workflows.

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
