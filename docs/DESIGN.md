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

### 2.3 Wishbone B3 Internal Bus

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

### 2.1 Control Plane (CH 0x01) — READ/WRITE registers

```
USB/SPI byte → ingress mux → fcsp_parser → fcsp_crc_gate → fcsp_router
  → [CH 0x01] → fcsp_rx_fifo → fcsp_wishbone_master → int_wb_* bus
  → wb_io_bus → peripheral slave → WB response
  → fcsp_wishbone_master response stream
  → fcsp_tx_fifo (CTRL) → fcsp_tx_arbiter → fcsp_tx_framer → USB TX
```

**Status: FUNCTIONAL.** 68 cocotb tests pass. E2E verified in sim.

### 2.2 ESC Passthrough (CH 0x05) — BLHeli serial bridge

```
HOST → FCSP frame CH 0x05 → fcsp_parser → fcsp_crc_gate → fcsp_router
  → [CH 0x05] m_esc_* AXIS output
  → ??? → wb_esc_uart TX → mux → motor pad (half-duplex)
  → motor pad RX → mux → wb_esc_uart RX
  → fcsp_stream_packetizer → fcsp_tx_arbiter (ESC input) → fcsp_tx_framer → USB TX
```

**Status: NOT WIRED.** The router outputs CH 0x05 data (`router_esc_tvalid/tdata/tlast`) but `fcsp_offloader_top` ties `m_esc_tready = 1'b1` (data accepted and dropped). The arbiter ESC input is tied to zero. The stream packetizer is not instantiated. All the building blocks exist — they just need to be connected.

**What's needed:**
1. Wire `router_esc_*` → `wb_esc_uart` stream TX input (`s_esc_tdata/tvalid/tready`)
2. Wire `wb_esc_uart` stream RX output (`m_esc_tdata/tvalid/tready`) → `fcsp_stream_packetizer` → `fcsp_tx_arbiter` ESC input
3. The `rtl/io/wb_esc_uart.sv` (ported version) does NOT have stream ports — only the legacy `rtl/fcsp/drivers/uart/wb_esc_uart.sv` has them. Either add stream ports to the ported version or use the legacy one.

### 2.3 SPI TX Egress

```
fcsp_tx_framer → tx_wire_* → ??? → SPI MISO
```

**Status: DISABLED.** `spi_tx_valid = 1'b0` in `fcsp_offloader_top`. All responses exit via USB-UART only. SPI link is RX-only.

**What's needed:** Route `tx_wire_*` to `fcsp_spi_frontend` TX side based on channel-aware policy (e.g., CONTROL responses → SPI when originated from SPI).

### 2.4 Channels 0x02, 0x03, 0x04 (Telemetry, FC_Log, Debug_Trace)

**Status: TIED OFF.** Router outputs exist but `m_tel_tready`, `m_log_tready`, `m_dbg_tready` are hardwired to `1'b1` — data accepted and dropped.

---

## 3. Complete Address Map

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

## 4. Register Maps (per peripheral)

### 4.1 WHO_AM_I (`0x40000000`)

| Offset | Name | R/W | Value |
|--------|------|-----|-------|
| `0x00` | ID | R | `0xFC500002` |

### 4.2 PWM Decoder (`0x40000100`)

| Offset | Name | R/W | Description |
|--------|------|-----|-------------|
| `0x00` | CH0_WIDTH | R | Pulse width (clocks) for PWM channel 0 |
| `0x04` | CH1_WIDTH | R | Channel 1 |
| `0x08` | CH2_WIDTH | R | Channel 2 |
| `0x0C` | CH3_WIDTH | R | Channel 3 |
| `0x10` | CH4_WIDTH | R | Channel 4 |
| `0x14` | CH5_WIDTH | R | Channel 5 |

### 4.3 DShot Controller (`0x40000300`)

| Offset | Name | R/W | Description |
|--------|------|-----|-------------|
| `0x00` | MOTOR1_RAW | W | 16-bit DShot word (throttle + telem + CRC) |
| `0x04` | MOTOR2_RAW | W | Motor 2 |
| `0x08` | MOTOR3_RAW | W | Motor 3 |
| `0x0C` | MOTOR4_RAW | W | Motor 4 |
| `0x10` | CONFIG | RW | `[1:0]` = DShot mode (150/300/600) |
| `0x14` | STATUS | R | `[3:0]` = per-motor ready bits |

> **Gap: Smart throttle registers (`0x40`–`0x4C`)** defined in Python `hwlib/registers.py` but NOT implemented in RTL. Only raw 16-bit word writes exist. Future feature.

### 4.4 Serial/DShot Pin Mux (`0x40000400`)

Single register at offset `0x00`:

| Bit | Name | Default | Description |
|-----|------|---------|-------------|
| `[0]` | `mux_sel` | `1` (DShot) | 0 = Serial/passthrough, 1 = DShot |
| `[2:1]` | `mux_ch` | `0` | Motor channel select (0–3) |
| `[3]` | `msp_mode` | `0` | 0 = passthrough, 1 = MSP FC protocol |
| `[4]` | `force_low` | `0` | Drive selected motor pin LOW (ESC bootloader break) |

### 4.5 NeoPixel (`0x40000600`)

| Offset | Name | R/W | Description |
|--------|------|-----|-------------|
| `0x00`–`0x1C` | PIX0–PIX7 | RW | 24-bit GRB color per pixel (8 pixels) |
| `0x20` | TRIGGER | W | Any write starts transmission |

### 4.6 ESC UART (`0x40000900`)

| Offset | Name | R/W | Description |
|--------|------|-----|-------------|
| `0x00` | TX_DATA | W | Write byte to transmit (only accepted when `tx_ready`) |
| `0x04` | STATUS | R | `[0]` tx_ready, `[1]` rx_valid, `[2]` tx_active |
| `0x08` | RX_DATA | R | Read received byte (clears `rx_valid` on read) |
| `0x0C` | BAUD_DIV | RW | 16-bit clocks-per-bit divider (default = CLK_FREQ_HZ / 19200) |

**Half-duplex behavior:** TX drives line, sets `tx_active`. RX FSM is gated — forced to IDLE while `tx_active` is high. Guard period (1 bit-time) after stop bit before releasing line.

### 4.7 LED Controller (`0x40000C00`)

| Offset | Name | R/W | Description |
|--------|------|-----|-------------|
| `0x00` | LED_SET | W | OR bits into LED output register |
| `0x04` | LED_CLEAR | W | AND-NOT bits from LED output register |
| `0x08` | LED_TOGGLE | W | XOR bits with LED output register |
| `0x0C` | LED_READ | R | Current LED output state |

---

## 5. BLHeli ESC Passthrough — Full Sequence

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

Host sends BLHeli 4-way protocol or MSP frames wrapped in FCSP CH 0x05 frames. The hardware extracts payload bytes and feeds them to `wb_esc_uart` TX. Responses from the ESC arrive on the motor pin RX path, are collected by `fcsp_stream_packetizer`, and sent back to the host as FCSP CH 0x05 response frames.

### Step 6: Restore DShot mode (CONTROL CH 0x01)

```
WRITE_BLOCK 0x40000400 ← 0x00000001   # DShot mode
```

### Auto-passthrough (MSP sniffer)

The `wb_serial_dshot_mux` MSP sniffer watches the PC USB-UART RX stream for `$M<` headers followed by size bytes `0xF5` or `0x64`. On match, it automatically overrides `mux_sel` to serial mode. A 5-second watchdog reverts to DShot if no further activity.

> **See also:** [BLHELI_PASSTHROUGH.md](BLHELI_PASSTHROUGH.md), [BLHELI_QUICKSTART.md](BLHELI_QUICKSTART.md)

---

## 6. FCSP Protocol Summary

| Field | Size | Description |
|-------|------|-------------|
| `sync` | 1 | `0xA5` |
| `version` | 1 | `1` |
| `flags` | 1 | `0x01` = ACK request, `0x02` = ACK response |
| `channel` | 1 | Routing ID (see below) |
| `seq` | 2 | Sequence number (big-endian) |
| `payload_len` | 2 | Payload bytes (max 512, big-endian) |
| `payload` | N | Data |
| `crc16` | 2 | CRC16/XMODEM over `version..payload` |

### Channels

| ID | Name | Datapath | Status |
|----|------|----------|--------|
| `0x01` | CONTROL | → WB master → register R/W → response | **Working** |
| `0x02` | TELEMETRY | Tied off (dropped) | Not implemented |
| `0x03` | FC_LOG | Tied off (dropped) | Not implemented |
| `0x04` | DEBUG_TRACE | Tied off (dropped) | Not implemented |
| `0x05` | ESC_SERIAL | → ESC UART TX → motor pad → RX → packetizer → response | **Not wired** |

### CONTROL Payload Ops

| Op | ID | Payload | Response |
|----|----|---------|----------|
| READ_BLOCK | `0x10` | `addr[31:0]` | `op(0x10) + addr + data[31:0]` |
| WRITE_BLOCK | `0x11` | `addr[31:0] + data[31:0]` | `op(0x11) + addr + status` |

> **See also:** [FCSP_PROTOCOL.md](FCSP_PROTOCOL.md), [FCSP_SPI_TRANSPORT.md](FCSP_SPI_TRANSPORT.md)

---

## 7. Physical Pins (Tang Nano 9K)

| Signal | Pin(s) | Direction | Notes |
|--------|--------|-----------|-------|
| CLK 27 MHz | 52 | I | → PLL → 54 MHz |
| RST_N | 4 | I | Active low |
| SPI_SCLK | 25 | I | From Pico/host |
| SPI_CS_N | 26 | I | |
| SPI_MOSI | 27 | I | |
| SPI_MISO | 28 | O | |
| USB_UART_RX | 18 | I | From USB-UART chip |
| USB_UART_TX | 17 | O | To USB-UART chip |
| Motor 1–4 | 29–32 | IO | Bidirectional (IOBUF), DShot or serial |
| NeoPixel | 33 | O | WS2812/SK6812 data |
| LED 1–6 | 10,11,13,14,15,16 | O | Status LEDs |
| PWM CH0–5 | 34–39 | I | RC receiver inputs |
| Debug 0–2 | 40–42 | O | Logic analyzer taps |

> **See also:** [HARDWARE_PINS.md](HARDWARE_PINS.md)

---

## 8. Known Gaps & Status

| # | Gap | Impact | Blocking? |
|---|-----|--------|-----------|
| G1 | **CH_ESC_SERIAL (0x05) not wired** in `fcsp_offloader_top` | ESC passthrough (BLHeli config/flash) does not work | **Yes** for ESC config |
| G2 | **`rtl/io/wb_esc_uart.sv` has no AXIS stream ports** | Cannot receive CH 0x05 bytes from router. Legacy version has them, ported version does not. | **Yes** for G1 |
| G3 | **`fcsp_stream_packetizer` not instantiated** | ESC UART RX bytes cannot be sent back to host as FCSP frames | **Yes** for G1 |
| G4 | **SPI TX egress disabled** | All responses exit via USB-UART only. SPI host gets no responses. | **Yes** for SPI-primary deployments |
| G5 | **DShot smart throttle** (`0x40`–`0x4C`) not in RTL | Python `hwlib/registers.py` defines them but RTL only has raw word writes | No — future feature |
| G6 | **Channels 0x02/0x03/0x04 tied off** | No telemetry, FC log, or debug trace egress | No — future feature |
| G7 | **`docs/TIMING_REPORT.md` referenced but does not exist** | Broken doc link | No |

---

## 9. Test Coverage Map

| Suite | Makefile Target | DUT | Tests | Covers |
|-------|----------------|-----|-------|--------|
| Parser | `test-cocotb` | `fcsp_parser` | Various | Frame parsing, sync, CRC extraction |
| Top-level | `test-top-cocotb` | `fcsp_offloader_top` | Various | Full E2E: USB → parser → CRC → router → WB → response |
| ESC passthrough | `test-top-cocotb-experimental` | `fcsp_offloader_top` | 2 | CH 0x05 routing, MSP bypass multi-message |
| Serial mux | `test-serial-mux-cocotb` | `wb_serial_dshot_mux` | 8 | DShot default, manual mode, sniffer, force-low, watchdog |
| LED | `test-wb-led-cocotb` | `wb_led_controller` | Various | SET/CLEAR/TOGGLE |
| WB master | `test-fcsp-wb-master-cocotb` | `fcsp_wishbone_master` | Various | READ/WRITE_BLOCK op decode |
| IO bus | `test-wb-io-bus-cocotb` | `wb_io_bus` | 7 | Address decode, WHO_AM_I, all slave select |
| DShot | `test-dshot-out-cocotb` | `dshot_out` | 4 | Pulse timing (150/300/600) |
| NeoPixel | `test-wb-neopx-cocotb` | `wb_neoPx` | 4 | Pixel write, trigger, waveform |
| PWM decoder | `test-pwmdecoder-cocotb` | `pwmdecoder` | 4 | Pulse width measurement |
| ESC UART | `test-wb-esc-uart-cocotb` | `wb_esc_uart` | 5 | TX ready, baud, start bit, tx_active, completion |
| E2E WB IO | `test-e2e-fcsp-wb-io-cocotb` | `fcsp_offloader_top` | 3 | FCSP → WB → WHO_AM_I, PING, HELLO |
| Python unit | `test-python` | N/A | 26 | Protocol codec, command adapter, HW script sim |
| **All strict** | `test-all-strict` | All above | **68+26** | Full regression |

### Missing test coverage

| Area | What's needed |
|------|---------------|
| ESC UART RX path | Send serial byte into `rx_in`, verify `rx_data_reg` and `rx_valid` |
| ESC half-duplex gating | Verify RX is suppressed while TX is active |
| DShot→Serial transition | Verify motor pin sequence: DShot → force_low (LOW for N ms) → release → serial idle (HIGH) |
| ESC serial echo (E2E) | FCSP CH 0x05 → UART TX → loopback → UART RX → CH 0x05 response |
| SPI TX egress | Response frames exit via SPI MISO |

---

## 10. Detail Document Index

| Document | What it covers |
|----------|---------------|
| [FCSP_PROTOCOL.md](FCSP_PROTOCOL.md) | Wire format, channel definitions, CONTROL op payloads |
| [FCSP_SPI_TRANSPORT.md](FCSP_SPI_TRANSPORT.md) | SPI-as-byte-stream model, TX batching, error counters |
| [BLHELI_PASSTHROUGH.md](BLHELI_PASSTHROUGH.md) | ESC passthrough theory: 3-stage handshake, half-duplex, baud |
| [BLHELI_QUICKSTART.md](BLHELI_QUICKSTART.md) | Quick-start wiring and usage for BLHeli configurator |
| [SYSTEM_OVERVIEW.md](SYSTEM_OVERVIEW.md) | High-level dual-plane architecture |
| [FPGA_BLOCK_DESIGN.md](FPGA_BLOCK_DESIGN.md) | Block responsibilities, Mermaid diagram, control register overview |
| [TOP_LEVEL_BLOCK_DIAGRAM.md](TOP_LEVEL_BLOCK_DIAGRAM.md) | Canonical Mermaid system diagram |
| [ARCH_BUS_STRATEGY.md](ARCH_BUS_STRATEGY.md) | Why AXIS + Wishbone hybrid (not monolithic bus) |
| [HARDWARE_PINS.md](HARDWARE_PINS.md) | Physical pin assignments, ESC wiring, LED mapping |
| [FCSP_BRINGUP_PLAN.md](FCSP_BRINGUP_PLAN.md) | Phased bringup (Phase 0–4) |
| [FCSP_COMMAND_TRANSLATION.md](FCSP_COMMAND_TRANSLATION.md) | MSP → FCSP intent translation pipeline |
| [TANG9K_FIT_GATE.md](TANG9K_FIT_GATE.md) | Resource budget and timing analysis |
| [VALIDATION_MATRIX.md](VALIDATION_MATRIX.md) | Test suites, CI gates, evidence template |
| [HARDWARE_PINS.md](HARDWARE_PINS.md) | Pin table, NeoPixel timing, clocking path |
| [../REQUIREMENTS.md](../REQUIREMENTS.md) | Mission, must-haves, MSP↔FCSP mapping, quality gates |
| [../GITHUB_TODO.md](../GITHUB_TODO.md) | Open tasks, IO IP port plan, integration milestones |
