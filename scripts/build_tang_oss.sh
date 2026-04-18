#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/oss_tools_env.sh
source "${SCRIPT_DIR}/oss_tools_env.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TANG_BOARD="${TANG_BOARD:-tangnano9k}"

# Check for Gowin tools
GOWIN_HOME="${GOWIN_HOME:-}"
USE_GOWIN=false
if [[ -n "${GOWIN_HOME}" && -d "${GOWIN_HOME}/IDE/bin" ]]; then
  USE_GOWIN=true
fi

if [[ $# -gt 0 && ("$1" == "tangnano9k" || "$1" == "tangnano20k") ]]; then
  TANG_BOARD="$1"
  shift
fi

BUILD_TIMEOUT_SEC="${TANG_BUILD_TIMEOUT_SEC:-${TANG9K_BUILD_TIMEOUT_SEC:-900}}"

case "${TANG_BOARD}" in
  tangnano9k)
    TOP="fcsp_tangnano9k_top"
    CST="${ROOT_DIR}/rtl/fcsp/boards/tangnano9k/tang9k.cst"
    SDC="${ROOT_DIR}/rtl/fcsp/boards/tangnano9k/tang9k.sdc"
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
      "${ROOT_DIR}/rtl/fcsp/fcsp_tx_fifo.sv"
      "${ROOT_DIR}/rtl/fcsp/fcsp_tx_arbiter.sv"
      "${ROOT_DIR}/rtl/fcsp/fcsp_tx_framer.sv"
      "${ROOT_DIR}/rtl/fcsp/fcsp_uart_byte_stream.sv"
      "${ROOT_DIR}/rtl/fcsp/fcsp_io_engines.sv"
      "${ROOT_DIR}/rtl/fcsp/fcsp_wishbone_master.sv"
      "${ROOT_DIR}/rtl/fcsp/fcsp_stream_packetizer.sv"
      "${ROOT_DIR}/rtl/fcsp/fcsp_debug_generator.sv"
      "${ROOT_DIR}/rtl/fcsp/drivers/wb_led_controller.sv"
      "${ROOT_DIR}/rtl/io/wb_io_bus.sv"
      "${ROOT_DIR}/rtl/io/wb_dshot_controller.sv"
      "${ROOT_DIR}/rtl/io/dshot_out.sv"
      "${ROOT_DIR}/rtl/io/wb_serial_dshot_mux.sv"
      "${ROOT_DIR}/rtl/io/wb_esc_uart.sv"
      "${ROOT_DIR}/rtl/io/wb_neoPx.sv"
      "${ROOT_DIR}/rtl/io/sendPx_axis_flexible.sv"
      "${ROOT_DIR}/rtl/io/pwmdecoder_wb.sv"
      "${ROOT_DIR}/rtl/io/pwmdecoder.sv"
    )
    OPENFPGALOADER_BOARD="tangnano9k"
    PNR_DEVICE="GW1NR-LV9QN88PC6/I5"
    PNR_FAMILY="GW1N-9C"
    PACK_DEVICE="GW1N-9C"
    ;;
  tangnano20k)
    TOP="fcsp_tangnano20k_top"
    CST="${ROOT_DIR}/rtl/fcsp/boards/tangnano20k/tang20k.cst"
    SDC="${ROOT_DIR}/rtl/fcsp/boards/tangnano20k/tang20k.sdc"
    SOURCES=(
      "${ROOT_DIR}/rtl/fcsp/boards/tangnano20k/fcsp_tangnano20k_top.sv"
      "${ROOT_DIR}/rtl/fcsp/fcsp_offloader_top.sv"
      "${ROOT_DIR}/rtl/fcsp/fcsp_spi_frontend.sv"
      "${ROOT_DIR}/rtl/fcsp/fcsp_parser.sv"
      "${ROOT_DIR}/rtl/fcsp/fcsp_crc16_core_xmodem.sv"
      "${ROOT_DIR}/rtl/fcsp/fcsp_crc16.sv"
      "${ROOT_DIR}/rtl/fcsp/fcsp_crc_gate.sv"
      "${ROOT_DIR}/rtl/fcsp/fcsp_router.sv"
      "${ROOT_DIR}/rtl/fcsp/fcsp_rx_fifo.sv"
      "${ROOT_DIR}/rtl/fcsp/fcsp_tx_fifo.sv"
      "${ROOT_DIR}/rtl/fcsp/fcsp_tx_arbiter.sv"
      "${ROOT_DIR}/rtl/fcsp/fcsp_tx_framer.sv"
      "${ROOT_DIR}/rtl/fcsp/fcsp_uart_byte_stream.sv"
      "${ROOT_DIR}/rtl/fcsp/fcsp_io_engines.sv"
      "${ROOT_DIR}/rtl/fcsp/fcsp_wishbone_master.sv"
      "${ROOT_DIR}/rtl/fcsp/fcsp_stream_packetizer.sv"
      "${ROOT_DIR}/rtl/fcsp/fcsp_debug_generator.sv"
      "${ROOT_DIR}/rtl/fcsp/drivers/wb_led_controller.sv"
      "${ROOT_DIR}/rtl/io/wb_io_bus.sv"
      "${ROOT_DIR}/rtl/io/wb_dshot_controller.sv"
      "${ROOT_DIR}/rtl/io/dshot_out.sv"
      "${ROOT_DIR}/rtl/io/wb_serial_dshot_mux.sv"
      "${ROOT_DIR}/rtl/io/wb_esc_uart.sv"
      "${ROOT_DIR}/rtl/io/wb_neoPx.sv"
      "${ROOT_DIR}/rtl/io/sendPx_axis_flexible.sv"
      "${ROOT_DIR}/rtl/io/pwmdecoder_wb.sv"
      "${ROOT_DIR}/rtl/io/pwmdecoder.sv"
    )
    OPENFPGALOADER_BOARD="tangnano20k"
    PNR_DEVICE="GW2AR-LV18QN88C8/I7"
    PNR_FAMILY="GW2A-18C"
    PACK_DEVICE="GW2A-18C"
    ;;
  *)
    echo "Unknown TANG_BOARD: ${TANG_BOARD}" >&2
    exit 2
    ;;
esac

if [[ ! -f "${CST}" ]]; then
  echo "Missing constraints file: ${CST}" >&2
  exit 3
fi
if [[ ! -f "${SDC}" ]]; then
  echo "Missing timing constraints file: ${SDC}" >&2
  exit 3
fi

OUT_DIR="${OUT_DIR:-${ROOT_DIR}/build/${TANG_BOARD}_oss}"
mkdir -p "${OUT_DIR}"

YOSYS_LOG="${OUT_DIR}/yosys.log"
NEXTPNR_LOG="${OUT_DIR}/nextpnr.log"

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
if [[ "${TANG_BOARD}" == "tangnano20k" && "${USE_GOWIN}" == "true" ]]; then
  require_tool "${GOWIN_HOME}/IDE/bin/GowinSynthesis"
  echo "[1/3] Synthesizing ${TOP} with GowinSynthesis"
  echo "      log: ${YOSYS_LOG}"
  # Set environment for Gowin
  export LD_LIBRARY_PATH="${GOWIN_HOME}/IDE/lib"
  export LD_PRELOAD="/usr/lib/x86_64-linux-gnu/libfreetype.so"
  "${TIMEOUT_CMD[@]}" "${GOWIN_HOME}/IDE/bin/GowinSynthesis" -i "${SOURCES[@]}" -top "${TOP}" -o "${OUT_DIR}/hardware.vm" -p "GW2AR-18C" > "${YOSYS_LOG}" 2>&1
  # Convert to JSON or something? Gowin uses different format.
  # For now, assume it works, but this might need adjustment.
else
  require_tool yosys
  echo "[1/3] Synthesizing ${TOP}"
  echo "      log: ${YOSYS_LOG}"
  "${TIMEOUT_CMD[@]}" yosys -l "${YOSYS_LOG}" -p "read_verilog -sv ${SOURCES[*]}; synth_gowin -top ${TOP} -json ${OUT_DIR}/hardware.json"
fi

if [[ "${TANG_BOARD}" == "tangnano20k" && "${USE_GOWIN}" == "true" ]]; then
  if [[ ! -f "${OUT_DIR}/hardware.vm" ]]; then
    echo "Synthesis did not produce ${OUT_DIR}/hardware.vm" >&2
    exit 3
  fi
else
  if [[ ! -f "${OUT_DIR}/hardware.json" ]]; then
    echo "Synthesis did not produce ${OUT_DIR}/hardware.json" >&2
    exit 3
  fi
fi

if [[ "${TANG_BOARD}" == "tangnano20k" && "${USE_GOWIN}" == "true" ]]; then
  require_tool "${GOWIN_HOME}/IDE/bin/gw_sh"
  echo "[2/3] Place and route (${TANG_BOARD}) with Gowin"
  echo "      log: ${NEXTPNR_LOG}"
  # Create Tcl script for P&R
  cat > "${OUT_DIR}/pnr.tcl" << EOF
set_device -name ${PNR_DEVICE}
set_option -top_module ${TOP}
add_file -verilog ${OUT_DIR}/hardware.vm
add_file -cst ${CST}
add_file -sdc ${SDC}
set_option -output_base_name hardware
run_pnr
EOF
  export LD_LIBRARY_PATH="${GOWIN_HOME}/IDE/lib"
  export LD_PRELOAD="/usr/lib/x86_64-linux-gnu/libfreetype.so"
  cd "${OUT_DIR}"
  "${TIMEOUT_CMD[@]}" "${GOWIN_HOME}/IDE/bin/gw_sh" pnr.tcl > "${NEXTPNR_LOG}" 2>&1
  cd "${ROOT_DIR}"
else
  require_tool nextpnr-himbaechel
  echo "[2/3] Place and route (${TANG_BOARD})"
  echo "      log: ${NEXTPNR_LOG}"
  "${TIMEOUT_CMD[@]}" nextpnr-himbaechel \
    --json "${OUT_DIR}/hardware.json" \
    --write "${OUT_DIR}/hardware_pnr.json" \
    --device "${PNR_DEVICE}" \
    --vopt "family=${PNR_FAMILY}" \
    --vopt "cst=${CST}" \
    --sdc "${SDC}" \
    --freq 27 \
    --seed "${NEXTPNR_SEED:-1}" \
    --report "${OUT_DIR}/nextpnr_report.json" \
    --log "${NEXTPNR_LOG}"
fi

if [[ "${TANG_BOARD}" == "tangnano20k" && "${USE_GOWIN}" == "true" ]]; then
  if [[ ! -f "${OUT_DIR}/hardware.fs" ]]; then
    echo "Place-and-route did not produce ${OUT_DIR}/hardware.fs" >&2
    exit 3
  fi
else
  if [[ ! -f "${OUT_DIR}/hardware_pnr.json" ]]; then
    echo "Place-and-route did not produce ${OUT_DIR}/hardware_pnr.json" >&2
    exit 3
  fi
fi

if [[ "${TANG_BOARD}" == "tangnano20k" && "${USE_GOWIN}" == "true" ]]; then
  echo "[3/3] Packing bitstream (skipped, Gowin P&R produces .fs directly)"
else
  require_tool gowin_pack
  echo "[3/3] Packing bitstream"
  "${TIMEOUT_CMD[@]}" gowin_pack -d "${PACK_DEVICE}" -o "${OUT_DIR}/hardware.fs" "${OUT_DIR}/hardware_pnr.json"
fi

if [[ ! -f "${OUT_DIR}/hardware.fs" ]]; then
  echo "Packing did not produce ${OUT_DIR}/hardware.fs" >&2
  exit 3
fi

echo "[post] Generating compile summary (and optional docs/TIMING_REPORT.md auto-update)"
if python3 "${ROOT_DIR}/python/tools/report_tang9k_build_summary.py" "${OUT_DIR}" "${ROOT_DIR}"; then
  echo "[post] Compile summary step completed."
else
  echo "[post] WARNING: compile summary step failed (non-fatal); bitstream build remains successful." >&2
fi

echo "Done: ${OUT_DIR}/hardware.fs"
