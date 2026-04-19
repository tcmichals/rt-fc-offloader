#!/usr/bin/env python3
"""Fast WHO_AM_I poller with single-line live status output.

Reads WHO_AM_I repeatedly over FCSP and verifies expected value.
Output stays on one updating line (status style).

Examples:
  python3 python/hw/test_hw_version_poll.py --port /dev/ttyUSB0
  python3 python/hw/test_hw_version_poll.py --port /dev/ttyUSB0 --interval-ms 20 --count 500
"""

from __future__ import annotations

import argparse
import sys
import time

from hwlib import EXPECTED_WHO_AM_I, FcspControlClient, WHO_AM_I


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Fast WHO_AM_I poll with one-line live status")
    ap.add_argument("--port", default="auto", help="Serial port (default: auto)")
    ap.add_argument("--baud", type=int, default=2_000_000, help="Baud rate (default: 2000000)")
    ap.add_argument("--interval-ms", type=int, default=25, help="Poll interval in ms (default: 25)")
    ap.add_argument(
        "--count",
        type=int,
        default=0,
        help="Number of polls before exit (0 = run forever, default: 0)",
    )
    ap.add_argument(
        "--flood",
        action="store_true",
        help="Flood mode: send next request immediately after response (no interval delay)",
    )
    ap.add_argument(
        "--no-ansi",
        action="store_true",
        help="Disable ANSI line control (fallback to carriage-return updates)",
    )
    return ap.parse_args()


def main() -> None:
    args = parse_args()
    interval_s = max(1, args.interval_ms) / 1000.0
    use_ansi = (not args.no_ansi) and sys.stdout.isatty()

    ok = 0
    bad = 0
    errs = 0
    total = 0
    rtt_min = float("inf")
    rtt_max = 0.0
    rtt_sum = 0.0
    start = time.monotonic()

    flood = args.flood
    if flood:
        print("FLOOD mode: no delay between polls")

    print(f"Connecting to {args.port} @ {args.baud} baud...")
    try:
        with FcspControlClient(port=args.port, baud=args.baud) as fcsp:
            print(f"Using port: {fcsp.port}")
            try:
                while True:
                    total += 1
                    now = time.monotonic()
                    elapsed = max(1e-9, now - start)
                    hz = total / elapsed

                    try:
                        t0 = time.monotonic()
                        value = fcsp.read_u32(WHO_AM_I)
                        rtt = time.monotonic() - t0
                        rtt_us = rtt * 1_000_000
                        rtt_sum += rtt
                        if rtt < rtt_min:
                            rtt_min = rtt
                        if rtt > rtt_max:
                            rtt_max = rtt

                        match = value == EXPECTED_WHO_AM_I
                        if match:
                            ok += 1
                            state = "OK"
                        else:
                            bad += 1
                            state = "BAD"

                        rtt_avg_us = (rtt_sum / total) * 1_000_000
                        line = (
                            f"WHO_AM_I 0x{value:08X} ({state}) | "
                            f"ok={ok} bad={bad} err={errs} total={total} | "
                            f"rate={hz:7.1f} Hz | "
                            f"rtt={rtt_us:.0f}/{rtt_avg_us:.0f}/{rtt_min*1e6:.0f}/{rtt_max*1e6:.0f} us (cur/avg/min/max)"
                        )
                    except Exception as exc:
                        errs += 1
                        line = (
                            f"WHO_AM_I read error ({type(exc).__name__}) | "
                            f"ok={ok} bad={bad} err={errs} total={total} | "
                            f"rate={hz:7.1f} Hz"
                        )

                    if use_ansi:
                        # ANSI: clear entire line then return carriage.
                        print(f"\x1b[2K\r{line}", end="", flush=True)
                    else:
                        # Fallback: carriage-return update only.
                        print(f"\r{line}", end="", flush=True)

                    if args.count > 0 and total >= args.count:
                        break

                    if not flood:
                        time.sleep(interval_s)
            except KeyboardInterrupt:
                pass
    except Exception as exc:
        print(f"ERROR: {exc}")
        print("Tip: pass --port /dev/ttyACM0 or --port /dev/ttyUSB0 when connected.")
        return

    print()
    elapsed = time.monotonic() - start
    rtt_avg_us = (rtt_sum / max(1, ok + bad)) * 1_000_000 if (ok + bad) > 0 else 0
    print(
        f"Done: ok={ok}, bad={bad}, err={errs}, total={total}, "
        f"expected=0x{EXPECTED_WHO_AM_I:08X}"
    )
    if ok + bad > 0:
        print(
            f"RTT (us): min={rtt_min*1e6:.0f}, avg={rtt_avg_us:.0f}, max={rtt_max*1e6:.0f}"
        )
    print(f"Elapsed: {elapsed:.1f}s, rate: {total/max(1e-9,elapsed):.1f} Hz")


if __name__ == "__main__":
    main()
