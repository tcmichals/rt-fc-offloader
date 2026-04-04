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

1. Ensure venv tools are on `PATH` (for `cocotb-config`):
	- `PATH="$(pwd)/.venv/bin:$PATH"`
2. Run protocol simulator tests:
	- `make -C sim test-python`
3. Run parser block cocotb tests:
	- `make -C sim test-cocotb`
4. Run top-level cocotb smoke tests:
	- `make -C sim test-top-cocotb`
5. Run teaching micro-references:
	- `make -C sim test-wb-example-cocotb`
	- `make -C sim test-axis-example-cocotb`

Convenience aggregate targets:

- FCSP smoke suite:
	- `make -C sim test-fcsp-smoke-cocotb`
- Teaching micro-reference suite:
	- `make -C sim test-teaching-examples-cocotb`
- Full local regression:
	- `make -C sim test-all`
- Generate fit-evidence snapshot template:
	- `make -C sim fit-evidence-snapshot`
