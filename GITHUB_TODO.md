# GitHub TODO — rt-fc-offloader

## Phase 0 — MSP baseline lock (PICO + ESC-config GUI)

- [ ] Validate standard MSP workflow end-to-end on PICO
- [ ] Verify passthrough enter/exit/scan baseline behavior
- [ ] Capture baseline reference for FCSP parity checks

## Current focus

- [ ] Finalize FCSP CONTROL op implementation skeleton
- [ ] Implement `HELLO` + `GET_CAPS` discovery path
- [ ] Implement `READ_BLOCK` / `WRITE_BLOCK` spaces for dynamic IO

## RTL/firmware tasks

- [ ] `rtl/fcsp/`: parser, CRC gate, channel router, FIFO boundaries
- [ ] `firmware/serv8/`: control op dispatcher + result code mapping
- [ ] Define stable IO space map for PWM/DSHOT/LED/NeoPixel windows

## Simulation

- [ ] Add frame parser noise-resync tests
- [ ] Add caps paging tests
- [ ] Add passthrough safety transition tests

## 50 MHz SERV8 target checks

- [ ] Confirm frame/FIFO-driven firmware handling (no per-byte bottleneck)
- [ ] Validate deterministic control latency and error recovery at 50 MHz profile

## Integration tasks

- [ ] Validate FCSP over primary SPI profile
- [ ] Validate FCSP semantic equivalence over simulation transport
- [ ] Publish migration notes for Python adapter consumers

## FCSP next-test gate

- [ ] MSP baseline complete
- [ ] FCSP parser/control/discovery/block-IO gates complete
- [ ] Parity delta list reviewed and approved for next test stage
