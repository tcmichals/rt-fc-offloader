# DESIGN — Master RTL Architecture Reference

> **Single source of truth.** Every RTL module, datapath, address, and register lives here.
> Detail docs are linked — never duplicated.

---

## 1. Hierarchy — Every Module

### 1.1 Board Wrapper

| Module | File | Purpose |
|--------|------|---------|
| `fcsp_tangnano9k_top` | `rtl/fcsp/boards/tangnano9k/fcsp_tangnano9k_top.sv` | Tang Nano 9K board wrapper. PLL, USB-UART byte stream, LED controller, heartbeat. |
| `Gowin_rPLL` | (IP) | 27 MHz → 54 MHz PLL |
| `fcsp_uart_byte_stream` | `rtl/fcsp/fcsp_uart_byte_stream.sv` | USB-UART TX/RX byte-level interface (1 Mbaud) |
| `wb_led_controller` | `rtl/fcsp/drivers/wb_led_controller.sv` | 6-LED SET/CLEAR/TOGGLE via WB (lives in board wrapper, NOT inside offloader_top) |

### 1.2 FCSP Offloader Core

| Module | File | Purpose |
|--------|------|---------|
| `fcsp_offloader_top` | `rtl/fcsp/fcsp_offloader_top.sv` | Top-level offloader. Integrates ingress, protocol engine, WB master, IO engines, TX egress. |

#### Ingress

| Module | File | Purpose |
|--------|------|---------|
| `fcsp_spi_frontend` | `rtl/fcsp/fcsp_spi_frontend.sv` | SPI slave → byte stream. CDC + bit-level shifter. |

USB ingress is directly from `fcsp_uart_byte_stream` at board level — no module inside offloader for it.

**Ingress arbitration:** USB-valid wins over SPI. Combinational mux in `fcsp_offloader_top`.

#### Protocol Engine

| Module | File | Purpose |
|--------|------|---------|
| `fcsp_parser` | `rtl/fcsp/fcsp_parser.sv` | Sync detect → header → payload → CRC extraction. Produces AXIS frame stream. |
| `fcsp_crc_gate` | `rtl/fcsp/fcsp_crc_gate.sv` | Buffers frame, validates CRC16/XMODEM, drops bad frames. |
| `fcsp_crc16` | `rtl/fcsp/fcsp_crc16.sv` | CRC16/XMODEM compute block (streaming). |
| `fcsp_crc16_core_xmodem` | `rtl/fcsp/fcsp_crc16_core_xmodem.sv` | Combinational CRC16 core. |
| `fcsp_router` | `rtl/fcsp/fcsp_router.sv` | Demux by channel ID → per-channel AXIS outputs. |

#### Control Plane (CH 0x01)

| Module | File | Purpose |
|--------|------|---------|
| `fcsp_rx_fifo` | `rtl/fcsp/fcsp_rx_fifo.sv` | Elastic FIFO between router and WB master. Stores channel/flags/seq metadata. |
| `fcsp_wishbone_master` | `rtl/fcsp/fcsp_wishbone_master.sv` | Decodes READ_BLOCK / WRITE_BLOCK op payloads → Wishbone bus cycles. Generates response stream. |

#### TX Egress

| Module | File | Purpose |
|--------|------|---------|
| `fcsp_tx_fifo` | `rtl/fcsp/fcsp_tx_fifo.sv` | Per-producer elastic FIFO (one for CTRL responses, one for DBG). Stores metadata. |
| `fcsp_tx_arbiter` | `rtl/fcsp/fcsp_tx_arbiter.sv` | 3-input priority mux: CTRL > ESC > DBG. Frame-atomic grant. |
| `fcsp_tx_framer` | `rtl/fcsp/fcsp_tx_framer.sv` | Wraps AXIS payload + metadata into wire-format FCSP frames (sync, header, CRC). |
| `fcsp_stream_packetizer` | `rtl/fcsp/fcsp_stream_packetizer.sv` | Collects raw bytes into frame-sized chunks (MAX_LEN or timeout). Generic — used for ESC RX → FCSP. |
| `fcsp_debug_generator` | `rtl/fcsp/fcsp_debug_generator.sv` | Optional debug telemetry producer. |

#### IO Engines (Wishbone Peripherals)

| Module | File | Purpose |
|--------|------|---------|
| `fcsp_io_engines` | `rtl/fcsp/fcsp_io_engines.sv` | Glue: instantiates `wb_io_bus` + all 6 IO peripherals. LED WB pass-through to board wrapper. |
| `wb_io_bus` | `rtl/io/wb_io_bus.sv` | Address decoder. 7 slave ports. WHO_AM_I returns `0xFC500002`. |
| `wb_dshot_controller` | `rtl/io/wb_dshot_controller.sv` | 4-channel DShot output engine. Registers: raw 16-bit word per motor. |
| `dshot_out` | `rtl/io/dshot_out.sv` | Single-channel DShot pulse transmitter (DSHOT150/300/600). |
| `wb_serial_dshot_mux` | `rtl/io/wb_serial_dshot_mux.sv` | Pin mux: DShot vs Serial mode per motor pad. MSP auto-sniffer. Force-low break. |
| `wb_esc_uart` | `rtl/io/wb_esc_uart.sv` | Half-duplex UART for ESC config. 19200 default. TX/RX/STATUS/BAUD_DIV registers. |
| `wb_neoPx` | `rtl/io/wb_neoPx.sv` | 8-pixel NeoPixel buffer + trigger. |
| `sendPx_axis_flexible` | `rtl/io/sendPx_axis_flexible.sv` | WS2812/SK6812 waveform generator (AXIS interface). |
| `pwmdecoder_wb` | `rtl/io/pwmdecoder_wb.sv` | WB wrapper for 6-channel PWM decoder. |
| `pwmdecoder` | `rtl/io/pwmdecoder.sv` | PWM pulse-width measurement engine. |

### 1.3 Legacy / Unused (in repo but NOT in production build)

| Module | File | Notes |
|--------|------|-------|
| `fcsp_serv_bridge` | `rtl/fcsp/fcsp_serv_bridge.sv` | Replaced by `fcsp_wishbone_master`. Dead code. |
| `fcsp_serv_stub` | `rtl/fcsp/fcsp_serv_stub.sv` | Replaced. Dead code. |
| `rtl/fcsp/drivers/*` | Various | Legacy copies of IO peripherals before port to `rtl/io/`. Not used in build. |

---

## 2. Bus & Transport Architecture

### 2.1 SPI Bus — Physical Layer

| Property | Value |
|----------|-------|
| Mode | **SPI Mode 0** (CPOL=0, CPHA=0) |
| Bit order | MSB-first |
| Data width | 8-bit byte-oriented |
| Duplex | Full-duplex (MOSI + MISO simultaneous) |
| FPGA role | **Slave** — Pico is SPI master |
| CDC | SCLK/CS: 3-FF sync; MOSI: 2-FF sync |
| Max SCLK | Conservative rule: ≤ sys_clk/4 = **13.5 MHz** (at 54 MHz sys_clk) |
| RTL module | `fcsp_spi_frontend` → wraps `spi_slave` |

**Byte-stream semantics:** The SPI frontend converts pin-level SPI into a simple byte stream (`rx_byte/rx_valid/rx_ready` + `tx_byte/tx_valid/tx_ready`). The rest of the FPGA never sees SPI pins — only bytes.

### 2.2 SPI ↔ FCSP Protocol Mapping

SPI is synchronous with no native packet boundaries. FCSP solves this at the protocol layer:

```
SPI bus (raw bytes)
  │
  ├─ One SPI burst may contain a partial FCSP frame
  ├─ One SPI burst may contain exactly one FCSP frame
  ├─ One SPI burst may contain multiple concatenated FCSP frames
  └─ Command + telemetry/log/debug frames may be interleaved
```

**Key rule:** FCSP-over-SPI is **streaming/multiplexed**, not request-response. The parser scans the byte stream for `sync = 0xA5`, parses the header, accumulates payload + CRC, and validates per frame — independent of SPI CS boundaries.

**Full-duplex flow:**    
Because SPI clocks MOSI and MISO simultaneously, the host must keep clocking bytes to receive replies. The SPI frontend has a 1-byte TX hold register; if no response byte is ready, MISO shifts zeros (pad bytes). Pad bytes are transport-layer behavior only — FCSP frame format is unchanged.

**Ingress arbitration (in `fcsp_offloader_top`):**

```
if (i_usb_rx_valid)           ← USB wins
    ingress = USB byte
else
    ingress = SPI byte
```

Both transports feed the same `fcsp_parser` — the protocol engine is transport-agnostic.

> **See also:** [FCSP_SPI_TRANSPORT.md](FCSP_SPI_TRANSPORT.md) for the full transport profile spec.

### 2.3 Internal Switch Fabric & AXIS Mapping

The offloader's internal datapath is structured as a **hardware switch**. Data moves through the system using AXI-Stream (AXIS) interfaces with stateful transaction tracking.

> **Detailed Specification:** [SWITCH_ARCHITECTURE.md](SWITCH_ARCHITECTURE.md) — How the protocol maps to AXIS, and how Transaction ID (TID) tracking ensures responses are routed correctly.

---

## 3. Best Practices & Common Gotchas

To ensure Verilator compliance and hardware stability, the following rules apply to all new RTL development in this repository.

### 3.1 Verilator Compatibility
- **Type `logic` only:** Use `logic` for all ports and internal signals. Avoid `wire` or `reg`. This prevents `PROCASSWIRE` errors when procedurally assigning to outputs in state machines.
- **No Inferred Latches:** Every `always_comb` block must specify default assignments for all driven signals at the start of the block.
- **Top-Level Linting:** Always run `make test-all-strict` (or the `sim-test-all-strict` CMake target) to catch linting errors before synthesis.

### 3.2 State Machine Design
- **Payload Draining:** Frame-oriented state machines must always drain payloads until `TLAST` is seen, even if the payload is invalid or unexpected (e.g., in `OP_PING`). This prevents FIFO desynchronization.
- **Stateful Responses:** Use the `TID` signal to latch the request source. Ensure the response frame sets its `TDEST` to match the latched `TID`.

---

## 4. Wishbone B3 Internal Bus

| Property | Value |
|----------|-------|
| Address width | 32-bit |
| Data width | 32-bit |
| Byte selects | 4-bit (`wb_sel`) |
| Pipelining | **None** — single outstanding transaction |
| Ack model | Slave asserts `ack` for 1 cycle; master waits |
| Error signals | **None** — no `wb_err_i` / timeout |
| Bus master | `fcsp_wishbone_master` (inside `fcsp_offloader_top`) |
| Bus decoder | `wb_io_bus` (inside `fcsp_io_engines`) |
| RTL signals | `int_wb_adr`, `int_wb_dat_m2s`, `int_wb_dat_s2m`, `int_wb_sel`, `int_wb_we`, `int_wb_cyc`, `int_wb_stb`, `int_wb_ack` |

**Transaction flow:**

```
fcsp_wishbone_master                    wb_io_bus                    Peripheral slave
       │                                    │                              │
       ├── wb_cyc=1, wb_stb=1 ─────────────►│                              │
       │   wb_adr, wb_dat, wb_we, wb_sel     ├── slave_cyc=1, stb=1 ──────►│
       │                                    │                              │
       │                                    │◄──── slave_ack=1 ────────────┤
       │◄────── wb_ack=1, wb_dat_i ─────────┤      (1 cycle pulse)        │
       │   wb_cyc=0, wb_stb=0               │                              │
```

- **Writes:** WB master packs FCSP payload into 32-bit words (up to 4 bytes per WB write). A WRITE_BLOCK with N payload bytes produces ⌈N/4⌉ WB write cycles.
- **Reads:** Currently READ_BLOCK reads one 32-bit word (single WB read cycle). Response is 7 bytes: `[0x10, addr[3:0], 0x04, data[3:0]]`.

### 2.4 Address Decode (`wb_io_bus`)

The decoder selects the slave from `wbm_adr_i[15:8]` (the "page byte"):

```
wbm_adr_i[31:16]  = 0x4000 (base, not checked by decoder)
wbm_adr_i[15:8]   = page   → slave select
wbm_adr_i[7:0]    = offset → forwarded to slave
```

| Page | Slave | Address forwarded |
|------|-------|-------------------|
| `0x00` | WHO_AM_I | (internal, no slave port) |
| `0x01` | PWM decoder | Full 32-bit address |
| `0x03` | DShot controller | Full 32-bit address |
| `0x04` | Serial/DShot mux | Full 32-bit address |
| `0x06` | NeoPixel | Full 32-bit address |
| `0x09` | ESC UART | `esc_adr_o[3:0]` = `wbm_adr_i[3:0]` |
| `0x0C` | LED controller | Full 32-bit address |
| other | NONE | Returns `ack` + `data=0` (prevents hang) |

**Unmapped address safety:** Any access to an unrecognized page returns `ack` with zero data. No bus error — the master never hangs.

### 2.5 Per-Slave WB Ack Timing

| Slave | Ack Style | Cycles |
|-------|-----------|--------|
| `wb_io_bus` WHO_AM_I | Registered pulse (`whoami_ack`) | 1 |
| `wb_io_bus` NONE (unmapped) | Registered pulse (`none_ack`) | 1 |
| `wb_dshot_controller` | `!wb_ack_o` guard → 1-cycle ack | 1 |
| `wb_serial_dshot_mux` | `!wb_ack_o` guard → 1-cycle ack | 1 |
| `wb_esc_uart` | `!wb_ack_o` guard → 1-cycle ack | 1 |
| `wb_neoPx` | `!wb_ack_o` guard → 1-cycle ack | 1 |
| `pwmdecoder_wb` | `!wb_ack_o` guard → 1-cycle ack | 1 |
| `wb_led_controller` | `!wb_ack_o` guard → 1-cycle ack | 1 |

All slaves respond in **1 clock cycle**. No wait states in current design.

---

## 3. Datapaths

### 2.6 Control Plane (CH 0x01) — READ/WRITE registers

```
USB/SPI byte → ingress mux → fcsp_parser → fcsp_crc_gate → fcsp_router
  → [CH 0x01] → fcsp_rx_fifo → fcsp_wishbone_master → int_wb_* bus
  → wb_io_bus → peripheral slave → WB response
  → fcsp_wishbone_master response stream
  → fcsp_tx_fifo (CTRL) → fcsp_tx_arbiter → fcsp_tx_framer → USB TX
```

**Status: FUNCTIONAL.** 68 cocotb tests pass. E2E verified in sim.

### 2.7 ESC Passthrough (CH 0x05) — BLHeli serial bridge

```
HOST → FCSP frame CH 0x05 → fcsp_parser → fcsp_crc_gate → fcsp_router
  → [CH 0x05] m_esc_* AXIS output
  → fcsp_io_engines s_esc_tx_* → wb_esc_uart TX → mux → motor pad (half-duplex)
  → motor pad RX → mux → wb_esc_uart RX
  → m_esc_rx_* → fcsp_stream_packetizer → fcsp_tx_arbiter (ESC input) → fcsp_tx_framer → USB TX
```

**Status: WIRED.** Router CH 0x05 output flows through `fcsp_io_engines` AXIS stream ports to `wb_esc_uart` TX. ESC UART RX bytes are collected by `fcsp_stream_packetizer` and fed into the TX arbiter ESC input for host delivery. Verified in cocotb simulation.

### 2.3 SPI TX Egress

```
fcsp_tx_framer → tx_wire_* → USB TX byte stream
                            ↘ (future) → fcsp_spi_frontend TX → SPI MISO
```

**Status: USB-ONLY.** `tx_wire_tready` is wired directly to `i_usb_tx_ready`. SPI TX egress path exists in hardware (`fcsp_spi_frontend` has full TX support) but `spi_tx_valid = 1'b0`; the framer output is not routed to SPI MISO.

**Channel-aware routing stub:** `fcsp_offloader_top` latches `tx_arb_channel` into `tx_frame_channel_latched` when the framer accepts a new frame. The signal `tx_route_spi_control` is derived (`== CH_CONTROL`) but currently unused. When SPI egress is enabled, this will gate whether a given frame exits via USB or SPI MISO.

### 2.4 Channels 0x02, 0x03 (Telemetry, FC_Log)

**Status: TIED OFF.** Router outputs exist but `m_tel_tready` and `m_log_tready` are hardwired to `1'b1` — data accepted and dropped. These channels are reserved for future flight-controller telemetry and logging.

---

## 3. TX Egress Fabric — Arbitration, Queuing, and Framing

The TX egress fabric is the return path that carries response and telemetry data from the FPGA back to the host. Three independent producers compete for a single serialized output link.

### 3.1 Architecture Overview

```
                    ┌─────────────────┐
 WB Master ───────► │  u_ctrl_tx_fifo │ ──┐
 (CTRL response)    │  fcsp_tx_fifo   │   │  ┌───────────────────┐    ┌──────────────────┐
                    │  depth=512      │   ├─►│  u_tx_arbiter     │───►│  u_ctrl_tx_framer│──► USB TX
                    └─────────────────┘   │  │  fcsp_tx_arbiter  │    │  fcsp_tx_framer  │    (wire bytes)
                    ┌─────────────────┐   │  │                   │    └──────────────────┘
 ESC UART RX ─────► │  u_esc_pkt      │ ──┤  │  3-input priority │
 (raw bytes)        │  fcsp_stream_   │   │  │  CTRL > ESC > DBG │
                    │  packetizer     │   │  │  frame-atomic     │
                    │  MAX_LEN=16     │   │  └───────────────────┘
                    └─────────────────┘   │
                    ┌─────────────────┐   │
 Debug Generator ──►│  u_dbg_tx_fifo  │ ──┘
 (external port)    │  fcsp_tx_fifo   │
                    │  depth=512      │
                    └─────────────────┘
```

### 3.2 Per-Producer Queuing

Each producer has its own buffering strategy before reaching the arbiter:

#### CTRL Path (CH 0x01 responses)

| Stage | Module | Depth | Description |
|-------|--------|-------|-------------|
| Produce | `fcsp_wishbone_master` | — | Generates response AXIS stream (`m_rsp_*`) after each WB transaction |
| Buffer | `u_ctrl_tx_fifo` (`fcsp_tx_fifo`) | 512 entries | Circular FIFO with per-entry metadata (channel, flags, seq, payload_len). FWFT read semantics. |

Metadata is stamped at FIFO ingress: `channel=0x01`, `flags=0x02` (ACK_RESPONSE), `seq=ctrl_pending_seq` (echoes the request sequence number). The `payload_len` sideband is forwarded from the write side but currently set to `0x0000` (the framer counts payload bytes from `tlast`).

#### ESC Path (CH 0x05 responses)

| Stage | Module | Depth | Description |
|-------|--------|-------|-------------|
| Produce | `wb_esc_uart` RX → `fcsp_io_engines` | — | Raw UART RX bytes as they arrive from the ESC |
| Packetize | `u_esc_packetizer` (`fcsp_stream_packetizer`) | 16-byte buffer | Collects raw bytes until `MAX_LEN=16` or `TIMEOUT=1000` cycles (~18 µs) with no new bytes, then emits a framed AXIS payload with `tlast` |

The packetizer has no separate FIFO output — its AXIS output connects directly to the arbiter's ESC input. Metadata is hardwired at the arbiter port: `channel=0x05`, `flags=0x00`, `seq=0x0000`. The ESC path intentionally does not echo request sequence numbers since ESC serial data is asynchronous to any FCSP request.

#### Debug Path (CH 0x04 trace)

| Stage | Module | Depth | Description |
|-------|--------|-------|-------------|
| Produce | `fcsp_debug_generator` (external) | — | 5-byte AXIS frames on signal change |
| Buffer | `u_dbg_tx_fifo` (`fcsp_tx_fifo`) | 512 entries | Same FIFO design as CTRL path. Metadata (channel, flags, seq) provided by the external producer. |

The debug producer is external to `fcsp_offloader_top` — it connects via the `s_dbg_tx_*` port group. This allows the board wrapper (`fcsp_tangnano9k_top`) to instantiate the debug generator and control what probes are monitored.

### 3.3 TX FIFO Design (`fcsp_tx_fifo`)

The TX FIFO is a synchronous circular buffer that stores payload bytes alongside per-byte metadata sidebands.

**Storage arrays (per entry):**

| Array | Width | Purpose |
|-------|-------|---------|
| `mem_data` | 8 bits | Payload byte |
| `mem_last` | 1 bit | `tlast` marker |
| `mem_channel` | 8 bits | FCSP channel ID |
| `mem_flags` | 8 bits | FCSP flags |
| `mem_seq` | 16 bits | FCSP sequence number |
| `mem_payload_len` | 16 bits | Payload length (sideband) |

**Pointer logic:** `wr_ptr` and `rd_ptr` are `$clog2(DEPTH)`-bit circular pointers. A `count` register (one bit wider) tracks occupancy. `full = (count == DEPTH)`, `empty = (count == 0)`.

**Backpressure:** `s_tready = ~full`. If the FIFO is full, the producer is stalled. An `o_overflow` pulse fires whenever `s_tvalid && ~s_tready` — data is offered but cannot be accepted.

**Frame visibility:** `o_frame_seen` pulses when a pop transfers a byte with `m_tlast = 1`, indicating a complete frame has exited the FIFO.

### 3.4 TX Arbiter (`fcsp_tx_arbiter`) — Priority and Frame Atomicity

The arbiter is a **fixed-priority, frame-atomic multiplexer** with three inputs.

#### Priority Order

| Priority | Input | Typical Source |
|----------|-------|----------------|
| 1 (highest) | `s_ctrl_*` | CTRL response FIFO |
| 2 | `s_esc_*` | ESC packetizer |
| 3 (lowest) | `s_dbg_*` | Debug trace FIFO |

#### State Machine

```
       ┌──────────────────────────────────────────┐
       │                SEL_NONE                   │
       │  (idle — evaluates priority each cycle)   │
       └───┬──────────┬──────────┬────────────────┘
           │          │          │
    ctrl_tvalid  esc_tvalid  dbg_tvalid
           │          │          │
           ▼          ▼          ▼
       SEL_CTRL   SEL_ESC    SEL_DBG
       (locked)   (locked)   (locked)
           │          │          │
     on tlast    on tlast    on tlast
     handshake   handshake   handshake
           │          │          │
           └──────────┴──────────┘
                      │
                      ▼
                  SEL_NONE
```

**Grant logic (combinational):**
- While `sel == SEL_NONE`: checks `s_ctrl_tvalid` first, then `s_esc_tvalid`, then `s_dbg_tvalid`. First valid input wins.
- Once a grant is issued (sel transitions to a non-NONE state), the grant is **locked** — the selected input's AXIS signals are wired through to the output and all other inputs are stalled (`tready = 0`).
- The grant releases back to `SEL_NONE` only when the current frame completes: `tvalid && tready && tlast` all asserted in the same cycle.

**Frame atomicity guarantee:** Because the grant is held until `tlast`, a frame from one producer is never interleaved with bytes from another. The downstream framer always receives a complete, contiguous payload.

**No round-robin or fairness:** This is intentional. CTRL responses are latency-critical (the host is blocking on them). ESC serial has real-time baud constraints. Debug trace is best-effort. In practice, CTRL and ESC frames are short (< 16 bytes) and transmit in microseconds, so starvation of lower-priority producers is rare.

**Metadata passthrough:** The arbiter forwards channel/flags/seq from the selected input to the output. The framer uses these to construct the FCSP wire header.

### 3.5 TX Framer (`fcsp_tx_framer`) — Payload to Wire Format

The framer converts one AXIS payload frame (plus metadata) into a complete FCSP wire-format frame.

#### Capture Phase (`S_CAPTURE`)

The framer accepts payload bytes via the AXIS slave port, storing them into `payload_mem[]` (up to `MAX_PAYLOAD_LEN = 512` bytes). When `s_tlast` arrives, the captured frame transitions to the emit phase. If the payload exceeds `MAX_PAYLOAD_LEN`, the frame is dropped and `o_overflow` pulses.

Metadata (`channel`, `flags`, `seq`) is latched on the first byte of each frame.

#### Emit Phase (11-state FSM)

```
S_EMIT_SYNC → S_EMIT_VER → S_EMIT_FLAGS → S_EMIT_CHAN →
S_EMIT_SEQ_H → S_EMIT_SEQ_L → S_EMIT_LEN_H → S_EMIT_LEN_L →
S_EMIT_PAYLD (repeats per byte) → S_EMIT_CRC_H → S_EMIT_CRC_L → S_CAPTURE
```

| State | Byte emitted | CRC updated? |
|-------|-------------|--------------|
| `S_EMIT_SYNC` | `0xA5` | No (CRC reset to 0) |
| `S_EMIT_VER` | `0x01` | Yes |
| `S_EMIT_FLAGS` | `frame_flags` | Yes |
| `S_EMIT_CHAN` | `frame_channel` | Yes |
| `S_EMIT_SEQ_H` | `frame_seq[15:8]` | Yes |
| `S_EMIT_SEQ_L` | `frame_seq[7:0]` | Yes |
| `S_EMIT_LEN_H` | `payload_count[15:8]` | Yes |
| `S_EMIT_LEN_L` | `payload_count[7:0]` | Yes |
| `S_EMIT_PAYLD` | `payload_mem[i]` | Yes |
| `S_EMIT_CRC_H` | `crc_reg[15:8]` | No |
| `S_EMIT_CRC_L` | `crc_reg[7:0]` | No |

CRC is computed incrementally using `fcsp_crc16_core_xmodem` (CRC16/XMODEM polynomial). The CRC covers `version` through the last payload byte.

#### Backpressure

During capture, `s_tready = 1` (arbiter can push bytes). During emit, `s_tready = 0` (arbiter is stalled). This means only one frame can be in-flight in the framer at a time. The arbiter naturally holds its grant during this period since `tlast` has already been consumed.

### 3.6 End-to-End TX Latency

For a typical CTRL READ_BLOCK response (7 payload bytes):

| Stage | Cycles | Notes |
|-------|--------|-------|
| WB master generates response | ~10 | op + addr + data serialization |
| CTRL TX FIFO transit | 1–2 | FWFT, near-zero if empty |
| Arbiter grant | 1 | CTRL always wins when idle |
| Framer capture | 7 | 1 cycle per payload byte |
| Framer emit | 17 | 8 header + 7 payload + 2 CRC |
| USB UART serialize | ~170 | 17 bytes × 10 bits/byte @ 1 Mbaud |
| **Total** | ~200 | ~3.7 µs @ 54 MHz sys_clk |

---

## 4. Complete Address Map

| Absolute Address | Page | Peripheral | RTL Module |
|-----------------|------|------------|------------|
| `0x40000000` | `0x00` | WHO_AM_I (read-only, returns `0xFC500002`) | `wb_io_bus` |
| `0x40000100` | `0x01` | PWM Decoder (6-channel) | `pwmdecoder_wb` |
| `0x40000300` | `0x03` | DShot Controller (4-channel) | `wb_dshot_controller` |
| `0x40000400` | `0x04` | Serial/DShot Pin Mux | `wb_serial_dshot_mux` |
| `0x40000600` | `0x06` | NeoPixel Controller | `wb_neoPx` |
| `0x40000900` | `0x09` | ESC UART | `wb_esc_uart` |
| `0x40000C00` | `0x0C` | LED Controller | `wb_led_controller` |

**Bus decode logic:** `wb_io_bus` matches `wbm_adr_i[15:8]` to select the slave. Address bits forwarded to each slave vary per peripheral.

---

## 5. Register Maps (per peripheral)

### 5.1 WHO_AM_I (`0x40000000`)

| Offset | Name | R/W | Value |
|--------|------|-----|-------|
| `0x00` | ID | R | `0xFC500002` |

### 5.2 PWM Decoder (`0x40000100`)

| Offset | Name | R/W | Description |
|--------|------|-----|-------------|
| `0x00` | CH0_WIDTH | R | Pulse width (clocks) for PWM channel 0 |
| `0x04` | CH1_WIDTH | R | Channel 1 |
| `0x08` | CH2_WIDTH | R | Channel 2 |
| `0x0C` | CH3_WIDTH | R | Channel 3 |
| `0x10` | CH4_WIDTH | R | Channel 4 |
| `0x14` | CH5_WIDTH | R | Channel 5 |

### 5.3 DShot Controller (`0x40000300`)

| Offset | Name | R/W | Description |
|--------|------|-----|-------------|
| `0x00` | MOTOR1_RAW | W | 16-bit DShot word (throttle + telem + CRC) |
| `0x04` | MOTOR2_RAW | W | Motor 2 |
| `0x08` | MOTOR3_RAW | W | Motor 3 |
| `0x0C` | MOTOR4_RAW | W | Motor 4 |
| `0x10` | CONFIG | RW | `[1:0]` = DShot mode (150/300/600) |
| `0x14` | STATUS | R | `[3:0]` = per-motor ready bits |

> **Note:** Smart throttle registers (`0x40`–`0x4C`) are defined in Python `hwlib/registers.py` but not yet implemented in RTL. See section 12.3 for implementation plan. Only raw 16-bit word writes exist currently.

### 5.4 Serial/DShot Pin Mux (`0x40000400`)

Single register at offset `0x00`:

| Bit | Name | Default | Description |
|-----|------|---------|-------------|
| `[0]` | `mux_sel` | `1` (DShot) | 0 = Serial/passthrough, 1 = DShot |
| `[2:1]` | `mux_ch` | `0` | Motor channel select (0–3) |
| `[3]` | `msp_mode` | `0` | 0 = passthrough, 1 = MSP FC protocol |
| `[4]` | `force_low` | `0` | Drive selected motor pin LOW (ESC bootloader break) |

### 5.5 NeoPixel (`0x40000600`)

| Offset | Name | R/W | Description |
|--------|------|-----|-------------|
| `0x00`–`0x1C` | PIX0–PIX7 | RW | 24-bit GRB color per pixel (8 pixels) |
| `0x20` | TRIGGER | W | Any write starts transmission |

### 5.6 ESC UART (`0x40000900`)

| Offset | Name | R/W | Description |
|--------|------|-----|-------------|
| `0x00` | TX_DATA | W | Write byte to transmit (only accepted when `tx_ready`) |
| `0x04` | STATUS | R | `[0]` tx_ready, `[1]` rx_valid, `[2]` tx_active |
| `0x08` | RX_DATA | R | Read received byte (clears `rx_valid` on read) |
| `0x0C` | BAUD_DIV | RW | 16-bit clocks-per-bit divider (default = CLK_FREQ_HZ / 19200) |

**Half-duplex behavior:** TX drives line, sets `tx_active`. RX FSM is gated — forced to IDLE while `tx_active` is high. Guard period (1 bit-time) after stop bit before releasing line.

### 5.7 LED Controller (`0x40000C00`)

| Offset | Name | R/W | Description |
|--------|------|-----|-------------|
| `0x00` | LED_SET | W | OR bits into LED output register |
| `0x04` | LED_CLEAR | W | AND-NOT bits from LED output register |
| `0x08` | LED_TOGGLE | W | XOR bits with LED output register |
| `0x0C` | LED_READ | R | Current LED output state |

---

## 6. BLHeli ESC Passthrough — Full Sequence

The complete sequence for entering ESC bootloader mode from the host:

### Step 1: Steer mux to target motor (CONTROL CH 0x01)

```
WRITE_BLOCK 0x40000400 ← 0x00000004   # serial mode, channel 2, no force
```

Bit decode: `mux_sel=0`, `mux_ch=2`, `msp_mode=0`, `force_low=0`.

### Step 2: Assert break — force pin LOW (CONTROL CH 0x01)

```
WRITE_BLOCK 0x40000400 ← 0x00000014   # serial mode, channel 2, force_low=1
```

The selected motor pin is driven LOW. All other motor pins are tri-stated.

**Hold for ≥20 ms** (Python-side `time.sleep(0.020)`). The ESC interprets this as a UART break condition and enters its bootloader.

### Step 3: Release break (CONTROL CH 0x01)

```
WRITE_BLOCK 0x40000400 ← 0x00000004   # serial mode, channel 2, force_low=0
```

Pin returns to serial idle (HIGH via `tx_out` idle state). The ESC bootloader is now listening.

### Step 4: Set baud rate (CONTROL CH 0x01)

```
WRITE_BLOCK 0x4000090C ← 0x00000AEC   # 54_000_000 / 19200 = 2812 (0xAEC)
```

Default is already 19200, so this step is optional unless changed.

### Step 5: Send/receive ESC serial data (ESC_SERIAL CH 0x05)

Host sends BLHeli 4-way protocol or MSP frames wrapped in FCSP CH 0x05 frames. The hardware extracts payload bytes and feeds them to `wb_esc_uart` TX via the `fcsp_io_engines` stream path. Responses from the ESC arrive on the motor pin RX path, are collected by `fcsp_stream_packetizer`, and sent back to the host as FCSP CH 0x05 response frames.

### Step 6: Restore DShot mode (CONTROL CH 0x01)

```
WRITE_BLOCK 0x40000400 ← 0x00000001   # DShot mode
```

### Auto-passthrough (MSP sniffer)

The `wb_serial_dshot_mux` MSP sniffer watches the PC USB-UART RX stream for `$M<` headers followed by size bytes `0xF5` or `0x64`. On match, it automatically overrides `mux_sel` to serial mode. A 5-second watchdog reverts to DShot if no further activity.

> **See also:** [BLHELI_PASSTHROUGH.md](BLHELI_PASSTHROUGH.md), [BLHELI_QUICKSTART.md](BLHELI_QUICKSTART.md)

---

## 7. FCSP Protocol Summary

The Flight Controller Serial Protocol (FCSP/1) provides a unified, reliable communication link across SPI and USB ingress transports. The protocol uses a sync-byte-delimited frame format with CRC16/XMODEM integrity checking and channel-based routing.

| Channel | Name | Status |
|---------|------|--------|
| `0x01` | CONTROL | **Working** — WB master register R/W |
| `0x02` | TELEMETRY | Tied off (reserved) |
| `0x03` | FC_LOG | Tied off (reserved) |
| `0x04` | DEBUG_TRACE | **Working** — change-detect probe generator |
| `0x05` | ESC_SERIAL | **Wired** — UART TX/RX + packetizer |
| `0x07` | ILA_TRACE | Not instantiated (module exists) |

> **Canonical specification:** [FCSP_PROTOCOL.md](FCSP_PROTOCOL.md) — frame format, field encoding, CONTROL payload ops, memory map, and MSP-over-FCSP theory.
> **Transport profile:** [FCSP_SPI_TRANSPORT.md](FCSP_SPI_TRANSPORT.md) — SPI byte-stream model, TX batching, pad bytes, error counters.

---

## 8. DShot Protocol — Wire Format, Telemetry, and ESC Bootloader Entry

> **Reference:** [BLUEJAY_ESC_ANALYSIS.md](BLUEJAY_ESC_ANALYSIS.md) provides the full ESC-side source code walkthrough. This section documents the wire-level protocol from the FPGA's perspective.

### 8.1 DShot Frame Format (FPGA → ESC)

Each DShot frame is 16 bits, sent MSB-first as modulated pulse widths on a single wire:

```
┌────────────────────────┬───┬──────────┐
│    Throttle (11 bit)   │ T │ CRC (4)  │
│    bits [15:5]         │[4]│ [3:0]    │
└────────────────────────┴───┴──────────┘
```

| Field | Bits | Range | Description |
|-------|------|-------|-------------|
| Throttle | `[15:5]` | 0–2047 | 0 = disarmed. 1–47 = DShot commands (requires T=1). 48–2047 = throttle. |
| Telemetry request | `[4]` | 0–1 | 1 = request ESC to send telemetry on next cycle |
| CRC | `[3:0]` | 0–15 | `(value ^ (value >> 4) ^ (value >> 8)) & 0x0F` |

### 8.2 Bit-Level Timing

Each bit is a fixed-period pulse. A `1` has a long HIGH time; a `0` has a short HIGH time:

```
         ┌──────────┐                ┌──────────────────┐
Bit=1:   │   T1H    │     T1L       │                  │
    ─────┘          └────────────────┘                  └──

         ┌────┐                      ┌──────────────────┐
Bit=0:   │T0H │       T0L           │                  │
    ─────┘    └──────────────────────┘                  └──
```

| Speed | T1H (1-high) | T0H (0-high) | Bit period | 16-bit frame | Max frame rate |
|-------|-------------|-------------|------------|-------------|---------------|
| DShot150 | 5.00 µs | 2.50 µs | 6.67 µs | 106.7 µs | 9.4 kHz |
| DShot300 | 2.50 µs | 1.25 µs | 3.33 µs | 53.3 µs | 18.8 kHz |
| DShot600 | 1.25 µs | 0.625 µs | 1.67 µs | 26.7 µs | 37.5 kHz |

**ESC decision rule:** The ESC samples the HIGH time of each pulse. If HIGH > 3/4 of the bit period → bit is `1`, else `0`.

**Guard time:** After the 16th bit, the line stays LOW for an inter-frame gap before the next frame. Bluejay uses 250 µs (DShot150), 125 µs (DShot300), or 62.5 µs (DShot600).

### 8.3 Our RTL Implementation (`dshot_out.sv`)

The `dshot_out` module generates the pulse waveform. It is a **transmit-only** block — it drives the motor pad but does not read it.

**FSM:** `ST_IDLE → ST_INIT → ST_HIGH → ST_LOW → (repeat for 16 bits) → ST_IDLE`

1. **ST_IDLE:** Waits for `i_write` strobe. Counts down `guard_count` (inter-frame gap). When guard expires and write arrives, latches the 16-bit `i_dshot_value` and transitions to ST_INIT.
2. **ST_INIT:** Inspects MSB of `dshot_command`. Loads `counter_high/counter_low` with T1H/T1L or T0H/T0L timing values (with ±7-clock guard band compensation).
3. **ST_HIGH:** Drives `o_pwm = 1`. Counts down `counter_high`. On zero → ST_LOW.
4. **ST_LOW:** Drives `o_pwm = 0`. Counts down `counter_low`. On zero, if bits remain, shifts `dshot_command` left and returns to ST_INIT. If all 16 bits sent → ST_IDLE.

**Timing constants** are computed at synthesis from `CLK_FREQ_HZ` using 64-bit intermediate math:

```systemverilog
// Example: DShot300 at 54 MHz
T0H_300 = (54_000_000 × 125) / 100_000_000 = 67 clocks  → 1.24 µs
T1H_300 = (54_000_000 × 25) / 10_000_000  = 135 clocks → 2.50 µs
```

**Controller:** `wb_dshot_controller` instantiates 4× `dshot_out`, one per motor. Writing a 16-bit word to `MOTOR1_RAW..MOTOR4_RAW` triggers a single-cycle strobe to the corresponding `dshot_out` instance. All four motors share a global `dshot_mode_reg` (set via CONFIG register at `0x14`).

### 8.4 Bidirectional DShot Telemetry (ESC → FC)

When the telemetry request bit is set AND the ESC supports bidirectional DShot, the ESC responds on the **same signal wire** approximately 30 µs after the DShot frame ends. The FC/FPGA must tri-state its output and listen.

#### 8.4.1 Physical Layer

The motor signal wire is normally driven by the FPGA. For bidirectional DShot:

1. FPGA sends the DShot frame (16 pulse-width-modulated bits)
2. FPGA tri-states the motor pin (releases to open-drain/input)
3. ESC drives the line LOW to send GCR-encoded telemetry (starting ~30 µs after frame end)
4. After telemetry completes, FPGA re-asserts drive for the next frame

The ESC uses **inverted signal** — line idles HIGH (via pull-up), ESC pulls LOW for data. This is the "inverted DShot" that Bluejay detects at startup.

#### 8.4.2 GCR Encoding

Telemetry data is 12 bits (eRPM or EDT) plus a 4-bit CRC, totaling 16 bits → 4 nibbles → 4 GCR codewords (5 bits each) = 20 GCR bits. Each nibble maps to a 5-bit GCR code via a fixed lookup table.

The GCR stream is transmitted as **transition durations** — the time between signal edges encodes 1, 2, or 3 consecutive same-bits. This is more efficient and noise-tolerant than raw-bit transmission.

| Duration | Encodes |
|----------|---------|
| Pulse_Time_1 (shortest) | Single bit boundary |
| Pulse_Time_2 (medium) | Two consecutive same-bits |
| Pulse_Time_3 (longest) | Three consecutive same-bits |

**Telemetry bitrate:** 5/4 × DShot rate (DShot300 → 375 kbps, DShot600 → 750 kbps).

> **Full GCR lookup table, CRC algorithm, and packet construction details:** [BLUEJAY_ESC_ANALYSIS.md](BLUEJAY_ESC_ANALYSIS.md) §7.5

#### 8.4.3 eRPM Data Format

The 12-bit telemetry value (`eeem mmmm mmmm`) encodes the electrical RPM:

```
eee  = exponent (3 bits, 0–7)
m... = mantissa  (9 bits)
cccc = CRC (same algorithm as DShot frame CRC)

Electrical RPM = mantissa << exponent
```

After normalization (setting bit 8 of mantissa), the exponent+bit[8] prefix distinguishes eRPM frames from EDT frames.

#### 8.4.4 Extended DShot Telemetry (EDT)

EDT reuses unused normalized eRPM prefix patterns to carry temperature, voltage, current, stress, and status data alongside eRPM. EDT is enabled by the FC sending DShot command 13 six consecutive times; the ESC acknowledges with a version frame. EDT frames are interleaved with eRPM on a ~1-second scheduler cycle.

> **Full EDT frame table, prefix discrimination rules, and Bluejay scheduler mapping:** [BLUEJAY_ESC_ANALYSIS.md](BLUEJAY_ESC_ANALYSIS.md) §7.6

### 8.5 Our Telemetry Implementation Status

**Current state: Transmit-only.** The FPGA has no DShot telemetry receive capability.

| Capability | Status | RTL Module |
|-----------|--------|-----------|
| DShot TX (pulse generation) | **Working** | `dshot_out` (4 instances) |
| DShot speed select (150/300/600) | **Working** | `wb_dshot_controller` CONFIG register |
| Raw 16-bit word transmit | **Working** | `wb_dshot_controller` MOTORx_RAW registers |
| Smart throttle (auto CRC) | **Not implemented** | See §11.3 |
| Pin tri-state for telemetry RX | **Not implemented** | `wb_serial_dshot_mux` has IOBUF but no timed tri-state |
| GCR pulse decode | **Not implemented** | No module exists |
| eRPM extraction | **Not implemented** | No module exists |
| EDT frame parsing | **Not implemented** | No module exists |
| Telemetry data registers | **Not implemented** | No telemetry registers in `wb_dshot_controller` |

**What would be needed for bidirectional DShot:**

1. **Timed tri-state controller:** After `dshot_out` finishes its 16th bit + guard time, tri-state the motor pad output for ~50 µs to receive the GCR telemetry response. Re-assert drive before the next DShot frame.

2. **GCR pulse-width decoder:** Measure time between signal edges on the motor pad input. Classify each interval as Pulse_Time_1/2/3. Reconstruct the 20-bit GCR stream.

3. **GCR→nibble decoder:** 5-to-4-bit lookup table (inverse of the GCR encoding table). Extract four nibbles (12-bit data + 4-bit checksum).

4. **eRPM / EDT demux:** Check the 4-bit prefix (exponent + bit[8]) to determine if the frame is eRPM or an EDT type. Extract the appropriate value.

5. **Telemetry registers:** Add per-motor eRPM and EDT data registers to `wb_dshot_controller` (or a new `wb_dshot_telemetry` module) readable via Wishbone.

### 8.6 ESC Bootloader Entry via Signal Wire

The ESC bootloader (BLHeli protocol) is entered by holding the signal wire LOW at power-on. In our design, the FPGA controls this via the `force_low` bit in the pin mux register.

#### 8.6.1 How Bluejay Detects Bootloader Entry

At power-on, before any DShot setup, Bluejay's `init_no_signal` code checks the signal wire level:

```
; If input signal is high for ~150ms, enter bootloader mode
input_high_check:
    jnb  RTX_BIT, bootloader_done   ; If LOW detected → skip bootloader
    djnz Temp3, input_high_check    ; Count down ~150ms
    djnz Temp2, input_high_check
    djnz Temp1, input_high_check

    call beep_enter_bootloader
    ljmp CSEG_BOOT_START             ; Jump to bootloader
```

**Key detail:** The signal must be **HIGH for ~150 ms** at power-on. This triggers because normal DShot signal includes LOW periods — a constant HIGH indicates a configurator is requesting bootloader mode.

However, in our design we use a different approach — we drive the signal **LOW** (break condition) because:
- The ESC is already powered and running
- We cannot control ESC power-on timing
- The break condition is the standard BLHeli passthrough method used by flight controllers

The break forces the ESC UART receiver to see a framing error (continuous LOW for >1 byte time), which BLHeli-compatible bootloaders interpret as a reset/entry request.

#### 8.6.2 Our Hardware Implementation

The `wb_serial_dshot_mux` module handles the pin-level control:

```
Register 0x40000400:
  bit[0]   mux_sel     = 0 (serial mode)
  bit[2:1] mux_ch      = target motor (0–3)  
  bit[3]   msp_mode    = 0
  bit[4]   force_low   = 1 → drives selected motor pin LOW
```

**Pin buffer logic:** In serial mode with `force_low=1`, the output driver for the selected motor channel is forced LOW. All other motor channels are tri-stated (safe — other ESCs not affected). When `force_low` is released, the pin returns to serial idle (HIGH).

**1-cycle blanking:** On any mode or channel change, a `global_tristate` pulse fires for one clock cycle, briefly tri-stating all pads. This prevents glitches during mux transitions.

#### 8.6.3 Full Bootloader Entry Sequence (Host Side)

```
1. WRITE 0x40000400 ← 0x00000004   # serial mode, ch2, force_low=0
2. WRITE 0x40000400 ← 0x00000014   # assert force_low → pin goes LOW
3. sleep(20ms)                       # hold break ≥20ms
4. WRITE 0x40000400 ← 0x00000004   # release force_low → pin idles HIGH
5. (ESC bootloader now listening on signal wire at 19200 baud)
6. Send BLHeli "BLHeli" handshake bytes via FCSP CH 0x05
7. ESC responds with boot info → received via CH 0x05 response frames
8. Flash read/write/erase commands via CH 0x05
9. WRITE 0x40000400 ← 0x00000001   # restore DShot mode when done
```

#### 8.6.4 BLHeli Bootloader Protocol (over Serial)

Once in bootloader mode, the ESC communicates at **19200 baud, 8N1** on the signal wire. The protocol is:

| Step | Direction | Content |
|------|-----------|---------|
| Handshake | FC → ESC | Send "BLHeli" string byte-by-byte |
| Ident response | ESC → FC | Boot message + chip signature + bootloader version |
| Set address | FC → ESC | Command `0xFF` + address (16-bit) + CRC16 |
| Set buffer | FC → ESC | Command `0xFE` + size + CRC16, then raw data bytes |
| Program flash | FC → ESC | Command `0x01` + CRC16 → writes buffer to flash at address |
| Erase flash | FC → ESC | Command `0x02` + CRC16 → erases page at address |
| Read flash | FC → ESC | Command `0x03` + count + CRC16 → ESC sends data + CRC |
| Run application | FC → ESC | Command `0x00` + `0x00` + CRC16 → ESC restarts firmware |

Each command returns a status byte: `0x30` = success, `0xC0`–`0xC5` = error codes.

CRC is CRC-16/IBM (polynomial `0xA001`), computed incrementally during bit-banged UART reception/transmission.

#### 8.6.5 Data Path Through Our Hardware

```
Host PC                                         ESC
   │                                              │
   │  FCSP frame (CH 0x05, payload = BLHeli bytes) │
   ├──────────────────────────────────────────────→│
   │        │                                      │
   │  fcsp_parser → fcsp_crc_gate → fcsp_router    │
   │        │                                      │
   │  fcsp_io_engines (s_esc_tx_* stream)          │
   │        │                                      │
   │  wb_esc_uart TX FSM (19200 baud serial)       │
   │        │                                      │
   │  wb_serial_dshot_mux (routes to motor pad)    │
   │        ├──────── motor pin ──────────────────→│ ESC bootloader
   │        │                                      │
   │        │←── ESC response (19200 baud serial)  │
   │        │                                      │
   │  wb_serial_dshot_mux (serial_rx_o)            │
   │        │                                      │
   │  wb_esc_uart RX FSM → m_esc_tdata stream      │
   │        │                                      │
   │  fcsp_stream_packetizer (collects bytes,      │
   │        timeout=1000 clks or max 16 bytes)     │
   │        │                                      │
   │  fcsp_tx_arbiter → fcsp_tx_framer             │
   │        │                                      │
   │  USB-UART TX → FCSP frame (CH 0x05)           │
   │←─────────────────────────────────────────────┤
   │                                              │
```

**Half-duplex management:** The `wb_esc_uart` RX FSM is gated by `tx_active` — it stays in IDLE while the TX FSM is sending. After the TX stop bit + 1-bit guard period, the RX FSM begins listening. This matches the ESC bootloader's half-duplex behavior (ESC only responds after receiving a complete command).

#### 8.6.6 MSP Auto-Passthrough (Sniffer)

The `wb_serial_dshot_mux` includes an MSP protocol sniffer that monitors the PC USB-UART RX stream, enabling automatic passthrough without explicit register writes:

**Detection FSM:**
```
S_IDLE → match '$' (0x24) → S_DOLLAR
S_DOLLAR → match 'M' (0x4D) → S_M
S_M → match '<' (0x3C) → S_ARROW
S_ARROW → any byte → S_SIZE
S_SIZE → if byte == 0xF5 or 0x64 → activate passthrough
```

`0xF5` is the BLHeli 4-way interface command, `0x64` is the MSP motor-related command. When matched, `auto_passthrough_active` overrides `mux_sel` to serial mode. A **5-second watchdog** (counting `CLK_FREQ_HZ × 5` cycles of no `pc_rx_valid` bytes) automatically reverts to DShot mode.

> **See also:** [BLHELI_PASSTHROUGH.md](BLHELI_PASSTHROUGH.md), [BLHELI_QUICKSTART.md](BLHELI_QUICKSTART.md), [BLUEJAY_ESC_ANALYSIS.md](BLUEJAY_ESC_ANALYSIS.md) §8

---

## 9. Physical Pins (Tang Nano 9K)

The Tang Nano 9K pin assignments are maintained in a single canonical document.

> **Canonical reference:** [HARDWARE_PINS.md](HARDWARE_PINS.md) — complete pin table, ESC wiring diagram, NeoPixel timing, LED status mapping, and clocking path.

**Quick reference (active signals):**

| Function | Pins | Direction |
|----------|------|-----------|
| SPI link (SCLK, CS, MOSI, MISO) | 25, 26, 27, 28 | I/O |
| USB-UART (RX, TX) | 18, 17 | I/O |
| Motor pads 1–4 | 51, 42, 41, 35 | Bidirectional (IOBUF) |
| NeoPixel data | 40 | O |
| Status LEDs 1–6 | 10, 11, 13, 14, 15, 16 | O |
| PWM inputs CH0–5 | 69, 68, 57, 56, 54, 53 | I |
| Clock (27 MHz → PLL → 54 MHz) | 52 | I |
| Reset (active low) | 4 | I |

---

## 10. Debug Trace Architecture

Two debug trace modules exist in the design, each targeting a different use case.

### 10.1 `fcsp_debug_generator` — Change-Detect Soft-ILA (CH 0x04)

**File:** `rtl/fcsp/fcsp_debug_generator.sv`

A lightweight probe capture block that emits a 5-byte AXIS frame whenever any monitored signal changes value, or when `i_sync_loss` fires.

**Probe snapshot (32 bits):**

| Bits | Signal | Description |
|------|--------|-------------|
| `[31:12]` | `20'h0` | Padding (reserved) |
| `[11:4]` | `i_router_chan` | Currently active FCSP channel |
| `[3]` | `i_wb_ack` | Wishbone ACK |
| `[2]` | `i_wb_cyc` | Wishbone bus cycle |
| `[1]` | `i_break_active` | ESC break signal state |
| `[0]` | `i_passthrough_enabled` | Passthrough mode active |

**Trigger:** `(probe_snapshot != last_snapshot) || i_sync_loss` — any change or parser sync loss fires a capture.

**Frame format (5 bytes, AXIS with `tlast` on byte 4):**

| Byte | Value | Description |
|------|-------|-------------|
| 0 | `0x01` | Event type (Snapshot) |
| 1 | `probe[7:0]` | Probe data byte 0 |
| 2 | `probe[15:8]` | Probe data byte 1 |
| 3 | `probe[23:16]` | Probe data byte 2 |
| 4 | `probe[31:24]` | Probe data byte 3 (+ `tlast`) |

**FSM:** `IDLE → HEADER → SEND_B0 → SEND_B1 → SEND_B2 → SEND_B3 → IDLE`

**Current status:** Module exists and is instantiated. Router CH 0x04 output is tied off (`m_dbg_tready = 1'b1`), so debug frames from the router ingress side are dropped. The generator's output connects through the external `s_dbg_tx_*` port of `fcsp_offloader_top` into the TX arbiter's debug input.

**Key property:** No RLE compression — every change generates a frame. Suitable for low-frequency hardware event monitoring.

### 10.2 `wb_ila` — Wishbone-Controlled Streaming RLE Trace (CH 0x07)

**File:** `rtl/fcsp/drivers/wb_ila.sv`

A full-featured logic analyzer with run-length encoding, software-controlled probe selection, and configurable sample rate via prescaler.

#### RLE Compression — How It Works

Traditional logic analyzers capture every sample cycle, which wastes bandwidth when signals are stable. The `wb_ila` uses **run-length encoding (RLE)** to compress consecutive identical samples into a single entry.

**RLE entry format (6 bytes):**

| Byte | Field | Description |
|------|-------|-------------|
| 0 | `repeat_hi` | Repeat count upper 8 bits |
| 1 | `repeat_lo` | Repeat count lower 8 bits |
| 2 | `data[31:24]` | Probe data byte 3 (MSB) |
| 3 | `data[23:16]` | Probe data byte 2 |
| 4 | `data[15:8]` | Probe data byte 1 |
| 5 | `data[7:0]` | Probe data byte 0 (LSB) |

- **`repeat_count`** (16-bit, big-endian): The number of consecutive (prescaled) sample cycles the **previous** probe value held before this new value appeared. Range: 0–65535.
- **`data`** (32-bit, big-endian): The **new** probe value that triggered the entry.

**Example decode:**

```
Bytes:  00 0A 00 00 00 05   →  repeat=10, data=0x00000005
Bytes:  01 F4 00 00 00 07   →  repeat=500, data=0x00000007
```

Interpretation: probe held value X for 10 sample cycles, then changed to `0x05`. Probe held `0x05` for 500 cycles, then changed to `0x07`.

**Trigger conditions:** An entry is emitted when:
1. **Change detected:** `probe_data != prev_probe` on a sample tick
2. **RLE overflow:** `rle_count == 0xFFFF` — counter saturated, must flush

**FIFO and framing:**
- Internal FIFO depth: `MAX_ENTRIES = 40` (configurable parameter)
- Frame size: 40 entries × 6 bytes = **240 bytes** per FCSP frame
- Frame emit triggers: FIFO full (40 entries) OR software flush request
- On emit, the full FIFO contents are serialized as an AXIS byte stream with `tlast` on the final byte

#### Wishbone Control Registers

| Offset | Name | R/W | Description |
|--------|------|-----|-------------|
| `0x00` | CTRL | RW | `[0]` ENABLE — start/stop sampling. `[1]` FLUSH — force emit current buffer (auto-clears). |
| `0x04` | PROBE_SEL | RW | `[3:0]` Probe group select: 0=WB bus, 1=Motor/DShot, 2=ESC UART, 3=Raw external |
| `0x08` | PRESCALE | RW | `[15:0]` Sample clock divider. 0=every cycle, N=sample every N+1 cycles. |
| `0x0C` | STATUS | R | `[15:0]` Frame count — total frames emitted since reset. |

**Prescaler:** At sys_clk = 54 MHz and PRESCALE = 53, the sample rate is 1 MHz. At PRESCALE = 0, every clock cycle is sampled (54 Msps).

**Emitter FSM:** `ST_IDLE → ST_BYTE0..ST_BYTE5` (repeats per entry) → `ST_IDLE`

**Current status:** Module exists but is **not instantiated** in `fcsp_offloader_top`. To enable, it needs:
1. Instantiation with Wishbone slave port connected to a new address page
2. `m_tdata/tvalid/tlast/tready` connected to a TX FIFO → arbiter path on CH 0x07
3. Probe mux feeding `probe_data` based on `probe_sel`

---

## 11. SPI Slave — Detailed Implementation

Two SPI slave implementations exist in the repo, each with different CDC robustness trade-offs.

### 11.1 `fcsp_spi_frontend` — Production SPI Slave

**File:** `rtl/fcsp/fcsp_spi_frontend.sv`

This is the SPI slave used in the production `fcsp_offloader_top` ingress path.

| Property | Value |
|----------|-------|
| SPI Mode | **Mode 0** (CPOL=0, CPHA=0) |
| Bit order | MSB-first |
| Data width | 8-bit byte-oriented |
| FPGA role | Slave (host/Pico is master) |
| Duplex | Full-duplex (MOSI + MISO simultaneous) |

#### CDC (Clock Domain Crossing) Pipeline

| Signal | Sync depth | Technique |
|--------|------------|-----------|
| `i_cs_n` | 3-FF | `cs_sync[2:0]` shift register |
| `i_sclk` | 3-FF | `sclk_sync[2:0]` shift register |
| `i_mosi` | 2-FF | `mosi_sync[1:0]` shift register |

**Edge detection:** Uses 2-bit pattern matching on the two deepest sync stages:
- Rising edge: `sclk_sync[2:1] == 2'b01`
- Falling edge: `sclk_sync[2:1] == 2'b10`

This requires **3 sys_clk cycles** from a physical SCLK edge to a detected edge inside the FPGA.

#### Maximum SCLK Calculation

The Nyquist constraint for reliable edge detection with a 3-FF synchronizer:

$$f_{SCLK,max} = \frac{f_{sys}}{2 \times N_{sync}} = \frac{54\text{ MHz}}{2 \times 3} = 9\text{ MHz (theoretical)}$$

In practice, the SCLK half-period must be long enough for the sync chain to settle and the edge detector to fire. Conservative rule:

$$f_{SCLK,max} = \frac{f_{sys}}{4} = \frac{54\text{ MHz}}{4} = \mathbf{13.5\text{ MHz}}$$

This ensures at least 2 sys_clk cycles per SCLK half-period, providing margin for metastability resolution.

#### Full-Duplex Byte Pipeline

1. **CS assert (`cs_fall`):** Primes `o_miso` with `tx_hold[7]` (MSB of queued TX byte)
2. **SCLK rising edges:** Sample `mosi_sync[1]` into `rx_shift`, MSB-first
3. **SCLK falling edges:** Shift `tx_shift` left, drive `o_miso` with next bit
4. **Byte boundary (bit_cnt == 7):** Complete RX byte pushed to `rx_byte_pending`
5. **TX hold register:** 1-byte deep. When core provides `i_tx_byte + i_tx_valid`, byte is queued. If no TX byte ready, MISO shifts zeros (pad bytes).
6. **CS deassert (`cs_rise`):** Resets bit counter and shift registers

### 11.2 `spi_slave` — Glitch-Filtered SPI Slave

**File:** `rtl/fcsp/drivers/spiSlave/spi_slave.sv`

A more robust SPI slave with deeper synchronization and glitch filtering. Used by `spi_slave_wb_bridge` for the Wishbone-over-SPI debug interface.

| Property | Value |
|----------|-------|
| SPI Mode | **Mode 0** (CPOL=0, CPHA=0) |
| CDC depth | SCLK: 4-FF, CS: 4-FF, MOSI: 3-FF |
| Glitch filter | Requires consistent signal for 2 consecutive cycles before and after transition |
| MISO drive | Tri-state on CS deassert (`1'bZ`) |
| TX interlock | `o_tx_ready` locks during active transfer |

#### Glitch Filter Detail

The 4-FF sync register is checked as a 4-bit pattern:

```
Rising edge:  sclk_sync[3:0] == 4'b0011  (2 cycles low, then 2 cycles high)
Falling edge: sclk_sync[3:0] == 4'b1100  (2 cycles high, then 2 cycles low)
```

This filters out noise spikes shorter than 2 sys_clk cycles. Any glitch that doesn't maintain a consistent level for 2 consecutive cycles is ignored.

#### Maximum SCLK Calculation (Glitch-Filtered)

The glitch filter requires 4 sys_clk cycles to detect a valid edge (2 cycles of old level + 2 cycles of new level). Each SCLK half-period must be at least 4 sys_clk cycles:

$$f_{SCLK,max} = \frac{f_{sys}}{2 \times 4} = \frac{54\text{ MHz}}{8} = \mathbf{6.75\text{ MHz}}$$

This is more conservative but provides guaranteed rejection of sub-2-cycle noise.

### 11.3 SPI Clock Rate Summary

| Implementation | CDC Depth | Glitch Filter | Max SCLK @ 54 MHz | Use Case |
|----------------|-----------|---------------|-------------------|----------|
| `fcsp_spi_frontend` | 3-FF | No | **13.5 MHz** (sys_clk/4) | Production ingress (high throughput) |
| `spi_slave` | 4-FF | Yes (2-cycle) | **6.75 MHz** (sys_clk/8) | Debug bridge (max robustness) |

**Recommendation:** For the Pico ↔ FPGA SPI link, use 10 MHz or below with `fcsp_spi_frontend`. This provides comfortable margin and is well within the Pico's SPI master capabilities.

---

## 12. Implementation Status

All core RTL datapaths are implemented and verified. The table below tracks remaining work items.

### 12.1 Resolved Items

| # | Item | Resolution |
|---|------|------------|
| G1 | CH_ESC_SERIAL (0x05) not wired | Full TX/RX path wired through `fcsp_io_engines`. Router → ESC UART → packetizer → arbiter. Verified in cocotb. |
| G2 | `rtl/io/wb_esc_uart.sv` has no AXIS stream ports | Stream ports (`s_esc_tdata/tvalid/tready`, `m_esc_tdata/tvalid/tready`) added. Wired through `fcsp_io_engines`. |
| G3 | `fcsp_stream_packetizer` not instantiated | Instantiated as `u_esc_packetizer` in `fcsp_offloader_top` with `MAX_LEN=16`, `TIMEOUT=1000`. |

### 12.2 SPI TX Egress (Not Wired)

**Current state:** The framer output (`tx_wire_*`) is wired exclusively to USB-UART TX. SPI MISO only sends pad bytes (`0x00`).

**What exists:** `fcsp_spi_frontend` has full TX support — `i_tx_byte`, `i_tx_valid`, `o_tx_ready` ports are operational. A channel-latch (`tx_frame_channel_latched`) and routing flag (`tx_route_spi_control`) are in place.

**Implementation plan:**
1. Add a transport-select mux after the framer: if `tx_route_spi_control`, route `tx_wire_*` to `fcsp_spi_frontend` TX, else to USB-UART TX
2. Both paths can share the framer — only one frame is in-flight at a time
3. Host must keep clocking SPI to drain MISO bytes; if framer stalls waiting for SPI tready, USB responses queue in the TX FIFOs

**Estimated complexity:** ~20 lines of mux logic in `fcsp_offloader_top`.

### 12.3 DShot Smart Throttle Registers

**Current state:** `wb_dshot_controller` only accepts raw 16-bit DShot words at offsets `0x00`–`0x0C`. Python `hwlib/registers.py` defines smart throttle registers at `0x40`–`0x4C` that would accept a 0–2047 throttle value and auto-compute the DShot CRC.

**Implementation plan:**
1. Add a secondary register bank (`0x40`–`0x4C`) in `wb_dshot_controller`
2. On write: extract throttle[10:0] and telemetry bit, compute CRC using the DShot CRC algorithm (XOR of nibbles), form the 16-bit word, and store it in the raw register
3. Write to smart register triggers automatic motor update (same as raw write)

**Estimated complexity:** ~40 lines of RTL per motor channel.

### 12.4 Channels 0x02 / 0x03 (Telemetry, FC_Log)

**Current state:** Router outputs exist but `m_tel_tready` and `m_log_tready` are hardwired to `1'b1` — data is accepted and dropped.

**Design intent:** These channels are reserved for future use when a flight controller CPU (SERV or external MCU) generates telemetry or logging data. The ingress (host → FPGA) direction is wired and will route correctly. The egress (FPGA → host) direction would need a TX FIFO and arbiter input per channel.

**No implementation planned** for the current milestone. The tie-off is safe — no data loss or hang occurs.

### 12.5 Debug Trace Channel Egress (CH 0x04)

**Current state:** `fcsp_debug_generator` exists and produces 5-byte AXIS frames. Its output connects through the external `s_dbg_tx_*` port into the TX arbiter's debug input via `u_dbg_tx_fifo`. The arbiter routes these as the lowest-priority stream. **This path is fully functional.**

The router's CH 0x04 *ingress* output (`m_dbg_tready = 1'b1`) is tied off — this is intentional. CH 0x04 ingress from the host has no defined purpose; only the egress direction (FPGA → host) carries debug trace.

### 12.6 `wb_ila` RLE Trace (CH 0x07)

**Current state:** Module exists in `rtl/fcsp/drivers/wb_ila.sv` but is not instantiated in the production build.

**Implementation plan:**
1. Add a new Wishbone page (`0x0D` or similar) in `wb_io_bus` for ILA control registers
2. Instantiate `wb_ila` in `fcsp_io_engines` with WB slave port
3. Add a probe mux driven by `PROBE_SEL` register (group 0=WB bus, 1=motor, 2=ESC, 3=external)
4. Route `m_tdata/tvalid/tlast` to a TX FIFO or directly to a new arbiter input (4th priority)
5. Assign channel `0x07` for host-side frame identification

**Estimated complexity:** ~60 lines of instantiation + probe mux. Arbiter would need a 4th input or the ILA output could share the debug FIFO port.

### 12.7 ESC Traffic Generator (Test Infrastructure)

**Current state:** No automated ESC traffic generator exists for simulation. Current ESC tests rely on manually driven cocotb stimuli.

**What's needed:** A cocotb fixture or RTL stub that simulates an ESC responding with BLHeli 4-way protocol bytes, enabling full-loop E2E testing of: FCSP CH 0x05 → UART TX → loopback → UART RX → packetizer → CH 0x05 response.

---

## 13. Verification Specification

> **This section is normative.** Each block's test requirements are defined here
> first. Cocotb test implementations must satisfy these requirements. If code
> exists without a matching entry below, add one. If a requirement below has no
> test, the block is not verified.

### 13.1 `fcsp_parser` — Frame Parser

**DUT:** `fcsp_parser` | **Target:** `test-cocotb` | **Sim module:** `test_fcsp_parser_cocotb`

| ID | Requirement | Stimulus | Expected |
|----|------------|----------|----------|
| P-1 | Sync detect + frame complete | Drive `0xA5` + valid header + payload + CRC | `o_frame_done` asserts, payload bytes match on output AXIS |
| P-2 | Resync after noise | Random bytes then valid frame | Parser ignores noise, locks on `0xA5`, produces correct frame |
| P-3 | Reject oversized payload | Frame with `payload_len > 512` | `o_len_error` asserts, frame dropped, parser returns to sync hunt |
| P-4 | Backpressure tolerance | Valid frame with random `tready` deassertion | All payload bytes delivered in order, no data lost |

### 13.2 `fcsp_crc_gate` — CRC Validation

**DUT:** `fcsp_crc_gate` (tested in composition with parser) | **Target:** `test-top-cocotb`

| ID | Requirement | Stimulus | Expected |
|----|------------|----------|----------|
| CG-1 | Good CRC passes frame | Valid FCSP frame with correct CRC | Frame appears on output, metadata intact |
| CG-2 | Bad CRC drops frame | Frame with corrupted CRC byte | No output frame, no hang, parser restarts |

### 13.3 `fcsp_router` — Channel Demux

**DUT:** `fcsp_router` (tested in composition) | **Target:** `test-top-cocotb`

| ID | Requirement | Stimulus | Expected |
|----|------------|----------|----------|
| R-1 | CH 0x01 routes to CTRL | Frame with `channel=0x01` | `m_ctrl_tvalid` asserts, data correct |
| R-2 | CH 0x05 routes to ESC | Frame with `channel=0x05` | `m_esc_tvalid` asserts, data correct |
| R-3 | Unknown channel dropped | Frame with `channel=0xFF` | `o_route_drop` asserts, `s_frame_tready` stays high (data consumed) |
| R-4 | Back-to-back routing | Two frames on different channels | Each routed to correct output without interleaving |

### 13.4 `fcsp_rx_fifo` — Ingress Elastic Buffer

**DUT:** `fcsp_rx_fifo` (tested in composition) | **Target:** `test-top-cocotb`

| ID | Requirement | Stimulus | Expected |
|----|------------|----------|----------|
| RF-1 | Pass-through when empty | Single frame, consumer ready | Frame exits with 1–2 cycle latency |
| RF-2 | Buffering under backpressure | Frame arrival while consumer stalled | Frame stored, delivered when consumer resumes |
| RF-3 | Overflow indication | Write when FIFO full | `o_overflow` pulses, no hang |
| RF-4 | Metadata fidelity | Frame with specific channel/flags/seq | Metadata reproduced exactly on output |

### 13.5 `fcsp_wishbone_master` — CONTROL Command Processor

**DUT:** `fcsp_wishbone_master` | **Target:** `test-fcsp-wb-master-cocotb` | **Sim module:** `test_fcsp_wishbone_master_cocotb`

| ID | Requirement | Stimulus | Expected |
|----|------------|----------|----------|
| WM-1 | READ_BLOCK decode | Payload `[0x10, addr_4B]` | WB read cycle at given address, response = `[0x10, addr, 0x04, data]` |
| WM-2 | WRITE_BLOCK decode | Payload `[0x11, addr_4B, data_4B]` | WB write cycle, response = `[0x11, addr, status]` |
| WM-3 | Unknown op reject | Payload `[0xFF, ...]` | No WB cycle issued, error response or drop |
| WM-4 | Response metadata | Any valid op | Response AXIS carries channel/flags/seq from pending request |

### 13.6 `fcsp_tx_fifo` — Egress Elastic Buffer

**DUT:** `fcsp_tx_fifo` | **Target:** `test-tx-fifo-cocotb` | **Sim module:** `test_fcsp_tx_fifo_cocotb`

| ID | Requirement | Stimulus | Expected |
|----|------------|----------|----------|
| TF-1 | FWFT read | Push one byte, read immediately | `m_tvalid` asserts on next cycle |
| TF-2 | Full FIFO backpressure | Fill to capacity | `s_tready` deasserts, `o_overflow` pulses on next push attempt |
| TF-3 | Frame boundary tracking | Push frame with `tlast`, pop it | `o_frame_seen` pulses when `tlast` popped |
| TF-4 | Metadata passthrough | Push with specific channel/flags/seq | Same metadata on output side |

### 13.7 `fcsp_tx_arbiter` — Priority Mux

**DUT:** `fcsp_tx_arbiter` | **Target:** `test-tx-arbiter-cocotb` | **Sim module:** `test_fcsp_tx_arbiter_cocotb`

| ID | Requirement | Stimulus | Expected |
|----|------------|----------|----------|
| TA-1 | Strict priority | CTRL and DBG both assert `tvalid` | CTRL wins, DBG stalled until CTRL `tlast` |
| TA-2 | Frame atomicity | DBG frame in progress, CTRL arrives mid-frame | CTRL waits until DBG `tlast`, then wins next grant |
| TA-3 | ESC priority | ESC and DBG both valid, no CTRL | ESC wins |
| TA-4 | Re-selection | CTRL completes `tlast`, CTRL still valid | Arbiter returns to `SEL_NONE`, re-evaluates, selects CTRL again |
| TA-5 | Idle passthrough | Only one input active | Output mirrors input with zero additional latency |

### 13.8 `fcsp_tx_framer` — Wire Format Serializer

**DUT:** `fcsp_tx_framer` (tested in E2E composition) | **Target:** `test-top-cocotb`

| ID | Requirement | Stimulus | Expected |
|----|------------|----------|----------|
| FR-1 | Complete frame format | 7-byte payload + metadata | Output = `[A5, 01, flags, chan, seq_h, seq_l, len_h, len_l, payload..., crc_h, crc_l]` |
| FR-2 | CRC correctness | Known payload | CRC16/XMODEM matches independently computed value |
| FR-3 | Overflow protection | Payload > MAX_PAYLOAD_LEN | Frame dropped, `o_overflow` pulses |
| FR-4 | Backpressure during emit | Deassert `m_tready` mid-frame | Framer pauses, resumes correctly when `tready` reasserts |

### 13.9 `fcsp_stream_packetizer` — Byte-to-Frame Aggregator

**DUT:** `fcsp_stream_packetizer` (tested in E2E) | **Target:** `test-top-cocotb-experimental`

| ID | Requirement | Stimulus | Expected |
|----|------------|----------|----------|
| SP-1 | MAX_LEN trigger | Send exactly MAX_LEN bytes | Frame emitted with `tlast` on last byte |
| SP-2 | Timeout trigger | Send 3 bytes, wait > TIMEOUT cycles | Partial frame emitted (3 bytes + `tlast`) |
| SP-3 | Back-to-back fill | Two full frames without gap | Two separate frames emitted, no data loss |

### 13.10 `wb_io_bus` — Address Decoder

**DUT:** `wb_io_bus` | **Target:** `test-wb-io-bus-cocotb` | **Sim module:** `test_wb_io_bus_cocotb`

| ID | Requirement | Stimulus | Expected |
|----|------------|----------|----------|
| IO-1 | WHO_AM_I read | Read `0x40000000` | Returns `0xFC500002` |
| IO-2 | Page select for each slave | Read/write at each page address | Correct slave selected, `cyc`/`stb` asserted to that slave only |
| IO-3 | Unmapped page safety | Access page `0xFF` | Returns `ack` + `data=0`, no hang |
| IO-4 | All 7 slave ports | Exercise each page (0x00..0x0C) | Each slave sees exactly one transaction |

### 13.11 `wb_dshot_controller` + `dshot_out` — Motor Output

**DUT:** `dshot_out` | **Target:** `test-dshot-out-cocotb` | **Sim module:** `test_dshot_out_cocotb`

| ID | Requirement | Stimulus | Expected |
|----|------------|----------|----------|
| DS-1 | DShot150 timing | Write raw word, DShot150 mode | Pulse widths match DShot150 spec (±5%) |
| DS-2 | DShot300 timing | Write raw word, DShot300 mode | Pulse widths match DShot300 spec |
| DS-3 | DShot600 timing | Write raw word, DShot600 mode | Pulse widths match DShot600 spec |
| DS-4 | Ready indication | Write motor word | `STATUS[n]` ready bit clears during TX, reasserts after |

### 13.12 `wb_serial_dshot_mux` — Pin Mux

**DUT:** `wb_serial_dshot_mux` | **Target:** `test-serial-mux-cocotb` | **Sim module:** `test_wb_serial_dshot_mux_cocotb`

| ID | Requirement | Stimulus | Expected |
|----|------------|----------|----------|
| MX-1 | Reset default | Reset | `mux_sel=1` (DShot mode) |
| MX-2 | Manual mode switch | Write `mux_sel=0` | Readback confirms serial mode, target pin driven by UART |
| MX-3 | MSP sniffer trigger | Feed `$M<` + `0xF5` or `0x64` on `pc_rx` | Mux auto-switches to serial, `mux_sel` readback = 0 |
| MX-4 | Non-target pin isolation | Serial mode on channel 2 | Channels 0,1,3 still in DShot mode |
| MX-5 | Force-low break | Write `force_low=1` | Target motor pin driven LOW |
| MX-6 | Force-low release | Clear `force_low` | Pin returns to serial idle (HIGH) |
| MX-7 | Multi-message bypass | Multiple MSP messages in sequence | Mux stays in serial mode |
| MX-8 | Watchdog revert | Sniffer triggers, then no activity for 5s | Mux reverts to DShot mode |

### 13.13 `wb_esc_uart` — Half-Duplex UART

**DUT:** `wb_esc_uart` | **Target:** `test-wb-esc-uart-cocotb` | **Sim module:** `test_wb_esc_uart_cocotb`

| ID | Requirement | Stimulus | Expected |
|----|------------|----------|----------|
| EU-1 | TX ready | Reset | `STATUS[0]` = 1 (tx_ready) |
| EU-2 | Baud divisor | Write BAUD_DIV | Bit period matches `CLK_FREQ / baud_div` |
| EU-3 | TX start bit | Write TX_DATA | Start bit (LOW) appears on `tx_out` for one bit-time |
| EU-4 | TX active gating | During TX | `STATUS[2]` = 1 (`tx_active`), RX FSM forced to IDLE |
| EU-5 | TX completion | After stop bit | `tx_ready` reasserts, `tx_active` clears |
| EU-6 | RX byte receive | Drive serial byte on `rx_in` | `rx_valid` asserts, `RX_DATA` readback matches sent byte |
| EU-7 | RX half-duplex gate | TX active, drive RX simultaneously | RX data ignored (not captured) until TX completes |
| EU-8 | Stream TX port | AXIS `s_esc_tdata/tvalid` | Byte written to TX_DATA, ready handshake works |
| EU-9 | Stream RX port | Serial byte arrives on `rx_in` | AXIS `m_esc_tdata/tvalid` asserts with received byte |

### 13.14 `wb_neoPx` — NeoPixel Controller

**DUT:** `wb_neoPx` | **Target:** `test-wb-neopx-cocotb` | **Sim module:** `test_wb_neoPx_cocotb`

| ID | Requirement | Stimulus | Expected |
|----|------------|----------|----------|
| NP-1 | Pixel buffer write | Write GRB to PIX0 | Readback matches |
| NP-2 | Trigger transmission | Write to TRIGGER register | `o_neo_data` waveform starts |
| NP-3 | WS2812 timing | 8-pixel sequence | T0H, T1H, T0L, T1L within WS2812 spec thresholds |
| NP-4 | Reset period | After all pixels sent | Data line LOW for ≥ 50 µs |

### 13.15 `pwmdecoder` — PWM Measurement

**DUT:** `pwmdecoder` | **Target:** `test-pwmdecoder-cocotb` | **Sim module:** `test_pwmdecoder_cocotb`

| ID | Requirement | Stimulus | Expected |
|----|------------|----------|----------|
| PW-1 | Pulse width capture | 1 ms pulse on channel 0 | CH0_WIDTH register ≈ 1ms × CLK_FREQ clocks |
| PW-2 | Multi-channel | Different widths on CH0–CH5 | Each register matches its channel's pulse |
| PW-3 | Edge timing | Known period and duty cycle | Measurement accuracy within ±1 clock cycle |
| PW-4 | No-pulse default | No edges after reset | Width = 0 |

### 13.16 `wb_led_controller` — LED Register Block

**DUT:** `wb_led_controller` | **Target:** `test-wb-led-cocotb` | **Sim module:** `test_wb_led_controller_cocotb`

| ID | Requirement | Stimulus | Expected |
|----|------------|----------|----------|
| LD-1 | SET register | Write bits to LED_SET | Output OR'd with current state |
| LD-2 | CLEAR register | Write bits to LED_CLEAR | Output AND-NOT'd |
| LD-3 | TOGGLE register | Write bits to LED_TOGGLE | Output XOR'd |
| LD-4 | READ register | Read LED_READ | Returns current output state |
| LD-5 | Reset state | After reset | All LEDs off (0) |

### 13.17 `fcsp_spi_frontend` — SPI Slave

**DUT:** `fcsp_spi_frontend` (tested in composition via `fcsp_offloader_top`) | **Target:** `test-top-cocotb`

| ID | Requirement | Stimulus | Expected |
|----|------------|----------|----------|
| SF-1 | Byte reception | Drive 8 SCLK rising edges with MOSI pattern | `o_rx_byte` matches, `o_rx_valid` asserts |
| SF-2 | TX hold register | Queue byte via `i_tx_byte/i_tx_valid` | Next SPI transfer shifts queued byte on MISO |
| SF-3 | CS reset | Deassert CS mid-byte | Bit counter resets, no partial byte produced |
| SF-4 | Continuous transfer | Multiple bytes without CS deassert | Each byte correctly captured, no gap |

### 13.18 `fcsp_debug_generator` — Soft-ILA

**DUT:** `fcsp_debug_generator` (tested via external port in composition)

| ID | Requirement | Stimulus | Expected |
|----|------------|----------|----------|
| DG-1 | Change-detect trigger | Modify a probe input | 5-byte AXIS frame emitted with event type + snapshot |
| DG-2 | Sync loss trigger | Assert `i_sync_loss` | Frame emitted even if probes unchanged |
| DG-3 | No-change quiescence | Hold all probes stable | No frame emitted |

### 13.19 E2E Integration Tests

**DUT:** `fcsp_offloader_top` | **Target:** `test-e2e-fcsp-wb-io-cocotb` | **Sim module:** `test_e2e_fcsp_wb_io_cocotb`

| ID | Requirement | Stimulus | Expected |
|----|------------|----------|----------|
| E2E-1 | FCSP → WHO_AM_I | FCSP READ_BLOCK `0x40000000` via USB | Response contains `0xFC500002` |
| E2E-2 | FCSP → LED write | FCSP WRITE_BLOCK LED_SET via USB | LED output changes, response ACK received |
| E2E-3 | ESC CH 0x05 routing | FCSP frame `channel=0x05` | Payload reaches `wb_esc_uart` TX, serial byte appears on pad |
| E2E-4 | MSP sniffer bypass | `$M<` + `0xF5` on PC RX feed | Mux auto-switches, motor pin routes serial |
| E2E-5 | ESC serial loopback | CH 0x05 frame → UART TX → loopback → RX → packetizer | CH 0x05 response frame received by host |

### 13.20 CI Gate Strategy

| Gate | Makefile Target | What it proves | CI step |
|------|----------------|----------------|---------|
| FCSP smoke | `test-fcsp-smoke-cocotb` | Parser + TX arbiter core logic | `Run FCSP smoke cocotb gate` |
| Serial mux | `test-serial-mux-cocotb` | Pin mux modes, sniffer, watchdog | `Run serial mux cocotb gate` |
| Docs | `check_docs_consistency.sh` | Doc cross-references valid | `Docs consistency gate` |

**Full regression** (`test-all-strict`) covers all suites but is not in CI to keep gate time < 60s. Run locally before push.

---

## 14. Detail Document Index

| Document | Role | What it covers |
|----------|------|---------------|
| [FCSP_PROTOCOL.md](FCSP_PROTOCOL.md) | **Canonical spec** | Wire format, channel definitions, CONTROL op payloads, memory map |
| [FCSP_SPI_TRANSPORT.md](FCSP_SPI_TRANSPORT.md) | **Canonical spec** | SPI-as-byte-stream model, TX batching, pad bytes, error counters |
| [HARDWARE_PINS.md](HARDWARE_PINS.md) | **Canonical reference** | Physical pin assignments, ESC wiring, NeoPixel timing, LED mapping |
| [BLUEJAY_ESC_ANALYSIS.md](BLUEJAY_ESC_ANALYSIS.md) | **Deep reference** | Bluejay ESC firmware: DShot decode, GCR telemetry, EDT, bootloader, 8051 assembly |
| [BLHELI_PASSTHROUGH.md](BLHELI_PASSTHROUGH.md) | Developer guide | ESC passthrough theory: 3-stage handshake, half-duplex, baud |
| [BLHELI_QUICKSTART.md](BLHELI_QUICKSTART.md) | Operator guide | Quick-start wiring and usage for ESC configurator |
| [SYSTEM_OVERVIEW.md](SYSTEM_OVERVIEW.md) | Overview | High-level dual-plane architecture (links here for detail) |
| [FPGA_BLOCK_DESIGN.md](FPGA_BLOCK_DESIGN.md) | Overview | Block responsibilities, Mermaid diagram (links here for registers) |
| [TOP_LEVEL_BLOCK_DIAGRAM.md](TOP_LEVEL_BLOCK_DIAGRAM.md) | Diagram | Canonical Mermaid system diagram |
| [ARCH_BUS_STRATEGY.md](ARCH_BUS_STRATEGY.md) | Decision record | Why AXIS + Wishbone hybrid (not monolithic bus) |
| [FCSP_BRINGUP_PLAN.md](FCSP_BRINGUP_PLAN.md) | Plan | Phased bringup (Phase 0–4) |
| [FCSP_COMMAND_TRANSLATION.md](FCSP_COMMAND_TRANSLATION.md) | Mapping | MSP → FCSP intent translation pipeline |
| [TANG9K_FIT_GATE.md](TANG9K_FIT_GATE.md) | Evidence | Resource budget and timing analysis |
| [VALIDATION_MATRIX.md](VALIDATION_MATRIX.md) | Evidence | Test suites, CI gates, evidence template |
| [TIMING_REPORT.md](TIMING_REPORT.md) | Evidence | Timing analysis and compile snapshots |
| [../REQUIREMENTS.md](../REQUIREMENTS.md) | Governance | Mission, must-haves, MSP↔FCSP mapping, quality gates |
| [../GITHUB_TODO.md](../GITHUB_TODO.md) | Tracking | Open tasks, IO IP port plan, integration milestones |

---

## 7. Stateful Return-Path Routing (TID/TDEST)

To support multiple ingress ports (USB Serial, SPI) sharing the same internal processing engines (Wishbone Master, ESC UART), a stateful routing mechanism is implemented using AXI-Stream sideband signals.

### 7.1 Port Identification (TID)
At the ingress of the offloader, each frame is tagged with a **TID (Transaction ID)**:
- **TID = 0**: Forwarded from USB Serial.
- **TID = 1**: Forwarded from SPI.

This TID is propagated through the elastic FIFOs () alongside the frame metadata.

### 7.2 Response Routing (TDEST)
Processing modules latch the TID of the request frame and drive the **TDEST (Destination ID)** of the response frame.
- **Wishbone Master**: Latches TID when a command is received; uses it as TDEST for the response frame.
- **ESC UART**: Latches TID of the last received CH 0x05 frame; result packets for that channel use the latched TID as TDEST.

### 7.3 Egress Demultiplexing
The TX Framer latches the TDEST of the outgoing frame. The physical egress logic in  uses this to route bytes:
- **TDEST = 0**: Routes to USB Serial TX.
- **TDEST = 1**: Routes to SPI MISO (only when SPI CS is active).

### 7.4 Debug Isolation
Internal debug generators (e.g., Trace, Status) are hard-wired to **TDEST = 0**. This ensures that background debug traffic never consumes SPI bandwidth or interferes with latency-sensitive flight control data on the SPI bus.

---

## 7. Stateful Return-Path Routing (TID/TDEST)

To support multiple ingress ports (USB Serial, SPI) sharing the same internal processing engines (Wishbone Master, ESC UART), a stateful routing mechanism is implemented using AXI-Stream sideband signals.

### 7.1 Port Identification (TID)
At the ingress of the offloader, each frame is tagged with a **TID (Transaction ID)**:
- **TID = 0**: Forwarded from USB Serial.
- **TID = 1**: Forwarded from SPI.

This TID is propagated through the elastic FIFOs (`fcsp_rx_fifo`) alongside the frame metadata.

### 7.2 Response Routing (TDEST)
Processing modules latch the TID of the request frame and drive the **TDEST (Destination ID)** of the response frame.
- **Wishbone Master**: Latches TID when a command is received; uses it as TDEST for the response frame.
- **ESC UART**: Latches TID of the last received CH 0x05 frame; result packets for that channel use the latched TID as TDEST.

### 7.3 Egress Demultiplexing
The TX Framer latches the TDEST of the outgoing frame. The physical egress logic in `fcsp_offloader_top` uses this to route bytes:
- **TDEST = 0**: Routes to USB Serial TX.
- **TDEST = 1**: Routes to SPI MISO (only when SPI CS is active).

### 7.4 Debug Isolation
Internal debug generators (e.g., Trace, Status) are hard-wired to **TDEST = 0**. This ensures that background debug traffic never consumes SPI bandwidth or interferes with latency-sensitive flight control data on the SPI bus.
