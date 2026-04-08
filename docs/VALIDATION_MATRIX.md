# Validation Matrix

This matrix defines reproducible checks for protocol/runtime milestones.

## How the test system works

Validation is split into two layers that run through `sim/Makefile` and are
exposed as CMake targets in `sim/CMakeLists.txt`.

1. **Python protocol tests (`pytest`)**
	 - Fast semantic checks against the Python FCSP model.
	 - Command path: `sim-test-python` -> `make -C sim test-python` -> `pytest -q tests`

2. **RTL tests (`cocotb + Verilator`)**
	 - Cycle-accurate checks of parser/router/top-level behaviors.
	 - Command path: `sim-test-*` -> `make -C sim <target>` -> cocotb/Verilator run
	 - Cocotb tests are module-targeted via `TOPLEVEL`, `COCOTB_TEST_MODULES`, and
		 `VERILOG_SOURCES` in `sim/Makefile`.

Execution policy:

- Run from repository root unless noted.
- CMake `sim-test-all` currently expands to:
	1) python tests, 2) FCSP smoke cocotb (parser + tx-arbiter),
	3) teaching/example cocotb.
- Top-level integration suites are run explicitly with:
	- `sim-test-top-cocotb`
	- `sim-test-top-cocotb-experimental`

## Required CI gates

| Gate | Command | Expected |
|---|---|---|
| Docs consistency | `bash scripts/check_docs_consistency.sh` | exit code 0 |
| FCSP smoke cocotb | `cd sim && make test-fcsp-smoke-cocotb` | all tests pass |
| Serial mux cocotb | `cd sim && make test-serial-mux-cocotb` | all tests pass |

Equivalent CMake-oriented flow:

- `cmake --build build/cmake --target sim-test-cocotb`
- `cmake --build build/cmake --target sim-test-all`

## Suggested pre-merge local checks

| Area | Command | Purpose |
|---|---|---|
| Core parser path | `cd sim && make test-cocotb` | parser seam correctness |
| TX arbiter | `cd sim && make test-tx-arbiter-cocotb` | arbitration behavior |
| Top integration | `cd sim && make test-top-cocotb` | end-to-end top-level sanity |

## Suite-to-coverage mapping

| Suite | Makefile target | DUT | Tests | Primary intent |
|-------|----------------|-----|-------|----------------|
| Python FCSP model | `test-python` | N/A | 26 | Protocol codec, command adapter, HW script sim |
| Parser cocotb | `test-cocotb` | `fcsp_parser` | Various | Frame sync/resync, header parsing, payload length guardrails |
| Top-level cocotb | `test-top-cocotb` | `fcsp_offloader_top` | 6 | CONTROL routing, control-response pathing, CRC drop, channel isolation |
| Experimental top E2E | `test-top-cocotb-experimental` | `fcsp_offloader_top` | 2 | ESC passthrough routing, MSP bypass multi-message |
| TX FIFO | `test-tx-fifo-cocotb` | `fcsp_tx_fifo` | Various | FIFO buffering, metadata pass-through |
| TX Arbiter | `test-tx-arbiter-cocotb` | `fcsp_tx_arbiter` | Various | Priority arbitration (CTRL > ESC > DBG) |
| Serial Mux | `test-serial-mux-cocotb` | `wb_serial_dshot_mux` | 8 | DShot/serial mode, force-low, MSP sniffer, watchdog |
| LED Controller | `test-wb-led-cocotb` | `wb_led_controller` | Various | SET/CLEAR/TOGGLE register behavior |
| WB Master | `test-fcsp-wb-master-cocotb` | `fcsp_wishbone_master` | Various | READ/WRITE_BLOCK op decode, WB cycle generation |
| IO Bus | `test-wb-io-bus-cocotb` | `wb_io_bus` | 7 | Address decode, WHO_AM_I, all slave select, unmapped safety |
| DShot Output | `test-dshot-out-cocotb` | `dshot_out` | 4 | Pulse timing (DSHOT150/300/600), 64-bit param safety |
| NeoPixel | `test-wb-neopx-cocotb` | `wb_neoPx` | 4 | Pixel write, trigger, waveform timing |
| PWM Decoder | `test-pwmdecoder-cocotb` | `pwmdecoder` | 4 | Pulse width measurement |
| ESC UART | `test-wb-esc-uart-cocotb` | `wb_esc_uart` | 5 | TX ready/baud/start-bit/active/completion |
| E2E FCSP→WB→IO | `test-e2e-fcsp-wb-io-cocotb` | `fcsp_offloader_top` | 3 | Full FCSP READ_BLOCK WHO_AM_I, PING, HELLO |
| Teaching examples | `test-teaching-examples-cocotb` | Various | Various | Wishbone/AXIS reference patterns |
| HW scripts sim | `test-hw-scripts-sim` | N/A | Various | Python HW test scripts in sim mode |

### Aggregate gates

| Gate | Makefile target | Includes |
|------|----------------|----------|
| Smoke | `test-fcsp-smoke-cocotb` | parser + TX arbiter |
| All | `test-all` | Python + smoke + teaching |
| **All strict** | `test-all-strict` | All above + top + experimental + serial-mux + LED + WB-master + IO-bus + DShot + NeoPixel + PWM + ESC-UART + E2E-WB-IO |

**Current regression: 68 cocotb tests + 26 Python tests = 94 total, all passing.**

## Recommended full local validation run

For complete confidence (including top-level integration suites):

1. `cmake --build build/cmake --target sim-test-python`
2. `cmake --build build/cmake --target sim-test-cocotb`
3. `cmake --build build/cmake --target sim-test-top-cocotb`
4. `cmake --build build/cmake --target sim-test-top-cocotb-experimental`
5. `cmake --build build/cmake --target sim-test-teaching-examples`
6. `cmake --build build/cmake --target sim-test-all`
7. `cmake --build build/cmake --target sim-test-all-strict`

## Failure triage quick guide

- **If pytest fails** (`sim-test-python`):
	- Inspect Python protocol expectations first.
	- Re-check FCSP behavior against `docs/FCSP_PROTOCOL.md`.

- **If parser cocotb fails** (`sim-test-cocotb`):
	- Focus on parser/CRC framing seams before top-level investigation.

- **If top-level cocotb fails** (`sim-test-top-cocotb*`):
	- Investigate routing decisions (CONTROL vs non-CONTROL), control-bridge paths,
		and CRC gate interactions.

- **If teaching examples fail**:
	- Treat as interface/contract regressions in reference AXIS/Wishbone patterns.

## Evidence capture template

- Date/time:
- Commit SHA:
- Host OS:
- Python version:
- Verilator version:
- CMake configure command:
- Commands run (exact):
- Result summary (pass/fail per suite):
- Artifact/log paths (e.g., `sim/sim_build`, cocotb output, CI logs):
- Failure signatures (if any):
- Resolution/notes:
