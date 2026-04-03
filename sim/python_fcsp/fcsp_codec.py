from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum
from enum import IntFlag
from typing import List

FCSP_SYNC = 0xA5
FCSP_VERSION = 0x01
_HEADER_NO_SYNC_LEN = 1 + 1 + 1 + 2 + 2  # version, flags, channel, seq, payload_len
_MIN_FRAME_LEN = 1 + _HEADER_NO_SYNC_LEN + 2  # sync + header + crc16


class Flags(IntFlag):
    ACK_REQUESTED = 0x01
    ACK_RESPONSE = 0x02
    ERROR = 0x04


class Channel(IntEnum):
    CONTROL = 0x01
    TELEMETRY = 0x02
    FC_LOG = 0x03
    DEBUG_TRACE = 0x04
    ESC_SERIAL = 0x05


class ControlOp(IntEnum):
    PT_ENTER = 0x01
    PT_EXIT = 0x02
    ESC_SCAN = 0x03
    SET_MOTOR_SPEED = 0x04
    GET_LINK_STATUS = 0x05
    PING = 0x06
    READ_BLOCK = 0x10
    WRITE_BLOCK = 0x11
    GET_CAPS = 0x12
    HELLO = 0x13


class ResultCode(IntEnum):
    OK = 0x00
    INVALID_ARGUMENT = 0x01
    BUSY = 0x02
    NOT_READY = 0x03
    NOT_SUPPORTED = 0x04
    CRC_OR_FRAME_ERROR = 0x05
    INTERNAL_ERROR = 0x06


class Space(IntEnum):
    FC_REG = 0x01
    ESC_EEPROM = 0x02
    FLASH = 0x03
    TELEMETRY_SNAPSHOT = 0x04
    PWM_IO = 0x10
    DSHOT_IO = 0x11
    LED_IO = 0x12
    NEO_IO = 0x13


@dataclass(frozen=True)
class Frame:
    version: int
    flags: int
    channel: int
    seq: int
    payload: bytes


@dataclass(frozen=True)
class Tlv:
    tlv_type: int
    value: bytes


def crc16_xmodem(data: bytes) -> int:
    crc = 0x0000
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            if crc & 0x8000:
                crc = ((crc << 1) ^ 0x1021) & 0xFFFF
            else:
                crc = (crc << 1) & 0xFFFF
    return crc


def encode_frame(*, flags: int, channel: int, seq: int, payload: bytes, version: int = FCSP_VERSION) -> bytes:
    if not (0 <= version <= 0xFF):
        raise ValueError("version out of range")
    if not (0 <= flags <= 0xFF):
        raise ValueError("flags out of range")
    if not (0 <= channel <= 0xFF):
        raise ValueError("channel out of range")
    if not (0 <= seq <= 0xFFFF):
        raise ValueError("seq out of range")
    if len(payload) > 0xFFFF:
        raise ValueError("payload too long")

    header = bytes([
        version,
        flags,
        channel,
    ]) + seq.to_bytes(2, "big") + len(payload).to_bytes(2, "big")

    crc = crc16_xmodem(header + payload)

    return bytes([FCSP_SYNC]) + header + payload + crc.to_bytes(2, "big")


def decode_frame(raw: bytes) -> Frame:
    if len(raw) < _MIN_FRAME_LEN:
        raise ValueError("frame too short")
    if raw[0] != FCSP_SYNC:
        raise ValueError("invalid sync")

    version = raw[1]
    flags = raw[2]
    channel = raw[3]
    seq = int.from_bytes(raw[4:6], "big")
    payload_len = int.from_bytes(raw[6:8], "big")

    expected_len = 1 + _HEADER_NO_SYNC_LEN + payload_len + 2
    if len(raw) != expected_len:
        raise ValueError("frame length mismatch")

    payload = raw[8 : 8 + payload_len]
    frame_crc = int.from_bytes(raw[-2:], "big")
    calc_crc = crc16_xmodem(raw[1:-2])
    if frame_crc != calc_crc:
        raise ValueError("crc mismatch")

    return Frame(version=version, flags=flags, channel=channel, seq=seq, payload=payload)


def build_control_payload(op_id: int, data: bytes = b"") -> bytes:
    return bytes([op_id & 0xFF]) + (data or b"")


def parse_control_payload(payload: bytes) -> tuple[int, bytes]:
    if not payload:
        raise ValueError("control payload empty")
    return payload[0], payload[1:]


def encode_tlvs(entries: list[Tlv]) -> bytes:
    out = bytearray()
    for entry in entries:
        value = bytes(entry.value)
        if len(value) > 0xFF:
            raise ValueError("tlv value too large")
        out.extend((entry.tlv_type & 0xFF, len(value) & 0xFF))
        out.extend(value)
    return bytes(out)


def decode_tlvs(data: bytes) -> list[Tlv]:
    pos = 0
    tlvs: list[Tlv] = []
    while pos < len(data):
        if pos + 2 > len(data):
            raise ValueError("truncated tlv header")
        tlv_type = data[pos]
        tlv_len = data[pos + 1]
        pos += 2
        if pos + tlv_len > len(data):
            raise ValueError("truncated tlv value")
        tlvs.append(Tlv(tlv_type=tlv_type, value=bytes(data[pos:pos + tlv_len])))
        pos += tlv_len
    return tlvs


def build_hello_request(client_hello_tlv: bytes = b"") -> bytes:
    payload = bytes(client_hello_tlv)
    if len(payload) > 0xFFFF:
        raise ValueError("hello tlv too large")
    return len(payload).to_bytes(2, "big") + payload


def parse_hello_request(data: bytes) -> bytes:
    if len(data) < 2:
        raise ValueError("hello request too short")
    hello_len = int.from_bytes(data[:2], "big")
    if len(data) != 2 + hello_len:
        raise ValueError("hello request length mismatch")
    return data[2:]


def build_hello_response(*, result: int, hello_tlv: bytes = b"") -> bytes:
    payload = bytes(hello_tlv)
    if len(payload) > 0xFFFF:
        raise ValueError("hello tlv too large")
    return bytes([result & 0xFF]) + len(payload).to_bytes(2, "big") + payload


def parse_hello_response(data: bytes) -> tuple[int, bytes]:
    if len(data) < 3:
        raise ValueError("hello response too short")
    result = data[0]
    hello_len = int.from_bytes(data[1:3], "big")
    if len(data) != 3 + hello_len:
        raise ValueError("hello response length mismatch")
    return result, data[3:]


def build_get_caps_request(*, page: int = 0, max_len: int = 0) -> bytes:
    if not (0 <= page <= 0xFF):
        raise ValueError("page out of range")
    if not (0 <= max_len <= 0xFFFF):
        raise ValueError("max_len out of range")
    return bytes([page]) + max_len.to_bytes(2, "big")


def parse_get_caps_request(data: bytes) -> tuple[int, int]:
    if not data:
        return 0, 0
    if len(data) != 3:
        raise ValueError("get_caps request length mismatch")
    return data[0], int.from_bytes(data[1:3], "big")


def build_get_caps_response(*, result: int, page: int, has_more: int, caps_tlv: bytes) -> bytes:
    if not (0 <= page <= 0xFF):
        raise ValueError("page out of range")
    if has_more not in (0, 1):
        raise ValueError("has_more must be 0 or 1")
    payload = bytes(caps_tlv)
    if len(payload) > 0xFFFF:
        raise ValueError("caps_tlv too large")
    return (
        bytes([result & 0xFF, page, has_more])
        + len(payload).to_bytes(2, "big")
        + payload
    )


def parse_get_caps_response(data: bytes) -> tuple[int, int, int, bytes]:
    if len(data) < 5:
        raise ValueError("get_caps response too short")
    result = data[0]
    page = data[1]
    has_more = data[2]
    if has_more not in (0, 1):
        raise ValueError("get_caps response has invalid has_more")
    caps_len = int.from_bytes(data[3:5], "big")
    if len(data) != 5 + caps_len:
        raise ValueError("get_caps response length mismatch")
    return result, page, has_more, data[5:]


class StreamParser:
    """Byte-stream FCSP parser with resynchronization behavior.

    - searches for sync byte
    - validates length and CRC
    - on failure advances by one byte and continues
    """

    def __init__(self, *, max_payload_len: int = 4096) -> None:
        self._buf = bytearray()
        self._max_payload_len = max_payload_len

    def feed(self, data: bytes) -> List[Frame]:
        self._buf.extend(data)
        out: List[Frame] = []

        while True:
            # 1) find sync
            sync_idx = self._find_sync()
            if sync_idx < 0:
                self._buf.clear()
                break
            if sync_idx > 0:
                del self._buf[:sync_idx]

            # need minimum header before parsing length
            if len(self._buf) < _MIN_FRAME_LEN:
                break

            payload_len = int.from_bytes(self._buf[6:8], "big")
            if payload_len > self._max_payload_len:
                # malformed length; shift by one and rescan
                del self._buf[0]
                continue

            frame_len = 1 + _HEADER_NO_SYNC_LEN + payload_len + 2
            if len(self._buf) < frame_len:
                break

            candidate = bytes(self._buf[:frame_len])
            try:
                frame = decode_frame(candidate)
                out.append(frame)
                del self._buf[:frame_len]
            except ValueError:
                # CRC or format failure: advance one byte and continue
                del self._buf[0]

        return out

    def _find_sync(self) -> int:
        try:
            return self._buf.index(FCSP_SYNC)
        except ValueError:
            return -1
