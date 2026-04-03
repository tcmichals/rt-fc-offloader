#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY_SUBMODULE_DIR="$ROOT_DIR/external/python-imgui-esc-configurator"
VENV_PY="$ROOT_DIR/.venv/bin/python"
export PYTHONPATH="$ROOT_DIR/sim:${PYTHONPATH:-}"

if [[ ! -x "$VENV_PY" ]]; then
  echo "[error] Missing workspace venv python: $VENV_PY"
  echo "        Create/configure .venv first."
  exit 1
fi

cd "$ROOT_DIR"

echo "[1/4] Ensuring companion submodule is initialized..."
git submodule update --init --recursive external/python-imgui-esc-configurator

if [[ ! -d "$PY_SUBMODULE_DIR" ]]; then
  echo "[error] Companion repo not found at: $PY_SUBMODULE_DIR"
  exit 1
fi

echo "[2/4] Running local FCSP simulator tests (canonical behavior)..."
"$VENV_PY" -m pytest -q sim/tests/test_fcsp_codec.py

echo "[3/4] Running local cocotb parser smoke..."
(
  cd "$ROOT_DIR/sim"
  PATH="$ROOT_DIR/.venv/bin:$PATH" make test-cocotb
)

echo "[4/4] Running companion FCSP-facing unit tests..."
"$VENV_PY" -m pytest -q "$PY_SUBMODULE_DIR/unitTests/test_fcsp.py" "$PY_SUBMODULE_DIR/unitTests/test_tang9k_stream.py"

echo
echo "[ok] FCSP canonical + companion checks passed."
echo "     Canonical spec remains in: $ROOT_DIR/docs/FCSP_PROTOCOL.md"
