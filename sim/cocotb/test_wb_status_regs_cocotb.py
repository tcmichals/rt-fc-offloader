"""Cocotb tests for wb_status_regs teaching/reference peripheral."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, NextTimeStep


async def _reset(dut) -> None:
    dut.rst.value = 1
    dut.wb_cyc_i.value = 0
    dut.wb_stb_i.value = 0
    dut.wb_we_i.value = 0
    dut.wb_sel_i.value = 0xF
    dut.wb_adr_i.value = 0
    dut.wb_dat_i.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def _wb_write(dut, addr: int, data: int, sel: int = 0xF) -> None:
    dut.wb_adr_i.value = addr & 0xFF
    dut.wb_dat_i.value = data & 0xFFFFFFFF
    dut.wb_sel_i.value = sel & 0xF
    dut.wb_we_i.value = 1
    dut.wb_cyc_i.value = 1
    dut.wb_stb_i.value = 1

    await RisingEdge(dut.clk)
    await ReadOnly()
    ack = bool(dut.wb_ack_o.value)
    err = bool(dut.wb_err_o.value)
    await NextTimeStep()

    dut.wb_cyc_i.value = 0
    dut.wb_stb_i.value = 0
    dut.wb_we_i.value = 0

    assert ack and not err, f"write failed at addr=0x{addr:02X} ack={ack} err={err}"


async def _wb_read(dut, addr: int) -> int:
    dut.wb_adr_i.value = addr & 0xFF
    dut.wb_we_i.value = 0
    dut.wb_cyc_i.value = 1
    dut.wb_stb_i.value = 1

    await RisingEdge(dut.clk)
    await ReadOnly()
    ack = bool(dut.wb_ack_o.value)
    err = bool(dut.wb_err_o.value)
    data = int(dut.wb_dat_o.value)
    await NextTimeStep()

    dut.wb_cyc_i.value = 0
    dut.wb_stb_i.value = 0

    assert ack and not err, f"read failed at addr=0x{addr:02X} ack={ack} err={err}"
    return data


@cocotb.test()
async def wb_rw_and_partial_write_behavior(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    ctrl0 = await _wb_read(dut, 0x00)
    scratch0 = await _wb_read(dut, 0x04)
    assert ctrl0 == 0
    assert scratch0 == 0

    await _wb_write(dut, 0x00, 0xAABBCCDD)
    await _wb_write(dut, 0x04, 0x11223344)

    ctrl1 = await _wb_read(dut, 0x00)
    scratch1 = await _wb_read(dut, 0x04)
    assert ctrl1 == 0xAABBCCDD
    assert scratch1 == 0x11223344

    await _wb_write(dut, 0x00, 0x00003344, sel=0x3)
    ctrl2 = await _wb_read(dut, 0x00)
    assert ctrl2 == 0xAABB3344


@cocotb.test()
async def wb_ro_and_error_paths(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    status_before = await _wb_read(dut, 0x08)
    await _wb_write(dut, 0x08, 0xFFFF_FFFF)
    status_after = await _wb_read(dut, 0x08)

    assert (status_before & 0x1) in (0, 1)
    assert (status_after & 0x1) in (0, 1)

    counter0 = await _wb_read(dut, 0x0C)
    for _ in range(4):
        await RisingEdge(dut.clk)
    counter1 = await _wb_read(dut, 0x0C)
    assert counter1 > counter0

    # Invalid word address: wb_adr_i[5:2] = 4 (outside 0..3)
    dut.wb_adr_i.value = 0x10
    dut.wb_we_i.value = 0
    dut.wb_cyc_i.value = 1
    dut.wb_stb_i.value = 1

    await RisingEdge(dut.clk)
    await ReadOnly()
    ack = bool(dut.wb_ack_o.value)
    err = bool(dut.wb_err_o.value)
    await NextTimeStep()

    dut.wb_cyc_i.value = 0
    dut.wb_stb_i.value = 0

    assert err and not ack, f"expected err on invalid address, got ack={ack} err={err}"
