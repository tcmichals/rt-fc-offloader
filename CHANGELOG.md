# Changelog

All notable changes to this project will be documented in this file.

The format follows Keep a Changelog principles.

## [Unreleased]

### Added
- `wb_serial_dshot_mux` watchdog-based serial inactivity fallback behavior.
- Comprehensive cocotb testbench for `wb_serial_dshot_mux` with full feature coverage.
- `sim` Make target: `test-serial-mux-cocotb`.
- CI workflow with required simulation and docs consistency gates.
- Repository governance files: CODEOWNERS, PR template, CONTRIBUTING guide.
- Docs consistency script: `scripts/check_docs_consistency.sh`.

### Changed
- Core FCSP docs aligned to current RTL integration behavior:
  - control path status
  - channel definitions
  - absolute + relative address notation

