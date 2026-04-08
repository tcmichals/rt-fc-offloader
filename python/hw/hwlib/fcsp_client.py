"""Reusable FCSP CONTROL-channel client for hardware validation scripts."""

from __future__ import annotations

import pathlib
import struct
import sys
import time
from typing import Optional

import serial
from serial.tools import list_ports


def _ensure_sim_codec_on_path() -> None:
    # <repo>/python/hw/hwlib/fcsp_client.py -> parents[3] == <repo>
    repo_root = pathlib.Path(__file__).resolve().parents[3]
    sim_path = str(repo_root / "sim")
    if sim_path not in sys.path:
        sys.path.insert(0, sim_path)


_ensure_sim_codec_on_path()

from python_fcsp.fcsp_codec import (  # type: ignore[import-not-found]  # noqa: E402
    FCSP_SYNC,
    Channel,
    StreamParser,
    build_read_block_payload,
    build_write_block_payload,
    decode_frame,
    encode_frame,
)


class FcspControlClient:
    """Minimal FCSP register read/write helper over serial CONTROL channel."""

    def __init__(self, port: str = "auto", baud: int = 1_000_000, timeout: float = 0.5) -> None:
        self.port = port
        self.baud = baud
        self.timeout = timeout
        self._ser: Optional[serial.Serial] = None
        self._seq_counter = 0
        self._sim_mode = False
        self._sim_regs: dict[int, int] = {}

    def _init_sim_registers(self) -> None:
        from .registers import (
            DSHOT_CONFIG,
            DSHOT_MOTOR_RAW,
            DSHOT_MOTOR_THR,
            DSHOT_STATUS,
            EXPECTED_WHO_AM_I,
            LED_OUT,
            MUX_CTRL,
            NEO_UPDATE,
            WHO_AM_I,
        )

        self._sim_regs = {
            WHO_AM_I: EXPECTED_WHO_AM_I,
            MUX_CTRL: 0x00000001,  # default to DSHOT mode
            DSHOT_STATUS: 0x0000000F,
            DSHOT_CONFIG: 600,
            LED_OUT: 0x00000000,
            NEO_UPDATE: 0x00000000,
        }
        for addr in DSHOT_MOTOR_RAW:
            self._sim_regs[addr] = 0x00000000
        for addr in DSHOT_MOTOR_THR:
            self._sim_regs[addr] = 0x00000000

    @staticmethod
    def list_candidate_ports() -> list[str]:
        """Return likely USB serial device names in stable order."""
        ports = [p.device for p in list_ports.comports()]
        preferred: list[str] = []
        other: list[str] = []
        for p in ports:
            if "/dev/ttyUSB" in p or "/dev/ttyACM" in p:
                preferred.append(p)
            else:
                other.append(p)
        return preferred + other

    def _resolve_port(self) -> str:
        if self.port.lower() in {"sim", "simulation"}:
            return "sim"
        if self.port != "auto":
            return self.port
        candidates = self.list_candidate_ports()
        if not candidates:
            raise RuntimeError(
                "No serial ports found. Connect USB-UART device and re-run with --port <device> "
                "(examples: /dev/ttyUSB0, /dev/ttyACM0)."
            )
        return candidates[0]

    def open(self) -> None:
        resolved_port = self._resolve_port()
        if resolved_port == "sim":
            self._sim_mode = True
            self._ser = None
            self._init_sim_registers()
            self.port = resolved_port
            return
        try:
            self._ser = serial.Serial(resolved_port, baudrate=self.baud, timeout=self.timeout)
        except Exception as exc:
            candidates = self.list_candidate_ports()
            hint = ", ".join(candidates) if candidates else "<none>"
            raise RuntimeError(
                f"Could not open serial port '{resolved_port}' @ {self.baud}. "
                f"Available ports: {hint}"
            ) from exc
        self.port = resolved_port
        time.sleep(0.1)

    def close(self) -> None:
        if self._sim_mode:
            self._sim_mode = False
            self._sim_regs.clear()
            return
        if self._ser is not None:
            self._ser.close()
            self._ser = None

    def __enter__(self) -> "FcspControlClient":
        self.open()
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()

    def _next_seq(self) -> int:
        self._seq_counter = (self._seq_counter + 1) & 0xFFFF
        return self._seq_counter

    def write_u32(self, address: int, value: int, settle_s: float = 0.01) -> None:
        if self._sim_mode:
            from .registers import LED_CLEAR, LED_OUT, LED_SET, LED_TOGGLE

            value &= 0xFFFFFFFF
            if address == LED_OUT:
                self._sim_regs[LED_OUT] = value
            elif address == LED_TOGGLE:
                self._sim_regs[LED_OUT] = (self._sim_regs.get(LED_OUT, 0) ^ value) & 0xFFFFFFFF
            elif address == LED_CLEAR:
                self._sim_regs[LED_OUT] = (self._sim_regs.get(LED_OUT, 0) & (~value & 0xFFFFFFFF)) & 0xFFFFFFFF
            elif address == LED_SET:
                self._sim_regs[LED_OUT] = (self._sim_regs.get(LED_OUT, 0) | value) & 0xFFFFFFFF
            else:
                self._sim_regs[address] = value
            if settle_s > 0:
                time.sleep(min(settle_s, 0.001))
            return

        if self._ser is None:
            raise RuntimeError("FCSP client is not open")
        payload = build_write_block_payload(address=address, data=struct.pack(">I", value))
        frame = encode_frame(flags=0, channel=Channel.CONTROL, seq=self._next_seq(), payload=payload)
        self._ser.write(frame)
        time.sleep(settle_s)

    def read_u32(self, address: int, wait_s: float = 0.05) -> int:
        if self._sim_mode:
            if wait_s > 0:
                time.sleep(min(wait_s, 0.001))
            return self._sim_regs.get(address, 0x00000000)

        if self._ser is None:
            raise RuntimeError("FCSP client is not open")
        payload = build_read_block_payload(address=address, length=4)
        frame = encode_frame(flags=1, channel=Channel.CONTROL, seq=self._next_seq(), payload=payload)
        self._ser.reset_input_buffer()
        self._ser.write(frame)

        # Allow endpoint turnaround and tolerate stream chunking/misalignment.
        deadline = time.monotonic() + max(wait_s, self.timeout)
        parser = StreamParser(max_payload_len=512)
        seen = bytearray()

        while time.monotonic() < deadline:
            chunk = self._ser.read(self._ser.in_waiting or 64)
            if not chunk:
                continue

            seen.extend(chunk)
            frames = parser.feed(chunk)
            for frame_rx in frames:
                if frame_rx.channel != Channel.CONTROL:
                    continue
                if len(frame_rx.payload) < 7:
                    raise RuntimeError(
                        f"FCSP payload too short for 32-bit read (len={len(frame_rx.payload)})"
                    )
                return struct.unpack(">I", frame_rx.payload[3:7])[0]

        if not seen:
            raise RuntimeError(f"No FCSP response for read @ 0x{address:08X}")

        sample = bytes(seen[:24]).hex()
        sync_seen = bytes([FCSP_SYNC]) in seen
        raise RuntimeError(
            f"No decodable FCSP CONTROL response for read @ 0x{address:08X}; "
            f"bytes_seen={len(seen)} sync_seen={sync_seen} sample={sample}"
        )
