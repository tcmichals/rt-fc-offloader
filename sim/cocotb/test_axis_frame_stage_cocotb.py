"""Cocotb tests for axis_frame_stage teaching/reference block."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, NextTimeStep


async def _reset(dut) -> None:
    dut.rst.value = 1
    dut.s_tvalid.value = 0
    dut.s_tdata.value = 0
    dut.s_tlast.value = 0
    dut.m_tready.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def _cycle(dut) -> None:
    await RisingEdge(dut.clk)
    await ReadOnly()
    await NextTimeStep()


@cocotb.test()
async def axis_basic_forwarding_and_tlast(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    # Keep sink ready and send two-byte frame.
    dut.m_tready.value = 1

    dut.s_tvalid.value = 1
    dut.s_tdata.value = 0x12
    dut.s_tlast.value = 0
    await _cycle(dut)

    assert bool(dut.m_tvalid.value), "expected output valid after first push"
    assert int(dut.m_tdata.value) == 0x12
    assert int(dut.m_tlast.value) == 0

    dut.s_tdata.value = 0x34
    dut.s_tlast.value = 1
    await _cycle(dut)

    assert bool(dut.m_tvalid.value), "expected output valid for second byte"
    assert int(dut.m_tdata.value) == 0x34
    assert int(dut.m_tlast.value) == 1

    # Stop driving input and allow drain.
    dut.s_tvalid.value = 0
    await _cycle(dut)


@cocotb.test()
async def axis_backpressure_holds_data_stable(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    # Push one byte, then stall sink.
    dut.m_tready.value = 1
    dut.s_tvalid.value = 1
    dut.s_tdata.value = 0xAB
    dut.s_tlast.value = 1
    await _cycle(dut)

    dut.m_tready.value = 0
    dut.s_tvalid.value = 0

    for _ in range(3):
        await _cycle(dut)
        assert bool(dut.m_tvalid.value), "valid should stay asserted while stalled"
        assert int(dut.m_tdata.value) == 0xAB, "data changed under backpressure"
        assert int(dut.m_tlast.value) == 1, "tlast changed under backpressure"

    # Release stall and ensure transfer completes.
    dut.m_tready.value = 1
    await _cycle(dut)


@cocotb.test()
async def axis_simultaneous_pop_push_replaces_payload(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    dut.m_tready.value = 1

    # Fill with first sample.
    dut.s_tvalid.value = 1
    dut.s_tdata.value = 0x55
    dut.s_tlast.value = 0
    await _cycle(dut)

    # While old sample is consumed, push new sample in same cycle.
    dut.s_tdata.value = 0x66
    dut.s_tlast.value = 1
    await _cycle(dut)

    assert bool(dut.m_tvalid.value), "stage should remain occupied after pop+push"
    assert int(dut.m_tdata.value) == 0x66, "expected replacement sample"
    assert int(dut.m_tlast.value) == 1

    # Drain final sample.
    dut.s_tvalid.value = 0
    await _cycle(dut)
