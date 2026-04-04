"""Cocotb tests for fcsp_tx_fifo."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, NextTimeStep


async def _reset(dut) -> None:
    dut.rst.value = 1
    dut.s_tvalid.value = 0
    dut.s_tdata.value = 0
    dut.s_tlast.value = 0
    dut.s_channel.value = 0
    dut.s_flags.value = 0
    dut.s_seq.value = 0
    dut.s_payload_len.value = 0
    dut.m_tready.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def _cycle(dut) -> None:
    await RisingEdge(dut.clk)
    await ReadOnly()
    await NextTimeStep()


async def _sample_then_step(dut) -> None:
    await ReadOnly()
    await RisingEdge(dut.clk)
    await NextTimeStep()


async def _push_byte(dut, byte: int, last: int) -> None:
    dut.s_tvalid.value = 1
    dut.s_tdata.value = byte
    dut.s_tlast.value = last

    accepted = False
    while not accepted:
        await ReadOnly()
        accepted = bool(dut.s_tready.value)
        await RisingEdge(dut.clk)
        await NextTimeStep()


@cocotb.test()
async def tx_fifo_buffers_and_preserves_metadata(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    frame = [0x11, 0x22, 0x33]
    dut.s_channel.value = 0x04
    dut.s_flags.value = 0xA2
    dut.s_seq.value = 0x0031
    dut.s_payload_len.value = len(frame)

    # Stall sink and queue complete frame.
    dut.m_tready.value = 0
    for idx, b in enumerate(frame):
        await _push_byte(dut, b, int(idx == len(frame) - 1))

    dut.s_tvalid.value = 0
    await _cycle(dut)

    # Data should be held while stalled.
    assert bool(dut.m_tvalid.value), "expected buffered data while sink stalled"
    assert int(dut.m_tdata.value) == frame[0]
    assert int(dut.m_tlast.value) == 0
    assert int(dut.m_channel.value) == 0x04
    assert int(dut.m_flags.value) == 0xA2
    assert int(dut.m_seq.value) == 0x0031
    assert int(dut.m_payload_len.value) == len(frame)

    # Drain and verify ordering + frame_seen pulse on final pop.
    dut.m_tready.value = 1
    seen = []
    seen_last = []
    frame_seen_pulse = False
    for _ in range(10):
        await ReadOnly()
        if bool(dut.m_tvalid.value) and bool(dut.m_tready.value):
            seen.append(int(dut.m_tdata.value))
            seen_last.append(int(dut.m_tlast.value))
        await RisingEdge(dut.clk)
        await NextTimeStep()
        if bool(dut.o_frame_seen.value):
            frame_seen_pulse = True
        if len(seen) == len(frame):
            break

    assert seen == frame, f"unexpected drain order: {seen!r}"
    assert seen_last == [0, 0, 1], f"unexpected tlast sequence: {seen_last!r}"
    assert frame_seen_pulse, "expected o_frame_seen pulse when last byte leaves FIFO"


@cocotb.test()
async def tx_fifo_overflow_pulses_when_full(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    # Keep sink stalled so FIFO fills.
    dut.m_tready.value = 0
    dut.s_tvalid.value = 1
    dut.s_tdata.value = 0x5A
    dut.s_tlast.value = 0
    dut.s_channel.value = 0x01
    dut.s_flags.value = 0x00
    dut.s_seq.value = 0x0000
    dut.s_payload_len.value = 0

    overflow_seen = False
    not_ready_seen = False

    # Default DEPTH is 512; run long enough to fill then overrun.
    for _ in range(530):
        await _cycle(dut)
        if not bool(dut.s_tready.value):
            not_ready_seen = True
        if bool(dut.o_overflow.value):
            overflow_seen = True
            break

    dut.s_tvalid.value = 0

    assert not_ready_seen, "expected s_tready to deassert once FIFO is full"
    assert overflow_seen, "expected o_overflow pulse when writing while full"
