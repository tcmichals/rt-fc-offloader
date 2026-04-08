"""Cocotb tests for wb_io_bus address decoder / mux."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, NextTimeStep


async def _reset(dut):
    dut.rst.value = 1
    dut.wbm_adr_i.value = 0
    dut.wbm_dat_i.value = 0
    dut.wbm_sel_i.value = 0
    dut.wbm_we_i.value = 0
    dut.wbm_cyc_i.value = 0
    dut.wbm_stb_i.value = 0
    # Tie off all slave ack/data inputs
    for prefix in ("dshot", "mux", "neo", "esc", "pwm", "led"):
        getattr(dut, f"{prefix}_ack_i").value = 0
        getattr(dut, f"{prefix}_dat_i").value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def _wb_read(dut, addr):
    """Single-cycle WB read. Returns 32-bit data."""
    dut.wbm_adr_i.value = addr
    dut.wbm_we_i.value = 0
    dut.wbm_sel_i.value = 0xF
    dut.wbm_cyc_i.value = 1
    dut.wbm_stb_i.value = 1
    for _ in range(10):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if dut.wbm_ack_o.value:
            val = int(dut.wbm_dat_o.value)
            await NextTimeStep()
            dut.wbm_cyc_i.value = 0
            dut.wbm_stb_i.value = 0
            return val
        await NextTimeStep()
    raise TimeoutError(f"WB read at 0x{addr:08x} did not ack")


async def _wb_write(dut, addr, data):
    """Single-cycle WB write."""
    dut.wbm_adr_i.value = addr
    dut.wbm_dat_i.value = data
    dut.wbm_we_i.value = 1
    dut.wbm_sel_i.value = 0xF
    dut.wbm_cyc_i.value = 1
    dut.wbm_stb_i.value = 1
    for _ in range(10):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if dut.wbm_ack_o.value:
            await NextTimeStep()
            dut.wbm_cyc_i.value = 0
            dut.wbm_stb_i.value = 0
            dut.wbm_we_i.value = 0
            return
        await NextTimeStep()
    raise TimeoutError(f"WB write at 0x{addr:08x} did not ack")


async def _stub_slave_ack(dut, prefix, read_data=0xDEAD_BEEF):
    """Auto-ack a single WB transaction on a slave port, returning read_data."""
    while True:
        await RisingEdge(dut.clk)
        await ReadOnly()
        cyc = getattr(dut, f"{prefix}_cyc_o").value
        stb = getattr(dut, f"{prefix}_stb_o").value
        if cyc and stb:
            await NextTimeStep()
            getattr(dut, f"{prefix}_ack_i").value = 1
            getattr(dut, f"{prefix}_dat_i").value = read_data
            await RisingEdge(dut.clk)
            await NextTimeStep()
            getattr(dut, f"{prefix}_ack_i").value = 0
            return
        await NextTimeStep()


@cocotb.test()
async def test_who_am_i_returns_identity(dut):
    """WHO_AM_I read at 0x40000000 returns 0xFC500002."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)
    val = await _wb_read(dut, 0x4000_0000)
    assert val == 0xFC50_0002, f"WHO_AM_I expected 0xFC500002, got 0x{val:08x}"


@cocotb.test()
async def test_dshot_page_routes_to_dshot_slave(dut):
    """Write to DShot page (0x40000300) routes to dshot slave port."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    stub = cocotb.start_soon(_stub_slave_ack(dut, "dshot", 0x1234_5678))
    val = await _wb_read(dut, 0x4000_0300)
    await stub
    assert val == 0x1234_5678, f"DShot read expected 0x12345678, got 0x{val:08x}"


@cocotb.test()
async def test_neo_page_routes_to_neo_slave(dut):
    """Read from NeoPixel page (0x40000600) routes to neo slave port."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    stub = cocotb.start_soon(_stub_slave_ack(dut, "neo", 0xAABB_CCDD))
    val = await _wb_read(dut, 0x4000_0600)
    await stub
    assert val == 0xAABB_CCDD, f"Neo read expected 0xAABBCCDD, got 0x{val:08x}"


@cocotb.test()
async def test_esc_page_routes_to_esc_slave(dut):
    """Read from ESC page (0x40000900) routes to esc slave port."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    stub = cocotb.start_soon(_stub_slave_ack(dut, "esc", 0x0000_0007))
    val = await _wb_read(dut, 0x4000_0900)
    await stub
    assert val == 0x0000_0007, f"ESC read expected 0x00000007, got 0x{val:08x}"


@cocotb.test()
async def test_unmatched_address_returns_zero(dut):
    """Unmatched page (e.g. 0x40000200) should ack with data=0."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)
    val = await _wb_read(dut, 0x4000_0200)
    assert val == 0, f"Unmatched address expected 0, got 0x{val:08x}"


@cocotb.test()
async def test_pwm_page_routes_to_pwm_slave(dut):
    """Read from PWM page (0x40000100) routes to pwm slave port."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    stub = cocotb.start_soon(_stub_slave_ack(dut, "pwm", 0x0000_03E8))
    val = await _wb_read(dut, 0x4000_0100)
    await stub
    assert val == 0x0000_03E8, f"PWM read expected 0x000003E8, got 0x{val:08x}"


@cocotb.test()
async def test_led_page_routes_to_led_slave(dut):
    """Read from LED page (0x40000C00) routes to led slave port."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    stub = cocotb.start_soon(_stub_slave_ack(dut, "led", 0x0000_000F))
    val = await _wb_read(dut, 0x4000_0C00)
    await stub
    assert val == 0x0000_000F, f"LED read expected 0x0000000F, got 0x{val:08x}"
