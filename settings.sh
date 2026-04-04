#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# rt-fc-offloader environment setup (source this file)
# -----------------------------------------------------------------------------
# Purpose
#   Provide a consistent, professional shell setup flow for this repository,
#   similar to SDK-style projects (source once per shell session).
#
# Guarantees
#   - Exports RT_FC_OFFLOADER_ROOT
#   - Exports/uses OSS_TOOLS_BIN
#   - Exports/uses ARM_GCC_BIN
#   - Exports/uses RISCV_GCC_BIN
#   - Prepends detected toolchain bin directories to PATH exactly once
#
# Variable contract (set before sourcing to override defaults)
#   OSS_TOOLS_BIN : path to OSS CAD Suite bin (yosys/nextpnr/gowin_pack/...)
#   ARM_GCC_BIN   : path to Arm GCC bin (arm-none-eabi-gcc)
#   RISCV_GCC_BIN : path to RISC-V GCC bin (riscv64-unknown-elf-gcc)
#
# Notes
#   - This script is intended to be sourced, not executed.
#   - If a configured path does not exist, it is skipped silently.
# -----------------------------------------------------------------------------
#
# Usage:
#   source settings.sh
#
# Optional overrides before sourcing:
#   export OSS_TOOLS_BIN=/path/to/oss-cad-suite/bin
#   export ARM_GCC_BIN=/path/to/arm-none-eabi/bin
#   export RISCV_GCC_BIN=/path/to/riscv/bin

# Resolve repository root even when sourced from another directory.
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  _RTFC_SETTINGS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  _RTFC_SETTINGS_DIR="$(pwd)"
fi

export RT_FC_OFFLOADER_ROOT="${_RTFC_SETTINGS_DIR}"

_rtfc_prepend_path_once() {
  # Prepend a directory to PATH only if it exists and is not already present.
  local dir="$1"
  if [[ -d "${dir}" ]]; then
    case ":${PATH}:" in
      *":${dir}:"*) ;;
      *) export PATH="${dir}:${PATH}" ;;
    esac
  fi
}

_rtfc_first_existing_dir() {
  # Return the first existing directory from the given candidate list.
  local candidate
  for candidate in "$@"; do
    if [[ -d "${candidate}" ]]; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  return 1
}

# Default OSS toolchain location (override supported).
if [[ -z "${OSS_TOOLS_BIN:-}" ]]; then
  export OSS_TOOLS_BIN="${HOME}/.tools/oss-cad-suite/bin"
fi

# Add OSS toolchain path if present.
_rtfc_prepend_path_once "${OSS_TOOLS_BIN}"

# ARM GCC toolchain bin directory.
if [[ -z "${ARM_GCC_BIN:-}" ]]; then
  _rtfc_arm_detected="$(_rtfc_first_existing_dir \
    "${HOME}/.tools/gcc-arm-none-eabi/bin" \
    "${HOME}/.tools/arm-gnu-toolchain/bin" \
    "${HOME}/.local/gcc-arm-none-eabi/bin" \
    "/opt/gcc-arm-none-eabi/bin" \
    "/opt/arm-gnu-toolchain/bin" 2>/dev/null || true)"
  if [[ -n "${_rtfc_arm_detected}" ]]; then
    export ARM_GCC_BIN="${_rtfc_arm_detected}"
  fi
  unset _rtfc_arm_detected
fi
if [[ -n "${ARM_GCC_BIN:-}" ]]; then
  _rtfc_prepend_path_once "${ARM_GCC_BIN}"
fi

# RISC-V GCC toolchain bin directory.
if [[ -z "${RISCV_GCC_BIN:-}" ]]; then
  _rtfc_riscv_detected="$(_rtfc_first_existing_dir \
    "${HOME}/.tools/riscv/bin" \
    "${HOME}/.tools/riscv-gnu-toolchain/bin" \
    "${HOME}/.local/riscv/bin" \
    "/opt/riscv/bin" \
    "/opt/riscv-gnu-toolchain/bin" 2>/dev/null || true)"
  if [[ -n "${_rtfc_riscv_detected}" ]]; then
    export RISCV_GCC_BIN="${_rtfc_riscv_detected}"
  fi
  unset _rtfc_riscv_detected
fi
if [[ -n "${RISCV_GCC_BIN:-}" ]]; then
  _rtfc_prepend_path_once "${RISCV_GCC_BIN}"
fi

echo "[rt-fc-offloader] Environment configured"
echo "  RT_FC_OFFLOADER_ROOT=${RT_FC_OFFLOADER_ROOT}"
echo "  OSS_TOOLS_BIN=${OSS_TOOLS_BIN}"
echo "  ARM_GCC_BIN=${ARM_GCC_BIN:-<not-set>}"
echo "  RISCV_GCC_BIN=${RISCV_GCC_BIN:-<not-set>}"

unset _RTFC_SETTINGS_DIR
unset -f _rtfc_prepend_path_once
unset -f _rtfc_first_existing_dir
