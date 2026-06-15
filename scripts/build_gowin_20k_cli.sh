#!/usr/bin/env bash
set -euo pipefail

# Allow user to provide GOWIN_HOME via environment variable
if [ -z "${GOWIN_HOME:-}" ]; then
    # Try to auto-detect common locations
    for path in "$HOME/tools/gowin" "$HOME/tools/Gowin" "/opt/gowin" "/opt/Gowin"; do
        if [ -d "$path/IDE" ]; then
            export GOWIN_HOME="$path"
            break
        fi
    done
fi

if [ -z "${GOWIN_HOME:-}" ]; then
    echo "Error: GOWIN_HOME not set and could not be auto-detected."
    echo "Please set it before running this script, e.g.:"
    echo "  export GOWIN_HOME=~/tools/gowin"
    exit 1
fi

echo "Using Gowin tools at: $GOWIN_HOME"

export LD_LIBRARY_PATH="${GOWIN_HOME}/IDE/lib"
export PATH="${GOWIN_HOME}/IDE/bin:$PATH"

# Optional: Disable preloading freetype if not absolutely necessary, or wrap it
if [ -f "/usr/lib/x86_64-linux-gnu/libfreetype.so" ]; then
    export LD_PRELOAD="/usr/lib/x86_64-linux-gnu/libfreetype.so"
fi

# Force Qt to use minimal platform and disable GL to bypass GLX/Wayland crashes entirely
export QT_QPA_PLATFORM=minimal
export QT_XCB_GL_INTEGRATION=none
export LIBGL_ALWAYS_SOFTWARE=1
echo "Building Tang Nano 20K using official Gowin CLI (gw_sh)..."
cd "$(dirname "$0")/.." # Go to project root

# Pass the TCL script to gw_sh
# We use xvfb-run to provide a dummy X11 server so the Qt/GLX backend doesn't crash on headless/Wayland setups
if command -v xvfb-run >/dev/null 2>&1; then
    echo "Using xvfb-run to bypass OpenGL/Wayland issues..."
    xvfb-run -a gw_sh scripts/build_gowin_20k.tcl
else
    echo "Warning: xvfb-run not found. It may crash if you are on Wayland."
    gw_sh scripts/build_gowin_20k.tcl
fi

if [ $? -eq 0 ]; then
    echo "================================================================================"
    echo "Gowin build successful! Bitstream is located in impl/pnr/project.fs"
    echo "================================================================================"
    if [ -f "impl/pnr/project.rpt.txt" ]; then
        awk '/3. Resource Usage Summary/,/====/' impl/pnr/project.rpt.txt
    fi
else
    echo "Gowin build failed. Check the logs."
fi
