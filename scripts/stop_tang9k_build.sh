#!/usr/bin/env bash
set -euo pipefail

echo "Stopping Tang9K build process tree..."

pkill -TERM -f 'cmake --build build/cmake --target tang9k-build' || true
pkill -TERM -f '/usr/bin/gmake.*tang9k-build|CMakeFiles/tang9k-build.dir/build.make' || true
pkill -TERM -f 'timeout --signal=TERM --kill-after=30 .* (yosys|nextpnr-himbaechel|gowin_pack)' || true
pkill -TERM -f '(yosys|nextpnr-himbaechel|gowin_pack)' || true

sleep 1

pkill -KILL -f '(cmake --build build/cmake --target tang9k-build|/usr/bin/gmake.*tang9k-build|yosys|nextpnr-himbaechel|gowin_pack)' || true

echo "Remaining related processes (if any):"
ps -eo pid,ppid,etimes,stat,cmd | grep -E 'cmake --build|gmake|yosys|nextpnr-himbaechel|gowin_pack|timeout --signal' | grep -v grep || true
