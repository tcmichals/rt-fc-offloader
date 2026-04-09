# GitHub TODO — rt-fc-offloader

## Phase 0 — MSP baseline lock (PICO + ESC-config GUI)

- [ ] Validate standard MSP workflow end-to-end on PICO
- [ ] Verify passthrough enter/exit/scan baseline behavior
- [ ] Capture baseline reference for FCSP parity checks

## Current focus

- [x] Finalize FCSP CONTROL op implementation skeleton
- [x] Implement `HELLO` + `GET_CAPS` discovery path
- [x] Implement `READ_BLOCK` / `WRITE_BLOCK` spaces for dynamic IO

## RTL/firmware tasks

- [x] `rtl/fcsp/`: parser, CRC gate, channel router, FIFO boundaries
- [x] Control/firmware dispatcher + result code mapping — `fcsp_wishbone_master` replaced legacy `firmware/serv8/`
- [x] Integrate control command/response wiring in `rtl/fcsp/boards/tangnano9k/fcsp_tangnano9k_top.sv` using `fcsp_serv_stub` (interim seam stub)
- [x] Add control-endpoint debug message producer (`DEBUG_TRACE`) in `fcsp_serv_stub` (interim format: short text frame)
- [x] Route `DEBUG_TRACE` channel into TX scheduler/framer (CONTROL + DEBUG via `fcsp_tx_arbiter`)
- [x] Wire USB-UART byte-stream shim in Tang9K wrapper so FCSP debug frames can exit on board serial port
- [x] Define stable IO space map for PWM/DSHOT/LED/NeoPixel windows — implemented in `wb_io_bus.sv`

## Next implementation queue (current)

- [x] Replace `fcsp_serv_stub` with production control endpoint — `fcsp_wishbone_master` is active control plane
- [x] Upgrade `fcsp_tx_fifo` from pass-through seam to true buffered FIFO with occupancy/backpressure counters
- [x] Implement buffered `fcsp_rx_fifo` for Tang9K
- [x] Add TX arbitration — `fcsp_tx_arbiter` (CONTROL > ESC > DEBUG priority)
- [x] Add FCSP command coverage for `HELLO`, `GET_CAPS`, `READ_BLOCK`, `WRITE_BLOCK` — tested in `test_fcsp_wishbone_master_cocotb` + `test_e2e_fcsp_wb_io_cocotb`
- [ ] Expose CONTROL/DEBUG drop/overflow counters through a Wishbone status block

## Simulation

- [x] Add frame parser noise-resync tests — 3 new tests (embedded sync, truncated frame, back-to-back)
- [ ] Add caps paging tests
- [ ] Add passthrough safety transition tests
- [ ] Compare `wb_neoPx` / `sendPx_axis_flexible` timing approach against external RTL NeoPixel reference projects (capture deltas + recommended updates)
- [x] Add E2E mux switching tests — 3 tests (read default, switch to serial, toggle back)
- [x] Add E2E LED controller tests — 4 tests (set/readback, clear, toggle, walk pattern)
- [x] Add E2E NeoPixel write+trigger tests — 2 tests (single pixel, multi pixel)
- [x] Add E2E BLHeli boot sequence tests — 2 tests (force low/release, ESC data after boot)
- [x] Add E2E SPI TX egress tests — 2 tests (PING mirror, CS-high passthrough)

## 50 MHz control-path target checks

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

## Professionalization backlog (Apr 2026 review)

### P0 — repo hygiene + review discipline

- [x] Enforce clean-branch rule: no unrelated file diffs in feature PRs
- [x] Split large mixed changes into scoped PR slices (RTL, docs, sim, tooling)
- [x] Require conventional commit messages with subsystem prefix (`rtl:`, `sim:`, `docs:`)

### P0 — CI quality gates (required before merge)

- [x] Add required CI job: `sim/test-serial-mux-cocotb`
- [x] Add required CI smoke gate for core FCSP parser/router/tx tests
- [x] Add CI doc-consistency check (flag stale terms like "CPU-less" when top-level uses SERV seam)
- [ ] Add branch protection: block merge on failing required checks *(manual GitHub repo setting; documented in CONTRIBUTING.md)*

### P1 — documentation contract

- [x] Add/maintain "Current Implementation Status" section in canonical architecture docs
- [x] Standardize address notation: always show `absolute + relative` pair where applicable
- [x] Add channel-table source-of-truth section and reference `rtl/fcsp/fcsp_router.sv` constants

### P1 — release engineering

- [x] Establish version tags for simulation/protocol milestones
- [x] Add `CHANGELOG.md` entries for protocol and register map changes
- [x] Publish reproducible validation matrix (sim targets + expected pass criteria)

### P2 — contributor standards

- [x] Add PR template with mandatory verification evidence (tests run + outputs)
- [x] Add CODEOWNERS for `rtl/`, `sim/`, and `docs/`
- [x] Add contributor guide for branch/commit/test expectations

## FPGA completion tracker (Apr 7, 2026)

Goal: close all remaining SystemVerilog implementation gaps for a production-complete FCSP offloader path on Tang9K-class targets.

- [x] Promote Wishbone control path in top — `fcsp_wishbone_master` wired in `fcsp_offloader_top`
- [x] Integrate HELLO and GET_CAPS ops — handled by `fcsp_wishbone_master`
- [x] Complete READ/WRITE_BLOCK space decode — `wb_io_bus` + all slaves
- [x] Expose full fcsp_io_engines register map — 7 slaves wired
- [x] Wire DShot outputs to motor pins — via `wb_serial_dshot_mux` + `pad_motor[3:0]`
- [x] Implement ESC_SERIAL channel hardware bridge — CH 0x05 stream ports + packetizer
- [x] Implement serial-dshot pin mux control — `wb_serial_dshot_mux` ported + tested
- [x] Add FCSP control response/result handling — TX FIFO → arbiter → framer → USB
- [x] Finalize USB/SPI ingress arbitration policy — USB priority, SPI fallback
- [ ] Add deterministic backpressure and overflow policy
- [ ] Add top-level debug/telemetry channel sources
- [x] Tie board wrapper to production top signals
- [ ] Close CDC/reset/timing hardening gaps
- [x] Create cocotb for each new block — 103 cocotb tests across 22 suites
- [x] Run strict regression and timing gates — 103 tests, 0 failures

## RTL Bugs Fixed (Apr 2026)

- [x] **CRC16 stale seed on back-to-back frames** — `fcsp_crc16.sv`: when `i_frame_start` and `i_data_valid` both assert on the same cycle, the CRC core was fed stale previous-frame CRC instead of 0. Fixed by muxing `crc_in = i_frame_start ? 0 : crc_reg` into the combinational core.
- [x] **Parser pulse latching** — `fcsp_parser.sv`: pulse outputs (`o_frame_done`, etc.) were only cleared inside `if (in_valid && in_ready)`, staying latched when `in_valid` drops between frames. Fixed by clearing pulses unconditionally every clock cycle.
- [x] **LED double-inversion** — `fcsp_tangnano9k_top.sv`: board wrapper applied `~led_reg_out` when `wb_led_controller` with `LED_POLARITY=0` already inverts internally. Removed redundant inversion.
- [x] **Missing OP_PING handler** — `fcsp_wishbone_master.sv`: PING opcode (0x06) was not recognized as a single-byte command, returning `RES_NOT_SUPPORTED`. Added OP_PING case alongside GET_CAPS/HELLO.
- [x] **SPI TX egress dual-egress** — `fcsp_offloader_top.sv`: implemented CS-gated SPI TX mirroring alongside USB TX.

---

## IO IP Port Plan — Legacy → rtl/io/ (Apr 7, 2026)

This section tracks the porting and adaptation of proven IP from:
`/media/tcmichals/projects/Tang9K/HacksterIO/SPIQuadCopter`

Each block must be ported to `rtl/io/`, adapted to 54 MHz / `CLK_FREQ_HZ=54_000_000`,
wired into the Wishbone IO subsystem, connected through `fcsp_io_engines.sv`,
and verified with a dedicated cocotb block-level testbench before integration.

### IP-1 — DShot Output Engine (4-channel) — ✅ COMPLETE

**Status**: Ported, wired in `fcsp_io_engines.sv`, block-tested (`test_dshot_out_cocotb.py`, 4 tests).

- [x] `rtl/io/dshot_out.sv` — ported, 54 MHz param
- [x] `rtl/io/wb_dshot_controller.sv` — ported, 54 MHz default
- [x] Instantiated in `fcsp_io_engines.sv` as `u_dshot`
- [x] Motor outputs wired through `wb_serial_dshot_mux` → `pad_motor[3:0]`
- [x] Block-level cocotb tests pass

---

### IP-2 — NeoPixel WS2812/SK6812 Timing Engine — ✅ COMPLETE

**Status**: Ported, wired in `fcsp_io_engines.sv`, block-tested (`test_wb_neoPx_cocotb.py`, 4 tests).

- [x] `rtl/io/sendPx_axis_flexible.sv` — ported
- [x] `rtl/io/wb_neoPx.sv` — ported, instantiates `sendPx_axis_flexible` internally
- [x] Instantiated in `fcsp_io_engines.sv` as `u_neopx`
- [x] `o_neo_data` wired to pin 40 in board wrapper
- [x] Block-level cocotb tests pass

---

### IP-3 — PWM Decoder (6-channel RC input) — ✅ COMPLETE

**Status**: Ported, wired in `fcsp_io_engines.sv`, block-tested (`test_pwmdecoder_cocotb.py`, 4 tests).

- [x] `rtl/io/pwmdecoder.sv` — ported, 54 MHz param
- [x] `rtl/io/pwmdecoder_wb.sv` — ported, 6-channel Wishbone wrapper
- [x] Instantiated in `fcsp_io_engines.sv` as `u_pwm`
- [x] 6 PWM input pins wired from board through `fcsp_offloader_top`
- [x] Block-level cocotb tests pass

---

### IP-4 — ESC Half-Duplex UART (BLHeli) — ✅ COMPLETE

**Status**: Ported with programmable baud + AXIS stream ports, wired in `fcsp_io_engines.sv`, block-tested (`test_wb_esc_uart_cocotb.py`, 12 tests) + E2E tested (`test_esc_passthrough_e2e.py`, 3 tests; `test_e2e_esc_roundtrip_cocotb.py`, 3 tests).

- [x] `rtl/io/wb_esc_uart.sv` — ported, 54 MHz, programmable BAUD_DIV at `0x0C`
- [x] AXIS stream ports: `s_esc_tdata/tvalid/tready` (TX) + `m_esc_tdata/tvalid/tready` (RX)
- [x] Wired through `fcsp_io_engines` → `fcsp_offloader_top` → `fcsp_stream_packetizer` → TX arbiter
- [x] Router CH 0x05 → ESC UART TX fully connected (no tie-offs)
- [x] ESC UART RX → packetizer → arbiter → framer → USB egress
- [x] Block tests: initial status, baud config, TX start/active/complete, RX byte, RX stream output, stream TX, WB priority, loopback, RX clear
- [x] E2E tests: routing, multi-message, CH 0x05 reaches UART TX

---

### IP-5 — Serial/DShot Pin Mux (with sniffer) — ✅ COMPLETE

**Status**: Ported, wired in `fcsp_io_engines.sv`, block-tested (`test_wb_serial_dshot_mux_cocotb.py`, 10 tests).

- [x] `rtl/io/wb_serial_dshot_mux.sv` — ported, 54 MHz, MSP sniffer preserved
- [x] DShot inputs from `wb_dshot_controller` wired
- [x] Serial TX/RX/OE wired to `wb_esc_uart`
- [x] `pc_rx_data`/`pc_rx_valid` sniffer feed wired
- [x] `pad_motor[3:0]` bidirectional pads wired to board
- [x] Block-level cocotb tests pass

---

### IP-6 — Wishbone IO Subsystem + fcsp_wishbone_master Integration — ✅ COMPLETE

**Status**: `wb_io_bus.sv` created with 7-slave decode, `fcsp_wishbone_master` wired as active control plane, block-tested (`test_wb_io_bus_cocotb.py`, 7 tests; `test_fcsp_wishbone_master_cocotb.py`, 8 tests) + E2E tested (`test_e2e_fcsp_wb_io_cocotb.py`, 4 tests).

- [x] `rtl/io/wb_io_bus.sv` — decodes WHO_AM_I, PWM, DSHOT, MUX, NEO, ESC, LED
- [x] `fcsp_wishbone_master` wired in `fcsp_offloader_top` (replaced `fcsp_serv_bridge`)
- [x] `fcsp_io_engines.sv` instantiates all real IO slaves
- [x] `HELLO`, `GET_CAPS`, `PING`, `READ_BLOCK`, `WRITE_BLOCK` ops verified
- [x] E2E: WHO_AM_I read returns `0xFC500002`
- [x] E2E: Two sequential READ_BLOCK commands both get responses (validates CRC16 fix)
- [x] Block + E2E cocotb tests pass

---

### Integration Milestone Gates (in order)

- [x] **M1**: IP-1 (DShot) + IP-5 (Mux) ported and block-tested → motor pins driven from DShot
- [x] **M2**: IP-4 (ESC UART) + IP-5 (Mux) + ESC_SERIAL CH 0x05 wired → ESC passthrough end-to-end
- [x] **M3**: IP-2 (NeoPixel) ported and block-tested → NeoPixel pin functional
- [x] **M4**: IP-3 (PWM Decoder) ported and block-tested → RC input readable via Wishbone
- [x] **M5**: IP-6 (WB bus + WB master integration) complete → `fcsp_wishbone_master` is active control path
- [ ] **M6**: All blocks integrated in `fcsp_tangnano9k_top` → `tang9k-build` passes timing
- [x] **M7**: `make test-all-strict` passes → 103 cocotb tests across 22 suites, 0 failures
- [ ] **M8**: All E2E Python hardware tests pass in simulation (`python/hw/test_hw_*.py --port sim`)

---

## End-to-End Python Hardware Test Simulation Plan (Apr 7, 2026)

These tests currently run against real hardware via USB serial.
The goal is to make every `python/hw/test_hw_*.py` script runnable in simulation
so that full register-path behavior is validated before flashing a board.

The existing `FcspControlClient` already has a `--port sim` mode with a basic
in-memory register model. The plan below extends this to cocotb-backed simulation
where register reads/writes drive the actual RTL through FCSP frames.

### Simulation harness design

- [ ] Create `sim/cocotb/test_e2e_hw_scripts.py`: cocotb top-level test that:
  1. Instantiates `fcsp_offloader_top` (with all IO slaves wired) under Verilator
  2. Provides a simulated USB-UART byte-stream driver (push FCSP frames into `i_usb_rx_*`)
  3. Provides a simulated USB-UART byte-stream monitor (capture FCSP response frames from `o_usb_tx_*`)
  4. Bridges the cocotb FCSP driver to a socket/pipe so `FcspControlClient` can connect
- [ ] Extend `FcspControlClient` `--port sim` mode to:
  - Option A (lightweight): use the existing in-memory model but populate it from RTL register map defaults
  - Option B (full fidelity): connect via local socket to cocotb FCSP driver for cycle-accurate RTL-backed E2E

### E2E-1 — `test_hw_version_poll.py` (identity / link smoke)

**What it exercises**: repeated `READ_BLOCK` of `WHO_AM_I` (`0x40000000`) over FCSP CONTROL

**Simulation test** — **✅ Implemented** in `sim/cocotb/test_e2e_fcsp_wb_io_cocotb.py`:
- [x] Send FCSP `READ_BLOCK(0x40000000)` frame into `i_usb_rx_*`
- [x] Verify response frame on `o_usb_tx_*` contains `0xFC500002`
- [ ] Repeat N times; verify all responses match, zero CRC errors, zero timeouts
- [ ] Verify link-status counters (frame_done, no overflow) on status outputs

**Depends on**: ~~IP-6 (WB master + bus wired)~~ ✅ Done

---

### E2E-2 — `test_hw_switching.py` (serial/DShot mux register round-trip)

**What it exercises**: `WRITE_BLOCK`/`READ_BLOCK` to mux register `0x40000400`,
channel sweep, mode toggle, force-low break pulse

**Simulation test** (`sim/cocotb/test_e2e_switching.py`):
- [ ] Write mux register with `mode=SERIAL, ch=0..3` via FCSP CONTROL `WRITE_BLOCK`
- [ ] Read back mux register via FCSP CONTROL `READ_BLOCK`; verify bits [4:0] match
- [ ] Write `mode=DSHOT`; read back; verify
- [ ] Write `force_low=1`; verify motor pin under test is held LOW in RTL
- [ ] Write `force_low=0`; verify motor pin released
- [ ] Verify pin-mux tristate behavior on mode change (1-cycle tristate, no glitch)
- [ ] Verify default power-on state is DSHOT mode

**Depends on**: IP-5 (mux ported), IP-6 (WB bus wired)

---

### E2E-3 — `test_hw_neopixel.py` (NeoPixel register write + waveform)

**What it exercises**: `WRITE_BLOCK` to pixel buffer registers `0x40000600..0x4000061C`,
trigger register `0x40000620`, verify NeoPixel serial waveform

**Simulation test** (`sim/cocotb/test_e2e_neopixel.py`):
- [ ] Write RGB value to `NEO_PIXEL_0` (`0x40000600`) via FCSP CONTROL `WRITE_BLOCK`
- [ ] Write `0x01` to `NEO_UPDATE` (`0x40000620`) to trigger
- [ ] Sample `o_neopixel` output pin in cocotb; verify WS2812 T0H/T1H pulse widths for written RGB
- [ ] Write multiple pixels (8); trigger; verify full strip waveform including latch gap
- [ ] Verify `o_neo_busy` assertion during waveform and deassertion after latch

**Depends on**: IP-2 (NeoPixel ported), IP-6 (WB bus wired)

---

### E2E-4 — `test_hw_onboard_led_walk.py` (LED controller register ops)

**What it exercises**: `WRITE_BLOCK`/`READ_BLOCK` to `wb_led_controller` registers
at LED_BASE (`0x40000C00`): OUT, TOGGLE, CLEAR, SET

**Simulation test** (`sim/cocotb/test_e2e_led_walk.py`):
- [ ] Write `LED_CLEAR(0xF)` via FCSP `WRITE_BLOCK`; read `LED_OUT`; verify `0x00`
- [ ] Write `LED_SET(0x5)` via FCSP `WRITE_BLOCK`; read `LED_OUT`; verify `0x05`
- [ ] Write `LED_TOGGLE(0xF)` via FCSP `WRITE_BLOCK`; read `LED_OUT`; verify `0x0A`
- [ ] Write `LED_OUT(0x3)` via FCSP `WRITE_BLOCK`; read `LED_OUT`; verify `0x03`
- [ ] Verify board LED output pins (`o_led_3..o_led_6`) reflect LED_OUT bits in RTL

**Depends on**: `wb_led_controller` mapped in WB bus (already exists in legacy), IP-6 (WB bus wired)

---

### E2E harness CMake / Makefile integration

- [ ] Add CMake target `sim-test-e2e-hw`: runs all E2E cocotb tests above
- [ ] Add to `sim-test-all-strict` expansion so E2E tests are part of strict regression
- [ ] Add `sim/Makefile` target `test-e2e-hw-cocotb` for direct invocation
- [ ] Document in `docs/VALIDATION_MATRIX.md` as a new suite row

---

## Repository Cleanup — Dead Code & Duplicate Files

Legacy porting left duplicate RTL and dead firmware trees in the repo. These inflate the build source list, confuse AI tooling, and risk accidental inclusion. Clean up after all IO IPs are verified.

### Dead firmware

- [ ] Remove `firmware/serv8/` — SERV CPU path was replaced by `fcsp_wishbone_master` (pure-RTL control plane). No firmware runs on this target.

### Duplicate RTL (legacy `rtl/fcsp/drivers/` vs ported `rtl/io/`)

Every file below exists as both a legacy copy under `rtl/fcsp/drivers/` and the production copy under `rtl/io/`. Only the `rtl/io/` versions are used in the build. Delete the legacy duplicates:

- [ ] `rtl/fcsp/drivers/dshot/dshot_out.sv` (ported → `rtl/io/dshot_out.sv`)
- [ ] `rtl/fcsp/drivers/dshot/wb_dshot_controller.sv` (ported → `rtl/io/wb_dshot_controller.sv`)
- [ ] `rtl/fcsp/drivers/dshot/motor_mailbox_sv.sv` (not used in production)
- [ ] `rtl/fcsp/drivers/dshot/wb_dshot_mailbox.sv` (not used in production)
- [ ] `rtl/fcsp/drivers/neoPXStrip/wb_neoPx.sv` (ported → `rtl/io/wb_neoPx.sv`)
- [ ] `rtl/fcsp/drivers/neoPXStrip/sendPx_axis_flexible.sv` (ported → `rtl/io/sendPx_axis_flexible.sv`)
- [ ] `rtl/fcsp/drivers/pwmDecoder/pwmdecoder.sv` (ported → `rtl/io/pwmdecoder.sv`)
- [ ] `rtl/fcsp/drivers/pwmDecoder/pwmdecoder_wb.sv` (ported → `rtl/io/pwmdecoder_wb.sv`)
- [ ] `rtl/fcsp/drivers/uart/wb_esc_uart.sv` (ported → `rtl/io/wb_esc_uart.sv`)
- [ ] `rtl/fcsp/drivers/uart/uart_rx.sv` (standalone; not used in production)
- [ ] `rtl/fcsp/drivers/uart/uart_tx.sv` (standalone; not used in production)
- [ ] `rtl/fcsp/drivers/uart/wb_usb_uart.sv` (not used in production)
- [ ] `rtl/fcsp/drivers/wb_serial_dshot_mux.sv` (ported → `rtl/io/wb_serial_dshot_mux.sv`)

### Dead RTL modules (replaced by architecture changes)

- [ ] `rtl/fcsp/fcsp_serv_bridge.sv` — replaced by `fcsp_wishbone_master`
- [ ] `rtl/fcsp/fcsp_serv_stub.sv` — interim stub, no longer used

### Other legacy drivers (assess & remove)

- [ ] `rtl/fcsp/drivers/wb_timer.sv` — not instantiated anywhere in production
- [ ] `rtl/fcsp/drivers/wb_ila.sv` — not instantiated anywhere in production
- [ ] `rtl/fcsp/drivers/wb_spisystem.sv` — legacy SPI system, replaced by `fcsp_spi_frontend`
- [ ] `rtl/fcsp/drivers/wb_debug_gpio.sv` — not instantiated anywhere in production
- [ ] `rtl/fcsp/drivers/wb_mux_6.sv` — legacy 6-port mux, replaced by `wb_io_bus`
- [ ] `rtl/fcsp/drivers/version/wb_version.sv` — not instantiated; WHO_AM_I is in `wb_io_bus`

---

## 100% Feature Complete — RTL + Cocotb + Python HW Tests

Goal: every feature that ships in the FPGA bitstream is verified in simulation (cocotb) AND has a Python hardware test script (`python/hw/test_hw_*.py`) for real USB-serial validation.

### RTL integration work remaining

- [x] **Wire CH 0x05 ESC stream path in `fcsp_offloader_top`**: router_esc → ESC UART stream TX, ESC UART RX → `fcsp_stream_packetizer` → `fcsp_tx_arbiter` ESC input
- [x] **Add AXIS stream ports to `rtl/io/wb_esc_uart.sv`**: `s_esc_tdata/tvalid/tready` (TX) + `m_esc_tdata/tvalid/tready` (RX)
- [x] **Instantiate `fcsp_stream_packetizer`** in `fcsp_offloader_top` — MAX_LEN=16, TIMEOUT=1000
- [ ] **Enable SPI TX egress**: route `tx_wire_*` to `fcsp_spi_frontend` TX side (channel-aware policy) — still `spi_tx_valid = 1'b0`

### Cocotb tests needed (block-level)

- [x] **ESC UART RX path**: drive serial waveform into `rx_in`, verify `rx_data_reg` and `rx_valid` via WB read
- [x] **ESC UART stream output**: RX byte appears on `m_esc_tdata/tvalid`
- [x] **ESC UART stream TX**: drive `s_esc_tdata/tvalid`, verify byte on `tx_out`
- [x] **ESC UART WB priority**: WB `TX_DATA` takes priority over stream TX
- [x] **ESC UART loopback**: stream TX → tx_out → verify TX completes
- [x] **ESC UART RX clear**: reading `RX_DATA` via WB clears `rx_valid`
- [x] **ESC UART back-to-back TX**: write two bytes rapidly, verify no data corruption — added to `test_wb_esc_uart_cocotb.py`
- [x] **DShot→Serial transition**: write DShot pattern → switch mux to serial → verify motor pin goes idle-high — added to `test_wb_serial_dshot_mux_cocotb.py`
- [x] **Force-low break sequence**: assert `force_low`, hold for simulated 20ms, release → verify pin LOW then HIGH — added to `test_wb_serial_dshot_mux_cocotb.py`
- [x] **Stream packetizer block test**: dedicated test for `fcsp_stream_packetizer` (MAX_LEN, TIMEOUT behavior) — `test_fcsp_stream_packetizer_cocotb.py`, 5 tests

### Cocotb tests needed (E2E top-level)

- [x] **FCSP CH 0x05 routing**: send FCSP CH 0x05 frame → verify router ESC stream fires, not control path
- [x] **FCSP CH 0x05 reaches UART TX**: send CH 0x05 frame → verify `o_esc_tx_active` fires
- [x] **FCSP CH 0x05 full roundtrip**: send CH 0x05 frame → UART TX → verify TX active fires and completes — `test_e2e_esc_roundtrip_cocotb.py`, 3 tests
- [ ] **BLHeli boot sequence E2E**: mux=serial → force_low → release → CH 0x05 data → verify UART TX on motor pad
- [ ] **SPI TX egress**: send FCSP CONTROL frame via SPI ingress → verify response exits on SPI MISO (once SPI TX is enabled)

### ESC traffic generator (Python cocotb helper)

- [ ] Create `sim/cocotb/esc_traffic_gen.py`: reusable ESC simulator that:
  - Drives serial bytes into `pad_motor[N]` (simulating ESC responses)
  - Validates BLHeli 4-way protocol framing
  - Supports configurable baud rate (19200 default)
  - Supports programmable response delay (simulating real ESC timing)
- [ ] Create `sim/cocotb/test_esc_protocol_cocotb.py`: full ESC protocol test using the traffic generator:
  - [ ] Send BLHeli init sequence via FCSP CH 0x05 → verify ESC sees correct bytes on motor pin
  - [ ] ESC simulator responds → verify host receives FCSP CH 0x05 response frame
  - [ ] Multi-byte exchange: send 16-byte command → receive 32-byte response → verify integrity
  - [ ] Baud rate change: write new BAUD_DIV → verify subsequent exchange uses new timing
  - [ ] Channel switch: reconfigure mux to different motor → verify correct pad is driven

### Python hardware test scripts (USB-serial, `python/hw/`)

Existing scripts (already created):
- [x] `test_hw_version_poll.py` — WHO_AM_I polling at ~40 Hz
- [x] `test_hw_switching.py` — MUX_CTRL read/write at `0x40000400`
- [x] `test_hw_onboard_led_walk.py` — LED SET/CLEAR/TOGGLE at `0x40000C00`
- [x] `test_hw_neopixel.py` — NeoPixel knight rider animation at `0x40000600`

New scripts needed:
- [ ] `test_hw_dshot_status.py` — write DShot raw words to `0x40000300`–`0x4000030C`, read CONFIG/STATUS, verify ready bits
- [ ] `test_hw_pwm_readback.py` — read PWM decoder registers at `0x40000100`–`0x40000114`, verify plausible values (or zero if no signal)
- [ ] `test_hw_esc_uart_loopback.py` — set mux to serial mode → write TX_DATA byte → if motor pin is looped back, read RX_DATA → verify echo
- [ ] `test_hw_esc_baud_config.py` — write BAUD_DIV register at `0x4000090C`, read back, verify value matches
- [ ] `test_hw_mux_force_low.py` — write `force_low=1` to mux register → verify (via scope or status) → release → verify
- [ ] `test_hw_esc_passthrough.py` — full BLHeli passthrough entry sequence: set serial mode → force_low break → release → send/receive ESC serial data via CH 0x05 FCSP frames
- [ ] `test_hw_register_sweep.py` — read every known register address in the map, verify no bus hang, expected values for read-only regs (WHO_AM_I, STATUS)
- [ ] `test_hw_spi_echo.py` — (when SPI TX enabled) send FCSP frame via SPI, verify response frame on SPI MISO

### Milestone gate

- [x] **ALL cocotb tests pass** (`make test-all-strict`) — 75 cocotb tests, 0 failures (Apr 8, 2026)
- [x] **ALL Python tests pass** — 26 Python tests, 0 failures
- [ ] **ALL Python HW tests pass** on real hardware over USB serial
- [ ] **FPGA bitstream builds** cleanly with updated sources (`./scripts/build_tang9k_oss.sh`)

### Remaining open items summary (Apr 8, 2026)

- [ ] Enable SPI TX egress (`spi_tx_valid` still tied off)
- [ ] ESC traffic generator (`sim/cocotb/esc_traffic_gen.py`)
- [ ] ESC protocol full roundtrip test (CH 0x05 → UART TX → loopback → RX → response frame)
- [ ] Stream packetizer dedicated block test
- [ ] 4 new Python HW scripts: `test_hw_dshot_status.py`, `test_hw_pwm_readback.py`, `test_hw_esc_uart_loopback.py`, `test_hw_register_sweep.py`
- [ ] Repository cleanup: `firmware/serv8/`, 13 legacy RTL duplicates, 2 dead modules
- [ ] CDC/reset/timing hardening
- [ ] Backpressure/overflow counters
- [ ] **DESIGN.md gaps section** shows zero blocking gaps (G1–G4 resolved)

---

## Missing Professional Documents (Apr 8, 2026)

Items needed to bring the repository to open-source-professional standard.

### P0 — Required

- [ ] **LICENSE** — Add a root `LICENSE` file (MIT or Apache-2.0). Required for any open-source project. Without it, code is technically all-rights-reserved.
- [ ] **SECURITY.md** — Vulnerability disclosure policy. GitHub surfaces this in the Security tab. Even a simple "email the maintainer" template counts.

### P1 — Recommended

- [ ] **docs/GETTING_STARTED.md** — Developer quick-start: clone, install tools, run sim, build bitstream. Consolidate from README + TOOLCHAIN_SETUP + TANG9K_PROGRAMMING into a single "first 15 minutes" guide.
- [ ] **docs/ADR/** — Architecture Decision Records directory. Capture key decisions already made (e.g., "Why Wishbone + AXIS hybrid", "Why fixed-priority not round-robin arbiter", "Why CRC16/XMODEM"). These already exist as prose in DESIGN.md and ARCH_BUS_STRATEGY.md — formalize as numbered ADRs.
- [ ] **python/README.md improvements** — API reference for `hwlib/` Python package. Document register map classes, FCSP codec usage, and HW test script conventions.
- [ ] **docs/GLOSSARY.md** — Project-specific term definitions (FCSP, AXIS seam, IO engine, probe snapshot, etc.) for new contributors.

### P2 — Nice to have

- [ ] **Issue templates** — `.github/ISSUE_TEMPLATE/bug_report.md` and `feature_request.md` with structured fields.
- [ ] **docs/CODING_STYLE.md** — SystemVerilog and Python naming/formatting conventions used in this repo.
- [ ] **docs/CI_PIPELINE.md** — Document what each CI gate tests, minimum Verilator version, and how to debug failures.
- [ ] **Mermaid/SVG block diagrams** — Rendered versions of the ASCII art in DESIGN.md for README and GitHub Pages.
