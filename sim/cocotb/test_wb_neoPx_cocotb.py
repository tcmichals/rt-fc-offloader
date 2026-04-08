"""Cocotb tests for wb_neoPx — 8-pixel WB NeoPixel controller."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, NextTimeStep


async def _reset(dut):
    dut.rst.value = 1
    dut.wb_adr_i.value = 0
    dut.wb_dat_i.value = 0
    dut.wb_sel_i.value = 0
    dut.wb_we_i.value = 0
    dut.wb_cyc_i.value = 0
    dut.wb_stb_i.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def _wb_write(dut, addr, data):
    dut.wb_adr_i.value = addr
    dut.wb_dat_i.value = data
    dut.wb_we_i.value = 1
    dut.wb_sel_i.value = 0xF
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
    raise TimeoutError("WB write did not ack")


async def _wb_read(dut, addr):
    dut.wb_adr_i.value = addr
    dut.wb_we_i.value = 0
    dut.wb_sel_i.value = 0xF
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
    raise TimeoutError("WB read did not ack")


@cocotb.test()
async def test_pixel_write_readback(dut):
    """Write pixel 0 and read it back."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    await _wb_write(dut, 0x00, 0x00FF0000)
    val = await _wb_read(dut, 0x00)
    assert val == 0x00FF0000, f"Pixel 0 expected 0x00FF0000, got 0x{val:08x}"


@cocotb.test()
async def test_all_pixels_independent(dut):
    """Write distinct values to all 8 pixels and read them back."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    for i in range(8):
        await _wb_write(dut, i * 4, (i + 1) * 0x11111111)

    for i in range(8):
        val = await _wb_read(dut, i * 4)
        expected = ((i + 1) * 0x11111111) & 0xFFFFFFFF
        assert val == expected, f"Pixel {i} expected 0x{expected:08x}, got 0x{val:08x}"


@cocotb.test()
async def test_trigger_produces_serial_output(dut):
    """Writing to the trigger address should eventually produce serial activity."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    # Set pixel 0 to a visible color
    await _wb_write(dut, 0x00, 0x00001100)
    # Trigger update
    await _wb_write(dut, 0x20, 0x00000001)

    # Watch for serial output activity
    saw_serial = False
    for _ in range(10_000):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.o_serial.value):
            saw_serial = True
            break
        await NextTimeStep()
    assert saw_serial, "o_serial should go high after trigger (sending pixel data)"


@cocotb.test()
async def test_trigger_address_reads_zero(dut):
    """Reading the trigger address range should return 0."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    val = await _wb_read(dut, 0x20)
    assert val == 0, f"Trigger address read expected 0, got 0x{val:08x}"
