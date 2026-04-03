from python_fcsp.command_adapter import (
    LegacyIntent,
    build_fcsp_command,
    build_fcsp_frame_for_intent,
)
from python_fcsp.fcsp_codec import ControlOp, decode_frame, parse_control_payload


def test_build_fcsp_command_set_motor_speed() -> None:
    cmd = build_fcsp_command(LegacyIntent.SET_MOTOR_SPEED, motor_index=2, speed=1200)
    assert cmd.channel == 0x01
    assert cmd.op == int(ControlOp.SET_MOTOR_SPEED)
    assert cmd.payload == bytes([2]) + (1200).to_bytes(2, "big")


def test_build_fcsp_frame_for_ping() -> None:
    raw = build_fcsp_frame_for_intent(seq=7, intent=LegacyIntent.PING, nonce=0x12345678)
    frame = decode_frame(raw)
    assert frame.channel == 0x01
    op, payload = parse_control_payload(frame.payload)
    assert op == int(ControlOp.PING)
    assert payload == (0x12345678).to_bytes(4, "big")


def test_invalid_speed_rejected() -> None:
    try:
        build_fcsp_command(LegacyIntent.SET_MOTOR_SPEED, motor_index=0, speed=70000)
    except ValueError as exc:
        assert "speed out of range" in str(exc)
    else:
        raise AssertionError("expected ValueError for invalid speed")
