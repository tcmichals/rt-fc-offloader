#!/usr/bin/env bash
set -euo pipefail

echo "Stopping active Tang build process tree..."
pkill -TERM -f 'cmake --build build/cmake --target .*build' || true
pkill -TERM -f '/usr/bin/gmake.*-build|CMakeFiles/.*-build.dir/build.make' || true
pkill -KILL -f '(cmake --build build/cmake --target .*build|/usr/bin/gmake.*-build|yosys|nextpnr-himbaechel|gowin_pack)' || true
