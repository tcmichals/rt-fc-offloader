# FPGA Block Design — FCSP Offloader (SERV8 @ 50 MHz)

This document defines the initial FPGA block architecture for FCSP/1 on the offloader path.

Design goals:

- deterministic FCSP byte-stream handling over SPI
- RTL-owned frame fast-path (sync/len/CRC/routing/FIFO)
- SERV8 firmware-owned control policy/state/result codes
- migration-safe behavior parity with MSP baseline workflows

---

## Top-level architecture

Canonical quick-reference diagram lives in:

- `docs/TOP_LEVEL_BLOCK_DIAGRAM.md`

The diagram below is an expanded architectural view that should stay semantically aligned with the canonical top-level diagram.

```mermaid
flowchart LR
    HOST[Host / FC link\nSPI byte stream] --> SPI[SPI RX/TX front-end]
    SPI --> RXA[RX align + byte stream adapter]
    RXA --> PARSER[fcsp_parser\nsync + header + len checks]
    PARSER --> CRC[fcsp_crc16\nXMODEM verify]
    CRC --> ROUTER[fcsp_router\nchannel dispatch]

    ROUTER --> QCTRL[CONTROL RX FIFO]
    ROUTER --> QTEL[TELEMETRY RX FIFO]
    ROUTER --> QLOG[FC_LOG RX FIFO]
    ROUTER --> QDBG[DEBUG_TRACE RX FIFO]
    ROUTER --> QESC[ESC_SERIAL RX FIFO]

    QCTRL --> SERV[SERV8 CONTROL firmware\nop dispatch + policy]
    SERV --> TXM[fcsp_tx_mux]

    QTEL --> TXM
    QLOG --> TXM
    QDBG --> TXM
    QESC --> TXM

    TXM --> ENCODER[fcsp_tx_framer\nheader + crc16]
    ENCODER --> SPI

    SERV --> IOREG[IO register windows\nPWM/DSHOT/LED/NEO spaces]
    IOREG <--> IOPHY[IO domain adapters]

    SERV --> STAT[link/status counters\ncrc_err rx_drop fifo_ovf]
    STAT --> TXM
```

---

## Block responsibilities

### 1) `spi_frontend`

- Converts SPI transfers into a continuous RX byte stream and TX byte source/sink.
- Must support split-frame and multi-frame bursts.
- No FCSP semantics here.

### 2) `fcsp_parser`

- Searches for sync byte `0xA5`.
- Parses FCSP header (`version`, `flags`, `channel`, `seq`, `payload_len`).
- Enforces payload length maximum.
- Emits candidate frame bytes/metadata to CRC block.
- On malformed header/length, shift by 1 byte and resync.

### 3) `fcsp_crc16`

- Computes CRC16/XMODEM across `version..payload`.
- Compares with frame CRC field.
- Accepts/denies frame; increments error counters on failure.

### 4) `fcsp_router`

- Routes validated frames into per-channel RX FIFOs:
  - CONTROL (`0x01`)
  - TELEMETRY (`0x02`)
  - FC_LOG (`0x03`)
  - DEBUG_TRACE (`0x04`)
  - ESC_SERIAL (`0x05`)
- Handles FIFO-full backpressure/drop policy (deterministic + counted).
- Internal implementation direction is AXIS-style:
  - one packetized input stream + frame metadata
  - per-channel AXIS-like output streams
  - ready/valid backpressure from the selected channel sink

### 5) Channel FIFOs (`fcsp_rx_fifo_*`, `fcsp_tx_fifo_*`)

- Isolate producer/consumer timing.
- Carry frame boundaries (`sof/eof` or length-tagged packets).
- Target aggregate depth >= 4 KB equivalent across RX/TX queues.
- Internal wrapper direction is AXIS-style payload stream plus metadata sideband:
  - payload: `tvalid`, `tready`, `tdata[7:0]`, `tlast`
  - metadata: `channel`, `flags`, `seq`, `payload_len`

### 6) `serv_control_dispatch` (firmware)

- Dequeues CONTROL channel frames.
- Dispatches `op_id` and builds deterministic result responses.
- Owns passthrough safety/state transitions.

Initial op priority:

1. `PING`, `GET_LINK_STATUS`
2. `HELLO`, `GET_CAPS`
3. `PT_ENTER`, `PT_EXIT`, `ESC_SCAN`
4. `SET_MOTOR_SPEED`
5. `READ_BLOCK`, `WRITE_BLOCK`

### 7) `io_space_windows`

- Shared register window abstraction for block IO spaces:
  - `0x10` PWM_IO
  - `0x11` DSHOT_IO
  - `0x12` LED_IO
  - `0x13` NEO_IO
- Enforces bounds checks and deterministic error return.

DSHOT mode compatibility requirement:

- Preserve legacy runtime mode support through `DSHOT_IO` control window.
- Required baseline modes: `150`, `300`, `600`.
- Include `1200` when enabled by selected legacy engine path.
- Mode changes must be guarded to avoid mid-frame glitches.

### 8) `fcsp_tx_mux` + `fcsp_tx_framer`

- Muxes outbound traffic from firmware responses and streaming channels.
- Applies QoS priority (recommended: CONTROL highest).
- Builds FCSP wire frames and appends CRC16.

---

## Internal interfaces (recommended)

Use AXIS-style valid/ready streams internally for bytes and packetized frame payloads.

### Byte-stream interface

- `tdata[7:0]`
- `tvalid`, `tready`
- optional `tlast` when packet boundaries are already known

### Frame-stream interface

- payload path: `tvalid`, `tready`, `tdata[7:0]`, `tlast`
- sideband metadata: `channel[7:0]`, `flags[7:0]`, `seq[15:0]`, `payload_len[15:0]`

Recommended naming style:

- `s_*` = slave/input side of a stream
- `m_*` = master/output side of a stream

### Status/counter interface

- `ctr_crc_error`
- `ctr_len_error`
- `ctr_sync_loss`
- `ctr_rx_drop`
- `ctr_fifo_overflow`

---

## Clock/reset and timing notes

- Single clock domain target to start: `clk_50m`.
- Synchronous active-high reset: `rst`.
- If SPI clock is asynchronous, isolate with front-end CDC FIFO before parser.
- Keep parser+CRC pipeline one-byte-per-cycle capable in nominal case.

---

## CONTROL path state machine (firmware-owned)

Core states:

- `IDLE`
- `PT_ACTIVE(motor_index, esc_count)`
- `ERROR_RECOVERY`

Rules:

1. `PT_ENTER` transitions `IDLE -> PT_ACTIVE` on success.
2. `PT_EXIT` transitions `PT_ACTIVE -> IDLE`.
3. `SET_MOTOR_SPEED` rejected while `PT_ACTIVE` (busy/not_ready policy).
4. Transport/frame errors surface as deterministic FCSP result/status.

---

## Verification decomposition (block-first)

Required standalone block tests before integration:

1. `fcsp_parser`: sync find, length reject, split/multi-frame stream handling
2. `fcsp_crc16`: known vectors + fail path
3. `fcsp_router`: per-channel routing + overflow behavior
4. FIFO wrappers: depth, watermark, boundary semantics
5. CONTROL dispatcher: op decode/result mapping + passthrough state logic
6. Block IO windows: bounds checks, read/write correctness

Then subsystem tests:

- parser + crc + router chain
- control request/response latency determinism
- cross-transport semantic equivalence in sim harness

---

## Implementation order (practical)

1. `fcsp_parser` + `fcsp_crc16` RTL skeletons
2. `fcsp_router` + per-channel RX FIFOs
3. SERV control dispatcher with `PING`, `GET_LINK_STATUS`, `HELLO`, `GET_CAPS`
4. passthrough ops and safety gating
5. `READ_BLOCK`/`WRITE_BLOCK` spaces for IO windows
6. TX mux/framer priority + telemetry/log streaming

This sequence satisfies protocol gates while reducing integration risk.