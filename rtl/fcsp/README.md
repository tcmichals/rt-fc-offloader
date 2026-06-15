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

## Key Modules

- `fcsp_offloader_top.sv`
	- Top integration tying together ingress, protocol parser, router, Wishbone master, IO engines, and TX arbiter/framer.
- `fcsp_parser.sv` / `fcsp_crc_gate.sv`
	- Stream parser, header decoder, and CRC validation path.
- `fcsp_router.sv`
	- Demuxes validated payload stream into CONTROL (0x01) and ESC_SERIAL (0x05) channels.
- `fcsp_wishbone_master.sv`
	- Translates CONTROL payloads (READ/WRITE_BLOCK) into internal Wishbone B3 cycles.
- `fcsp_tx_arbiter.sv` / `fcsp_tx_framer.sv`
	- Priority multiplexer (CTRL > ESC > DBG) and FCSP wire formatter for response egress.
- `fcsp_io_engines.sv`
	- Wrapper seam for IO endpoints (DShot, PWM, NeoPixel, ESC UART) mapping them to the internal Wishbone bus or raw streams.
## Internal stream convention

- Prefer **AXIS-style naming internally**: `tvalid/tready/tdata/tlast`
- Use `s_*` for slave/input stream endpoints
- Use `m_*` for master/output stream endpoints
- See `rtl/fcsp/INTERFACES.md`

## Verification goals

- noise-resync behavior
- malformed length rejection
- CRC fail path and recovery
- multiple frames per burst and split-frame burst handling

## Required test strategy

- Each RTL block in this directory must have an independent cocotb/Verilator testbench.
- Block tests must pass before running or claiming pass on integrated protocol tests.
