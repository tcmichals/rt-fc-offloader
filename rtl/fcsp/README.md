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

## Integration scaffolds now present

- `fcsp_serv_bridge.sv`
	- CONTROL-plane byte-stream seam between FCSP and SERV firmware endpoint
	- models both directions (RX command ingress + TX response egress)
- `fcsp_io_engines.sv`
	- wrapper seam for lift/adapt engines:
		- DSHOT output/mailbox path
		- PWM decode path
		- NeoPixel output path
- `fcsp_offloader_top.sv`
	- top integration scaffold showing both transport ends:
		- SPI frontend path
		- optional USB serial ingress/egress path
	- includes parser observability, SERV bridge hookup, IO engine wrapper hookup

These are compile-safe skeletons intended to accelerate integration while legacy blocks are brought over.

## Verification goals

- noise-resync behavior
- malformed length rejection
- CRC fail path and recovery
- multiple frames per burst and split-frame burst handling

## Required test strategy

- Each RTL block in this directory must have an independent cocotb/Verilator testbench.
- Block tests must pass before running or claiming pass on integrated protocol tests.
