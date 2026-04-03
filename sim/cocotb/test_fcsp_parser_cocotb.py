"""Cocotb tests for FCSP parser RTL behavior."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from python_fcsp.fcsp_codec import encode_frame


async def _reset(dut) -> None:
    dut.rst_n.value = 0
    dut.in_valid.value = 0
    dut.in_byte.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def _drive_bytes(dut, data: bytes) -> None:
    for b in data:
        dut.in_valid.value = 1
        dut.in_byte.value = b
        await RisingEdge(dut.clk)
    dut.in_valid.value = 0
    await RisingEdge(dut.clk)


@cocotb.test()
async def parser_detects_sync_and_completes_frame(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    frame = encode_frame(flags=0, channel=0x01, seq=1, payload=b"ping")

    saw_sync = False
    saw_header = False
    saw_done = False
    observed_payload_len = []
    observed_body_remaining = []

    for b in frame:
        dut.in_valid.value = 1
        dut.in_byte.value = b
        await RisingEdge(dut.clk)
        saw_sync |= bool(dut.o_sync_seen.value)
        saw_header |= bool(dut.o_header_valid.value)
        saw_done |= bool(dut.o_frame_done.value)
        observed_body_remaining.append(int(dut.body_remaining.value))
        if bool(dut.o_header_valid.value):
            observed_payload_len.append(int(dut.o_payload_len.value))

    dut.in_valid.value = 0
    await RisingEdge(dut.clk)

    assert saw_sync, "expected sync detection pulse"
    assert saw_header, "expected header_valid pulse"
    assert observed_payload_len and observed_payload_len[-1] == 4, (
        f"expected payload_len=4, got {observed_payload_len}"
    )
    assert saw_done, f"expected frame_done pulse; body_remaining={observed_body_remaining}"
    assert int(dut.o_len_error.value) == 0


@cocotb.test()
async def parser_resyncs_after_noise(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    frame = encode_frame(flags=0, channel=0x01, seq=2, payload=b"ok")
    stream = b"\x00\x11\x22\x33" + frame

    saw_done = False
    for b in stream:
        dut.in_valid.value = 1
        dut.in_byte.value = b
        await RisingEdge(dut.clk)
        saw_done |= bool(dut.o_frame_done.value)

    dut.in_valid.value = 0
    await RisingEdge(dut.clk)
    assert saw_done, "expected parser to recover and complete frame"


@cocotb.test()
async def parser_rejects_payload_len_over_512(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    # Manually craft: sync + header with payload_len=513, then no body needed
    header = bytes([
        0xA5,  # sync
        0x01,  # version
        0x00,  # flags
        0x01,  # channel
        0x00, 0x01,  # seq
        0x02, 0x01,  # payload_len = 513
    ])

    saw_len_error = False
    observed_payload_len = []
    for b in header:
        dut.in_valid.value = 1
        dut.in_byte.value = b
        await RisingEdge(dut.clk)
        saw_len_error |= bool(dut.o_len_error.value)
        if bool(dut.o_header_valid.value):
            observed_payload_len.append(int(dut.o_payload_len.value))

    dut.in_valid.value = 0
    await RisingEdge(dut.clk)

    assert saw_len_error, (
        f"expected len_error pulse for payload > 512; header lens seen={observed_payload_len}"
    )

