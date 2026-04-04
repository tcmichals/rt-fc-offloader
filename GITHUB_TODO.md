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
- [x] Integrate SERV command/response wiring in `rtl/fcsp/boards/tangnano9k/fcsp_tangnano9k_top.sv` using `fcsp_serv_stub` (interim, replaces seam stubs)
- [x] Add SERV-originated debug message producer (`DEBUG_TRACE`) in `fcsp_serv_stub` (interim format: short text frame)
- [x] Route `DEBUG_TRACE` channel into TX scheduler/framer (CONTROL + DEBUG via `fcsp_tx_arbiter`)
- [x] Wire USB-UART byte-stream shim in Tang9K wrapper so FCSP debug frames can exit on board serial port
- [ ] Define stable IO space map for PWM/DSHOT/LED/NeoPixel windows

## Next implementation queue (current)

- [ ] Replace `fcsp_serv_stub` with real SERV core + firmware mailbox contract
- [x] Upgrade `fcsp_tx_fifo` from pass-through seam to true buffered FIFO with occupancy/backpressure counters
- [x] Implement fit-aware buffered `fcsp_rx_fifo` for Tang9K (current RX seam remains pass-through to preserve build fit)
- [ ] Add TX arbitration policy controls (priority/round-robin) and fairness tests
- [ ] Add FCSP command coverage for `HELLO`, `GET_CAPS`, `READ_BLOCK`, `WRITE_BLOCK` against live control map
- [ ] Expose CONTROL/DEBUG drop/overflow counters through a Wishbone status block

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
- [ ] Validate FCSP `DEBUG_TRACE` egress over USB-UART at 1 Mbit/s baseline (loss/error counters)
- [ ] Publish migration notes for Python adapter consumers

## FCSP next-test gate

- [ ] MSP baseline complete
- [ ] FCSP parser/control/discovery/block-IO gates complete
- [ ] Parity delta list reviewed and approved for next test stage
