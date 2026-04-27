#!/usr/bin/env python3
"""
FCSP Hardware Test: DShot Throttle
Sets motor throttle values via the DShot engine.

Usage:
    python3 python/hw/test_hw_dshot.py --motor 0 --throttle 100
"""

from __future__ import annotations

import argparse
import time

from hwlib import (
    FcspControlClient,
    DSHOT_MOTOR_THR,
    WHO_AM_I,
    EXPECTED_WHO_AM_I,
    MUX_CTRL,
    MODE_DSHOT,
    make_mux_word,
)

# Checking if DSHOT_UPDATE is in registers...
# If not, I'll use the raw register offsets.

def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="FCSP DShot hardware exerciser")
    ap.add_argument("--port", default="auto", help="Serial port (default: auto)")
    ap.add_argument("--baud", type=int, default=2_000_000, help="Baud rate (default: 2000000)")
    ap.add_argument("--motor", type=int, default=0, choices=[0, 1, 2, 3], help="Motor index (0-3)")
    ap.add_argument("--throttle", type=int, default=0, help="Throttle value (0-2047, default: 0)")
    ap.add_argument("--sweep", action="store_true", help="Perform a small throttle sweep")
    return ap.parse_args()

def main() -> None:
    args = parse_args()
    
    print(f"Connecting to {args.port} @ {args.baud} baud...")
    with FcspControlClient(port=args.port, baud=args.baud) as fcsp:
        # Check identity
        who = fcsp.read_u32(WHO_AM_I)
        print(f"WHO_AM_I: 0x{who:08X}")
        if who != EXPECTED_WHO_AM_I:
            print(f"[WARN] Unexpected ID (expected 0x{EXPECTED_WHO_AM_I:08X})")

        # 1. Switch MUX to DShot mode for this channel
        print(f"Switching motor {args.motor} MUX to DShot mode...")
        fcsp.write_u32(MUX_CTRL, make_mux_word(MODE_DSHOT, args.motor))

        # 2. DShot address mapping
        motor_addr = DSHOT_MOTOR_THR[args.motor]
        
        if args.sweep:
            print(f"Sweeping motor {args.motor} throttle 0 -> 200 -> 0...")
            for thr in range(0, 201, 10):
                print(f"  Throttle: {thr}", end="\r")
                fcsp.write_u32(motor_addr, thr)
                time.sleep(0.05)
            for thr in range(200, -1, -10):
                print(f"  Throttle: {thr}", end="\r")
                fcsp.write_u32(motor_addr, thr)
                time.sleep(0.05)
            print("\nSweep done.")
        else:
            print(f"Setting motor {args.motor} throttle to {args.throttle}...")
            fcsp.write_u32(motor_addr, args.throttle)
        
        print("Done.")

if __name__ == "__main__":
    main()
