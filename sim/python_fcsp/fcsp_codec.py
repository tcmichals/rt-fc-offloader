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


class EndpointRole(IntEnum):
    OFFLOADER = 0x01
    FLIGHT_CONTROLLER = 0x02
    SIM = 0x03


class Space(IntEnum):
    FC_REG = 0x01
    ESC_EEPROM = 0x02
    FLASH = 0x03
    TELEMETRY_SNAPSHOT = 0x04
    PWM_IO = 0x10
    DSHOT_IO = 0x11
    LED_IO = 0x12
    NEO_IO = 0x13


# ---------------------------------------------------------------------------
# HELLO TLV type constants
# ---------------------------------------------------------------------------
HELLO_TLV_ENDPOINT_ROLE = 0x01
HELLO_TLV_ENDPOINT_NAME = 0x02
HELLO_TLV_PROTOCOL_STRING = 0x03
HELLO_TLV_PROFILE_STRING = 0x04
HELLO_TLV_INSTANCE_ID = 0x05
HELLO_TLV_UPTIME_MS = 0x06

# ---------------------------------------------------------------------------
# Capability TLV type constants
# ---------------------------------------------------------------------------
CAP_TLV_SUPPORTED_OPS = 0x01
CAP_TLV_SUPPORTED_SPACES = 0x02
CAP_TLV_MAX_READ_BLOCK_LEN = 0x03
CAP_TLV_MAX_WRITE_BLOCK_LEN = 0x04
CAP_TLV_PROFILE_STRING = 0x05
CAP_TLV_FEATURE_FLAGS = 0x06
CAP_TLV_PWM_CHANNEL_COUNT = 0x10
CAP_TLV_DSHOT_MOTOR_COUNT = 0x11
CAP_TLV_LED_COUNT = 0x12
CAP_TLV_NEOPIXEL_COUNT = 0x13
CAP_TLV_SUPPORTED_IO_SPACES = 0x14


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


def build_write_block_payload(*, space: int = 0x01, address: int, data: bytes) -> bytes:
    if not (0 <= space <= 0xFF):
        raise ValueError("space out of range")
    if not (0 <= address <= 0xFFFFFFFF):
        raise ValueError("address out of range")
    if len(data) > 0xFFFF:
        raise ValueError("data too long")
    return (
        bytes([ControlOp.WRITE_BLOCK, space])
        + address.to_bytes(4, "big")
        + len(data).to_bytes(2, "big")
        + data
    )


def build_read_block_payload(*, space: int = 0x01, address: int, length: int) -> bytes:
    if not (0 <= space <= 0xFF):
        raise ValueError("space out of range")
    if not (0 <= address <= 0xFFFFFFFF):
        raise ValueError("address out of range")
    if not (0 <= length <= 0xFFFF):
        raise ValueError("length out of range")
    return (
        bytes([ControlOp.READ_BLOCK, space])
        + address.to_bytes(4, "big")
        + length.to_bytes(2, "big")
    )


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

    def __init__(self, *, max_payload_len: int = 512) -> None:
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


# ---------------------------------------------------------------------------
# Summary dataclasses  (ported from esc-configurator comm_proto/fcsp.py)
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class HelloSummary:
    endpoint_role: int | None
    endpoint_name: str
    protocol_string: str
    profile_string: str
    instance_id: int | None
    uptime_ms: int | None
    entries: tuple[Tlv, ...]


@dataclass(frozen=True)
class CapabilitySummary:
    supported_ops_bitmap: bytes | None
    supported_spaces_bitmap: bytes | None
    max_read_block_length: int | None
    max_write_block_length: int | None
    profile_string: str
    feature_flags: int | None
    pwm_channel_count: int | None
    dshot_motor_count: int | None
    led_count: int | None
    neopixel_count: int | None
    supported_io_spaces_bitmap: bytes | None
    entries: tuple[Tlv, ...]


def summarize_hello_tlvs(entries: list[Tlv]) -> HelloSummary:
    endpoint_role: int | None = None
    endpoint_name = ""
    protocol_string = ""
    profile_string = ""
    instance_id: int | None = None
    uptime_ms: int | None = None

    for entry in entries:
        value = bytes(entry.value)
        if entry.tlv_type == HELLO_TLV_ENDPOINT_ROLE and value:
            endpoint_role = int(value[0])
        elif entry.tlv_type == HELLO_TLV_ENDPOINT_NAME:
            endpoint_name = value.decode("utf-8", errors="replace")
        elif entry.tlv_type == HELLO_TLV_PROTOCOL_STRING:
            protocol_string = value.decode("utf-8", errors="replace")
        elif entry.tlv_type == HELLO_TLV_PROFILE_STRING:
            profile_string = value.decode("utf-8", errors="replace")
        elif entry.tlv_type == HELLO_TLV_INSTANCE_ID and value:
            instance_id = int.from_bytes(value, "big")
        elif entry.tlv_type == HELLO_TLV_UPTIME_MS and value:
            uptime_ms = int.from_bytes(value, "big")

    return HelloSummary(
        endpoint_role=endpoint_role,
        endpoint_name=endpoint_name,
        protocol_string=protocol_string,
        profile_string=profile_string,
        instance_id=instance_id,
        uptime_ms=uptime_ms,
        entries=tuple(entries),
    )


def summarize_capability_tlvs(entries: list[Tlv]) -> CapabilitySummary:
    supported_ops_bitmap: bytes | None = None
    supported_spaces_bitmap: bytes | None = None
    max_read_block_length: int | None = None
    max_write_block_length: int | None = None
    profile_string = ""
    feature_flags: int | None = None
    pwm_channel_count: int | None = None
    dshot_motor_count: int | None = None
    led_count: int | None = None
    neopixel_count: int | None = None
    supported_io_spaces_bitmap: bytes | None = None
    for entry in entries:
        value = bytes(entry.value)
        if entry.tlv_type == CAP_TLV_SUPPORTED_OPS:
            supported_ops_bitmap = value
        elif entry.tlv_type == CAP_TLV_SUPPORTED_SPACES:
            supported_spaces_bitmap = value
        elif entry.tlv_type == CAP_TLV_MAX_READ_BLOCK_LEN and value:
            max_read_block_length = int.from_bytes(value, "big")
        elif entry.tlv_type == CAP_TLV_MAX_WRITE_BLOCK_LEN and value:
            max_write_block_length = int.from_bytes(value, "big")
        elif entry.tlv_type == CAP_TLV_PROFILE_STRING:
            profile_string = value.decode("utf-8", errors="replace")
        elif entry.tlv_type == CAP_TLV_FEATURE_FLAGS and value:
            feature_flags = int.from_bytes(value, "big")
        elif entry.tlv_type == CAP_TLV_PWM_CHANNEL_COUNT and value:
            pwm_channel_count = int.from_bytes(value, "big")
        elif entry.tlv_type == CAP_TLV_DSHOT_MOTOR_COUNT and value:
            dshot_motor_count = int.from_bytes(value, "big")
        elif entry.tlv_type == CAP_TLV_LED_COUNT and value:
            led_count = int.from_bytes(value, "big")
        elif entry.tlv_type == CAP_TLV_NEOPIXEL_COUNT and value:
            neopixel_count = int.from_bytes(value, "big")
        elif entry.tlv_type == CAP_TLV_SUPPORTED_IO_SPACES:
            supported_io_spaces_bitmap = value
    return CapabilitySummary(
        supported_ops_bitmap=supported_ops_bitmap,
        supported_spaces_bitmap=supported_spaces_bitmap,
        max_read_block_length=max_read_block_length,
        max_write_block_length=max_write_block_length,
        profile_string=profile_string,
        feature_flags=feature_flags,
        pwm_channel_count=pwm_channel_count,
        dshot_motor_count=dshot_motor_count,
        led_count=led_count,
        neopixel_count=neopixel_count,
        supported_io_spaces_bitmap=supported_io_spaces_bitmap,
        entries=tuple(entries),
    )


def format_capability_tlv(entry: Tlv) -> str:
    label = {
        CAP_TLV_SUPPORTED_OPS: "Supported ops bitmap",
        CAP_TLV_SUPPORTED_SPACES: "Supported spaces bitmap",
        CAP_TLV_MAX_READ_BLOCK_LEN: "Max read block length",
        CAP_TLV_MAX_WRITE_BLOCK_LEN: "Max write block length",
        CAP_TLV_PROFILE_STRING: "Profile string",
        CAP_TLV_FEATURE_FLAGS: "Feature flags",
        CAP_TLV_PWM_CHANNEL_COUNT: "PWM channel count",
        CAP_TLV_DSHOT_MOTOR_COUNT: "DSHOT motor count",
        CAP_TLV_LED_COUNT: "LED count",
        CAP_TLV_NEOPIXEL_COUNT: "NeoPixel count",
        CAP_TLV_SUPPORTED_IO_SPACES: "Supported IO spaces bitmap",
    }.get(entry.tlv_type, f"TLV 0x{entry.tlv_type:02X}")

    value = bytes(entry.value)
    if not value:
        return f"{label}: <empty>"
    if entry.tlv_type in {
        CAP_TLV_MAX_READ_BLOCK_LEN,
        CAP_TLV_MAX_WRITE_BLOCK_LEN,
        CAP_TLV_PWM_CHANNEL_COUNT,
        CAP_TLV_DSHOT_MOTOR_COUNT,
        CAP_TLV_LED_COUNT,
        CAP_TLV_NEOPIXEL_COUNT,
    }:
        return f"{label}: {int.from_bytes(value, 'big')}"
    if entry.tlv_type == CAP_TLV_FEATURE_FLAGS:
        numeric = int.from_bytes(value, "big")
        return f"{label}: 0x{numeric:0{max(2, len(value) * 2)}X}"
    if entry.tlv_type in {CAP_TLV_SUPPORTED_OPS, CAP_TLV_SUPPORTED_SPACES, CAP_TLV_SUPPORTED_IO_SPACES}:
        return f"{label}: {value.hex(' ').upper()}"
    if all(32 <= byte < 127 for byte in value):
        return f"{label}: {value.decode('ascii', errors='replace')}"
    if len(value) <= 4:
        numeric = int.from_bytes(value, "big")
        return f"{label}: 0x{numeric:0{max(2, len(value) * 2)}X} ({numeric})"
    return f"{label}: {value.hex(' ').upper()}"
