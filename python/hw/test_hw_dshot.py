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
    DSHOT_MOTOR_RAW,
    DSHOT_STATUS,
    WHO_AM_I,
    EXPECTED_WHO_AM_I,
    MUX_CTRL,
    MODE_DSHOT,
    make_mux_word,
    DSHOT_CONFIG,
)

# Checking if DSHOT_UPDATE is in registers...
# If not, I'll use the raw register offsets.

def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="FCSP DShot hardware exerciser")
    ap.add_argument("--port", default="/dev/ttyUSB1", help="Serial port (default: /dev/ttyUSB1)")
    ap.add_argument("--baud", type=int, default=115200, help="Baud rate (default: 115200)")
    ap.add_argument("--motor", type=int, default=0, choices=[0, 1, 2, 3], help="Motor index (0-3)")
    ap.add_argument("--throttle", type=int, default=0, help="Throttle value (0-2047, default: 0)")
    ap.add_argument("--mode", type=int, default=150, choices=[150, 300, 600], help="DShot mode (150/300/600, default: 150)")
    ap.add_argument("--sweep", action="store_true", help="Perform a small throttle sweep")
    ap.add_argument(
        "--duration",
        type=float,
        default=0.0,
        help="Hold throttle for N seconds, then set throttle to 0 (default: 0 = no timed stop)",
    )
    ap.add_argument(
        "--freeze",
        action="store_true",
        help="Send one frame then stop writing — lets the RTL watchdog fire (safety test)",
    )
    ap.add_argument(
        "--arm",
        type=float,
        default=3.0,
        help="Send zero-throttle for N seconds to arm ESC before commanding throttle (default: 3.0, 0=skip)",
    )
    return ap.parse_args()


def build_dshot_frame(value: int, telemetry: int = 0) -> int:
    """Build 16-bit DShot frame: [15:5] value, [4] telemetry, [3:0] crc."""
    value &= 0x7FF
    telemetry &= 0x1
    payload = (value << 1) | telemetry
    crc = (payload ^ (payload >> 4) ^ (payload >> 8)) & 0x0F
    return ((payload << 4) | crc) & 0xFFFF

def main() -> None:
    args = parse_args()
    
    print(f"Connecting to {args.port} @ {args.baud} baud...")
    with FcspControlClient(port=args.port, baud=args.baud) as fcsp:
        # Check identity
        who = fcsp.read_u32(WHO_AM_I)
        print(f"WHO_AM_I: 0x{who:08X}")
        if who != EXPECTED_WHO_AM_I:
            print(f"[WARN] Unexpected ID (expected 0x{EXPECTED_WHO_AM_I:08X})")

        # 1. Configure DShot mode (speed)
        print(f"Configuring DShot mode to {args.mode}...")
        fcsp.write_u32(DSHOT_CONFIG, args.mode)

        # 2. Switch MUX to DShot mode for this channel
        print(f"Switching motor {args.motor} MUX to DShot mode...")
        fcsp.write_u32(MUX_CTRL, make_mux_word(MODE_DSHOT, args.motor, auto_passthrough_en=0))

        # 3. DShot address mapping (RAW registers are implemented in RTL)
        motor_addr = DSHOT_MOTOR_RAW[args.motor]

        # Optional status readback for quick sanity check
        try:
            status = fcsp.read_u32(DSHOT_STATUS)
            wdt_bit = (status >> 4) & 1
            print(f"DSHOT_STATUS: 0x{status:08X} (ready bits[3:0]={status&0xF:04b}, wdt_expired={wdt_bit})")
        except Exception as exc:
            print(f"[WARN] Could not read DSHOT_STATUS: {exc}")
        
        # Arm ESC: send zero-throttle so the ESC recognizes idle before accepting throttle
        if args.arm > 0 and not args.sweep:
            arm_frame = build_dshot_frame(0)
            print(f"Arming ESC: sending throttle=0 for {args.arm:.1f}s...")
            deadline = time.monotonic() + args.arm
            while time.monotonic() < deadline:
                fcsp.write_u32(motor_addr, arm_frame, settle_s=0.05)
            print("Arm complete.")

        if args.sweep:
            print(f"Sweeping motor {args.motor} throttle 0 -> 200 -> 0...")
            try:
                for thr in range(0, 201, 10):
                    print(f"  Throttle: {thr}", end="\r")
                    fcsp.write_u32(motor_addr, build_dshot_frame(thr))
                    time.sleep(0.05)
                for thr in range(200, -1, -10):
                    print(f"  Throttle: {thr}", end="\r")
                    fcsp.write_u32(motor_addr, build_dshot_frame(thr))
                    time.sleep(0.05)
                print("\nSweep done.")
            finally:
                stop_frame = build_dshot_frame(0)
                print(f"\nZeroing all motors (frame=0x{stop_frame:04X})...")
                for i in range(4):
                    try:
                        fcsp.write_u32(DSHOT_MOTOR_RAW[i], stop_frame)
                    except Exception:
                        pass
        else:
            if 1 <= args.throttle <= 47:
                print(f"[WARN] throttle={args.throttle} is in DShot command range (1..47), not normal throttle")
            frame = build_dshot_frame(args.throttle)
            print(f"Setting motor {args.motor} throttle to {args.throttle} (frame=0x{frame:04X})...")
            try:
                fcsp.write_u32(motor_addr, frame)

                if args.freeze:
                    print("[FREEZE] Frame sent. Stopped writing — waiting for watchdog to fire (Ctrl+C to exit)...")
                    while True:
                        time.sleep(0.1)
                        try:
                            status = fcsp.read_u32(DSHOT_STATUS)
                            wdt_bit = (status >> 4) & 1
                            print(f"  DSHOT_STATUS: wdt_expired={wdt_bit} ready={status&0xF:04b}", end="\r")
                            if wdt_bit:
                                print(f"\n[FREEZE] Watchdog fired! Motor output muted by RTL.")
                                break
                        except Exception:
                            pass
                else:
                    # Continuously re-write the frame to keep RTL watchdog fed.
                    # The RTL auto-repeats at 1ms but watchdog expires after 1s
                    # of no new WB writes. Keep writing every ~50ms to be safe.
                    hold_s = args.duration if args.duration > 0 else float("inf")
                    deadline = time.monotonic() + hold_s
                    print(f"Sending continuously (Ctrl+C to stop)...")
                    while time.monotonic() < deadline:
                        fcsp.write_u32(motor_addr, frame, settle_s=0.05)
            finally:
                # Safety: always zero all motors on exit (Ctrl+C, exception, or clean)
                stop_frame = build_dshot_frame(0)
                print(f"\nZeroing all motors (frame=0x{stop_frame:04X})...")
                for i in range(4):
                    try:
                        fcsp.write_u32(DSHOT_MOTOR_RAW[i], stop_frame)
                    except Exception:
                        pass

        print("Done.")

if __name__ == "__main__":
    main()
