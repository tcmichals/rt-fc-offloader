#!/usr/bin/env python3
"""BLHeli ESC passthrough test — read ESC version and settings via 4-way protocol.

Follows DESIGN.md §6 procedure:
  1. Switch mux to serial mode on target motor channel
  2. Assert break (force pin LOW) for bootloader entry
  3. Release break
  4. Set ESC UART baud to 19200
  5. Send BLHeli 4-way commands over FCSP CH 0x05
  6. Restore DShot mode on exit

Examples:
  python3 python/hw/test_hw_esc_passthrough.py --port /dev/ttyUSB1 --motor 0
  python3 python/hw/test_hw_esc_passthrough.py --port /dev/ttyUSB1 --motor 0 --read-settings
"""

from __future__ import annotations

import argparse
import struct
import sys
import time

sys.path.insert(0, ".")

from hwlib import (
    ESC_BAUD_DIV,
    EXPECTED_WHO_AM_I,
    FcspControlClient,
    MODE_DSHOT,
    MODE_SERIAL,
    MUX_CTRL,
    WHO_AM_I,
    make_mux_word,
)

# ---------------------------------------------------------------------------
# BLHeli 4-way protocol constants
# ---------------------------------------------------------------------------
FOURWAY_PC_SYNC = 0x2F
FOURWAY_FC_SYNC = 0x2E

CMD_TEST_ALIVE = 0x30
CMD_GET_VERSION = 0x31
CMD_GET_NAME = 0x32
CMD_GET_IF_VERSION = 0x33
CMD_EXIT = 0x34
CMD_DEVICE_INIT_FLASH = 0x37
CMD_DEVICE_READ = 0x3A
CMD_READ_EEPROM = 0x3D

FOURWAY_ACK = {
    0x00: "OK",
    0x01: "UNKNOWN_ERROR",
    0x02: "INVALID_CMD",
    0x03: "INVALID_CRC",
    0x04: "VERIFY_ERROR",
    0x05: "D_INVALID_CMD",
    0x06: "D_CMD_FAILED",
    0x07: "D_UNKNOWN_ERROR",
    0x08: "INVALID_CHANNEL",
    0x09: "INVALID_PARAM",
    0x0F: "GENERAL_ERROR",
}

# FCSP imports for ESC_SERIAL channel framing
sys.path.insert(0, "../sim")
from python_fcsp.fcsp_codec import (
    Channel,
    StreamParser,
    encode_frame,
)


def crc16_xmodem(data: bytes) -> int:
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
    if not params:
        params = b"\x00"
    param_len = len(params) if len(params) < 256 else 0
    body = bytes([
        FOURWAY_PC_SYNC,
        command & 0xFF,
        (address >> 8) & 0xFF,
        address & 0xFF,
        param_len,
    ]) + params
    crc = crc16_xmodem(body)
    return body + bytes([(crc >> 8) & 0xFF, crc & 0xFF])


def parse_fourway_response(data: bytes) -> dict:
    """Parse a complete 4-way response from raw bytes."""
    if len(data) < 8:
        raise ValueError(f"4-way response too short ({len(data)} bytes)")
    if data[0] != FOURWAY_FC_SYNC:
        raise ValueError(f"bad 4-way sync: 0x{data[0]:02X}")

    command = data[1]
    address = (data[2] << 8) | data[3]
    param_len = data[4] if data[4] != 0 else 256
    expected = 5 + param_len + 1 + 2
    if len(data) != expected:
        raise ValueError(f"4-way length mismatch: got {len(data)}, expected {expected}")

    params = data[5:5 + param_len]
    ack = data[5 + param_len]
    frame_crc = (data[-2] << 8) | data[-1]
    calc_crc = crc16_xmodem(data[:-2])

    return {
        "command": command,
        "address": address,
        "params": params,
        "ack": ack,
        "ack_str": FOURWAY_ACK.get(ack, f"UNKNOWN(0x{ack:02X})"),
        "crc_ok": frame_crc == calc_crc,
    }


class EscPassthrough:
    """BLHeli 4-way client operating via FCSP CONTROL + ESC_SERIAL channels."""

    def __init__(self, fcsp: FcspControlClient, esc_timeout: float = 2.0):
        self.fcsp = fcsp
        self.esc_timeout = esc_timeout
        self._seq = 0
        self._parser = StreamParser(max_payload_len=512)

    def _next_seq(self) -> int:
        self._seq = (self._seq + 1) & 0xFFFF
        return self._seq

    def _send_esc_bytes(self, data: bytes) -> None:
        """Send raw bytes to ESC via FCSP CH 0x05."""
        frame = encode_frame(
            flags=0,
            channel=int(Channel.ESC_SERIAL),
            seq=self._next_seq(),
            payload=data,
        )
        self.fcsp._ser.write(frame)

    def _recv_esc_bytes(self, timeout: float | None = None) -> bytes:
        """Receive accumulated ESC response bytes from FCSP CH 0x05 frames."""
        timeout = timeout or self.esc_timeout
        deadline = time.monotonic() + timeout
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
                # If we already have data and nothing new arrives after a short gap, done
                if result and time.monotonic() > deadline - timeout + 0.1:
                    break
                continue

            frames = self._parser.feed(chunk)
            for f in frames:
                if f.channel == int(Channel.ESC_SERIAL) or f.channel == 0x05:
                    result.extend(f.payload)

            # If we got enough for a 4-way response, return early
            if len(result) >= 8:
                # Check if we have a complete frame
                if result[0] == FOURWAY_FC_SYNC and len(result) >= 5:
                    plen = result[4] if result[4] != 0 else 256
                    needed = 5 + plen + 1 + 2
                    if len(result) >= needed:
                        break

        return bytes(result)

    def send_fourway(self, command: int, address: int = 0, params: bytes = b"",
                     timeout: float | None = None) -> dict:
        """Send a 4-way command and wait for response."""
        frame = build_fourway_frame(command, address, params)
        self._send_esc_bytes(frame)
        raw = self._recv_esc_bytes(timeout=timeout)
        if not raw:
            raise TimeoutError(f"No 4-way response for cmd 0x{command:02X}")

        # Find the response sync byte
        idx = raw.find(bytes([FOURWAY_FC_SYNC]))
        if idx < 0:
            raise ValueError(f"No 4-way sync in {len(raw)} bytes: {raw[:20].hex()}")
        raw = raw[idx:]
        return parse_fourway_response(raw)

    def test_alive(self) -> dict:
        return self.send_fourway(CMD_TEST_ALIVE)

    def get_version(self) -> dict:
        return self.send_fourway(CMD_GET_VERSION)

    def get_name(self) -> dict:
        return self.send_fourway(CMD_GET_NAME)

    def get_if_version(self) -> dict:
        return self.send_fourway(CMD_GET_IF_VERSION)

    def init_flash(self, esc_num: int = 0) -> dict:
        return self.send_fourway(CMD_DEVICE_INIT_FLASH,
                                 params=bytes([esc_num & 0x03]),
                                 timeout=10.0)

    def read_eeprom(self, address: int = 0, length: int = 0) -> dict:
        """Read ESC EEPROM. length=0 means 256 bytes."""
        return self.send_fourway(CMD_READ_EEPROM, address=address,
                                 params=bytes([length & 0xFF]),
                                 timeout=5.0)

    def exit_4way(self) -> dict:
        return self.send_fourway(CMD_EXIT)


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="BLHeli ESC passthrough: read version and settings")
    ap.add_argument("--port", default="/dev/ttyUSB1", help="Serial port (default: /dev/ttyUSB1)")
    ap.add_argument("--baud", type=int, default=115200, help="FCSP baud rate (default: 115200)")
    ap.add_argument("--motor", type=int, default=0, choices=[0, 1, 2, 3],
                    help="Motor channel 0-3 (default: 0)")
    ap.add_argument("--esc-baud", type=int, default=19200,
                    help="ESC UART baud rate (default: 19200)")
    ap.add_argument("--break-ms", type=int, default=50,
                    help="Break hold time in ms (default: 50)")
    ap.add_argument("--read-settings", action="store_true",
                    help="Also read EEPROM settings (48 bytes @ 0x7C00)")
    ap.add_argument("--timeout", type=float, default=3.0,
                    help="4-way response timeout in seconds (default: 3.0)")
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


def print_response(label: str, resp: dict) -> None:
    ack = resp["ack_str"]
    crc = "OK" if resp["crc_ok"] else "BAD"
    params = resp["params"]
    print(f"  {label}: ack={ack} crc={crc} params[{len(params)}]={params.hex(' ')}")


def main() -> None:
    args = parse_args()
    motor = args.motor
    sys_clk = 54_000_000
    esc_baud_div = sys_clk // args.esc_baud

    print(f"ESC Passthrough Test — motor {motor}")
    print(f"FCSP port={args.port} @ {args.baud}, ESC UART @ {args.esc_baud} (div={esc_baud_div})")
    print()

    try:
        with FcspControlClient(port=args.port, baud=args.baud) as fcsp:
            print(f"Connected: {fcsp.port}")

            # Verify FPGA is alive
            who = fcsp.read_u32(WHO_AM_I)
            if who != EXPECTED_WHO_AM_I:
                print(f"ERROR: WHO_AM_I=0x{who:08X}, expected 0x{EXPECTED_WHO_AM_I:08X}")
                return
            print(f"WHO_AM_I: 0x{who:08X} ✓")

            esc = EscPassthrough(fcsp, esc_timeout=args.timeout)

            try:
                # Step 1: Switch mux to serial mode on target channel
                mux = make_mux_word(mode=MODE_SERIAL, channel=motor, auto_passthrough_en=1)
                print(f"\n[1] Mux → serial CH{motor} (0x{mux:02X})")
                fcsp.write_u32(MUX_CTRL, mux, settle_s=0.005)

                # Step 2: Assert break
                mux_break = make_mux_word(mode=MODE_SERIAL, channel=motor, force_low=1, auto_passthrough_en=1)
                print(f"[2] Assert break (0x{mux_break:02X}), hold {args.break_ms}ms")
                fcsp.write_u32(MUX_CTRL, mux_break, settle_s=0.0)
                time.sleep(args.break_ms / 1000.0)

                # Step 3: Release break
                print(f"[3] Release break (0x{mux:02X})")
                fcsp.write_u32(MUX_CTRL, mux, settle_s=0.005)

                # Step 4: Set ESC baud
                print(f"[4] ESC baud divider → {esc_baud_div}")
                fcsp.write_u32(ESC_BAUD_DIV, esc_baud_div, settle_s=0.005)

                # Drain any stale bytes
                time.sleep(0.05)
                if fcsp._ser:
                    fcsp._ser.reset_input_buffer()

                # Step 5: 4-way commands
                print(f"\n[5] BLHeli 4-way protocol:")

                # Test alive
                print("  Sending test_alive...")
                try:
                    resp = esc.test_alive()
                    print_response("test_alive", resp)
                except (TimeoutError, ValueError) as e:
                    print(f"  test_alive FAILED: {e}")
                    print("  (ESC may not have entered bootloader)")
                    return

                # Get interface version
                print("  Sending get_version...")
                try:
                    resp = esc.get_version()
                    print_response("get_version", resp)
                    if resp["ack"] == 0 and len(resp["params"]) >= 2:
                        ver = int.from_bytes(resp["params"][:2], "big")
                        print(f"    → Interface version: {ver}")
                except (TimeoutError, ValueError) as e:
                    print(f"  get_version FAILED: {e}")

                # Get interface name
                print("  Sending get_name...")
                try:
                    resp = esc.get_name()
                    print_response("get_name", resp)
                    if resp["ack"] == 0:
                        name = resp["params"].rstrip(b"\x00").decode("ascii", errors="replace")
                        print(f"    → Interface name: '{name}'")
                except (TimeoutError, ValueError) as e:
                    print(f"  get_name FAILED: {e}")

                # Init flash on target ESC
                print(f"  Sending init_flash(esc={motor})...")
                try:
                    resp = esc.init_flash(motor)
                    print_response("init_flash", resp)
                    if resp["ack"] != 0:
                        print(f"  init_flash returned {resp['ack_str']} — cannot read ESC")
                        return
                except (TimeoutError, ValueError) as e:
                    print(f"  init_flash FAILED: {e}")
                    return

                # Read EEPROM settings
                if args.read_settings:
                    print(f"\n  Reading EEPROM settings (48 bytes @ 0x7C00)...")
                    try:
                        resp = esc.read_eeprom(address=0x7C00, length=48)
                        print_response("read_eeprom", resp)
                        if resp["ack"] == 0 and resp["params"]:
                            data = resp["params"]
                            print(f"    → {len(data)} bytes:")
                            for i in range(0, len(data), 16):
                                line = data[i:i+16]
                                hex_str = " ".join(f"{b:02X}" for b in line)
                                ascii_str = "".join(chr(b) if 32 <= b < 127 else "." for b in line)
                                print(f"      {0x7C00+i:04X}: {hex_str:<48s} {ascii_str}")
                    except (TimeoutError, ValueError) as e:
                        print(f"  read_eeprom FAILED: {e}")

                # Exit 4-way
                print(f"\n  Sending exit...")
                try:
                    resp = esc.exit_4way()
                    print_response("exit", resp)
                except (TimeoutError, ValueError) as e:
                    print(f"  exit FAILED: {e}")

            finally:
                # Step 6: Always restore DShot
                mux_dshot = make_mux_word(mode=MODE_DSHOT, channel=0, auto_passthrough_en=0)
                print(f"\n[6] Restore DShot (0x{mux_dshot:02X})")
                fcsp.write_u32(MUX_CTRL, mux_dshot, settle_s=0.01)

            print("\nDone.")

    except Exception as exc:
        print(f"ERROR: {exc}")
        return


if __name__ == "__main__":
    main()
