#!/usr/bin/env python3
"""
FCSP Hardware Test: Targeted NeoPixel Debug
Sets one LED at a time to a solid color to verify indexing and bit-order.

Usage:
    python3 python/hw/test_hw_neopixel_debug.py --index 0 --color blue
"""

from __future__ import annotations

import argparse
import time

from hwlib import (
    FcspControlClient,
    NEO_PIXEL_0,
    NEO_UPDATE,
    WHO_AM_I,
    rgbw,
)

def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Targeted NeoPixel Debug")
    ap.add_argument("--port", default="auto", help="Serial port (default: auto)")
    ap.add_argument("--baud", type=int, default=2_000_000, help="Baud rate (default: 2000000)")
    ap.add_argument("--index", type=int, default=0, help="LED index (0-7, used if pattern is 'single')")
    ap.add_argument("--color", default="blue", choices=["red", "green", "blue", "white", "off"], help="Color to set")
    ap.add_argument("--brightness", type=int, default=50, help="Brightness (0-255)")
    ap.add_argument("--pattern", default="single", choices=["single", "every-other", "all"], help="Pattern to display")
    ap.add_argument("--num-leds", type=int, default=8, help="Total number of LEDs (default: 8)")
    return ap.parse_args()

def main() -> None:
    args = parse_args()
    
    colors = {
        "red":   (args.brightness, 0, 0, 0),
        "green": (0, args.brightness, 0, 0),
        "blue":  (0, 0, args.brightness, 0),
        "white": (0, 0, 0, args.brightness),
        "off":   (0, 0, 0, 0),
    }
    
    r, g, b, w = colors[args.color]
    pixel_val = rgbw(r, g, b, w)
    
    print(f"Connecting to {args.port} @ {args.baud} baud...")
    with FcspControlClient(port=args.port, baud=args.baud) as fcsp:
        # Check identity
        who = fcsp.read_u32(WHO_AM_I)
        print(f"WHO_AM_I: 0x{who:08X}")
        
        if args.pattern == "single":
            target_indices = [args.index]
        elif args.pattern == "every-other":
            target_indices = [i for i in range(args.num_leds) if i % 2 == 0]
        else: # all
            target_indices = list(range(args.num_leds))

        print(f"Applying pattern '{args.pattern}' with color {args.color} to indices {target_indices}...")
        
        # Clear all first
        for i in range(args.num_leds):
            fcsp.write_u32(NEO_PIXEL_0 + (i * 4), 0)
            
        # Set target pixels
        for i in target_indices:
            fcsp.write_u32(NEO_PIXEL_0 + (i * 4), pixel_val)
            
        # Trigger update
        fcsp.write_u32(NEO_UPDATE, 0x01)
        
        print("Done.")

if __name__ == "__main__":
    main()
