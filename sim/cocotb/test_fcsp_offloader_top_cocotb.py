"""Cocotb smoke tests for the FCSP offloader top scaffold."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, NextTimeStep, with_timeout

from python_fcsp.fcsp_codec import build_control_payload, decode_frame, encode_frame


async def _reset(dut) -> None:
    dut.rst.value = 1
    dut.i_spi_sclk.value = 0
    dut.i_spi_cs_n.value = 1
    dut.i_spi_mosi.value = 0
    dut.i_usb_rx_valid.value = 0
    dut.i_usb_rx_byte.value = 0
    dut.i_usb_tx_ready.value = 1
    dut.m_serv_cmd_tready.value = 1
    dut.s_serv_rsp_tvalid.value = 0
    dut.s_serv_rsp_tdata.value = 0
    dut.s_serv_rsp_tlast.value = 0
    dut.i_pwm_in.value = 0

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


async def _collect_serv_cmd_payload(dut, expected_len: int) -> bytes:
    collected = bytearray()
    saw_last = False

    while len(collected) < expected_len or not saw_last:
        await RisingEdge(dut.clk)
        await ReadOnly()
        if bool(dut.m_serv_cmd_tvalid.value) and bool(dut.m_serv_cmd_tready.value):
            collected.append(int(dut.m_serv_cmd_tdata.value))
            saw_last = bool(dut.m_serv_cmd_tlast.value)
        await NextTimeStep()

    return bytes(collected)


async def _observe_serv_cmd_for_cycles(dut, cycles: int) -> bool:
    saw_serv_cmd = False
    for _ in range(cycles):
        await RisingEdge(dut.clk)
        await ReadOnly()
        saw_serv_cmd |= bool(dut.m_serv_cmd_tvalid.value)
        await NextTimeStep()
    return saw_serv_cmd


async def _drive_serv_response(dut, payload: bytes) -> None:
    for idx, byte in enumerate(payload):
        accepted = False
        wait_cycles = 0
        while not accepted:
            dut.s_serv_rsp_tvalid.value = 1
            dut.s_serv_rsp_tdata.value = byte
            dut.s_serv_rsp_tlast.value = int(idx == (len(payload) - 1))
            await ReadOnly()
            accepted = bool(dut.s_serv_rsp_tready.value)
            wait_cycles += 1
            if not accepted and wait_cycles >= 8:
                raise AssertionError(
                    "SERV response byte was not accepted within 8 cycles; "
                    f"idx={idx}, byte=0x{byte:02x}, "
                    f"bridge_state={int(dut.u_serv_bridge.state.value)}, "
                    f"framer_state={int(dut.u_ctrl_tx_framer.state.value)}, "
                    f"ctrl_tx_tready={int(dut.ctrl_tx_tready.value)}, "
                    f"ctrl_tx_fifo_tready={int(dut.ctrl_tx_fifo_tready.value)}, "
                    f"ctrl_tx_tvalid={int(dut.ctrl_tx_tvalid.value)}, "
                    f"ctrl_tx_tlast={int(dut.ctrl_tx_tlast.value)}, "
                    f"tx_wire_tvalid={int(dut.tx_wire_tvalid.value)}"
                )
            await RisingEdge(dut.clk)
            await NextTimeStep()

    dut.s_serv_rsp_tvalid.value = 0
    dut.s_serv_rsp_tdata.value = 0
    dut.s_serv_rsp_tlast.value = 0


async def _collect_usb_tx_bytes(dut, expected_len: int) -> bytes:
    collected = bytearray()
    while len(collected) < expected_len:
        await RisingEdge(dut.clk)
        await ReadOnly()
        if bool(dut.o_usb_tx_valid.value):
            collected.append(int(dut.o_usb_tx_byte.value))
        await NextTimeStep()
    return bytes(collected)


@cocotb.test()
async def control_frame_reaches_serv_and_response_exits_usb(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    control_payload = build_control_payload(0x06, b"ping")
    frame = encode_frame(flags=0, channel=0x01, seq=7, payload=control_payload)

    collector = cocotb.start_soon(_collect_serv_cmd_payload(dut, len(control_payload)))
    await with_timeout(_drive_usb_bytes(dut, frame), 100, "us")
    observed_cmd = await with_timeout(collector, 100, "us")

    assert observed_cmd == control_payload, (
        f"expected SERV command payload {control_payload!r}, got {observed_cmd!r}"
    )

    await RisingEdge(dut.clk)
    await ReadOnly()
    assert bool(dut.s_serv_rsp_tready.value), (
        "expected SERV response path to be ready after request completion; "
        f"bridge_state={int(dut.u_serv_bridge.state.value)}, "
        f"ctrl_tx_tready={int(dut.ctrl_tx_tready.value)}, "
        f"ctrl_tx_fifo_tready={int(dut.ctrl_tx_fifo_tready.value)}"
    )
    await NextTimeStep()

    response_payload = b"pong"
    expected_response = encode_frame(flags=0x02, channel=0x01, seq=7, payload=response_payload)
    tx_collector = cocotb.start_soon(_collect_usb_tx_bytes(dut, len(expected_response)))
    await with_timeout(_drive_serv_response(dut, response_payload), 100, "us")
    observed_tx = await with_timeout(tx_collector, 100, "us")

    assert observed_tx == expected_response, (
        f"expected USB TX frame {expected_response!r}, got {observed_tx!r}"
    )

    decoded = decode_frame(observed_tx)
    assert decoded.channel == 0x01
    assert decoded.flags == 0x02
    assert decoded.seq == 7
    assert decoded.payload == response_payload


@cocotb.test()
async def telemetry_frame_does_not_reach_serv_command_path(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    telemetry_payload = b"tele"
    frame = encode_frame(flags=0, channel=0x02, seq=9, payload=telemetry_payload)

    await with_timeout(_drive_usb_bytes(dut, frame), 100, "us")

    saw_serv_cmd = await with_timeout(_observe_serv_cmd_for_cycles(dut, 12), 100, "us")

    assert not saw_serv_cmd, "telemetry frame should not drive SERV command stream"


@cocotb.test()
async def bad_crc_control_frame_is_dropped_before_serv(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    control_payload = build_control_payload(0x06, b"fail")
    frame = bytearray(encode_frame(flags=0, channel=0x01, seq=11, payload=control_payload))
    frame[-1] ^= 0x01

    await with_timeout(_drive_usb_bytes(dut, bytes(frame)), 100, "us")

    saw_serv_cmd = await with_timeout(_observe_serv_cmd_for_cycles(dut, 20), 100, "us")

    assert not saw_serv_cmd, "bad CRC control frame should be dropped before SERV"