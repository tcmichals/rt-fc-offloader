#!/usr/bin/env python3
"""FCSP hardware switching validation for serial/DSHOT mux.

Validates the switching software path by writing/reading the mux control register
at 0x40000400 over FCSP CONTROL channel.

What it checks:
- WHO_AM_I register is reachable
- Mux mode toggles between DShot and Serial/Passthrough
- Channel select bits [2:1] round-trip correctly for motors 0..3
- Optional break pulse (bit[4]) can be asserted/deasserted and read back

Usage:
  python3 python/hw/test_hw_switching.py --port /dev/ttyUSB0
  python3 python/hw/test_hw_switching.py --port /dev/ttyUSB0 --break-ms 250
"""

from __future__ import annotations

import argparse
import time

from hwlib import (
    EXPECTED_WHO_AM_I,
    FcspControlClient,
    MODE_DSHOT,
    MODE_SERIAL,
    MUX_CTRL,
    WHO_AM_I,
    decode_mux_word,
    make_mux_word,
)

def expect_mux(fcsp: FcspControlClient, expected_word: int, tag: str) -> None:
    got = fcsp.read_u32(MUX_CTRL)
    # Compare documented control bits [5:0]
    if (got & 0x3F) != (expected_word & 0x3F):
        raise AssertionError(
            f"{tag}: readback mismatch: wrote=0x{expected_word & 0x3F:02X}, got=0x{got & 0x3F:02X}"
        )
    fields = decode_mux_word(got)
    print(
        f"  [OK] {tag}: mode={fields['mode']} channel={fields['channel']} "
        f"msp={fields['msp_mode']} force_low={fields['force_low']} auto={fields['auto_passthrough_en']}"
    )


def run_test(port: str, baud: int, break_ms: int) -> None:
    print(f"Connecting to {port} @ {baud} baud")

    with FcspControlClient(port=port, baud=baud) as fcsp:
        print("\n[1] Identity check")
        who = fcsp.read_u32(WHO_AM_I)
        print(f"  WHO_AM_I = 0x{who:08X}")
        if who != EXPECTED_WHO_AM_I:
            print("  [WARN] Unexpected identity value, continuing with mux validation")

        print("\n[2] Baseline readback")
        baseline = fcsp.read_u32(MUX_CTRL)
        b = decode_mux_word(baseline)
        print(
            f"  Baseline mux: mode={b['mode']} channel={b['channel']} "
            f"msp={b['msp_mode']} force_low={b['force_low']}"
        )

        print("\n[3] Channel sweep in SERIAL mode (software switching path)")
        for motor in range(4):
            word = make_mux_word(mode=MODE_SERIAL, channel=motor, msp_mode=0, force_low=0, auto_passthrough_en=0)
            fcsp.write_u32(MUX_CTRL, word)
            expect_mux(fcsp, word, f"serial/ch{motor}")

        print("\n[4] Return to DSHOT mode")
        word_dshot = make_mux_word(mode=MODE_DSHOT, channel=0, msp_mode=0, force_low=0, auto_passthrough_en=0)
        fcsp.write_u32(MUX_CTRL, word_dshot)
        expect_mux(fcsp, word_dshot, "dshot restore")

        if break_ms > 0:
            print(f"\n[5] Break pulse test ({break_ms} ms) in SERIAL mode")
            word_break_on = make_mux_word(mode=MODE_SERIAL, channel=0, msp_mode=0, force_low=1, auto_passthrough_en=0)
            fcsp.write_u32(MUX_CTRL, word_break_on)
            expect_mux(fcsp, word_break_on, "break on")
            time.sleep(break_ms / 1000.0)

            word_break_off = make_mux_word(mode=MODE_SERIAL, channel=0, msp_mode=0, force_low=0, auto_passthrough_en=0)
            fcsp.write_u32(MUX_CTRL, word_break_off)
            expect_mux(fcsp, word_break_off, "break off")

            fcsp.write_u32(MUX_CTRL, word_dshot)
            expect_mux(fcsp, word_dshot, "dshot re-restore")

        print("\nPASS: switching path validated")
        # Safety: always try to leave system in DSHOT mode
        try:
            fcsp.write_u32(MUX_CTRL, make_mux_word(mode=MODE_DSHOT, channel=0, msp_mode=0, force_low=0, auto_passthrough_en=0))
        except Exception:
            pass


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Validate FCSP switching software path via mux register read/write")
    ap.add_argument("--port", default="/dev/ttyUSB1", help="Serial port (default: /dev/ttyUSB1)")
    ap.add_argument("--baud", type=int, default=115200, help="Baud rate (default: 115200)")
    ap.add_argument(
        "--break-ms",
        type=int,
        default=0,
        help="Optional break pulse duration in ms (0 disables break test)",
    )
    ap.add_argument(
        "--count",
        type=int,
        default=0,
        help="Number of iterations before exit (0 = run forever, default: 0)",
    )
    ap.add_argument(
        "--no-ansi",
        action="store_true",
        help="Disable ANSI line control",
    )
    return ap.parse_args()


def main() -> None:
    args = parse_args()
    run_test(port=args.port, baud=args.baud, break_ms=args.break_ms)


if __name__ == "__main__":
    main()
