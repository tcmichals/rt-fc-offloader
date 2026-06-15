#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TANG_BOARD=tangnano20k
# Gowin official tools default bitstream output path is impl/pnr/project.fs
exec "${SCRIPT_DIR}/program_tang.sh" "$TANG_BOARD" "${SCRIPT_DIR}/../impl/pnr/project.fs" "$@"
