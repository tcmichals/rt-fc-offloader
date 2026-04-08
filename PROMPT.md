# FPGA Repo Prompt Guide (rt-fc-offloader)

Use this file as a concise prompt starter for FPGA/offloader work.

## Mission

Build a deterministic offloader path where:

- FCSP is the protocol layer
- SPI is the primary physical layer for offloader ↔ flight-controller
- `fcsp_wishbone_master` (pure RTL) executes control-plane ops directly on the Wishbone bus
- timing-critical paths stay in RTL

## Canonical sources

- `docs/DESIGN.md` — **master architecture reference** (all modules, buses, address map, registers, datapaths, gaps)
- `docs/FCSP_PROTOCOL.md` — protocol wire format and channel definitions

Do not create duplicate FCSP spec files in companion repos.

## Core implementation split

- `rtl/fcsp/` → framing, sync, CRC16, channel routing, FIFOs, Wishbone master, TX egress
- `rtl/io/` → PWM decode, DSHOT, LED/NeoPixel, ESC UART, serial/DShot pin mux
- `sim/` → parser/link tests and integration harnesses (Verilator + cocotb)
- `python/hw/` → hardware test scripts (USB-UART via `hwlib.FcspControlClient`)

## Guardrails

1. Keep FCSP frame semantics identical across physical layers.
2. Keep GUI workflow protocol-agnostic; protocol adaptation is worker/offloader side.
3. Preserve passthrough safety ownership (no DSHOT writes while passthrough active).
4. Prefer small fixed payloads + TLV extension records for discoverability.
5. Use HELLO + GET_CAPS for discovery; mDNS is optional for IP-exposed links only.
6. FPGA RTL implementation language is SystemVerilog only.
7. Testbench/simulation stack is Verilator + cocotb.

## Suggested prompt snippet

> Implement the next smallest FCSP milestone in `rt-fc-offloader`.
> Use `docs/DESIGN.md` as the master architecture reference and `docs/FCSP_PROTOCOL.md` as canonical protocol spec.
> Keep all control ops in pure RTL via `fcsp_wishbone_master`.
> Maintain cross-transport protocol equivalence and passthrough safety semantics.
> Add tests/sim checks for any new op/channel behavior.
