# FPGA Repo Prompt Guide (rt-fc-offloader)

Use this file as a concise prompt starter for FPGA/offloader work.

## Mission

Build a deterministic offloader path where:

- FCSP is the protocol layer
- SPI is the primary physical layer for offloader ↔ flight-controller
- SERV 8-bit @ 50 MHz runs control-plane logic
- timing-critical paths stay in RTL

## Canonical sources

- `docs/DESIGN.md` — **master architecture reference** (all modules, buses, address map, registers, datapaths, gaps)
- `docs/FCSP_PROTOCOL.md` — protocol wire format and channel definitions

Do not create duplicate FCSP spec files in companion repos.

## Core implementation split

- `rtl/fcsp/` → framing, sync, CRC16, channel routing, FIFOs
- `rtl/io/` → PWM decode, DSHOT, LED/NeoPixel, SPI bridge I/O
- `firmware/serv8/` → control ops, policy/state transitions, error/result mapping
- `sim/` → parser/link tests and integration harnesses

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
> Use `docs/FCSP_PROTOCOL.md` as canonical.
> Keep RTL on the fast path (framing/CRC/routing), and keep SERV focused on control policy.
> Maintain cross-transport protocol equivalence and passthrough safety semantics.
> Add tests/sim checks for any new op/channel behavior.
