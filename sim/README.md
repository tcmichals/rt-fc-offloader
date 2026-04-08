# sim — FCSP verification harness

Simulation validates deterministic FCSP behavior before integration.

Two complementary benches are required:

1. RTL testbench: **Verilator + cocotb**
2. Protocol golden-model bench: **Python FCSP simulator**

## Verification policy

- Run block-level testbenches first, then subsystem/integration suites.
- Integration tests do not count as complete unless all required block-level suites are already passing.
- Keep Python simulator semantics aligned with `docs/FCSP_PROTOCOL.md`; treat it as a golden reference for frame/op/result behavior.

## Priority tests

1. frame parser noise-resync
2. CRC pass/fail + recovery
3. caps paging (`GET_CAPS`) behavior
4. passthrough safety transitions
5. cross-transport semantic equivalence (SPI profile vs serial/sim profile)

## Expected outputs

- pass/fail logs for each test group
- behavior snapshots for FCSP baseline regression checks
- clear defect reproduction notes for protocol regressions
- per-block pass reports (parser, CRC, router, FIFO, control dispatcher, block-IO)

## Layout

- `python_fcsp/` — FCSP protocol simulator/reference codec
- `tests/` — Python simulator unit tests
- `cocotb/` — cocotb RTL tests
- `rtl/` — temporary/bring-up RTL stubs for simulation wiring
- `Makefile` — common test entry points

## Local run flow

1. Install sim dependencies from `requirements.txt`.
2. Run Python protocol simulator tests.
3. Run cocotb/Verilator tests.
4. Keep both suites green before integration sign-off.

## Quickstart commands

From repo root:

1. Configure CMake:
	- `cmake -S . -B build/cmake`
2. Run protocol simulator tests:
	- `cmake --build build/cmake --target sim-test-python`
2b. Run python/hw script simulation-compatibility tests:
	- `cmake --build build/cmake --target sim-test-hw-scripts-sim`
3. Run parser block cocotb tests:
	- `cmake --build build/cmake --target sim-test-cocotb`
4. Run top-level cocotb integration tests (experimental):
	- `cmake --build build/cmake --target sim-test-top-cocotb`
5. Run teaching micro-reference suite:
	- `cmake --build build/cmake --target sim-test-teaching-examples`

Convenience aggregate targets:

- FCSP smoke suite:
	- `cmake --build build/cmake --target sim-test-cocotb`
	- `cmake --build build/cmake --target sim-test-cocotb`
- Python hardware-script compatibility suite:
	- `cmake --build build/cmake --target sim-test-hw-scripts-sim`
- Teaching micro-reference suite:
	- `cmake --build build/cmake --target sim-test-teaching-examples`
- Full local regression:
	- `cmake --build build/cmake --target sim-test-all`
- Experimental top-level integration suite:
	- `cmake --build build/cmake --target sim-test-top-cocotb`
- Generate fit-evidence snapshot template:
	- `cmake --build build/cmake --target sim-fit-evidence`
