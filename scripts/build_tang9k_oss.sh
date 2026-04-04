#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/oss_tools_env.sh
source "${SCRIPT_DIR}/oss_tools_env.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/build/tang9k_oss}"
TOP="fcsp_tangnano9k_top"

CST="${ROOT_DIR}/rtl/fcsp/boards/tangnano9k/tang9k.cst"

mkdir -p "${OUT_DIR}"

require_tool() {
  local t="$1"
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "Missing required tool: $t" >&2
    exit 2
  fi
}

require_tool yosys
require_tool nextpnr-himbaechel
require_tool gowin_pack

SOURCES=(
  "${ROOT_DIR}/rtl/fcsp/boards/tangnano9k/fcsp_tangnano9k_top.sv"
  "${ROOT_DIR}/rtl/fcsp/fcsp_offloader_top.sv"
  "${ROOT_DIR}/rtl/fcsp/fcsp_spi_frontend.sv"
  "${ROOT_DIR}/rtl/fcsp/fcsp_parser.sv"
  "${ROOT_DIR}/rtl/fcsp/fcsp_crc16_core_xmodem.sv"
  "${ROOT_DIR}/rtl/fcsp/fcsp_crc16.sv"
  "${ROOT_DIR}/rtl/fcsp/fcsp_crc_gate.sv"
  "${ROOT_DIR}/rtl/fcsp/fcsp_router.sv"
  "${ROOT_DIR}/rtl/fcsp/fcsp_rx_fifo.sv"
  "${ROOT_DIR}/rtl/fcsp/fcsp_serv_bridge.sv"
  "${ROOT_DIR}/rtl/fcsp/fcsp_tx_fifo.sv"
  "${ROOT_DIR}/rtl/fcsp/fcsp_tx_framer.sv"
  "${ROOT_DIR}/rtl/fcsp/fcsp_io_engines.sv"
)

echo "[1/3] Synthesizing ${TOP}"
yosys -q -p "read_verilog -sv ${SOURCES[*]}; synth_gowin -top ${TOP} -json ${OUT_DIR}/hardware.json"

echo "[2/3] Place and route (Tang Nano 9K)"
nextpnr-himbaechel \
  --json "${OUT_DIR}/hardware.json" \
  --write "${OUT_DIR}/hardware_pnr.json" \
  --device GW1NR-LV9QN88PC6/I5 \
  --vopt "family=GW1N-9C" \
  --vopt "cst=${CST}" \
  --freq 27 \
  --report "${OUT_DIR}/nextpnr_report.json"

if [[ ! -f "${OUT_DIR}/hardware_pnr.json" ]]; then
  echo "Place-and-route did not produce ${OUT_DIR}/hardware_pnr.json" >&2
  exit 3
fi

echo "[3/3] Packing bitstream"
gowin_pack -d GW1N-9C -o "${OUT_DIR}/hardware.fs" "${OUT_DIR}/hardware_pnr.json"

echo "Done: ${OUT_DIR}/hardware.fs"