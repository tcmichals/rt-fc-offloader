# Engineering Log

This file is a lightweight running history of what we ran into, what we decided, and what was verified.

Use it for:

- design decisions that should not get lost in chat history
- bring-up discoveries
- protocol/RTL gotchas
- validation milestones
- known pain points and why choices were made

Historical note:

- Older entries may reference SERV/SERV8 terms from prior exploration milestones.
- Those terms are intentionally preserved in this log for historical traceability.
- Current project direction is no active embedded soft-CPU dependency; treat SERV/SERV8 references here as legacy context, not current architecture requirements.

Newest entries should be added near the top.

---

## 2026-04-05 — Teaching focus: pure register writes for control; timing stays in RTL

- Captured and reinforced a core teaching rule for this repo:
  - control software should use **pure Wishbone register transactions** (`write/read + ack`)
  - cycle-accurate timing generation stays inside dedicated RTL engines
- `wb_led_controller.sv` is now explicitly treated as a classroom example of this split:
  - parameterized control surface (`LED_WIDTH`)
  - simple register map semantics (`OUT`, `TOGGLE`, `CLEAR`, `SET`)
  - no software-managed timing loops
- Added matching teaching context for NeoPixel paths:
  - FCSP seam (`fcsp_io_engines`) remains scaffold-level behavior in current integration
  - legacy NeoPixel engine path (`wb_neoPx` + `sendPx_axis_flexible`) is the full timing-generator reference
- External comparison pass (Horton + splinedrive) confirmed the same architectural lesson:
  - ingress/control API should be simple and deterministic
  - waveform timing should be isolated in RTL state machines/counters

Why it matters:

- keeps control code portable and easy to reason about
- keeps nanosecond-level protocol behavior deterministic in hardware
- improves classroom value by clearly separating control-plane vs timing-engine responsibilities

---

## 2026-04-04 — Tang9K board build/program scaffold added

- Added board wrapper:
  - `rtl/fcsp/boards/tangnano9k/fcsp_tangnano9k_top.sv`
- Added Tang9K constraints/timing files:
  - `rtl/fcsp/boards/tangnano9k/tang9k.cst`
  - `rtl/fcsp/boards/tangnano9k/tang9k.sdc`
- Added build/program scripts:
  - `scripts/build_tang9k_oss.sh`
  - `scripts/program_tang9k.sh`
- Added programming doc:
  - `docs/TANG9K_PROGRAMMING.md`

Pin assignments were transcribed from prior Tang9K pinout/constraints references in the legacy project lineage to preserve established wiring conventions.

This milestone closes the repo-level gap from "sim-only" to a concrete Tang9K bitstream/program entrypoint.

Validation status:

- New board wrapper parses cleanly with Verilator lint (non-fatal warning mode).
- Existing top-level FCSP cocotb smoke remains green: `TESTS=3 PASS=3 FAIL=0`.
- `build_tang9k_oss.sh` now reports missing toolchain dependencies explicitly (for this environment: `yosys` missing).
- `program_tang9k.sh` reports explicit preconditions (`bitstream not found`, `openFPGALoader` missing) instead of silent failure.

---

## 2026-04-04 — CONTROL responses now exit as real FCSP wire frames

- Added `rtl/fcsp/fcsp_tx_framer.sv`
  - captures one response payload frame
  - emits `sync + version + flags + channel + seq + payload_len + payload + crc16`
  - computes CRC16/XMODEM on the transmitted header/payload bytes
- Updated `fcsp_offloader_top.sv` so the CONTROL response path is now:
  - `SERV response -> fcsp_tx_fifo -> fcsp_tx_framer -> USB/SPI TX seam`
- Updated `fcsp_serv_bridge.sv` to preserve CONTROL response metadata:
  - response channel fixed to CONTROL (`0x01`)
  - response flag fixed to `ACK_RESPONSE` (`0x02`)
  - response `seq` mirrors the completed request
  - bridge now enforces one in-flight CONTROL request/response association
- Updated top-level cocotb smoke coverage so TX expectations are now full FCSP frames, not raw payload bytes.
- Tightened cocotb source-driver helpers to sample `ready` before the handshake edge; this fixed a false stall on the last response byte caused by post-edge `ready` observation.

Validation status:

- `make -C sim test-top-cocotb`: `3 passed`
- `/media/tcmichals/projects/pico/flightcontroller/rt-fc-offloader/.venv/bin/python -m pytest -q sim/tests/test_fcsp_codec.py`: `12 passed`

Why it matters:

- closes the biggest remaining top-level protocol seam on the CONTROL path
- moves egress behavior from scaffold/raw bytes to real FCSP framing
- provides a reusable TX framing block for later multi-channel scheduler integration

---

## 2026-04-04 — Snapshot now supports single-root multi-config report discovery

- Added `GOWIN_REPORT_ROOT` to `scripts/generate_fit_evidence_snapshot.sh`
- The script now auto-discovers per-config Gowin report directories under one build root using common aliases:
  - min: `cfg_min_control`, `min_control`, `control_only`, `control-only`
  - mid: `cfg_mid_stream`, `mid_stream`, `control_telemetry`, `control-telemetry`, `telemetry`
  - full: `cfg_full_target`, `full_target`, `full_path`, `full-path`
- Discovery precedence is now:
  1. explicit `CFG_*_REPORT_DIR`
  2. explicit `CFG_*_PNR_RPT` / `CFG_*_TIMING`
  3. derived config dir under `GOWIN_REPORT_ROOT`
- Updated follow-up guidance to mention `GOWIN_REPORT_ROOT` as a valid remediation path when reports are missing.

Validation status:

- Built a synthetic 3-config tree from a real Gowin `impl/pnr/` sample.
- Verified a snapshot generated with only `GOWIN_REPORT_ROOT` populated:
  - `cfg_min_control` row auto-filled
  - `cfg_mid_stream` row auto-filled
  - `cfg_full_target` row auto-filled

---

## 2026-04-04 — Live fit snapshot now includes guidance sections and uses stable sim paths

- Fixed `sim/Makefile` to anchor RTL source paths from `$(CURDIR)` / repo root instead of caller-dependent `$(PWD)`
  - this removed false live-snapshot failures like `No rule to make target .../../rtl/...`
- Snapshot script now auto-fills:
  - `High-impact modules`
  - `Follow-up actions`
- Guidance heuristics distinguish between:
  - missing report data
  - simulation-gate failures
  - true negative-WNS timing failures
- Verified end-to-end with:
  - `RUN_SIM_GATE=1`
  - `CFG_MIN_CONTROL_REPORT_DIR=<real Gowin impl/pnr>`
- Verified generated artifact:
  - simulation evidence gate = `PASS`
  - `cfg_min_control` row = `PASS`
  - critical paths rendered
  - follow-up actions narrowed to remaining missing configs (`cfg_mid_stream`, `cfg_full_target`)

---

## 2026-04-03 — Fit snapshot now auto-discovers Gowin report dirs and extracts top critical paths

- Added optional convenience env vars:
  - `CFG_MIN_CONTROL_REPORT_DIR`
  - `CFG_MID_STREAM_REPORT_DIR`
  - `CFG_FULL_TARGET_REPORT_DIR`
- When set to a Gowin `impl/pnr/` directory, the snapshot script auto-discovers:
  - the first matching `*.rpt.txt`
  - the first matching `*.timing_paths`
- The snapshot now auto-fills the `Critical paths (top 3)` section from Gowin timing data
  - summary format: `start_signal -> end_signal (delay=X ns, slack=Y ns)`
- Added overall `Fit gate result` roll-up logic:
  - `FAIL` if any config row fails
  - `PASS` only if all config rows pass
  - `TBD` otherwise
- Verified with a real Gowin `impl/pnr/` directory:
  - `cfg_min_control` auto-filled resource/timing columns
  - critical paths rendered as `clk_ibuf -> count_28_s0`, etc.

---

## 2026-04-03 — Gowin synth/P&R auto-fill wired into fit evidence snapshot

- Added 7 bash functions to `scripts/generate_fit_evidence_snapshot.sh`:
  - `parse_gowin_lut`, `parse_gowin_ff`, `parse_gowin_bram`, `parse_gowin_dsp`
  - `parse_gowin_wns`, `parse_gowin_fmax`, `compute_row_result`
- Report file paths supplied via env vars per config:
  - `CFG_MIN_CONTROL_PNR_RPT` / `CFG_MIN_CONTROL_TIMING`
  - `CFG_MID_STREAM_PNR_RPT` / `CFG_MID_STREAM_TIMING`
  - `CFG_FULL_TARGET_PNR_RPT` / `CFG_FULL_TARGET_TIMING`
- If files are absent: table cells default to TBD (backward compatible)
- Fmax computed as `1000 / critical_path_arrival_ns` from Gowin `.timing_paths` line 4
- WNS taken directly from `.timing_paths` line 3
- Result logic: PASS when sim gate=PASS and WNS≥0; FAIL when timing violated; TBD otherwise
- Smoke-tested with real GW5A-25 PnR reports; confirmed LUT=29, FF=29, Fmax=177.2 MHz, WNS=16.931 ns
- `docs/TANG9K_FIT_GATE.md` updated with usage instructions and env var reference

---

## 2026-04-03 — Fit snapshots now include raw log references per suite

- Extended live snapshot output to include direct log paths for:
  - parser cocotb
  - top-level cocotb
  - Wishbone micro-reference cocotb
  - AXIS micro-reference cocotb
- Live logs are stored under:
  - `docs/fit_reports/logs/`
- Verified generated snapshot includes log references:
  - `docs/fit_reports/fit_evidence_20260403_230224Z.md`

Why it matters:

- gives reviewers immediate traceability from summary status to raw simulator output
- improves auditability for Tang9K fit-signoff artifacts

---

## 2026-04-03 — Live fit evidence snapshot now auto-fills sim gate results

- Enhanced `generate_fit_evidence_snapshot.sh` with optional live mode (`RUN_SIM_GATE=1`):
  - runs parser, top-level, Wishbone example, and AXIS example cocotb targets
  - parses `TESTS/PASS/FAIL` summaries from logs
  - auto-fills simulation evidence lines in the generated report
  - sets `Simulation evidence gate` and `cfg_min_control` status based on run outcomes
- Added make target:
  - `make -C sim fit-evidence-snapshot-live`

Verification status:

- Generated live artifact successfully:
  - `docs/fit_reports/fit_evidence_20260403_222758Z.md`
- Live artifact contains populated simulation evidence and `Simulation evidence gate: PASS`.

Why it matters:

- turns fit evidence from a manual template into a reproducible, measurable artifact
- reduces copy/paste mistakes in milestone reporting
- keeps Tang9K fit-signoff workflow tied to current functional simulation state

---

## 2026-04-03 — Fit evidence snapshot automation added

- Added generator script:
  - `scripts/generate_fit_evidence_snapshot.sh`
- Added make target:
  - `make -C sim fit-evidence-snapshot`
- Added docs references in:
  - `docs/TANG9K_FIT_GATE.md`
  - `sim/README.md`

Verification status:

- Generated artifact successfully:
  - `docs/fit_reports/fit_evidence_20260403_222624Z.md`

Why it matters:

- creates a consistent per-milestone evidence artifact
- ties simulation gate status and hardware-fit placeholders into one report
- improves traceability for Tang9K fit-signoff decisions

---

## 2026-04-03 — Simulation evidence gate aggregate targets verified

- Ran new aggregate FCSP smoke target:
  - `make -C sim test-fcsp-smoke-cocotb`
  - parser cocotb: `3 passed`
  - top-level cocotb: `3 passed`
- Ran new aggregate teaching target:
  - `make -C sim test-teaching-examples-cocotb`
  - Wishbone example cocotb: `2 passed`
  - AXIS example cocotb: `3 passed`

Operational note:

- shell-style `PATH=... cmd1 && cmd2` scopes `PATH` only to `cmd1`.
- use `export PATH=... && cmd1 && cmd2` for multi-command runs that need `cocotb-config` consistently.

Why it matters:

- confirms the simulation pre-fit gate is runnable and green
- keeps fit-signoff discipline tied to verified functional smoke coverage

---

## 2026-04-03 — Simulation UX tightened for reproducible local runs

- Updated `sim/README.md` quickstart with explicit runnable targets for:
  - parser cocotb
  - top-level cocotb smoke
  - Wishbone micro-reference
  - AXIS micro-reference
- Added explicit note to include `.venv/bin` on `PATH` so `cocotb-config` resolves predictably.
- Replaced deprecated `MODULE=` make usage with `COCOTB_TEST_MODULES=` in `sim/Makefile` test targets.

Validation status:

- `test-axis-example-cocotb`: `3 passed`
- `test-wb-example-cocotb`: `2 passed`

Why it matters:

- lowers onboarding friction for fresh environments
- removes noisy deprecation warnings from normal simulation flow
- keeps teaching examples easy to run and verify

---

## 2026-04-03 — FCSP is the required path; Pico is optional legacy context

- Clarified project direction: this repository does **not** require Pico/MSP to progress.
- Pico/MSP references remain for migration history and ecosystem context only.
- Documentation updated so FCSP-on-FPGA is the explicit baseline path.

Why it matters:

- removes ambiguity about implementation dependency
- keeps team effort focused on FCSP parser/router/CRC/FIFO/control integration

## 2026-04-03 — No big FPGA assumption (small-FPGA-first)

- Added explicit constraint that the architecture should not require a large FPGA.
- Tang9K-class viability remains the guiding target.
- Preferred resource allocation remains:
  - deterministic RTL datapaths first
  - minimal control-plane CPU footprint

Why it matters:

- prevents silent scope creep toward oversized-device assumptions
- keeps design decisions aligned with practical low-resource deployment

---

## 2026-04-03 — Readability and snippet-lift value are explicit project requirements

- This repo is not only meant to work; it is also meant to help engineers learn.
- An important requirement is that people can read a small part of the design,
  understand it, and **lift ideas or code snippets** into a related project.
- That pushes the design toward:
  - small modules
  - stable interfaces
  - wrapper-first reuse
  - per-block / per-device tests
  - short, focused documentation sections

Why it matters:

- improves classroom/reference value
- makes retargeting nearby designs easier
- reduces the chance that useful ideas are trapped inside a monolithic top-level
  implementation

## 2026-04-03 — Educational / classroom value depends on stable standard interfaces

- We want this repo to help engineers design related systems, not just solve one
  narrow implementation.
- That means the design should be understandable as a **teaching example** as
  well as a working offloader.
- Current interface direction is:
  - **AXIS-style streams** for FCSP datapaths
  - **Wishbone** for device/register-oriented peripherals when a standard bus is useful
- This split is intentional because it teaches two common FPGA patterns clearly:
  - streaming pipelines
  - bus-attached devices/register maps

Testing implication:

- each Wishbone-attached device should eventually have its own unit testbench
- stream blocks should keep their own block-level cocotb tests

Why it matters:

- makes reuse/retargeting easier for nearby designs
- gives engineers a cleaner mental model of where to change edges vs. core datapath
- improves the repo's value as a classroom/reference project

## 2026-04-03 — Reused the existing CRC16/XMODEM block via a buffered CRC gate

- We did **not** create a new CRC algorithm block for FCSP receive validation.
- Instead, we reused the existing `fcsp_crc16` / `fcsp_crc16_core_xmodem` path and wrapped it with a small `fcsp_crc_gate` stage.
- The gate buffers one parsed frame payload, reconstructs the FCSP CRC input stream (`version`, `flags`, `channel`, `seq`, `payload_len`, `payload`), and compares against the parser-captured wire CRC.
- Only CRC-clean frames are released downstream to the router.
- Bad CRC frames are dropped before they can reach the control endpoint.

Why it matters:

- preserves legacy-proven CRC logic instead of cloning checksum behavior in a second implementation
- keeps reuse aligned with the earlier RTL reuse plan
- gives the top-level FCSP path a real validation stage before CONTROL dispatch

Validation status:

- parser cocotb: `3 passed`
- top-level cocotb smoke: `3 passed`
- verified case: corrupted CONTROL frame does **not** reach the control endpoint

## 2026-04-03 — Historical note: prior soft-CPU exploration (superseded)

- At that point in exploration, a small control-plane CPU was being considered, not as the FCSP byte-stream engine.
- RTL still owns the hot path:
  - sync detect
  - header/length parse
  - CRC16/XMODEM check
  - channel routing
  - FIFO buffering
  - timing-critical IO engines
- The control endpoint would only see **validated CONTROL payloads** after the hardware fast path had already done the heavy lifting.

Historical mode note:

- A very small soft-CPU profile was being evaluated at the time for control-plane work:
  - op decode
  - policy/state transitions
  - result code generation
  - register-window / IO-space orchestration

Why this was preferred over something larger like VexRiscv:

- VexRiscv is a good core, but it is a **bigger and more feature-rich** CPU than this control-plane role currently needs.
- In this architecture, we do **not** want the CPU spending area or cycles on:
  - raw SPI byte handling
  - CRC math
  - framing/resync
  - DSHOT or other bit-timed engines
- Those jobs are intentionally kept in RTL in the current design direction.

Tang9K fit note:

- This choice is aligned with the goal of keeping the design viable on a **Tang9K-class** target, where area pressure matters.
- The point of the historical comparison was that **a smaller control CPU plus RTL offload** looked attractive at the time.
- Exact fit still needs synthesis / place-and-route confirmation once more of the datapath is fully wired in, but the architectural direction is deliberately chosen to keep that target plausible.

Why it matters:

- preserves FPGA area for deterministic data-path logic
- keeps control-plane firmware simple and bounded
- avoids moving fast-path protocol work into software
- supports the project goal of a compact FCSP offloader architecture that can still make sense on small Gowin boards

## 2026-04-03 — FCSP stream semantics clarified

- FCSP is a **streaming / multiplexed** protocol, not strict send-and-wait.
- Multiple FCSP frames may appear back-to-back on the wire.
- `CONTROL`, `TELEMETRY`, `FC_LOG`, and `DEBUG_TRACE` traffic may be intermixed.
- This reinforced the architectural direction toward parser → router → FIFO → scheduler style hardware.

Why it matters:

- supports background logs/telemetry without stalling control traffic
- maps well to FPGA stream pipelines and AXIS-style internal handshakes

---

## 2026-04-03 — Parser cocotb failure root cause was testbench sampling phase

- `fcsp_parser` cocotb tests initially reported missing `frame_done` / `len_error` pulses.
- The parser logic itself was close; the testbench was sampling one-cycle pulses at the wrong simulator phase.
- Fix direction: sample outputs in `ReadOnly`, then advance out of read-only phase before driving next inputs.

Why it matters:

- avoids chasing false RTL bugs caused by cocotb scheduling
- establishes a more reliable pattern for future block-level cocotb tests

Validation status:

- parser cocotb tests pass after timing fix
- Python sim tests pass (`15 passed`)

---

## 2026-04-03 — FCSP payload cap fixed at 512 bytes for this profile

- FCSP wire field remains `u16` for `payload_len`.
- Project implementation profile currently caps payloads at `512` bytes.
- Maximum FCSP frame size at this cap is `522` bytes.

Why it matters:

- deterministic buffer sizing
- simpler parser/FIFO sizing in early FPGA implementation

---

## 2026-04-03 — Hot path ownership split settled

- Raw transport byte handling stays in RTL.
- A control endpoint is **not** in the raw SPI byte hot path.
- The control endpoint handles validated CONTROL-plane frames and policy/state transitions.

Why it matters:

- avoids firmware byte-rate bottlenecks
- keeps frame parsing, CRC, and routing deterministic
- allows mixed traffic to continue flowing while control logic runs separately

---

## 2026-04-03 — FPGA architecture differs intentionally from Pico MSP/PIO bring-up path

- Pico/MSP is the quick bring-up and ESC-config validation path.
- That path has already been proven with a **single ESC + motor**.
- FPGA/FCSP target architecture is different by design:
  - stream-oriented and multiplexed
  - parser/router/FIFO based
  - better suited for mixed traffic and deterministic IO timing

Why it matters:

- prevents accidental pressure to make FPGA internals mirror the Pico design
- keeps bring-up path and runtime architecture conceptually separate

See also:

- `docs/FPGA_VS_PICO_PIO_NOTES.md`

---

## 2026-04-03 — Internal interface direction: AXIS-style, not full AXI everywhere

- Decision direction: use AXIS-like valid/ready streams internally.
- Keep external boundaries lightweight (SPI frontend, USB serial shim, SERV seam).
- Do not pull in full AXI infrastructure unless needed for specific IP interop.

Why it matters:

- fits FCSP stream model
- simplifies router/FIFO/TX mux composition
- avoids unnecessary protocol overhead at boundaries
