"""Cocotb smoke tests for the FCSP offloader top scaffold."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, NextTimeStep, with_timeout

from python_fcsp.fcsp_codec import build_control_payload, decode_frame, encode_frame


def _try_extract_first_frame(raw: bytes):
    if not raw:
        return None
    for idx, b in enumerate(raw):
        if b != 0xA5:
            continue
        if idx + 8 > len(raw):
            continue
        payload_len = (raw[idx + 6] << 8) | raw[idx + 7]
        total_len = 1 + 7 + payload_len + 2
        end = idx + total_len
        if end > len(raw):
            continue
        candidate = bytes(raw[idx:end])
        try:
            return decode_frame(candidate)
        except ValueError:
            continue
    return None


async def _reset(dut) -> None:
    dut.rst.value = 1
    dut.i_spi_sclk.value = 0
    dut.i_spi_cs_n.value = 1
    dut.i_spi_mosi.value = 0
    dut.i_usb_rx_valid.value = 0
    dut.i_usb_rx_byte.value = 0
    dut.i_usb_tx_ready.value = 1
    dut.i_pwm_0.value = 0
    dut.i_pwm_1.value = 0
    dut.i_pwm_2.value = 0
    dut.i_pwm_3.value = 0
    dut.i_pwm_4.value = 0
    dut.i_pwm_5.value = 0
    dut.pc_rx_data.value = 0
    dut.pc_rx_valid.value = 0
    dut.led_dat_i.value = 0
    dut.led_ack_i.value = 0
    dut.s_dbg_tx_tvalid.value = 0
    dut.s_dbg_tx_tdata.value = 0
    dut.s_dbg_tx_tlast.value = 0
    dut.s_dbg_tx_channel.value = 0
    dut.s_dbg_tx_flags.value = 0
    dut.s_dbg_tx_seq.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def _drive_usb_bytes(dut, data: bytes) -> None:
    for byte in data:
        accepted = False
        while not accepted:
            dut.i_usb_rx_valid.value = 1
            dut.i_usb_rx_byte.value = byte
            await ReadOnly()
            accepted = bool(dut.o_usb_rx_ready.value)
            await RisingEdge(dut.clk)
            await NextTimeStep()
    dut.i_usb_rx_valid.value = 0
    await RisingEdge(dut.clk)
    await ReadOnly()
    await NextTimeStep()


async def _observe_wb_master_cmd_for_cycles(dut, cycles: int) -> bool:
    """Watch whether the internal WB master receives a command."""
    saw_cmd = False
    for _ in range(cycles):
        await RisingEdge(dut.clk)
        await ReadOnly()
        saw_cmd |= bool(dut.ctrl_rx_tvalid.value)
        await NextTimeStep()
    return saw_cmd


async def _collect_usb_tx_bytes(dut, expected_len: int) -> bytes:
    collected = bytearray()
    while len(collected) < expected_len:
        await RisingEdge(dut.clk)
        await ReadOnly()
        if bool(dut.o_usb_tx_valid.value):
            collected.append(int(dut.o_usb_tx_byte.value))
        await NextTimeStep()
    return bytes(collected)


async def _collect_first_spi_frame(dut, max_cycles: int = 20_000):
    collected = bytearray()
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if bool(dut.spi_tx_valid.value):
            collected.append(int(dut.spi_tx_byte.value))
            decoded = _try_extract_first_frame(collected)
            if decoded is not None:
                return decoded
        await NextTimeStep()
    return None


async def _observe_tx_activity_for_cycles(dut, cycles: int) -> bool:
    saw_activity = False
    for _ in range(cycles):
        await RisingEdge(dut.clk)
        await ReadOnly()
        saw_activity |= bool(dut.ctrl_tx_tvalid.value)
        saw_activity |= bool(dut.tx_wire_tvalid.value)
        await NextTimeStep()
    return saw_activity


async def _observe_usb_tx_activity_for_cycles(dut, cycles: int) -> bool:
    saw_activity = False
    for _ in range(cycles):
        await RisingEdge(dut.clk)
        await ReadOnly()
        saw_activity |= bool(dut.o_usb_tx_valid.value)
        await NextTimeStep()
    return saw_activity


async def _observe_control_route_to_usb_for_cycles(dut, cycles: int) -> tuple[bool, bool]:
    """Returns (saw_control_routed_to_usb, saw_spi_tx_activity)."""
    saw_routed_usb = False
    saw_spi_tx = False
    for _ in range(cycles):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if bool(dut.o_usb_tx_valid.value):
            saw_routed_usb = True
        saw_spi_tx |= bool(dut.spi_tx_valid.value)
        await NextTimeStep()
    return saw_routed_usb, saw_spi_tx


async def _drive_dbg_frame(dut, payload: bytes, *, channel: int = 0x04, flags: int = 0x00, seq: int = 0x1111) -> None:
    dut.s_dbg_tx_channel.value = channel & 0xFF
    dut.s_dbg_tx_flags.value = flags & 0xFF
    dut.s_dbg_tx_seq.value = seq & 0xFFFF

    for idx, byte in enumerate(payload):
        accepted = False
        while not accepted:
            dut.s_dbg_tx_tvalid.value = 1
            dut.s_dbg_tx_tdata.value = byte
            dut.s_dbg_tx_tlast.value = int(idx == (len(payload) - 1))
            await ReadOnly()
            accepted = bool(dut.s_dbg_tx_tready.value)
            await RisingEdge(dut.clk)
            await NextTimeStep()

    dut.s_dbg_tx_tvalid.value = 0
    dut.s_dbg_tx_tdata.value = 0
    dut.s_dbg_tx_tlast.value = 0


@cocotb.test()
async def control_frame_reaches_endpoint_and_response_exits_usb(dut) -> None:
    """Send a PING CONTROL frame; the internal WB master auto-responds via USB TX."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    control_payload = build_control_payload(0x06, b"ping")
    frame = encode_frame(flags=0, channel=0x01, seq=7, payload=control_payload)

    # WB master auto-processes the CONTROL frame and generates a response.
    await with_timeout(_drive_usb_bytes(dut, frame), 100, "us")

    # Expect USB TX activity from the auto-generated PING response.
    saw_usb_tx = await with_timeout(_observe_usb_tx_activity_for_cycles(dut, 512), 200, "us")
    assert saw_usb_tx, "expected WB master PING response to drive USB TX activity"


@cocotb.test()
async def telemetry_frame_does_not_reach_control_command_path(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    telemetry_payload = b"tele"
    frame = encode_frame(flags=0, channel=0x02, seq=9, payload=telemetry_payload)

    await with_timeout(_drive_usb_bytes(dut, frame), 100, "us")

    saw_control_cmd = await with_timeout(_observe_wb_master_cmd_for_cycles(dut, 12), 100, "us")

    assert not saw_control_cmd, "telemetry frame should not drive control command stream"


@cocotb.test()
async def bad_crc_control_frame_is_dropped_before_control_endpoint(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    control_payload = build_control_payload(0x06, b"fail")
    frame = bytearray(encode_frame(flags=0, channel=0x01, seq=11, payload=control_payload))
    frame[-1] ^= 0x01

    await with_timeout(_drive_usb_bytes(dut, bytes(frame)), 100, "us")

    saw_control_cmd = await with_timeout(_observe_wb_master_cmd_for_cycles(dut, 20), 100, "us")

    assert not saw_control_cmd, "bad CRC control frame should be dropped before control endpoint"


@cocotb.test()
async def control_response_is_routed_to_usb_path(dut) -> None:
    """PING response from the internal WB master must egress via USB, not SPI."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    control_payload = build_control_payload(0x06, b"route")
    req_frame = encode_frame(flags=0, channel=0x01, seq=0x21, payload=control_payload)

    await with_timeout(_drive_usb_bytes(dut, req_frame), 100, "us")

    saw_routed_usb, saw_spi_tx = await with_timeout(
        _observe_control_route_to_usb_for_cycles(dut, 512), 200, "us"
    )
    assert saw_routed_usb, "expected control response traffic to be routed to USB path"
    assert not saw_spi_tx, "control responses should not egress SPI in current top-level routing policy"


@cocotb.test()
async def debug_trace_input_is_framed_and_routed_to_usb(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    dbg_payload = b"dbg!"
    await with_timeout(_drive_dbg_frame(dut, dbg_payload, channel=0x04, seq=0x1234), 100, "us")

    usb_bytes = await with_timeout(_collect_usb_tx_bytes(dut, 1 + 7 + len(dbg_payload) + 2), 200, "us")
    frame = _try_extract_first_frame(usb_bytes)
    assert frame is not None, "expected framed DEBUG_TRACE packet on USB egress"
    assert frame.channel == 0x04, f"expected CH=0x04 frame on USB, got 0x{frame.channel:02x}"


@cocotb.test()
async def non_control_channels_never_drive_control_cmd(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    for ch in (0x02, 0x03, 0x04, 0x05):
        payload = bytes([ch, 0xAA, 0x55])
        frame = encode_frame(flags=0, channel=ch, seq=0x40 + ch, payload=payload)
        await with_timeout(_drive_usb_bytes(dut, frame), 100, "us")

    saw_control_cmd = await with_timeout(_observe_wb_master_cmd_for_cycles(dut, 64), 100, "us")
    assert not saw_control_cmd, "non-control channels (0x02-0x05) must not drive control command path"
