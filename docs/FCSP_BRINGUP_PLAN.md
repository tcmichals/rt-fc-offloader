# FCSP Bring-up Plan (Execution-First)

This plan turns the protocol requirements into immediate implementation steps.

## Objective

- Validate **MSP baseline on PICO + ESC-config GUI** first.
- Implement **FCSP runtime path on FPGA** with **SERV 8-bit @ 50 MHz** target.
- Advance to the next FCSP test stage only after parity and timing gates are met.
- Run two synchronized benches: RTL (Verilator/cocotb) and Python FCSP protocol simulator.

Mandatory verification rule:

- Break the design into independently testable blocks.
- Every block must pass block-level tests before entering subsystem/integration validation.

## Phase 0 — Baseline lock (MSP/PICO)

## Exit criteria

- GUI workflows pass over standard MSP path.
- Passthrough enter/exit/scan behavior verified.
- ESC settings read/write and representative flash workflow verified.
- Baseline behavior captured for FCSP parity comparison.

## Artifacts

- Baseline test notes: `sim/baseline_msp_results.md` (to be created during execution)

---

## Phase 1 — FCSP parser + control minimum

## Scope

- FCSP frame parser with resync + payload bounds + CRC16/XMODEM.
- Channel router and RX/TX FIFO boundaries in RTL.
- Minimal CONTROL operations in firmware:
  - `PING` (`0x06`)
  - `HELLO` (`0x13`)
  - `GET_CAPS` (`0x12`)
  - `GET_LINK_STATUS` (`0x05`)

## Exit criteria

- Parser noise-resync tests pass.
- CRC pass/fail behavior deterministic.
- HELLO/GET_CAPS responses parse and version correctly.
- Block-level tests pass for parser, CRC, router, and FIFO boundary logic.
- Python simulator parser/CRC/resync golden-model tests pass.

---

## Phase 2 — Migration-critical CONTROL ops

## Scope

- Implement:
  - `PT_ENTER` (`0x01`)
  - `PT_EXIT` (`0x02`)
  - `ESC_SCAN` (`0x03`)
  - `SET_MOTOR_SPEED` (`0x04`)
- Enforce passthrough safety ownership (no DSHOT writes while passthrough active).

## Exit criteria

- State transitions match MSP baseline semantics.
- Result/error code mapping deterministic and documented.
- Block-level tests pass for CONTROL dispatcher and passthrough state machine behavior.
- Python simulator op/result mapping tests pass for CONTROL ops in scope.

---

## Phase 3 — Dynamic block IO and unified spaces

## Scope

- Implement `READ_BLOCK` (`0x10`) / `WRITE_BLOCK` (`0x11`).
- Add FCSP spaces for unified IO domains:
  - `0x10` PWM_IO
  - `0x11` DSHOT_IO
  - `0x12` LED_IO
  - `0x13` NEO_IO

## Exit criteria

- Capability TLVs expose supported spaces and limits.
- Read/write bounds checking and deterministic errors verified.
- Block-level tests pass for block-IO decoder, space mapping, and bounds/error paths.

---

## Phase 4 — Cross-transport equivalence + 50 MHz gate

## Scope

- Validate equivalent FCSP semantics over SPI (primary) and serial/sim transport (optional).
- Confirm SERV 8-bit @ 50 MHz viability with RTL fast path ownership.

## Exit criteria

- Semantic parity holds across transport profiles.
- No per-byte firmware bottleneck in nominal traffic.
- Deterministic control latency and recovery behavior confirmed.
- Integration sign-off allowed only after all required block-level suites are green.

---

## Immediate next implementation tasks (start now)

1. Implement RTL parser skeleton (`rtl/fcsp/`).
2. Implement firmware CONTROL dispatcher skeleton (`firmware/serv8/`).
3. Build RTL simulation tests for parser resync + caps paging (`sim/`).
4. Build Python FCSP simulator tests for frame/op/result behavior (`sim/python_fcsp/`).
5. Run MSP baseline checklist and freeze expected behavior snapshots.

## Done definition for “FCSP next test”

Proceed only when:

1. MSP baseline checklist is complete.
2. FCSP Phase 1–3 gates pass in simulation.
3. 50 MHz target constraints are met for control-plane profile.
4. Parity deltas (if any) are documented with owners and closure plan.
