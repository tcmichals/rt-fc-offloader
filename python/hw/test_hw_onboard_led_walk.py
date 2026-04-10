#!/usr/bin/env python3
"""Walk on-board LED bits via wb_led_controller register block.

This is separate from NeoPixel testing and is intended for builds where
`wb_led_controller` is memory-mapped into the FCSP/Wishbone address space.

Register offsets (from LED base):
  +0x00 LED_OUT
  +0x04 LED_TOGGLE
  +0x08 LED_CLEAR
  +0x0C LED_SET

Usage examples:
  python3 python/hw/test_hw_onboard_led_walk.py --port /dev/ttyUSB0 --led-base 0x40000C00
  python3 python/hw/test_hw_onboard_led_walk.py --port /dev/ttyUSB0 --led-base 0x40000C00 --width 4 --step-ms 120
"""

from __future__ import annotations

import argparse
import time

from hwlib import EXPECTED_WHO_AM_I, FcspControlClient, WHO_AM_I, LED_BASE

LED_OUT_OFF = 0x00
LED_TOGGLE_OFF = 0x04
LED_CLEAR_OFF = 0x08
LED_SET_OFF = 0x0C


def _u32(value: int) -> int:
    return value & 0xFFFFFFFF


def run_test(port: str, baud: int, led_base: int, width: int, step_ms: int, loops: int) -> None:
    if width <= 0 or width > 32:
        raise ValueError("width must be in range [1, 32]")

    step_s = max(1, step_ms) / 1000.0
    led_mask = (1 << width) - 1

    print(f"Connecting to {port} @ {baud} baud")
    print(f"LED base: 0x{led_base:08X}, width={width}, step={step_ms} ms, loops={loops}")

    with FcspControlClient(port=port, baud=baud) as fcsp:
        who = fcsp.read_u32(WHO_AM_I)
        print(f"WHO_AM_I = 0x{who:08X}")
        if who != EXPECTED_WHO_AM_I:
            print(f"[WARN] Unexpected ID (expected 0x{EXPECTED_WHO_AM_I:08X}), continuing")

        led_out_addr = led_base + LED_OUT_OFF
        led_toggle_addr = led_base + LED_TOGGLE_OFF
        led_clear_addr = led_base + LED_CLEAR_OFF
        led_set_addr = led_base + LED_SET_OFF

        # Probe: clear all and verify readable shape (best-effort)
        print("\n[1] Probe LED register block")
        fcsp.write_u32(led_clear_addr, _u32(led_mask))
        rb = fcsp.read_u32(led_out_addr)
        print(f"  read LED_OUT = 0x{rb:08X}")

        print("\n[2] Walking LED pattern (SET/CLEAR)")
        try:
            for n in range(loops):
                print(f"  loop {n + 1}/{loops}")
                # forward
                for bit in range(width):
                    val = 1 << bit
                    fcsp.write_u32(led_clear_addr, _u32(led_mask))
                    fcsp.write_u32(led_set_addr, _u32(val))
                    time.sleep(step_s)
                # reverse
                for bit in range(width - 2, 0, -1):
                    val = 1 << bit
                    fcsp.write_u32(led_clear_addr, _u32(led_mask))
                    fcsp.write_u32(led_set_addr, _u32(val))
                    time.sleep(step_s)

            print("\n[3] Toggle demo (optional sanity)")
            fcsp.write_u32(led_out_addr, 0x0)
            for _ in range(min(8, width * 2)):
                fcsp.write_u32(led_toggle_addr, _u32(led_mask))
                time.sleep(step_s)

            print("\nPASS: onboard LED walk completed")

        finally:
            # Leave LEDs off
            fcsp.write_u32(led_clear_addr, _u32(led_mask))


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Walk on-board LEDs via wb_led_controller (separate from NeoPixel)")
    ap.add_argument("--port", default="/dev/ttyUSB0", help="Serial port (default: /dev/ttyUSB0)")
    ap.add_argument("--baud", type=int, default=1_000_000, help="Baud rate (default: 1000000)")
    ap.add_argument(
        "--led-base",
        default=LED_BASE,
        type=lambda x: int(x, 0),
        help=f"Base address of wb_led_controller (default: 0x{LED_BASE:08X})",
    )
    ap.add_argument("--width", type=int, default=4, help="Number of LED bits to walk (default: 4)")
    ap.add_argument("--step-ms", type=int, default=120, help="Step delay in ms (default: 120)")
    ap.add_argument("--loops", type=int, default=4, help="Forward/backward loop count (default: 4)")
    return ap.parse_args()


def main() -> None:
    args = parse_args()
    run_test(
        port=args.port,
        baud=args.baud,
        led_base=args.led_base,
        width=args.width,
        step_ms=args.step_ms,
        loops=args.loops,
    )


if __name__ == "__main__":
    main()
