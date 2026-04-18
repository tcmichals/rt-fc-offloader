#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TANG_BOARD="${TANG_BOARD:-tangnano9k}"
if [[ $# -gt 0 && ("$1" == "tangnano9k" || "$1" == "tangnano20k") ]]; then
  TANG_BOARD="$1"
  shift
fi

BITSTREAM="${1:-${ROOT_DIR}/build/${TANG_BOARD}_oss/hardware.fs}"
MODE="${2:-sram}"

if [[ ! -f "${BITSTREAM}" ]]; then
  echo "Bitstream not found: ${BITSTREAM}" >&2
  exit 1
fi

if ! command -v openFPGALoader >/dev/null 2>&1; then
  echo "Missing required tool: openFPGALoader" >&2
  exit 2
fi

OPENFPGALOADER_BOARD="${TANG_BOARD}"

if [[ "${MODE}" == "flash" ]]; then
  echo "Programming FLASH with ${BITSTREAM}"
  openFPGALoader -b "${OPENFPGALOADER_BOARD}" -f "${BITSTREAM}"
else
  echo "Programming SRAM with ${BITSTREAM}"
  openFPGALoader -b "${OPENFPGALOADER_BOARD}" "${BITSTREAM}"
fi
