#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TANG_BOARD=tangnano20k
exec "${SCRIPT_DIR}/program_tang.sh" "$@"
