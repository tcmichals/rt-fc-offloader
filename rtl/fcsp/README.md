# rtl/fcsp — FCSP fast-path RTL

This folder owns FCSP byte-stream fast-path logic.

## Responsibilities

- sync detect (`0xA5`)
- header decode + payload length bound checks
- CRC16/XMODEM verification
- channel routing (`CONTROL`, `TELEMETRY`, `FC_LOG`, `DEBUG_TRACE`, `ESC_SERIAL`)
- FIFO push/pop boundaries and backpressure behavior

## First modules to implement

- `fcsp_parser` — stream parser and frame validator
- `fcsp_crc16` — CRC16/XMODEM pipeline or stepper
- `fcsp_router` — channel dispatch to per-channel FIFOs
- `fcsp_rx_fifo` / `fcsp_tx_fifo` wrappers

## Verification goals

- noise-resync behavior
- malformed length rejection
- CRC fail path and recovery
- multiple frames per burst and split-frame burst handling

## Required test strategy

- Each RTL block in this directory must have an independent cocotb/Verilator testbench.
- Block tests must pass before running or claiming pass on integrated protocol tests.
