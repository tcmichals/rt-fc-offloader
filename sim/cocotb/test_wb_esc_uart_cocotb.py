"""Cocotb tests for wb_esc_uart — half-duplex ESC UART controller."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, NextTimeStep


# Use a fast baud divider for simulation speed
# CLK=100MHz, baud_div=10 → one bit period = 10 clocks
SIM_CLK_NS = 10
SIM_BAUD_DIV = 10


async def _reset(dut):
    dut.rst.value = 1
    dut.wb_adr_i.value = 0
    dut.wb_dat_i.value = 0
    dut.wb_we_i.value = 0
    dut.wb_stb_i.value = 0
    dut.wb_cyc_i.value = 0
    dut.rx_in.value = 1  # idle high
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def _wb_write(dut, addr, data):
    dut.wb_adr_i.value = addr
    dut.wb_dat_i.value = data
    dut.wb_we_i.value = 1
    dut.wb_cyc_i.value = 1
    dut.wb_stb_i.value = 1
    for _ in range(10):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if dut.wb_ack_o.value:
            await NextTimeStep()
            dut.wb_cyc_i.value = 0
            dut.wb_stb_i.value = 0
            dut.wb_we_i.value = 0
            return
        await NextTimeStep()
    raise TimeoutError("wb_esc_uart WB write did not ack")


async def _wb_read(dut, addr):
    dut.wb_adr_i.value = addr
    dut.wb_we_i.value = 0
    dut.wb_cyc_i.value = 1
    dut.wb_stb_i.value = 1
    for _ in range(10):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if dut.wb_ack_o.value:
            val = int(dut.wb_dat_o.value)
            await NextTimeStep()
            dut.wb_cyc_i.value = 0
            dut.wb_stb_i.value = 0
            return val
        await NextTimeStep()
    raise TimeoutError("wb_esc_uart WB read did not ack")


@cocotb.test()
async def test_initial_status_tx_ready(dut):
    """After reset, STATUS register bit0 (TX ready) should be set."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)

    status = await _wb_read(dut, 0x04)
    assert status & 1, f"STATUS bit0 (tx_ready) should be 1 after reset, got 0x{status:08x}"


@cocotb.test()
async def test_baud_div_write_readback(dut):
    """BAUD_DIV register (0x0C) should be writable and readable."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)

    await _wb_write(dut, 0x0C, SIM_BAUD_DIV)
    val = await _wb_read(dut, 0x0C)
    assert val == SIM_BAUD_DIV, f"BAUD_DIV expected {SIM_BAUD_DIV}, got {val}"


@cocotb.test()
async def test_tx_produces_start_bit(dut):
    """Writing TX_DATA should produce a start bit (low) on tx_out."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)

    # Set a fast baud rate
    await _wb_write(dut, 0x0C, SIM_BAUD_DIV)

    # Verify tx_out is idle high
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert int(dut.tx_out.value) == 1, "tx_out should be idle-high before TX"
    await NextTimeStep()

    # Write a byte to TX_DATA
    await _wb_write(dut, 0x00, 0x55)

    # Watch for start bit (tx_out goes low)
    saw_start = False
    for _ in range(50):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if not int(dut.tx_out.value):
            saw_start = True
            break
        await NextTimeStep()
    assert saw_start, "tx_out should go low (start bit) after TX_DATA write"


@cocotb.test()
async def test_tx_active_during_transmission(dut):
    """tx_active should be high during byte transmission."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)

    await _wb_write(dut, 0x0C, SIM_BAUD_DIV)
    await _wb_write(dut, 0x00, 0xAA)

    saw_active = False
    for _ in range(200):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.tx_active.value):
            saw_active = True
            break
        await NextTimeStep()
    assert saw_active, "tx_active should be high during transmission"


@cocotb.test()
async def test_tx_completes_returns_ready(dut):
    """After a full byte TX, STATUS tx_ready should re-assert."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)

    await _wb_write(dut, 0x0C, SIM_BAUD_DIV)
    await _wb_write(dut, 0x00, 0x42)

    # Wait for transmission to complete (start + 8 data + stop + guard)
    # At baud_div=10, total ~ 10 * 11 = 110 clocks + guard
    for _ in range(300):
        await RisingEdge(dut.clk)

    status = await _wb_read(dut, 0x04)
    assert status & 1, f"STATUS tx_ready should be 1 after TX completes, got 0x{status:08x}"
