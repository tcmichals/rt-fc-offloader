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


def test_build_fcsp_command_read_block() -> None:
    cmd = build_fcsp_command(LegacyIntent.READ_BLOCK, space=0x11, address=0x01020304, length=0x0020)
    assert cmd.channel == 0x01
    assert cmd.op == int(ControlOp.READ_BLOCK)
    assert cmd.payload == bytes([0x11, 0x01, 0x02, 0x03, 0x04, 0x00, 0x20])


def test_build_fcsp_command_write_block() -> None:
    cmd = build_fcsp_command(LegacyIntent.WRITE_BLOCK, space=0x12, address=0x00000010, data=b"\xAA\xBB")
    assert cmd.channel == 0x01
    assert cmd.op == int(ControlOp.WRITE_BLOCK)
    assert cmd.payload == bytes([0x12, 0x00, 0x00, 0x00, 0x10, 0x00, 0x02, 0xAA, 0xBB])


def test_build_fcsp_command_get_caps() -> None:
    cmd = build_fcsp_command(LegacyIntent.GET_CAPS, page=2, max_len=256)
    assert cmd.channel == 0x01
    assert cmd.op == int(ControlOp.GET_CAPS)
    assert cmd.payload == bytes([0x02, 0x01, 0x00])


def test_build_fcsp_command_hello() -> None:
    cmd = build_fcsp_command(LegacyIntent.HELLO, hello_tlv=b"\x01\x01\x03")
    assert cmd.channel == 0x01
    assert cmd.op == int(ControlOp.HELLO)
    assert cmd.payload == bytes([0x00, 0x03, 0x01, 0x01, 0x03])
