from __future__ import annotations

from dataclasses import dataclass
from enum import Enum

from .fcsp_codec import Channel, ControlOp, build_control_payload, encode_frame


class LegacyIntent(str, Enum):
    PASSTHROUGH_ENTER = "passthrough_enter"
    PASSTHROUGH_EXIT = "passthrough_exit"
    ESC_SCAN = "esc_scan"
    SET_MOTOR_SPEED = "set_motor_speed"
    GET_LINK_STATUS = "get_link_status"
    PING = "ping"


@dataclass(frozen=True)
class FcspCommand:
    channel: int
    op: int
    payload: bytes


def build_fcsp_command(intent: LegacyIntent, **kwargs: int) -> FcspCommand:
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

    raise ValueError(f"unsupported intent: {intent}")


def build_fcsp_frame_for_intent(*, seq: int, intent: LegacyIntent, flags: int = 0, **kwargs: int) -> bytes:
    cmd = build_fcsp_command(intent, **kwargs)
    control_payload = build_control_payload(cmd.op, cmd.payload)
    return encode_frame(flags=flags, channel=cmd.channel, seq=seq, payload=control_payload)
