# Tang9K Fit Gate

This document defines the **small-FPGA-first** acceptance gate for `rt-fc-offloader`.

Goal:

- keep the FCSP architecture viable on **Tang9K-class** devices
- avoid silent drift toward "needs a bigger FPGA"

## Policy

- Tang9K-class fit is a primary design constraint.
- New features should include a quick resource/timing impact note.
- If a change materially increases area/timing risk, it must include mitigation options.

## Required evidence per integration milestone

For each milestone configuration (minimum: `control-only`, `control+telemetry`, `full-path`), capture:

0. simulation smoke evidence (before synthesis/P&R)
1. synthesis resource report (LUT/FF/BRAM/DSP)
2. place-and-route timing report (WNS/TNS and achieved Fmax)
3. top 3 critical paths summary
4. notes on high-impact modules

### Simulation evidence gate (pre-fit)

Before recording hardware fit numbers, require a clean simulation baseline:

- `make -C sim test-fcsp-smoke-cocotb`
  - parser block cocotb
  - top-level FCSP smoke cocotb
- `make -C sim test-teaching-examples-cocotb`
  - Wishbone micro-reference cocotb
  - AXIS micro-reference cocotb

Rationale:

- prevents spending synthesis/P&R cycles on known-broken logic
- keeps architectural examples continuously validated while the core evolves

### Snapshot artifact command

Generate a fit-evidence snapshot template (for PRs/logs):

- `make -C sim fit-evidence-snapshot`

Generate a snapshot with simulation evidence auto-filled:

- `make -C sim fit-evidence-snapshot-live`

Artifact output path:

- `docs/fit_reports/fit_evidence_<UTC timestamp>.md`
- Live mode also records per-suite raw logs under:
  - `docs/fit_reports/logs/`

### Synthesis / P&R auto-fill

After running Gowin synthesis and P&R, point the snapshot script at the
report files via environment variables to auto-populate LUT/FF/BRAM/DSP/Fmax/WNS:

```
export CFG_MIN_CONTROL_PNR_RPT=<path-to>/impl/pnr/<project>.rpt.txt
export CFG_MIN_CONTROL_TIMING=<path-to>/impl/pnr/<project>.timing_paths
export CFG_MID_STREAM_PNR_RPT=<path-to-mid>/impl/pnr/<project>.rpt.txt
export CFG_MID_STREAM_TIMING=<path-to-mid>/impl/pnr/<project>.timing_paths
export CFG_FULL_TARGET_PNR_RPT=<path-to-full>/impl/pnr/<project>.rpt.txt
export CFG_FULL_TARGET_TIMING=<path-to-full>/impl/pnr/<project>.timing_paths
make -C sim fit-evidence-snapshot-live
```

Or, if you already have a single Gowin `impl/pnr/` directory for a config, you can
point the script at the directory and let it auto-discover `*.rpt.txt` and
`*.timing_paths`:

```
export CFG_MIN_CONTROL_REPORT_DIR=<path-to>/impl/pnr
export CFG_MID_STREAM_REPORT_DIR=<path-to-mid>/impl/pnr
export CFG_FULL_TARGET_REPORT_DIR=<path-to-full>/impl/pnr
make -C sim fit-evidence-snapshot-live
```

If you have a conventional multi-config build tree, you can point the script at
one root and let it auto-discover config report dirs by name:

```
export GOWIN_REPORT_ROOT=<build-root>
make -C sim fit-evidence-snapshot-live
```

Recognized config directory aliases under `GOWIN_REPORT_ROOT` include:

- `cfg_min_control`, `min_control`, `control_only`, `control-only`
- `cfg_mid_stream`, `mid_stream`, `control_telemetry`, `control-telemetry`, `telemetry`
- `cfg_full_target`, `full_target`, `full_path`, `full-path`

Report parsing:

- `*.rpt.txt` — Gowin PnR summary text; extracts Logic (LUT+ALU), Register (FF), Block SRAM, Multiplier counts
- `*.timing_paths` — Gowin critical path data; line 3 = WNS (ns), line 4 = critical path delay → Fmax = 1000/delay (MHz)
- `*_REPORT_DIR` vars — optional convenience mode; auto-discovers the first matching `*.rpt.txt` and `*.timing_paths` under that config directory
- `GOWIN_REPORT_ROOT` — optional multi-config convenience mode; auto-discovers per-config report dirs from common config directory names
- Result column: PASS when sim gate = PASS and WNS ≥ 0; FAIL when timing violated; TBD when reports not yet available
- `Critical paths (top 3)` — auto-filled from the first three `SETUP` blocks in Gowin `*.timing_paths`
- `High-impact modules` — inferred from repeated start/end signals appearing in those critical paths
- `Follow-up actions` — auto-generated from missing reports, sim-gate status, and timing failure conditions

## Pass/fail rule

A milestone is **fit-pass** only when:

- simulation evidence gate is green
- bitstream builds successfully for Tang9K target flow
- timing is met for the active profile clock targets
- resource usage leaves practical headroom for board-level integration

If any gate fails:

- classify root cause (`area`, `timing`, or `both`)
- add corrective plan with owner and expected closure milestone

## Suggested run matrix

- `cfg_min_control`
  - parser + CRC gate + CONTROL route + SERV bridge
- `cfg_mid_stream`
  - min + telemetry/log path stubs active
- `cfg_full_target`
  - all intended runtime channels and egress framing

## Reporting template

Use this table in milestone PRs/log entries:

| Config | Sim Gate | LUT | FF | BRAM | DSP | Fmax (MHz) | WNS | Result |
|---|---|---:|---:|---:|---:|---:|---:|---|
| cfg_min_control | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| cfg_mid_stream | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| cfg_full_target | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |

## Notes

- This gate does not force premature optimization; it forces **continuous fit visibility**.
- Architectural preference remains: deterministic RTL datapath first, minimal control CPU footprint.
