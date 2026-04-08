# rt-fc-offloader Requirements

## Mission

Provide deterministic offloader-side protocol and hardware control paths using FCSP over SPI (primary profile), with support for equivalent FCSP semantics over alternate links when needed.

## Role split and migration intent

- **PICO path (validation-first)**: use standard **MSP** with the ESC-config GUI to validate workflow behavior and feature parity.
- **FPGA offloader path (runtime target)**: implement **FCSP** for deterministic transport/performance.
   - Primary FCSP physical layer: **SPI**
   - Secondary/alternate FCSP layers: **serial/UART/USB-CDC** for debug/simulation

Migration rule:

1. Prove GUI/worker behavior on MSP (PICO path).
2. Preserve identical feature intent on FCSP.
3. Move test traffic from MSP baseline to FCSP once FCSP acceptance gates pass.

## Must-have requirements

1. Canonical FCSP ownership in this repo:
   - `docs/FCSP_PROTOCOL.md`
2. 50 MHz control-path profile viability with RTL fast-path offload (no embedded soft-CPU dependency).
3. RTL handles sync/length/CRC/channel routing/FIFO.
4. The control endpoint handles policy/state transitions and result codes.
5. Unified dynamic IO model via FCSP block operations:
   - PWM, DSHOT, LED, NeoPixel handled through discoverable spaces.
6. Discovery support:
   - required `HELLO` + `GET_CAPS`
   - optional mDNS for IP-exposed transports.
7. FPGA implementation language/tooling:
   - all FPGA RTL code must be **SystemVerilog**
   - simulation/testbench stack must be **Verilator + cocotb**
8. Verification granularity requirement:
   - design must be decomposed into testable blocks
   - each RTL/firmware block must have an independent block-level test before subsystem/integration tests
9. Dual testbench requirement:
   - maintain RTL-focused block/subsystem testbenches using **Verilator + cocotb**
   - maintain a **Python FCSP protocol simulator** testbench/golden-model for frame/op/result validation
   - Python simulator artifacts must be shareable with companion Python adapter validation workflows

## MSP ↔ FCSP mapping requirements

The following mappings are required to keep user-facing behavior unchanged during migration:

- passthrough enter/exit/scan: MSP semantics -> FCSP `CONTROL` (`PT_ENTER`, `PT_EXIT`, `ESC_SCAN`)
- motor speed command: MSP motor command -> FCSP `CONTROL/SET_MOTOR_SPEED`
- ESC settings/flash phase-1: legacy 4-way intent -> FCSP `ESC_SERIAL` tunnel
- discovery/capabilities: MSP ad hoc probing -> FCSP `HELLO` + `GET_CAPS` (required)
- dynamic IO control/state (PWM/DSHOT/LED/NeoPixel): FCSP `READ_BLOCK`/`WRITE_BLOCK` spaces

Mapping stability rules:

1. Same user-visible outcomes for GUI actions across MSP baseline and FCSP path.
2. Passthrough safety semantics must remain identical.
3. Error/result behavior must remain deterministic and documented.

## Cross-repo contract

- Python repo consumes FCSP as client/adapter.
- FCSP wire changes are made here first, then implemented in companion repo.
- No duplicated FCSP spec files in companion repos.

## Quality gates

- Every protocol-critical block has a dedicated block-level test with documented pass criteria.
- Protocol/frame parser tests pass in simulation.
- Python FCSP simulator/golden-model tests pass for encode/decode, CRC, resync, and op-level mapping.
- Capability/discovery behavior is deterministic and versioned.
- Backward-safe migration path from MSP remains documented.

## Definition of done (execution checklist)

### A) PICO MSP baseline done

- ESC-config GUI workflows complete using standard MSP path.
- Passthrough enter/exit/scan verified.
- Core ESC settings read/write and representative flash flow validated.
- Baseline behavior captured as reference for FCSP parity checks.

### B) FCSP protocol readiness done (FPGA target)

- FCSP parser/resync/CRC/channel behavior validated in simulation.
- Python FCSP simulator bench validates frame semantics and operation/result mapping.
- `CONTROL` ops implemented for migration-critical functions.
- `HELLO` + `GET_CAPS` implemented and versioned capability TLVs verified.
- `READ_BLOCK`/`WRITE_BLOCK` spaces for dynamic IO defined and tested.
- Cross-transport semantic equivalence validated (SPI primary, serial/sim optional).

### C) 50 MHz control-path target done

- Implementation demonstrates control-plane viability at 50 MHz profile without an embedded soft CPU.
- RTL owns byte-stream fast path (sync/length/CRC/routing/FIFO), firmware owns control policy.
- No per-byte firmware bottleneck in normal operation (frame/FIFO-driven handling).
- Deterministic control latency and error handling observed in integration tests.
- SystemVerilog RTL and Verilator/cocotb testbenches are used for all FPGA-side protocol verification.
- Block-level test suite passes for each major block (parser, CRC, router, FIFOs, control dispatcher) before full integration sign-off.

### D) FCSP next-test gate (go/no-go)

Proceed to the next FCSP test stage only when:

1. Sections A, B, and C are all satisfied.
2. MSP baseline vs FCSP outcomes are parity-checked for critical workflows.
3. Remaining deltas are documented with owners and planned closure.
