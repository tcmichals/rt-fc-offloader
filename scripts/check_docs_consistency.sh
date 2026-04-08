#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CORE_DOCS=(
  "docs/SYSTEM_OVERVIEW.md"
  "docs/FCSP_PROTOCOL.md"
  "docs/TOP_LEVEL_BLOCK_DIAGRAM.md"
  "docs/FPGA_BLOCK_DESIGN.md"
  "docs/TANG9K_FIT_GATE.md"
)

for f in "${CORE_DOCS[@]}"; do
  [[ -f "$f" ]] || { echo "missing required doc: $f"; exit 1; }
done

# Guardrails against stale architecture language that conflicts with current RTL top integration.
BANNED='CPU-less|Zero-CPU|Zero BRAM|Replaces the SERV CPU|Ingress Arbiter'
if grep -RinE "$BANNED" "${CORE_DOCS[@]}"; then
  echo
  echo "❌ docs consistency check failed: stale terminology found in core docs"
  exit 1
fi

# FCSP channel table must define all router channels.
for ch in 0x01 0x02 0x03 0x04 0x05; do
  if ! grep -q "$ch" docs/FCSP_PROTOCOL.md; then
    echo "❌ docs consistency check failed: missing channel $ch in docs/FCSP_PROTOCOL.md"
    exit 1
  fi
done

# Address aliasing must remain explicit for serial mux register.
if ! grep -q '0x40000400' docs/FCSP_PROTOCOL.md || ! grep -q '0x0020' docs/FCSP_PROTOCOL.md; then
  echo "❌ docs consistency check failed: expected absolute+relative address notation not found"
  exit 1
fi

echo "✅ docs consistency checks passed"
