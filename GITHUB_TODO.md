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
- [ ] Control/firmware dispatcher + result code mapping (legacy scaffolding currently under `firmware/serv8/`)
- [x] Integrate control command/response wiring in `rtl/fcsp/boards/tangnano9k/fcsp_tangnano9k_top.sv` using `fcsp_serv_stub` (interim seam stub)
- [x] Add control-endpoint debug message producer (`DEBUG_TRACE`) in `fcsp_serv_stub` (interim format: short text frame)
- [x] Route `DEBUG_TRACE` channel into TX scheduler/framer (CONTROL + DEBUG via `fcsp_tx_arbiter`)
- [x] Wire USB-UART byte-stream shim in Tang9K wrapper so FCSP debug frames can exit on board serial port
- [ ] Define stable IO space map for PWM/DSHOT/LED/NeoPixel windows

## Next implementation queue (current)

- [ ] Replace `fcsp_serv_stub` with production control endpoint + firmware mailbox contract
- [x] Upgrade `fcsp_tx_fifo` from pass-through seam to true buffered FIFO with occupancy/backpressure counters
- [ ] Implement fit-aware buffered `fcsp_rx_fifo` for Tang9K (current RX seam remains pass-through to preserve build fit)
- [ ] Add TX arbitration policy controls (priority/round-robin) and fairness tests
- [ ] Add FCSP command coverage for `HELLO`, `GET_CAPS`, `READ_BLOCK`, `WRITE_BLOCK` against live control map
- [ ] Expose CONTROL/DEBUG drop/overflow counters through a Wishbone status block

## Simulation

- [ ] Add frame parser noise-resync tests
- [ ] Add caps paging tests
- [ ] Add passthrough safety transition tests
- [ ] Compare `wb_neoPx` / `sendPx_axis_flexible` timing approach against external RTL NeoPixel reference projects (capture deltas + recommended updates)

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

- [ ] Promote Wishbone control path in top
- [ ] Integrate HELLO and GET_CAPS ops
- [ ] Complete READ/WRITE_BLOCK space decode
- [ ] Expose full fcsp_io_engines register map
- [ ] Wire DShot outputs to motor pins
- [ ] Implement ESC_SERIAL channel hardware bridge
- [ ] Implement serial-dshot pin mux control
- [ ] Add FCSP control response/result handling
- [ ] Finalize USB/SPI ingress arbitration policy
- [ ] Add deterministic backpressure and overflow policy
- [ ] Add top-level debug/telemetry channel sources
- [ ] Tie board wrapper to production top signals
- [ ] Close CDC/reset/timing hardening gaps
- [ ] Create cocotb for each new block
- [ ] Run strict regression and timing gates

---

## IO IP Port Plan — Legacy → rtl/io/ (Apr 7, 2026)

This section tracks the porting and adaptation of proven IP from:
`/media/tcmichals/projects/Tang9K/HacksterIO/SPIQuadCopter`

Each block must be ported to `rtl/io/`, adapted to 54 MHz / `CLK_FREQ_HZ=54_000_000`,
wired into the Wishbone IO subsystem, connected through `fcsp_io_engines.sv`,
and verified with a dedicated cocotb block-level testbench before integration.

### IP-1 — DShot Output Engine (4-channel)

**Missing**: `rtl/io/` is empty; `fcsp_io_engines.sv` is scaffold (always-ready stub).

**Source files to port**:
- `dshot/dshot_out.v` → `rtl/io/dshot_out.sv`
  - Pure bit-level pulse generator; convert to SV, parameterize `CLK_FREQ_HZ`
- `dshot/dshot_mailbox.sv` → `rtl/io/dshot_mailbox.sv`
  - Motor command mailbox (Wishbone port A + dispatch port B); adapt to project WB convention
- `src/wb_dshot_controller.sv` → `rtl/io/wb_dshot_controller.sv`
  - 4-channel WB controller; exposes `0x00–0x14` register map; change `CLK_FREQ_HZ` default to 54 MHz
  - Keep DSHOT150/300/600 runtime-selectable mode support

**Implementation tasks**:
- [ ] Copy + adapt `dshot_out.v` → `rtl/io/dshot_out.sv` (SV, 54 MHz param)
- [ ] Copy + adapt `dshot_mailbox.sv` → `rtl/io/dshot_mailbox.sv`
- [ ] Copy + adapt `wb_dshot_controller.sv` → `rtl/io/wb_dshot_controller.sv` (54 MHz default)
- [ ] Update `fcsp_io_engines.sv`: replace stub with real `wb_dshot_controller` instance
- [ ] Expose motor output wires from `fcsp_io_engines` → `fcsp_offloader_top` → board wrapper
- [ ] Wire motor pins in `fcsp_tangnano9k_top.sv` (pins 51, 42, 41, 35)

**Testbench tasks** (`sim/cocotb/test_dshot.py`):
- [ ] Single-channel: send DSHOT150/300/600 word, verify bit timing on output pin
- [ ] All 4 channels: verify independent simultaneous operation
- [ ] Guard time: verify rejection of too-rapid writes
- [ ] Wishbone read STATUS register: verify ready bits per channel
- [ ] Wishbone write CONFIG: verify mode switch DSHOT150 → DSHOT600
- [ ] Reset behavior: verify all outputs go low on rst

---

### IP-2 — NeoPixel WS2812/SK6812 Timing Engine

**Missing**: `fcsp_io_engines.sv` only forwards `rgb[0]` to data pin (no real waveform).

**Source files to port**:
- `neoPXStrip/sendPx_axis_flexible.sv` → `rtl/io/sendPx_axis_flexible.sv`
  - WS2812/SK6812 AXIS-fed bit-serial waveform generator; parameterize for 54 MHz
- `neoPXStrip/wb_neoPx.v` → `rtl/io/wb_neoPx.sv`
  - Wishbone pixel buffer (8 pixels, 32-bit RGBW); drives `sendPx_axis_flexible` via AXI stream

**Implementation tasks**:
- [ ] Copy + adapt `sendPx_axis_flexible.sv` → `rtl/io/sendPx_axis_flexible.sv` (54 MHz default)
- [ ] Copy + adapt `wb_neoPx.v` → `rtl/io/wb_neoPx.sv` (SV conversion, 54 MHz default)
- [ ] Update `fcsp_io_engines.sv`: replace `o_neo_data = i_neo_rgb[0]` stub with real `wb_neoPx` + `sendPx` chain
- [ ] Wire `o_neo_data` → `o_neopixel` pin 40 in board wrapper (already mapped)

**Testbench tasks** (`sim/cocotb/test_neopixel.py`):
- [ ] Write single pixel RGB value via Wishbone, trigger update, verify T0H/T1H pulse widths
- [ ] Verify WS2812 vs SK6812 timing with `LED_TYPE` parameter
- [ ] Write 8-pixel frame, verify latch gap (300 µs) after last bit
- [ ] Verify `isReady`/`o_neo_busy` deasserts correctly after frame completes
- [ ] CLK_FREQ_HZ boundary test: verify timing at 54 MHz matches spec

---

### IP-3 — PWM Decoder (6-channel RC input)

**Missing**: `fcsp_io_engines.sv` stub returns `o_pwm_new_sample = i_pwm_in` and zeros for widths.

**Source files to port**:
- `pwmDecoder/pwmdecoder.v` → `rtl/io/pwmdecoder.sv`
  - Core edge-time capture state machine; SV conversion, 54 MHz param
- `pwmDecoder/pwmdecoder_wb.v` → `rtl/io/pwmdecoder_wb.sv`
  - 6-channel Wishbone wrapper; registers 0x00–0x18 (channel values + status)

**Implementation tasks**:
- [ ] Copy + adapt `pwmdecoder.v` → `rtl/io/pwmdecoder.sv` (SV, 54 MHz param)
- [ ] Copy + adapt `pwmdecoder_wb.v` → `rtl/io/pwmdecoder_wb.sv` (54 MHz, 6-channel)
- [ ] Update `fcsp_io_engines.sv`: replace `o_pwm_width_ticks` stub with real `pwmdecoder_wb`
- [ ] Wire 6 PWM input pins from `fcsp_tangnano9k_top` (`i_pwm_ch0..5`) through to `fcsp_io_engines`

**Testbench tasks** (`sim/cocotb/test_pwm_decoder.py`):
- [ ] Drive single channel with 1000 µs / 1500 µs / 2000 µs pulses; read back via Wishbone
- [ ] All 6 channels simultaneously; verify independent capture
- [ ] Guard time error bit (`0x8000`) on overlong pulse
- [ ] No-signal error bit (`0xC000`) on missing pulse
- [ ] Read status register: verify ready flags per channel

---

### IP-4 — ESC Half-Duplex UART (BLHeli)

**Missing**: ESC serial tunnel output (`fcsp_uart_byte_stream`) exists for the USB link but there
is no dedicated half-duplex engine for the ESC/motor-pin serial path.

**Source files to port**:
- `src/wb_esc_uart.sv` → `rtl/io/wb_esc_uart.sv`
  - Half-duplex 8-N-1 UART; auto TX/RX direction switching; configurable baud via `CLK_FREQ_HZ`
  - Register map: `0x00` TX_DATA, `0x04` STATUS, `0x08` RX_DATA
  - Note: move baud-rate divider to a separate configurable register (currently hard-coded at 19200);
    expose programmable divider at `0x4000090C` per `FCSP_PROTOCOL.md` address map

**Implementation tasks**:
- [ ] Copy + adapt `wb_esc_uart.sv` → `rtl/io/wb_esc_uart.sv` (54 MHz, programmable baud)
- [ ] Add programmable baud divider register at offset `0x0C` (default: `54_000_000 / 19200 = 2812`)
- [ ] Wire `tx_out` / `rx_in` / `tx_active` into `wb_serial_dshot_mux` serial interface
- [ ] Expose Wishbone slave port into IO subsystem address map at `0x40000900`

**Testbench tasks** (`sim/cocotb/test_esc_uart.py`):
- [ ] Write byte to TX_DATA via Wishbone; verify 8-N-1 serial output at 19200 baud
- [ ] Drive RX with known byte; verify readable via STATUS + RX_DATA registers
- [ ] Auto-direction: verify TX active signal goes high during TX, returns low after guard time
- [ ] Baud config: write divider register, verify timing changes correctly
- [ ] Write then immediately read: verify half-duplex handoff without data corruption

---

### IP-5 — Serial/DShot Pin Mux (with sniffer)

**Missing**: Hardware pin mux described in docs and top-level diagram does not exist in RTL.
The motor pins in `fcsp_tangnano9k_top` are currently undriven from DShot/UART paths.

**Source files to port**:
- `src/wb_serial_dshot_mux.sv` → `rtl/io/wb_serial_dshot_mux.sv`
  - Wishbone register at address `0x0020` (relative), controls mode/ch/force-low
  - Drives `pad_motor[3:0]` as `inout wire` with bidirectional tristate
  - PC traffic sniffer: auto-enables serial bridge on MSP/passthrough header detection
  - One-cycle global tristate on all mode/channel changes
  - Force-low bit (`[4]`) for ESC bootloader break pulse

**Implementation tasks**:
- [ ] Copy + adapt `wb_serial_dshot_mux.sv` → `rtl/io/wb_serial_dshot_mux.sv`
  - Change `CLK_FREQ_HZ` default to 54 MHz
  - Verify `SIM_CONTROL` ifdef testbench override ports are preserved
  - Keep MSP sniffer auto-passthrough feature
- [ ] Wire `dshot_in[3:0]` from `wb_dshot_controller` motor outputs
- [ ] Wire `serial_tx_i`, `serial_oe_i`, `serial_rx_o` from/to `wb_esc_uart`
- [ ] Wire `pc_rx_data`/`pc_rx_valid` from USB-UART byte stream (sniffer feed)
- [ ] Wire `pad_motor[3:0]` to `o_motor1..4` inout pads in board wrapper
- [ ] Wire `mux_sel`/`mux_ch` to `fcsp_io_engines` observability/status

**Testbench tasks** (`sim/cocotb/test_serial_dshot_mux.py`):
- [ ] Default state: DShot mode, write DShot pattern, verify motor pin toggles correctly
- [ ] Mode switch: write `0x0020[0]=1`, verify pin switches to serial path in 1 cycle
- [ ] Channel select: write each `mux_ch` (0–3), verify correct motor pin is selected
- [ ] Force-low: assert `[4]`, verify selected motor pin held low; deassert, verify release
- [ ] MSP sniffer: inject `$M<\xF5` header via `pc_rx_data`; verify auto-bridge triggers
- [ ] Global tristate: verify 1-cycle tristate on mode change (no glitch on unselected pins)
- [ ] `SIM_CONTROL` override: use `tb_mux_force_en` to override selection in sim

---

### IP-6 — Wishbone IO Subsystem + fcsp_wishbone_master Integration

**Missing**: `fcsp_wishbone_master.sv` exists but is not wired into `fcsp_offloader_top`.
The Wishbone mux/decoder tying all IO slaves together does not exist in this repo.

**Source files to reference**:
- `src/wb_mux_4.v`, `src/wb_mux_5.v`, `src/wb_mux_6.v` — legacy WB address muxes
- `verilog-wishbone/rtl/` — generic WB fabric blocks (optional reuse)

**Implementation tasks**:
- [ ] Create `rtl/io/wb_io_bus.sv`: Wishbone address decoder/mux connecting:
  - `0x40000300` → `wb_dshot_controller`
  - `0x40000400` → `wb_serial_dshot_mux`
  - `0x40000600` → `wb_neoPx`
  - `0x40000900` → `wb_esc_uart`
  - `0x40000000` → `pwmdecoder_wb` (PWM read-only space)
- [ ] Replace `fcsp_serv_bridge` in `fcsp_offloader_top.sv` with `fcsp_wishbone_master`
  - Wire `fcsp_wishbone_master` WB master ports to `wb_io_bus` slave port
  - Wire CONTROL RX/TX streams from router and TX arbiter
- [ ] Update `fcsp_io_engines.sv` to instantiate all real IO slaves and expose WB ports
- [ ] Verify `HELLO` + `GET_CAPS` ops through `fcsp_wishbone_master` (already stubbed in WB master)
- [ ] Verify `READ_BLOCK`/`WRITE_BLOCK` decode through WB master into each IO slave

**Testbench tasks** (`sim/cocotb/test_wb_io_bus.py`):
- [ ] Write/read each slave at correct absolute address; verify correct slave responds
- [ ] Out-of-range address: verify no ack hang (bus error or timeout)
- [ ] Back-to-back transactions to different slaves: verify no contention
- [ ] E2E: FCSP CONTROL `WRITE_BLOCK` → `fcsp_wishbone_master` → WB bus → DShot register update

---

### Integration Milestone Gates (in order)

- [ ] **M1**: IP-1 (DShot) + IP-5 (Mux) ported and block-tested → motor pins driven from DShot
- [ ] **M2**: IP-4 (ESC UART) + IP-5 (Mux) + ESC_SERIAL CH 0x05 wired → ESC passthrough end-to-end
- [ ] **M3**: IP-2 (NeoPixel) ported and block-tested → NeoPixel pin functional
- [ ] **M4**: IP-3 (PWM Decoder) ported and block-tested → RC input readable via Wishbone
- [ ] **M5**: IP-6 (WB bus + WB master integration) complete → `fcsp_wishbone_master` is active control path
- [ ] **M6**: All blocks integrated in `fcsp_tangnano9k_top` → `tang9k-build` passes timing
- [ ] **M7**: `sim-test-all-strict` passes with all new cocotb block tests included
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

**Simulation test** (`sim/cocotb/test_e2e_version_poll.py` or inline in harness):
- [ ] Send FCSP `READ_BLOCK(0x40000000)` frame into `i_usb_rx_*`
- [ ] Verify response frame on `o_usb_tx_*` contains `0xFC500002`
- [ ] Repeat N times; verify all responses match, zero CRC errors, zero timeouts
- [ ] Verify link-status counters (frame_done, no overflow) on status outputs

**Depends on**: IP-6 (WB master + bus wired), WHO_AM_I register mapped in address decoder

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
