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
#   - Exports/uses PICO_SDK_PATH
#   - Prepends detected toolchain bin directories to PATH exactly once
#
# Variable contract (set before sourcing to override defaults)
#   OSS_TOOLS_BIN  : path to OSS CAD Suite bin (yosys/nextpnr/gowin_pack/...)
#   ARM_GCC_BIN    : path to Arm GCC bin (arm-none-eabi-gcc)
#   RISCV_GCC_BIN  : path to RISC-V GCC bin (riscv64-unknown-elf-gcc)
#   PICO_SDK_PATH  : path to Pico SDK root (pico_sdk_init.cmake)
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
#   export RISCV_GCC_BIN=/path/to/gcc-riscv-none-eabi/bin
#   export PICO_SDK_PATH=/path/to/pico-sdk

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

_rtfc_warn_if_compiler_outside_tools() {
  # Warn if resolved compiler is outside ${HOME}/.tools.
  local compiler="$1"
  local resolved
  local tools_prefix="${HOME}/.tools/"

  resolved="$(command -v "${compiler}" 2>/dev/null || true)"
  [[ -n "${resolved}" ]] || return 0

  case "${resolved}" in
    "${tools_prefix}"*)
      ;;
    *)
      echo "[rt-fc-offloader] WARNING: ${compiler} resolves to '${resolved}' (outside ${HOME}/.tools)." >&2
      echo "[rt-fc-offloader]          Preferred flow uses official archives under ~/.tools for deterministic Tang Nano builds." >&2
      ;;
  esac
}

_rtfc_warn_if_missing_nano_specs() {
  # Warn if compiler does not provide nano.specs.
  local compiler="$1"
  local resolved
  local nano_path

  resolved="$(command -v "${compiler}" 2>/dev/null || true)"
  [[ -n "${resolved}" ]] || return 0

  nano_path="$(${resolved} -print-file-name=nano.specs 2>/dev/null || true)"
  if [[ -z "${nano_path}" || "${nano_path}" == "nano.specs" ]]; then
    echo "[rt-fc-offloader] WARNING: ${compiler} at '${resolved}' does not expose nano.specs." >&2
    echo "[rt-fc-offloader]          Prefer official archives under ~/.tools (or run scripts/install_latest_tools.sh)." >&2
  fi
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
    "${HOME}/.tools/gcc-riscv-none-eabi/bin" \
    "/opt/gcc-riscv-none-eabi/bin" 2>/dev/null || true)"
  if [[ -n "${_rtfc_riscv_detected}" ]]; then
    export RISCV_GCC_BIN="${_rtfc_riscv_detected}"
  fi
  unset _rtfc_riscv_detected
fi
if [[ -n "${RISCV_GCC_BIN:-}" ]]; then
  _rtfc_prepend_path_once "${RISCV_GCC_BIN}"
fi

# Pico SDK path.
if [[ -z "${PICO_SDK_PATH:-}" ]]; then
  if [[ -f "${HOME}/.tools/pico-sdk/pico_sdk_init.cmake" ]]; then
    export PICO_SDK_PATH="${HOME}/.tools/pico-sdk"
  fi
elif [[ ! -f "${PICO_SDK_PATH}/pico_sdk_init.cmake" ]]; then
  echo "[rt-fc-offloader] WARNING: PICO_SDK_PATH='${PICO_SDK_PATH}' does not contain pico_sdk_init.cmake." >&2
fi

_rtfc_warn_if_compiler_outside_tools arm-none-eabi-gcc
_rtfc_warn_if_compiler_outside_tools riscv64-unknown-elf-gcc
_rtfc_warn_if_missing_nano_specs arm-none-eabi-gcc
_rtfc_warn_if_missing_nano_specs riscv64-unknown-elf-gcc

echo "[rt-fc-offloader] Environment configured"
echo "  RT_FC_OFFLOADER_ROOT=${RT_FC_OFFLOADER_ROOT}"
echo "  OSS_TOOLS_BIN=${OSS_TOOLS_BIN}"
echo "  ARM_GCC_BIN=${ARM_GCC_BIN:-<not-set>}"
echo "  RISCV_GCC_BIN=${RISCV_GCC_BIN:-<not-set>}"
echo "  PICO_SDK_PATH=${PICO_SDK_PATH:-<not-set>}"

unset _RTFC_SETTINGS_DIR
unset -f _rtfc_prepend_path_once
unset -f _rtfc_first_existing_dir
unset -f _rtfc_warn_if_compiler_outside_tools
unset -f _rtfc_warn_if_missing_nano_specs
