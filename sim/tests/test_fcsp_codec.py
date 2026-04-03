from python_fcsp.fcsp_codec import (
    ControlOp,
    Flags,
    ResultCode,
    StreamParser,
    Tlv,
    build_control_payload,
    build_get_caps_request,
    build_get_caps_response,
    build_hello_request,
    build_hello_response,
    decode_tlvs,
    decode_frame,
    encode_tlvs,
    encode_frame,
    parse_get_caps_request,
    parse_get_caps_response,
    parse_hello_request,
    parse_hello_response,
    parse_control_payload,
)


def test_round_trip_encode_decode() -> None:
    raw = encode_frame(flags=int(Flags.ACK_REQUESTED), channel=0x01, seq=0x1234, payload=b"abc")
    frame = decode_frame(raw)

    assert frame.version == 0x01
    assert frame.flags == int(Flags.ACK_REQUESTED)
    assert frame.channel == 0x01
    assert frame.seq == 0x1234
    assert frame.payload == b"abc"


def test_stream_parser_resync_after_noise() -> None:
    parser = StreamParser(max_payload_len=256)

    f1 = encode_frame(flags=0, channel=0x01, seq=1, payload=b"hello")
    f2 = encode_frame(flags=0, channel=0x02, seq=2, payload=b"world")
    stream = b"\x00\x11\x22" + f1 + b"\x99\x88" + f2

    out = parser.feed(stream)

    assert len(out) == 2
    assert out[0].seq == 1
    assert out[0].payload == b"hello"
    assert out[1].seq == 2
    assert out[1].payload == b"world"


def test_stream_parser_recovers_from_crc_failure() -> None:
    parser = StreamParser(max_payload_len=256)

    good = encode_frame(flags=0, channel=0x01, seq=7, payload=b"good")
    bad = bytearray(encode_frame(flags=0, channel=0x01, seq=6, payload=b"bad"))
    bad[-1] ^= 0xFF

    out = parser.feed(bytes(bad) + good)

    assert len(out) == 1
    assert out[0].seq == 7
    assert out[0].payload == b"good"


def test_control_payload_helpers_roundtrip() -> None:
    body = b"\x01\x02\x03"
    payload = build_control_payload(ControlOp.PING, body)
    op_id, data = parse_control_payload(payload)

    assert op_id == int(ControlOp.PING)
    assert data == body


def test_control_payload_parse_rejects_empty() -> None:
    try:
        parse_control_payload(b"")
    except ValueError as exc:
        assert "control payload empty" in str(exc)
    else:
        raise AssertionError("expected ValueError for empty control payload")


def test_tlv_roundtrip() -> None:
    encoded = encode_tlvs([
        Tlv(tlv_type=0x01, value=b"FCSP/1"),
        Tlv(tlv_type=0x03, value=(64).to_bytes(2, "big")),
    ])

    decoded = decode_tlvs(encoded)
    assert decoded == [
        Tlv(tlv_type=0x01, value=b"FCSP/1"),
        Tlv(tlv_type=0x03, value=(64).to_bytes(2, "big")),
    ]


def test_decode_tlvs_rejects_truncated_value() -> None:
    malformed = bytes([0x10, 0x04, 0xAA])
    try:
        decode_tlvs(malformed)
    except ValueError as exc:
        assert "truncated tlv value" in str(exc)
    else:
        raise AssertionError("expected ValueError for truncated TLV")


def test_hello_request_roundtrip() -> None:
    tlv = encode_tlvs([Tlv(tlv_type=0x03, value=b"FCSP/1")])
    raw = build_hello_request(tlv)
    parsed = parse_hello_request(raw)

    assert parsed == tlv


def test_hello_response_roundtrip() -> None:
    tlv = encode_tlvs([Tlv(tlv_type=0x05, value=(1234).to_bytes(4, "big"))])
    raw = build_hello_response(result=ResultCode.OK, hello_tlv=tlv)
    result, parsed = parse_hello_response(raw)

    assert result == int(ResultCode.OK)
    assert parsed == tlv


def test_get_caps_request_default_and_explicit() -> None:
    assert parse_get_caps_request(b"") == (0, 0)

    raw = build_get_caps_request(page=2, max_len=512)
    assert parse_get_caps_request(raw) == (2, 512)


def test_get_caps_response_roundtrip() -> None:
    caps_tlv = encode_tlvs([
        Tlv(tlv_type=0x03, value=(128).to_bytes(2, "big")),
        Tlv(tlv_type=0x04, value=(64).to_bytes(2, "big")),
    ])
    raw = build_get_caps_response(
        result=ResultCode.OK,
        page=1,
        has_more=1,
        caps_tlv=caps_tlv,
    )

    result, page, has_more, parsed_caps_tlv = parse_get_caps_response(raw)
    assert result == int(ResultCode.OK)
    assert page == 1
    assert has_more == 1
    assert parsed_caps_tlv == caps_tlv


def test_parse_get_caps_response_rejects_invalid_has_more() -> None:
    malformed = bytes([0x00, 0x00, 0x02, 0x00, 0x00])
    try:
        parse_get_caps_response(malformed)
    except ValueError as exc:
        assert "invalid has_more" in str(exc)
    else:
        raise AssertionError("expected ValueError for invalid has_more")
