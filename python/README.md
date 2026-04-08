# Python Utilities

## Environment (required for scripts/tests)

- Default Python environment for this repo is `./.venv`.
- Run scripts/tests with:
  - `./.venv/bin/python`
  - `./.venv/bin/pytest`
- For AI/automation workflows: assume `.venv` first for all Python execution unless explicitly overridden.

This directory groups Python tooling by purpose.

- `python/hw/` — direct hardware bring-up / exerciser scripts
  - `python/hw/hwlib/` — reusable FCSP transport + register/protocol helpers
- `python/tools/` — build/report tooling helpers

Current utilities:

- `python/hw/test_hw_neopixel.py`
  - FCSP serial hardware test and NeoPixel animation exerciser (built on `hwlib`).
- `python/hw/test_hw_switching.py`
  - FCSP mux/switching validation (serial↔dshot mode, channel select, optional break pulse) built on `hwlib`.
- `python/hw/test_hw_onboard_led_walk.py`
  - Separate on-board LED walker via `wb_led_controller` register block (requires `--led-base`).
- `python/hw/test_hw_version_poll.py`
  - Fast repeated `WHO_AM_I` checker with single-line live status output (`--port auto` by default; override with explicit `/dev/ttyUSB*` or `/dev/ttyACM*`).
- `python/hw/hwlib/fcsp_client.py`
  - Reusable FCSP CONTROL-channel client (`read_u32` / `write_u32`).
- `python/hw/hwlib/registers.py`
  - Shared address constants and protocol bitfield helpers (mux/rgbw).
- `python/tools/report_tang9k_build_summary.py`
  - Parses nextpnr logs and writes compile/timing summary artifacts.
