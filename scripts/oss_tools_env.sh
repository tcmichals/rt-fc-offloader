#!/usr/bin/env bash

# Source this file to add OSS FPGA tools to PATH.
#
# Precedence:
# 1) OSS_TOOLS_BIN (if provided)
# 2) ~/.tools/oss-cad-suite/bin (if present)

OSS_TOOLS_BIN_CANDIDATE="${OSS_TOOLS_BIN:-${HOME}/.tools/oss-cad-suite/bin}"

if [[ -d "${OSS_TOOLS_BIN_CANDIDATE}" ]]; then
  case ":${PATH}:" in
    *":${OSS_TOOLS_BIN_CANDIDATE}:"*)
      ;;
    *)
      export PATH="${OSS_TOOLS_BIN_CANDIDATE}:${PATH}"
      ;;
  esac
fi
