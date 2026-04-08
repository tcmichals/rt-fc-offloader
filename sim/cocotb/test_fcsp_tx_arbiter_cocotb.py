"""Cocotb tests for fcsp_tx_arbiter."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, NextTimeStep


async def _reset(dut) -> None:
    dut.rst.value = 1
    dut.s_ctrl_tvalid.value = 0
    dut.s_esc_tvalid.value = 0
    dut.s_dbg_tvalid.value = 0
    dut.s_ctrl_tlast.value = 0
    dut.s_esc_tlast.value = 0
    dut.s_dbg_tlast.value = 0
    dut.m_tready.value = 0
    
    # Initialize data/channels
    dut.s_ctrl_tdata.value = 0x11
    dut.s_esc_tdata.value = 0x22
    dut.s_dbg_tdata.value = 0x33
    dut.s_ctrl_channel.value = 0x01
    dut.s_esc_channel.value = 0x02
    dut.s_dbg_channel.value = 0x03
    
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def _cycle(dut) -> None:
    await RisingEdge(dut.clk)
    await ReadOnly()
    await NextTimeStep()

@cocotb.test()
async def tx_arbiter_strict_priority(dut) -> None:
    # Current RTL policy is strict priority: CTRL > ESC > DBG.
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    # Asserts that if all are valid, CTRL gets priority over ESC over DBG.
    dut.s_ctrl_tvalid.value = 1
    dut.s_esc_tvalid.value = 1
    dut.s_dbg_tvalid.value = 1
    dut.m_tready.value = 1

    await _cycle(dut)
    
    # Assert output is CTRL
    assert bool(dut.m_tvalid.value), "m_tvalid should be high"
    assert int(dut.m_channel.value) == 0x01, f"Expected channel 1 (CTRL), got {int(dut.m_channel.value)}"
    assert bool(dut.s_ctrl_tready.value), "CTRL stream should be ready"

    # End the CTRL stream
    dut.s_ctrl_tlast.value = 1
    await _cycle(dut)
    dut.s_ctrl_tvalid.value = 0
    dut.s_ctrl_tlast.value = 0

    await _cycle(dut)

    # Assert output is now ESC
    assert bool(dut.m_tvalid.value), "m_tvalid should be high"
    assert int(dut.m_channel.value) == 0x02, f"Expected channel 2 (ESC), got {int(dut.m_channel.value)}"
    assert bool(dut.s_esc_tready.value), "ESC stream should be ready"
    
    # End the ESC stream
    dut.s_esc_tlast.value = 1
    await _cycle(dut)
    dut.s_esc_tvalid.value = 0
    dut.s_esc_tlast.value = 0

    await _cycle(dut)
    
    # Assert output is now DBG
    assert bool(dut.m_tvalid.value), "m_tvalid should be high"
    assert int(dut.m_channel.value) == 0x03, f"Expected channel 3 (DBG), got {int(dut.m_channel.value)}"
    assert bool(dut.s_dbg_tready.value), "DBG stream should be ready"

    dut.s_dbg_tlast.value = 1
    await _cycle(dut)
    dut.s_dbg_tvalid.value = 0
    dut.s_dbg_tlast.value = 0
    
    await _cycle(dut)
    assert not bool(dut.m_tvalid.value), "Should be idle now"


@cocotb.test()
async def tx_arbiter_reselects_ctrl_when_still_valid(dut) -> None:
    # Verify strict-priority behavior when CTRL remains continuously valid.
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    # Set all valid. First selection should be CTRL.
    dut.s_ctrl_tvalid.value = 1
    dut.s_esc_tvalid.value = 1
    dut.s_dbg_tvalid.value = 1
    dut.m_tready.value = 1

    await _cycle(dut)
    assert int(dut.m_channel.value) == 0x01, "Expected CTRL as first pick"

    # Finish CTRL
    dut.s_ctrl_tlast.value = 1
    await _cycle(dut)
    dut.s_ctrl_tlast.value = 0
    
    await _cycle(dut)
    # With strict priority, arbiter should reselect CTRL while it remains valid.
    assert int(dut.m_channel.value) == 0x01, f"Expected CTRL reselection, got {int(dut.m_channel.value)}"
    assert bool(dut.s_ctrl_tready.value), "CTRL stream should remain selected"

    # End the reselected CTRL frame; arbiter releases grant only on tlast handshake.
    dut.s_ctrl_tlast.value = 1
    await _cycle(dut)
    dut.s_ctrl_tlast.value = 0
    dut.s_ctrl_tvalid.value = 0

    await _cycle(dut)
    assert int(dut.m_channel.value) == 0x02, f"Expected ESC after CTRL deasserts, got {int(dut.m_channel.value)}"

    dut.s_esc_tlast.value = 1
    await _cycle(dut)
    dut.s_esc_tlast.value = 0
    dut.s_esc_tvalid.value = 0

    await _cycle(dut)
    assert int(dut.m_channel.value) == 0x03, f"Expected DBG after ESC finishes, got {int(dut.m_channel.value)}"

