#!/usr/bin/env python3
"""
FCSP Hardware Test: Read FPGA Version, Blink NeoPixels

Connects to the Tang Nano 9K via USB serial and exercises
the hardware registers over the FCSP protocol.

Usage:
    python3 python/hw/test_hw_neopixel.py [/dev/ttyUSB0]
"""

from __future__ import annotations

import argparse
import sys
import time

from hwlib import (
    EXPECTED_WHO_AM_I,
    FcspControlClient,
    NEO_PIXEL_0,
    NEO_UPDATE,
    WHO_AM_I,
    rgbw,
)

def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="FCSP NeoPixel hardware exerciser")
    ap.add_argument("--port", default="auto", help="Serial port (default: auto)")
    ap.add_argument("--baud", type=int, default=2_000_000, help="Baud rate (default: 2000000)")
    ap.add_argument("--num-leds", type=int, default=8, help="NeoPixel count to animate (default: 8)")
    ap.add_argument("--step-delay", type=float, default=0.08, help="Animation step delay in seconds")
    ap.add_argument(
        "--count",
        type=int,
        default=0,
        help="Number of full scanner cycles to run (0 = run forever, default: 0)",
    )
    ap.add_argument(
        "--interval-ms",
        type=int,
        default=25,
        help="Poll interval in ms (default: 25)",
    )
    ap.add_argument(
        "--no-ansi",
        action="store_true",
        help="Disable ANSI line control",
    )
    return ap.parse_args()


def run_test(port: str, baud: int, num_leds: int, step_delay: float, count: int) -> None:
    print(f"Connecting to {port} @ {baud} baud...")

    with FcspControlClient(port=port, baud=baud) as fcsp:
        # 1. Read FPGA Version
        print("\n── FPGA Identity ──")
        version = fcsp.read_u32(WHO_AM_I)
        print(f"  WHO_AM_I: 0x{version:08X}")
        if version == EXPECTED_WHO_AM_I:
            print("  ✓ Hardware identified correctly!")
        else:
            print(f"  ✗ Unexpected ID (expected 0x{EXPECTED_WHO_AM_I:08X})")

        # 2. Knight Rider (KITT) Scanner - Red
        led_addrs = [NEO_PIXEL_0 + (i * 4) for i in range(num_leds)]

        print("\n── Knight Rider Scanner (Ctrl+C to stop) ──")
        completed_cycles = 0
        try:
            while True:
                # Sweep right
                for pos in range(num_leds):
                    for i in range(num_leds):
                        dist = abs(i - pos)
                        if dist == 0:
                            brightness = 255
                        elif dist == 1:
                            brightness = 60
                        elif dist == 2:
                            brightness = 15
                        else:
                            brightness = 0
                        fcsp.write_u32(led_addrs[i], rgbw(brightness, 0, 0), settle_s=0.005)
                    fcsp.write_u32(NEO_UPDATE, 0x01, settle_s=0.005)
                    time.sleep(step_delay)

                # Sweep left
                for pos in range(num_leds - 2, 0, -1):
                    for i in range(num_leds):
                        dist = abs(i - pos)
                        if dist == 0:
                            brightness = 255
                        elif dist == 1:
                            brightness = 60
                        elif dist == 2:
                            brightness = 15
                        else:
                            brightness = 0
                        fcsp.write_u32(led_addrs[i], rgbw(brightness, 0, 0), settle_s=0.005)
                    fcsp.write_u32(NEO_UPDATE, 0x01, settle_s=0.005)
                    time.sleep(step_delay)

                completed_cycles += 1
                if count > 0 and completed_cycles >= count:
                    break

        except KeyboardInterrupt:
            print("\n  Stopping...")

        # Turn off all LEDs
        for addr in led_addrs:
            fcsp.write_u32(addr, 0, settle_s=0.005)
        fcsp.write_u32(NEO_UPDATE, 0x01, settle_s=0.005)

        print("── Done ──")


# ── Main ───────────────────────────────────────────────────────
def main() -> None:
    args = parse_args()
    run_test(
        port=args.port,
        baud=args.baud,
        num_leds=args.num_leds,
        step_delay=args.step_delay,
        count=args.count,
    )


if __name__ == "__main__":
    main()
