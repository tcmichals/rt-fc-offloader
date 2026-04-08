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

| Suite | CMake target | Underlying make target | Primary intent |
|---|---|---|---|
| Python FCSP model | `sim-test-python` | `test-python` | Protocol semantics and regression safety in Python model |
| Parser cocotb | `sim-test-cocotb` | `test-cocotb` | Frame sync/resync, header parsing, payload length guardrails |
| Top-level cocotb | `sim-test-top-cocotb` | `test-top-cocotb` | CONTROL routing, control-response pathing, CRC drop behavior |
| Experimental top E2E | `sim-test-top-cocotb-experimental` | `test-top-cocotb-experimental` | ESC passthrough/E2E behavior under top-level integration |
| Teaching examples | `sim-test-teaching-examples` | `test-teaching-examples-cocotb` | Wishbone/AXIS reference patterns and educational examples |
| Full local regression | `sim-test-all` | `test-all` | Python + smoke cocotb + teaching examples |
| Strict local regression | `sim-test-all-strict` | `test-all-strict` | Full regression plus top-level/experimental/serial-mux integration |

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
