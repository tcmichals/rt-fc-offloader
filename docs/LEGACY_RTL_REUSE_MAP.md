# Legacy RTL Reuse Map (HacksterIO + pico-msp-bridge)

This note captures what we can directly leverage from legacy codebases while building FCSP fast-path RTL.

## Source repos examined

- `/media/tcmichals/projects/Tang9K/HacksterIO/SPIQuadCopter`
- `/media/tcmichals/projects/pico/flightcontroller/pico-msp-bridge.old/rtl`

## Reuse candidates

### 1) SPI front-end (high value)

- `SPIQuadCopter/spiSlave/spi_slave.sv`
- `SPIQuadCopter/src/spi_slave_wb_bridge.sv`
- `pico-msp-bridge.old/rtl/spi_slave/spi_slave.v`

Reuse intent:

- keep proven SPI sampling/shift logic
- adapt output into FCSP byte-stream valid/ready interface
- remove protocol-specific MSP framing assumptions at this layer

### 2) CRC core (high value)

- `pico-msp-bridge.old/rtl/crc/crc16_xmodem.v`

Reuse intent:

- use as FCSP `crc16_xmodem` engine in `fcsp_crc16`
- wrap with clean frame-level handshake (`start`, `data_valid`, `done`, `crc_ok`)

### 3) Stream/framing patterns (medium value)

- `pico-msp-bridge.old/rtl/framing/stream_framer.v`
- `pico-msp-bridge.old/rtl/framing/stream_framer_wb.v`

Reuse intent:

- borrow packet boundary/state-machine style
- do **not** reuse MSP payload schema; FCSP header/CRC framing is different

### 4) DSHOT datapath (for IO spaces, not FCSP parser)

- `SPIQuadCopter/dshot/dshot_out.v`
- `SPIQuadCopter/dshot/dshot_mailbox.sv`
- `SPIQuadCopter/src/wb_dshot_mailbox.sv`
- `SPIQuadCopter/src/wb_dshot_controller.sv`

Reuse intent:

- keep DSHOT generation/mailbox blocks as IO-domain implementation
- expose controls via FCSP `WRITE_BLOCK(space=0x11 DSHOT_IO, ...)`
- expose state/telemetry via FCSP `READ_BLOCK(space=0x11 DSHOT_IO, ...)`

Mode parity requirement (from legacy support):

- Preserve runtime-selectable DSHOT rates currently supported in legacy RTL.
- At minimum: `DSHOT150`, `DSHOT300`, `DSHOT600`.
- Include `DSHOT1200` where legacy path already supports it (for example via mailbox/config paths that accept mode value `1200`).
- Mode switching must remain deterministic and safe (only when channel/engine reports ready or via guarded transition).

### 5) Generic fabric blocks (selective)

- `verilog-wishbone/rtl/*` (mux/arbiter/ram/adapter)

Reuse intent:

- optional for internal register windows / buffering
- avoid dragging full legacy SoC topology unless needed

Recommended use in this project:

- Prefer **Wishbone** for device/register attachment points that sit beside the
	FCSP stream fabric.
- Good candidates are IO windows, control/status peripherals, and optional
	CPU-facing peripheral maps.
- Do **not** force Wishbone into the FCSP byte-stream hot path; keep AXIS-style
	stream seams there.

Teaching / reuse value:

- engineers can learn a standard lightweight device bus
- legacy Wishbone peripherals can be wrapped and reused with less effort
- nearby target designs can retarget device blocks while preserving the same
	FCSP stream pipeline

## What not to port as-is

- MSP-specific framers/parsers
- monolithic top-level SoC glue (`wb_spisystem` style coupling)
- SERV in byte hot path (SERV stays control-plane only)

## FCSP adaptation targets in this repo

Implement in `rtl/fcsp/`:

1. `fcsp_spi_frontend.sv` (from SPI slave patterns)
2. `fcsp_crc16.sv` (wrapping CRC16/XMODEM core)
3. `fcsp_parser.sv` (FCSP sync/header/len parser)
4. `fcsp_router.sv` (channel dispatch)
5. `fcsp_rx_fifo_*.sv` / `fcsp_tx_fifo_*.sv`

DSHOT/LED/NeoPixel live behind FCSP block-space windows, not inside parser/router path.

## Suggested `DSHOT_IO` register window (initial)

- `0x00..0x0F` throttle frame words (per motor)
- `0x10` mode register (`150|300|600|1200`)
- `0x14` ready/status bitfield
- `0x20..` telemetry/RPM readback (if enabled)

This keeps legacy DSHOT capabilities while moving transport to FCSP block operations.

## Immediate next step

Start with SPI + CRC wrappers and a cocotb smoke test that proves:

- split bursts accepted
- sync/length gating works
- CRC pass/fail classification works

Longer-term reuse rule:

- for stream datapaths, keep AXIS-style seams
- for device/register blocks, prefer Wishbone wrappers and per-device unit tests
