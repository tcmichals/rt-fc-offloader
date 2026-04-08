"""End-to-end ESC stream verification on fcsp_offloader_top.

This validates Channel 0x05 routing behavior through the top-level integration
that is currently compiled by `make test-top-cocotb-experimental`.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer, ReadOnly, NextTimeStep, with_timeout
from python_fcsp.fcsp_codec import encode_frame, Channel

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
    await Timer(100, unit="ns")
    dut.rst.value = 0
    await RisingEdge(dut.clk)

async def _send_usb_stream(dut, data: bytes):
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


async def _observe_esc_route_for_cycles(dut, cycles: int) -> bool:
    saw_esc_route = False
    for _ in range(cycles):
        await RisingEdge(dut.clk)
        await ReadOnly()
        saw_esc_route |= bool(dut.router_esc_tvalid.value)
        await NextTimeStep()
    return saw_esc_route


async def _observe_control_cmd_for_cycles(dut, cycles: int) -> bool:
    saw_control_cmd = False
    for _ in range(cycles):
        await RisingEdge(dut.clk)
        await ReadOnly()
        saw_control_cmd |= bool(dut.ctrl_rx_tvalid.value)
        await NextTimeStep()
    return saw_control_cmd

@cocotb.test()
async def test_auto_hijack_passthrough(dut) -> None:
    """Verifies ESC_SERIAL channel traffic routes to ESC stream path, not control-command path."""
    cocotb.start_soon(Clock(dut.clk, 18.5, unit="ns").start())
    await _reset(dut)

    # Send MSP-like trigger bytes over ESC_SERIAL channel.
    msp_packet = b"$M<\x00\xF5"
    stream_frame = encode_frame(flags=0, channel=Channel.ESC_SERIAL, seq=1, payload=msp_packet)

    await _send_usb_stream(dut, stream_frame)

    saw_esc_route = await _observe_esc_route_for_cycles(dut, 64)
    saw_control_cmd = await _observe_control_cmd_for_cycles(dut, 64)

    assert saw_esc_route, "Expected ESC_SERIAL payload to drive router ESC stream"
    assert not saw_control_cmd, "ESC_SERIAL traffic must not drive control command stream"


@cocotb.test()
async def test_msp_bypass_handles_multiple_serial_messages(dut) -> None:
    """Several ESC_SERIAL messages should continue routing to ESC stream without control-command leakage."""
    cocotb.start_soon(Clock(dut.clk, 18.5, unit="ns").start())
    await _reset(dut)

    # Send several sequential ESC_SERIAL messages.
    payloads = [b"MSG0", b"MSG1", b"MSG2", b"MSG3", b"MSG4"]
    seq = 20
    saw_any_esc_route = False
    for p in payloads:
        frame = encode_frame(flags=0, channel=Channel.ESC_SERIAL, seq=seq, payload=p)
        seq += 1
        await _send_usb_stream(dut, frame)
        saw_any_esc_route |= await _observe_esc_route_for_cycles(dut, 48)

    saw_control_cmd = await _observe_control_cmd_for_cycles(dut, 64)

    assert saw_any_esc_route, "Expected ESC routing activity for multi-message stream"
    assert not saw_control_cmd, "ESC_SERIAL multi-message stream must not leak into control command path"
