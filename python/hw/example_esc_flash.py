#!/usr/bin/env python3
"""Simplified ESC flashing example using rt-fc-offloader FPGA.

This example demonstrates how to flash BLHeli/Bluejay firmware to an ESC
using the FPGA offloader. It shows the complete workflow:
1. Enter serial mode
2. Assert break to enter bootloader
3. Send BLHeli commands
4. Restore DShot mode

Usage:
    python3 python/hw/example_esc_flash.py --port /dev/ttyUSB0 --motor 0
"""

import argparse
import struct
import sys
import time

sys.path.insert(0, ".")
from hwlib import (
    DSHOT_CONFIG,
    DSHOT_MOTOR_RAW,
    ESC_BAUD_DIV,
    EXPECTED_WHO_AM_I,
    FcspControlClient,
    MODE_DSHOT,
    MODE_SERIAL,
    MUX_CTRL,
    WHO_AM_I,
    make_mux_word,
)

# FCSP imports for ESC_SERIAL channel framing
sys.path.insert(0, "../sim")
from python_fcsp.fcsp_codec import Channel, StreamParser, encode_frame


def crc16_xmodem(data: bytes) -> int:
    """Calculate CRC-16/XMODEM checksum."""
    crc = 0
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            if crc & 0x8000:
                crc = (crc << 1) ^ 0x1021
            else:
                crc <<= 1
        crc &= 0xFFFF
    return crc


def build_fourway_frame(command: int, address: int = 0, params: bytes = b"") -> bytes:
    """Build a BLHeli 4-way protocol frame."""
    if not params:
        params = b"\x00"
    param_len = len(params) if len(params) < 256 else 0
    body = bytes([
        0x2F,  # PC sync
        command & 0xFF,
        (address >> 8) & 0xFF,
        address & 0xFF,
        param_len,
    ]) + params
    crc = crc16_xmodem(body)
    return body + bytes([(crc >> 8) & 0xFF, crc & 0xFF])


class EscFlasher:
    """Simple ESC flashing client using FCSP."""

    def __init__(self, fcsp: FcspControlClient, timeout: float = 2.0):
        self.fcsp = fcsp
        self.timeout = timeout
        self._seq = 0
        self._parser = StreamParser(max_payload_len=512)

    def _next_seq(self) -> int:
        self._seq = (self._seq + 1) & 0xFFFF
        return self._seq

    def send_esc_bytes(self, data: bytes) -> None:
        """Send raw bytes to ESC via FCSP Channel 0x05."""
        frame = encode_frame(
            flags=0,
            channel=int(Channel.ESC_SERIAL),
            seq=self._next_seq(),
            payload=data,
        )
        self.fcsp._ser.write(frame)
        self.fcsp._ser.flush()

    def recv_esc_bytes(self) -> bytes:
        """Receive ESC response bytes from FCSP Channel 0x05."""
        deadline = time.monotonic() + self.timeout
        result = bytearray()
        ser = self.fcsp._ser

        while time.monotonic() < deadline:
            waiting = ser.in_waiting
            if waiting:
                chunk = ser.read(waiting)
            else:
                ser.timeout = 0.01
                chunk = ser.read(1)
                ser.timeout = self.fcsp.timeout
            if not chunk:
                if result and time.monotonic() > deadline - self.timeout + 0.1:
                    break
                continue

            frames = self._parser.feed(chunk)
            for f in frames:
                if f.channel == int(Channel.ESC_SERIAL) or f.channel == 0x05:
                    result.extend(f.payload)

            if len(result) >= 8:
                if result[0] == 0x2E and len(result) >= 5:
                    plen = result[4] if result[4] != 0 else 256
                    needed = 5 + plen + 1 + 2
                    if len(result) >= needed:
                        break

        return bytes(result)

    def send_command(self, command: int, address: int = 0, params: bytes = b"") -> bytes:
        """Send a 4-way command and return response."""
        frame = build_fourway_frame(command, address, params)
        self.send_esc_bytes(frame)
        return self.recv_esc_bytes()


def main():
    parser = argparse.ArgumentParser(description="ESC flashing example")
    parser.add_argument("--port", default="/dev/ttyUSB0", help="Serial port")
    parser.add_argument("--baud", type=int, default=115200, help="FCSP baud rate")
    parser.add_argument("--motor", type=int, default=0, choices=[0, 1, 2, 3], help="Motor channel")
    parser.add_argument("--break-ms", type=int, default=50, help="Break hold time (ms)")
    args = parser.parse_args()

    motor = args.motor
    sys_clk = 54_000_000
    esc_baud = 19200
    esc_baud_div = sys_clk // esc_baud

    print(f"ESC Flashing Example — motor {motor}")
    print(f"Port: {args.port} @ {args.baud}")
    print(f"ESC UART: {esc_baud} baud (div={esc_baud_div})")
    print()

    try:
        with FcspControlClient(port=args.port, baud=args.baud) as fcsp:
            print(f"Connected to {fcsp.port}")

            # Verify FPGA is alive
            who = fcsp.read_u32(WHO_AM_I)
            if who != EXPECTED_WHO_AM_I:
                print(f"ERROR: WHO_AM_I=0x{who:08X}, expected 0x{EXPECTED_WHO_AM_I:08X}")
                return
            print(f"FPGA WHO_AM_I: 0x{who:08X} ✓")

            flasher = EscFlasher(fcsp)

            try:
                # Step 1: Send DShot zero to idle ESC
                motor_addr = DSHOT_MOTOR_RAW[motor]
                mux_dshot = make_mux_word(mode=MODE_DSHOT, channel=motor)
                fcsp.write_u32(MUX_CTRL, mux_dshot, settle_s=0.005)
                fcsp.write_u32(DSHOT_CONFIG, 600, settle_s=0.005)
                print("[1] Sending DShot zero frames for 5s...")
                deadline = time.monotonic() + 5.0
                while time.monotonic() < deadline:
                    fcsp.write_u32(motor_addr, 0, settle_s=0.01)
                print("    ESC idle done.")

                # Step 2: Switch to serial mode
                mux = make_mux_word(mode=MODE_SERIAL, channel=motor, auto_passthrough_en=1)
                print(f"[2] Switch to serial mode (0x{mux:08X})")
                fcsp.write_u32(MUX_CTRL, mux, settle_s=0.005)

                # Step 3: Assert break
                mux_break = make_mux_word(mode=MODE_SERIAL, channel=motor, force_low=1, auto_passthrough_en=1)
                print(f"[3] Assert break (0x{mux_break:08X}), hold {args.break_ms}ms")
                fcsp.write_u32(MUX_CTRL, mux_break, settle_s=0.0)
                time.sleep(args.break_ms / 1000.0)

                # Step 4: Release break
                print(f"[4] Release break (0x{mux:08X})")
                fcsp.write_u32(MUX_CTRL, mux, settle_s=0.005)

                # Step 5: Set ESC baud
                print(f"[5] Set ESC baud divider to {esc_baud_div}")
                fcsp.write_u32(ESC_BAUD_DIV, esc_baud_div, settle_s=0.005)
                time.sleep(0.05)
                if fcsp._ser:
                    fcsp._ser.reset_input_buffer()

                # Step 6: BLHeli handshake
                print("[6] BLHeli handshake...")
                flasher.send_esc_bytes(b"BLHeli")
                response = flasher.recv_esc_bytes()
                print(f"    Response: {response.hex() if response else 'None'}")

                # Step 7: Get ESC info
                print("[7] Get ESC info...")
                resp = flasher.send_command(0x31)  # GET_VERSION
                print(f"    Version response: {resp.hex() if resp else 'None'}")

                resp = flasher.send_command(0x32)  # GET_NAME
                print(f"    Name response: {resp.hex() if resp else 'None'}")
                if resp and len(resp) > 5:
                    name = resp[5:5+resp[4]].rstrip(b"\x00").decode("ascii", errors="replace")
                    print(f"    ESC name: '{name}'")

                print("\nNote: Actual firmware flashing would use commands 0xFF (set address),")
                print("      0xFE (set buffer), 0x01 (program flash), 0x02 (erase page)")
                print("      See test_hw_esc_passthrough.py for full implementation.")

            finally:
                # Step 8: Restore DShot
                mux_dshot = make_mux_word(mode=MODE_DSHOT, channel=0, auto_passthrough_en=0)
                print(f"\n[8] Restore DShot mode (0x{mux_dshot:08X})")
                fcsp.write_u32(MUX_CTRL, mux_dshot, settle_s=0.01)

            print("\nDone.")

    except Exception as exc:
        print(f"ERROR: {exc}")
        import traceback
        traceback.print_exc()


if __name__ == "__main__":
    main()
