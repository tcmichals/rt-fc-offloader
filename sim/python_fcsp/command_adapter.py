from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Any

from .fcsp_codec import Channel, ControlOp, build_control_payload, encode_frame


class LegacyIntent(str, Enum):
    PASSTHROUGH_ENTER = "passthrough_enter"
    PASSTHROUGH_EXIT = "passthrough_exit"
    ESC_SCAN = "esc_scan"
    SET_MOTOR_SPEED = "set_motor_speed"
    GET_LINK_STATUS = "get_link_status"
    PING = "ping"
    READ_BLOCK = "read_block"
    WRITE_BLOCK = "write_block"
    GET_CAPS = "get_caps"
    HELLO = "hello"


@dataclass(frozen=True)
class FcspCommand:
    channel: int
    op: int
    payload: bytes


def build_fcsp_command(intent: LegacyIntent, **kwargs: Any) -> FcspCommand:
    if intent == LegacyIntent.PASSTHROUGH_ENTER:
        motor_index = int(kwargs["motor_index"]) & 0xFF
        data = bytes([motor_index])
        return FcspCommand(int(Channel.CONTROL), int(ControlOp.PT_ENTER), data)

    if intent == LegacyIntent.PASSTHROUGH_EXIT:
        return FcspCommand(int(Channel.CONTROL), int(ControlOp.PT_EXIT), b"")

    if intent == LegacyIntent.ESC_SCAN:
        motor_index = int(kwargs["motor_index"]) & 0xFF
        data = bytes([motor_index])
        return FcspCommand(int(Channel.CONTROL), int(ControlOp.ESC_SCAN), data)

    if intent == LegacyIntent.SET_MOTOR_SPEED:
        motor_index = int(kwargs["motor_index"]) & 0xFF
        speed = int(kwargs["speed"])
        if not (0 <= speed <= 0xFFFF):
            raise ValueError("speed out of range")
        data = bytes([motor_index]) + speed.to_bytes(2, "big")
        return FcspCommand(int(Channel.CONTROL), int(ControlOp.SET_MOTOR_SPEED), data)

    if intent == LegacyIntent.GET_LINK_STATUS:
        return FcspCommand(int(Channel.CONTROL), int(ControlOp.GET_LINK_STATUS), b"")

    if intent == LegacyIntent.PING:
        nonce = int(kwargs["nonce"])
        if not (0 <= nonce <= 0xFFFFFFFF):
            raise ValueError("nonce out of range")
        data = nonce.to_bytes(4, "big")
        return FcspCommand(int(Channel.CONTROL), int(ControlOp.PING), data)

    if intent == LegacyIntent.READ_BLOCK:
        space = int(kwargs["space"])
        address = int(kwargs["address"])
        length = int(kwargs["length"])
        if not (0 <= space <= 0xFF):
            raise ValueError("space out of range")
        if not (0 <= address <= 0xFFFFFFFF):
            raise ValueError("address out of range")
        if not (0 <= length <= 0xFFFF):
            raise ValueError("length out of range")
        data = bytes([space]) + address.to_bytes(4, "big") + length.to_bytes(2, "big")
        return FcspCommand(int(Channel.CONTROL), int(ControlOp.READ_BLOCK), data)

    if intent == LegacyIntent.WRITE_BLOCK:
        space = int(kwargs["space"])
        address = int(kwargs["address"])
        write_data = bytes(kwargs["data"])
        if not (0 <= space <= 0xFF):
            raise ValueError("space out of range")
        if not (0 <= address <= 0xFFFFFFFF):
            raise ValueError("address out of range")
        if len(write_data) > 0xFFFF:
            raise ValueError("data too long")
        data = (
            bytes([space])
            + address.to_bytes(4, "big")
            + len(write_data).to_bytes(2, "big")
            + write_data
        )
        return FcspCommand(int(Channel.CONTROL), int(ControlOp.WRITE_BLOCK), data)

    if intent == LegacyIntent.GET_CAPS:
        page = int(kwargs.get("page", 0))
        max_len = int(kwargs.get("max_len", 0))
        if not (0 <= page <= 0xFF):
            raise ValueError("page out of range")
        if not (0 <= max_len <= 0xFFFF):
            raise ValueError("max_len out of range")
        data = bytes([page]) + max_len.to_bytes(2, "big")
        return FcspCommand(int(Channel.CONTROL), int(ControlOp.GET_CAPS), data)

    if intent == LegacyIntent.HELLO:
        hello_tlv = bytes(kwargs.get("hello_tlv", b""))
        if len(hello_tlv) > 0xFFFF:
            raise ValueError("hello_tlv too large")
        data = len(hello_tlv).to_bytes(2, "big") + hello_tlv
        return FcspCommand(int(Channel.CONTROL), int(ControlOp.HELLO), data)

    raise ValueError(f"unsupported intent: {intent}")


def build_fcsp_frame_for_intent(*, seq: int, intent: LegacyIntent, flags: int = 0, **kwargs: int) -> bytes:
    cmd = build_fcsp_command(intent, **kwargs)
    control_payload = build_control_payload(cmd.op, cmd.payload)
    return encode_frame(flags=flags, channel=cmd.channel, seq=seq, payload=control_payload)
