#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/oss_tools_env.sh
source "${SCRIPT_DIR}/oss_tools_env.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BITSTREAM="${1:-${ROOT_DIR}/build/tang9k_oss/hardware.fs}"
MODE="${2:-sram}"

if [[ ! -f "${BITSTREAM}" ]]; then
  echo "Bitstream not found: ${BITSTREAM}" >&2
  exit 1
fi

if ! command -v openFPGALoader >/dev/null 2>&1; then
  echo "Missing required tool: openFPGALoader" >&2
  exit 2
fi

if [[ "${MODE}" == "flash" ]]; then
  echo "Programming FLASH with ${BITSTREAM}"
  openFPGALoader -b tangnano9k -f "${BITSTREAM}"
else
  echo "Programming SRAM with ${BITSTREAM}"
  openFPGALoader -b tangnano9k "${BITSTREAM}"
fi