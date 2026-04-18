"""Comprehensive tests for the canonical FCSP codec.

Covers framing, CRC, stream parsing, control payloads, TLV encode/decode,
HELLO/GET_CAPS request/response helpers, read/write block payloads,
summary helpers, and format_capability_tlv.

This is the single source-of-truth test suite; esc-configurator should
import from this codec via its submodule link.
"""
import struct

import pytest

from python_fcsp.fcsp_codec import (
    FCSP_SYNC,
    FCSP_VERSION,
    CAP_TLV_DSHOT_MOTOR_COUNT,
    CAP_TLV_FEATURE_FLAGS,
    CAP_TLV_LED_COUNT,
    CAP_TLV_MAX_READ_BLOCK_LEN,
    CAP_TLV_MAX_WRITE_BLOCK_LEN,
    CAP_TLV_NEOPIXEL_COUNT,
    CAP_TLV_PROFILE_STRING,
    CAP_TLV_PWM_CHANNEL_COUNT,
    CAP_TLV_SUPPORTED_IO_SPACES,
    CAP_TLV_SUPPORTED_OPS,
    CAP_TLV_SUPPORTED_SPACES,
    HELLO_TLV_ENDPOINT_NAME,
    HELLO_TLV_ENDPOINT_ROLE,
    HELLO_TLV_INSTANCE_ID,
    HELLO_TLV_PROTOCOL_STRING,
    HELLO_TLV_PROFILE_STRING,
    HELLO_TLV_UPTIME_MS,
    CapabilitySummary,
    Channel,
    ControlOp,
    EndpointRole,
    Flags,
    Frame,
    HelloSummary,
    ResultCode,
    Space,
    StreamParser,
    Tlv,
    build_control_payload,
    build_get_caps_request,
    build_get_caps_response,
    build_hello_request,
    build_hello_response,
    build_read_block_payload,
    build_write_block_payload,
    crc16_xmodem,
    decode_frame,
    decode_tlvs,
    encode_frame,
    encode_tlvs,
    format_capability_tlv,
    parse_control_payload,
    parse_get_caps_request,
    parse_get_caps_response,
    parse_hello_request,
    parse_hello_response,
    summarize_capability_tlvs,
    summarize_hello_tlvs,
)


# ===================================================================
# Frame encode / decode
# ===================================================================

class TestFrameRoundtrip:
    def test_basic_roundtrip(self):
        raw = encode_frame(flags=int(Flags.ACK_REQUESTED), channel=0x01, seq=0x1234, payload=b"abc")
        frame = decode_frame(raw)
        assert frame.version == FCSP_VERSION
        assert frame.flags == int(Flags.ACK_REQUESTED)
        assert frame.channel == 0x01
        assert frame.seq == 0x1234
        assert frame.payload == b"abc"

    def test_empty_payload(self):
        raw = encode_frame(flags=0, channel=Channel.CONTROL, seq=0, payload=b"")
        frame = decode_frame(raw)
        assert frame.payload == b""
        assert frame.channel == Channel.CONTROL

    def test_max_seq(self):
        raw = encode_frame(flags=0, channel=0x01, seq=0xFFFF, payload=b"x")
        frame = decode_frame(raw)
        assert frame.seq == 0xFFFF

    def test_all_channels(self):
        for ch in Channel:
            raw = encode_frame(flags=0, channel=int(ch), seq=1, payload=b"ch")
            frame = decode_frame(raw)
            assert frame.channel == int(ch)

    def test_all_flags_combinations(self):
        for f in [Flags.ACK_REQUESTED, Flags.ACK_RESPONSE, Flags.ERROR,
                   Flags.ACK_REQUESTED | Flags.ERROR]:
            raw = encode_frame(flags=int(f), channel=0x01, seq=1, payload=b"f")
            frame = decode_frame(raw)
            assert frame.flags == int(f)

    def test_large_payload(self):
        big = bytes(range(256)) * 4  # 1024 bytes
        raw = encode_frame(flags=0, channel=0x01, seq=42, payload=big)
        frame = decode_frame(raw)
        assert frame.payload == big


class TestFrameErrors:
    def test_too_short(self):
        with pytest.raises(ValueError, match="too short"):
            decode_frame(b"\xA5\x01\x00")

    def test_bad_sync(self):
        raw = bytearray(encode_frame(flags=0, channel=1, seq=1, payload=b"x"))
        raw[0] = 0x00
        with pytest.raises(ValueError, match="invalid sync"):
            decode_frame(bytes(raw))

    def test_crc_mismatch(self):
        raw = bytearray(encode_frame(flags=0, channel=1, seq=1, payload=b"x"))
        raw[-1] ^= 0xFF
        with pytest.raises(ValueError, match="crc mismatch"):
            decode_frame(bytes(raw))

    def test_length_mismatch(self):
        raw = encode_frame(flags=0, channel=1, seq=1, payload=b"hello")
        with pytest.raises(ValueError, match="length mismatch"):
            decode_frame(raw[:-1])  # truncated


# ===================================================================
# CRC
# ===================================================================

class TestCrc16:
    def test_known_vector(self):
        # CRC-16/XMODEM of "123456789" = 0x31C3
        assert crc16_xmodem(b"123456789") == 0x31C3

    def test_empty(self):
        assert crc16_xmodem(b"") == 0x0000

    def test_single_byte(self):
        assert isinstance(crc16_xmodem(b"\x00"), int)


# ===================================================================
# Stream parser
# ===================================================================

class TestStreamParser:
    def test_resync_after_noise(self):
        parser = StreamParser(max_payload_len=256)
        f1 = encode_frame(flags=0, channel=0x01, seq=1, payload=b"hello")
        f2 = encode_frame(flags=0, channel=0x02, seq=2, payload=b"world")
        out = parser.feed(b"\x00\x11\x22" + f1 + b"\x99\x88" + f2)
        assert len(out) == 2
        assert out[0].seq == 1
        assert out[0].payload == b"hello"
        assert out[1].seq == 2
        assert out[1].payload == b"world"

    def test_recovers_from_crc_failure(self):
        parser = StreamParser(max_payload_len=256)
        good = encode_frame(flags=0, channel=0x01, seq=7, payload=b"good")
        bad = bytearray(encode_frame(flags=0, channel=0x01, seq=6, payload=b"bad"))
        bad[-1] ^= 0xFF
        out = parser.feed(bytes(bad) + good)
        assert len(out) == 1
        assert out[0].seq == 7

    def test_incremental_feed(self):
        parser = StreamParser(max_payload_len=256)
        raw = encode_frame(flags=0, channel=0x01, seq=3, payload=b"split")
        mid = len(raw) // 2
        out1 = parser.feed(raw[:mid])
        assert out1 == []
        out2 = parser.feed(raw[mid:])
        assert len(out2) == 1
        assert out2[0].payload == b"split"

    def test_rejects_oversized_payload(self):
        parser = StreamParser(max_payload_len=16)
        big = encode_frame(flags=0, channel=0x01, seq=1, payload=b"x" * 32)
        small = encode_frame(flags=0, channel=0x01, seq=2, payload=b"ok")
        out = parser.feed(big + small)
        assert len(out) == 1
        assert out[0].seq == 2

    def test_empty_feed(self):
        parser = StreamParser()
        assert parser.feed(b"") == []


# ===================================================================
# Control payload
# ===================================================================

class TestControlPayload:
    def test_roundtrip(self):
        body = b"\x01\x02\x03"
        payload = build_control_payload(ControlOp.PING, body)
        op_id, data = parse_control_payload(payload)
        assert op_id == int(ControlOp.PING)
        assert data == body

    def test_empty_body(self):
        payload = build_control_payload(ControlOp.HELLO)
        op_id, data = parse_control_payload(payload)
        assert op_id == int(ControlOp.HELLO)
        assert data == b""

    def test_parse_rejects_empty(self):
        with pytest.raises(ValueError, match="control payload empty"):
            parse_control_payload(b"")


# ===================================================================
# TLV encode / decode
# ===================================================================

class TestTlv:
    def test_roundtrip(self):
        tlvs = [
            Tlv(tlv_type=0x01, value=b"FCSP/1"),
            Tlv(tlv_type=0x03, value=(64).to_bytes(2, "big")),
        ]
        assert decode_tlvs(encode_tlvs(tlvs)) == tlvs

    def test_empty_value(self):
        tlvs = [Tlv(tlv_type=0xFF, value=b"")]
        raw = encode_tlvs(tlvs)
        assert decode_tlvs(raw) == tlvs

    def test_empty_list(self):
        assert encode_tlvs([]) == b""
        assert decode_tlvs(b"") == []

    def test_rejects_truncated_header(self):
        with pytest.raises(ValueError, match="truncated tlv header"):
            decode_tlvs(b"\x01")

    def test_rejects_truncated_value(self):
        with pytest.raises(ValueError, match="truncated tlv value"):
            decode_tlvs(bytes([0x10, 0x04, 0xAA]))

    def test_rejects_oversized_value(self):
        with pytest.raises(ValueError, match="tlv value too large"):
            encode_tlvs([Tlv(tlv_type=0x01, value=b"\x00" * 256)])

    def test_max_value_length(self):
        tlvs = [Tlv(tlv_type=0x01, value=b"\xAB" * 255)]
        assert decode_tlvs(encode_tlvs(tlvs)) == tlvs


# ===================================================================
# HELLO helpers
# ===================================================================

class TestHello:
    def test_request_roundtrip(self):
        tlv_blob = encode_tlvs([Tlv(tlv_type=0x03, value=b"FCSP/1")])
        raw = build_hello_request(tlv_blob)
        parsed = parse_hello_request(raw)
        assert parsed == tlv_blob

    def test_request_empty(self):
        raw = build_hello_request()
        parsed = parse_hello_request(raw)
        assert parsed == b""

    def test_response_roundtrip(self):
        tlv_blob = encode_tlvs([Tlv(tlv_type=0x05, value=(1234).to_bytes(4, "big"))])
        raw = build_hello_response(result=ResultCode.OK, hello_tlv=tlv_blob)
        result, parsed = parse_hello_response(raw)
        assert result == int(ResultCode.OK)
        assert parsed == tlv_blob

    def test_response_error_code(self):
        raw = build_hello_response(result=ResultCode.NOT_SUPPORTED, hello_tlv=b"")
        result, _ = parse_hello_response(raw)
        assert result == int(ResultCode.NOT_SUPPORTED)

    def test_request_parse_rejects_short(self):
        with pytest.raises(ValueError, match="too short"):
            parse_hello_request(b"\x00")

    def test_response_parse_rejects_short(self):
        with pytest.raises(ValueError, match="too short"):
            parse_hello_response(b"\x00\x00")


# ===================================================================
# GET_CAPS helpers
# ===================================================================

class TestGetCaps:
    def test_request_default(self):
        assert parse_get_caps_request(b"") == (0, 0)

    def test_request_explicit(self):
        raw = build_get_caps_request(page=2, max_len=512)
        assert parse_get_caps_request(raw) == (2, 512)

    def test_response_roundtrip(self):
        caps_tlv = encode_tlvs([
            Tlv(tlv_type=0x03, value=(128).to_bytes(2, "big")),
            Tlv(tlv_type=0x04, value=(64).to_bytes(2, "big")),
        ])
        raw = build_get_caps_response(
            result=ResultCode.OK, page=1, has_more=1, caps_tlv=caps_tlv,
        )
        result, page, has_more, parsed = parse_get_caps_response(raw)
        assert result == int(ResultCode.OK)
        assert page == 1
        assert has_more == 1
        assert parsed == caps_tlv

    def test_response_rejects_invalid_has_more(self):
        malformed = bytes([0x00, 0x00, 0x02, 0x00, 0x00])
        with pytest.raises(ValueError, match="invalid has_more"):
            parse_get_caps_response(malformed)

    def test_request_rejects_bad_length(self):
        with pytest.raises(ValueError, match="length mismatch"):
            parse_get_caps_request(b"\x00\x00")


# ===================================================================
# Read/Write block payloads  (legacy style with op-byte prefix)
# ===================================================================

class TestBlockPayloads:
    def test_read_block_contains_op_prefix(self):
        raw = build_read_block_payload(space=Space.FC_REG, address=0x40000000, length=4)
        assert raw[0] == ControlOp.READ_BLOCK
        assert raw[1] == Space.FC_REG

    def test_write_block_contains_op_prefix(self):
        raw = build_write_block_payload(space=Space.FC_REG, address=0x100, data=b"\xAA\x55")
        assert raw[0] == ControlOp.WRITE_BLOCK

    def test_read_block_wire_format(self):
        raw = build_read_block_payload(space=0x02, address=0x1234, length=16)
        # op(1) + space(1) + addr(4) + len(2) = 8 bytes
        assert len(raw) == 8
        assert raw[0] == ControlOp.READ_BLOCK
        assert raw[1] == 0x02
        assert int.from_bytes(raw[2:6], "big") == 0x1234
        assert int.from_bytes(raw[6:8], "big") == 16

    def test_write_block_wire_format(self):
        data = b"\x01\x02\x03\x04"
        raw = build_write_block_payload(space=0x01, address=0xDEAD, data=data)
        # op(1) + space(1) + addr(4) + len(2) + data(4) = 12 bytes
        assert len(raw) == 12
        assert raw[0] == ControlOp.WRITE_BLOCK
        assert int.from_bytes(raw[2:6], "big") == 0xDEAD
        assert int.from_bytes(raw[6:8], "big") == 4
        assert raw[8:] == data

    def test_read_block_default_space(self):
        raw = build_read_block_payload(address=0x0, length=1)
        assert raw[1] == 0x01  # default FC_REG

    def test_write_block_rejects_oversized(self):
        with pytest.raises(ValueError):
            build_write_block_payload(address=0, data=b"\x00" * 0x10000)


# ===================================================================
# Enum value coverage
# ===================================================================

class TestEnums:
    def test_channel_values(self):
        assert Channel.CONTROL == 0x01
        assert Channel.ESC_SERIAL == 0x05

    def test_control_op_values(self):
        assert ControlOp.PT_ENTER == 0x01
        assert ControlOp.HELLO == 0x13

    def test_result_code_values(self):
        assert ResultCode.OK == 0x00
        assert ResultCode.INTERNAL_ERROR == 0x06

    def test_space_values(self):
        assert Space.FC_REG == 0x01
        assert Space.NEO_IO == 0x13

    def test_endpoint_role_values(self):
        assert EndpointRole.OFFLOADER == 0x01
        assert EndpointRole.FLIGHT_CONTROLLER == 0x02
        assert EndpointRole.SIM == 0x03

    def test_flags_composable(self):
        combined = Flags.ACK_REQUESTED | Flags.ERROR
        assert int(combined) == 0x05


# ===================================================================
# HELLO TLV summary
# ===================================================================

class TestHelloSummary:
    def test_full_summary(self):
        tlvs = [
            Tlv(tlv_type=HELLO_TLV_ENDPOINT_ROLE, value=bytes([EndpointRole.OFFLOADER])),
            Tlv(tlv_type=HELLO_TLV_ENDPOINT_NAME, value=b"fcsp-offloader-01"),
            Tlv(tlv_type=HELLO_TLV_PROTOCOL_STRING, value=b"FCSP/1"),
            Tlv(tlv_type=HELLO_TLV_PROFILE_STRING, value=b"SERV8-50"),
            Tlv(tlv_type=HELLO_TLV_INSTANCE_ID, value=(42).to_bytes(2, "big")),
            Tlv(tlv_type=HELLO_TLV_UPTIME_MS, value=(99000).to_bytes(4, "big")),
        ]
        summary = summarize_hello_tlvs(tlvs)
        assert summary.endpoint_role == EndpointRole.OFFLOADER
        assert summary.endpoint_name == "fcsp-offloader-01"
        assert summary.protocol_string == "FCSP/1"
        assert summary.profile_string == "SERV8-50"
        assert summary.instance_id == 42
        assert summary.uptime_ms == 99000
        assert summary.entries == tuple(tlvs)

    def test_minimal_summary(self):
        summary = summarize_hello_tlvs([])
        assert summary.endpoint_role is None
        assert summary.endpoint_name == ""
        assert summary.instance_id is None
        assert summary.uptime_ms is None

    def test_unknown_tlv_ignored(self):
        tlvs = [
            Tlv(tlv_type=HELLO_TLV_ENDPOINT_NAME, value=b"test"),
            Tlv(tlv_type=0xFE, value=b"unknown"),
        ]
        summary = summarize_hello_tlvs(tlvs)
        assert summary.endpoint_name == "test"
        assert len(summary.entries) == 2


# ===================================================================
# Capability TLV summary
# ===================================================================

class TestCapabilitySummary:
    def test_full_summary(self):
        tlvs = [
            Tlv(tlv_type=CAP_TLV_SUPPORTED_OPS, value=b"\xFF\x00"),
            Tlv(tlv_type=CAP_TLV_SUPPORTED_SPACES, value=b"\x0F"),
            Tlv(tlv_type=CAP_TLV_MAX_READ_BLOCK_LEN, value=b"\x01\x00"),
            Tlv(tlv_type=CAP_TLV_MAX_WRITE_BLOCK_LEN, value=b"\x00\x80"),
            Tlv(tlv_type=CAP_TLV_PROFILE_STRING, value=b"SERV8-50-SPIPROD"),
            Tlv(tlv_type=CAP_TLV_FEATURE_FLAGS, value=b"\x00\x00\x00\x01"),
            Tlv(tlv_type=CAP_TLV_PWM_CHANNEL_COUNT, value=b"\x08"),
            Tlv(tlv_type=CAP_TLV_DSHOT_MOTOR_COUNT, value=b"\x00\x04"),
            Tlv(tlv_type=CAP_TLV_LED_COUNT, value=b"\x05"),
            Tlv(tlv_type=CAP_TLV_NEOPIXEL_COUNT, value=b"\x10"),
            Tlv(tlv_type=CAP_TLV_SUPPORTED_IO_SPACES, value=b"\x3F"),
        ]
        summary = summarize_capability_tlvs(tlvs)
        assert summary.supported_ops_bitmap == b"\xFF\x00"
        assert summary.supported_spaces_bitmap == b"\x0F"
        assert summary.max_read_block_length == 256
        assert summary.max_write_block_length == 128
        assert summary.profile_string == "SERV8-50-SPIPROD"
        assert summary.feature_flags == 1
        assert summary.pwm_channel_count == 8
        assert summary.dshot_motor_count == 4
        assert summary.led_count == 5
        assert summary.neopixel_count == 16
        assert summary.supported_io_spaces_bitmap == b"\x3F"

    def test_empty_summary(self):
        summary = summarize_capability_tlvs([])
        assert summary.supported_ops_bitmap is None
        assert summary.max_read_block_length is None
        assert summary.profile_string == ""
        assert summary.dshot_motor_count is None


# ===================================================================
# format_capability_tlv
# ===================================================================

class TestFormatCapabilityTlv:
    def test_numeric_tlvs(self):
        assert format_capability_tlv(
            Tlv(tlv_type=CAP_TLV_DSHOT_MOTOR_COUNT, value=b"\x00\x04")
        ) == "DSHOT motor count: 4"
        assert format_capability_tlv(
            Tlv(tlv_type=CAP_TLV_MAX_READ_BLOCK_LEN, value=b"\x01\x00")
        ) == "Max read block length: 256"
        assert format_capability_tlv(
            Tlv(tlv_type=CAP_TLV_LED_COUNT, value=b"\x05")
        ) == "LED count: 5"
        assert format_capability_tlv(
            Tlv(tlv_type=CAP_TLV_NEOPIXEL_COUNT, value=b"\x10")
        ) == "NeoPixel count: 16"
        assert format_capability_tlv(
            Tlv(tlv_type=CAP_TLV_PWM_CHANNEL_COUNT, value=b"\x08")
        ) == "PWM channel count: 8"

    def test_profile_string(self):
        assert format_capability_tlv(
            Tlv(tlv_type=CAP_TLV_PROFILE_STRING, value=b"SERV8-50-SPIPROD")
        ) == "Profile string: SERV8-50-SPIPROD"

    def test_feature_flags(self):
        assert format_capability_tlv(
            Tlv(tlv_type=CAP_TLV_FEATURE_FLAGS, value=b"\x00\x00\x00\x01")
        ) == "Feature flags: 0x00000001"

    def test_bitmap_tlvs(self):
        result = format_capability_tlv(
            Tlv(tlv_type=CAP_TLV_SUPPORTED_OPS, value=b"\xFF\x00")
        )
        assert "Supported ops bitmap" in result

    def test_empty_value(self):
        result = format_capability_tlv(
            Tlv(tlv_type=CAP_TLV_DSHOT_MOTOR_COUNT, value=b"")
        )
        assert "<empty>" in result

    def test_unknown_tlv_type(self):
        result = format_capability_tlv(
            Tlv(tlv_type=0xFE, value=b"\x42")
        )
        assert "TLV 0xFE" in result


# ===================================================================
# Wire compatibility: verify canonical codec matches esc-config wire format
# ===================================================================

class TestWireCompat:
    """Verify our encode_frame produces identical bytes to what esc-config expects."""

    def test_frame_sync_byte(self):
        raw = encode_frame(flags=0, channel=1, seq=0, payload=b"")
        assert raw[0] == 0xA5

    def test_frame_header_layout(self):
        raw = encode_frame(flags=0x03, channel=0x05, seq=0x1234, payload=b"AB")
        # [sync][ver][flags][ch][seq_hi][seq_lo][len_hi][len_lo][payload...][crc_hi][crc_lo]
        assert raw[1] == FCSP_VERSION  # version
        assert raw[2] == 0x03          # flags
        assert raw[3] == 0x05          # channel
        assert raw[4:6] == b"\x12\x34" # seq big-endian
        assert raw[6:8] == b"\x00\x02" # payload_len big-endian
        assert raw[8:10] == b"AB"      # payload

    def test_crc_position(self):
        raw = encode_frame(flags=0, channel=1, seq=0, payload=b"")
        # CRC covers header (no sync) + payload
        header_no_sync = raw[1:-2]
        expected_crc = crc16_xmodem(header_no_sync)
        actual_crc = int.from_bytes(raw[-2:], "big")
        assert actual_crc == expected_crc


# ===================================================================
# Edge cases / regression
# ===================================================================

class TestEdgeCases:
    def test_encode_frame_rejects_payload_too_long(self):
        with pytest.raises(ValueError, match="payload too long"):
            encode_frame(flags=0, channel=1, seq=0, payload=b"\x00" * 0x10000)

    def test_encode_frame_rejects_bad_seq(self):
        with pytest.raises(ValueError, match="seq out of range"):
            encode_frame(flags=0, channel=1, seq=0x10000, payload=b"")

    def test_stream_parser_many_frames(self):
        parser = StreamParser(max_payload_len=64)
        stream = b""
        for i in range(50):
            stream += encode_frame(flags=0, channel=1, seq=i, payload=bytes([i & 0xFF]))
        frames = parser.feed(stream)
        assert len(frames) == 50
        for i, f in enumerate(frames):
            assert f.seq == i

    def test_tlv_constants_no_collisions(self):
        hello_ids = [
            HELLO_TLV_ENDPOINT_ROLE, HELLO_TLV_ENDPOINT_NAME,
            HELLO_TLV_PROTOCOL_STRING, HELLO_TLV_PROFILE_STRING,
            HELLO_TLV_INSTANCE_ID, HELLO_TLV_UPTIME_MS,
        ]
        assert len(hello_ids) == len(set(hello_ids))

        cap_ids = [
            CAP_TLV_SUPPORTED_OPS, CAP_TLV_SUPPORTED_SPACES,
            CAP_TLV_MAX_READ_BLOCK_LEN, CAP_TLV_MAX_WRITE_BLOCK_LEN,
            CAP_TLV_PROFILE_STRING, CAP_TLV_FEATURE_FLAGS,
            CAP_TLV_PWM_CHANNEL_COUNT, CAP_TLV_DSHOT_MOTOR_COUNT,
            CAP_TLV_LED_COUNT, CAP_TLV_NEOPIXEL_COUNT,
            CAP_TLV_SUPPORTED_IO_SPACES,
        ]
        assert len(cap_ids) == len(set(cap_ids))
