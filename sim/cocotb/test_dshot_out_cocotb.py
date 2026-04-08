"""Cocotb tests for dshot_out — pure DSHOT pulse transmitter."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, NextTimeStep, with_timeout


CLK_PERIOD_NS = 10  # 100 MHz for simulation
CLK_FREQ_HZ = 100_000_000


async def _reset(dut):
    dut.rst.value = 1
    dut.i_dshot_value.value = 0
    dut.i_dshot_mode.value = 600
    dut.i_write.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_idle_output_low(dut):
    """After reset, o_pwm should be low and o_ready should be high."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    await _reset(dut)
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert int(dut.o_pwm.value) == 0, "o_pwm should be 0 at idle"
    assert int(dut.o_ready.value) == 1, "o_ready should be 1 at idle"


@cocotb.test()
async def test_write_starts_pulse_train(dut):
    """Writing a DSHOT value should drive o_pwm high within a few cycles."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    await _reset(dut)

    # Write throttle=1000, telemetry=0, CRC computed externally
    dut.i_dshot_value.value = 0b1111101000_0_0000  # throttle 1000, telem=0, CRC=0
    dut.i_dshot_mode.value = 600
    dut.i_write.value = 1
    await RisingEdge(dut.clk)
    dut.i_write.value = 0

    # Wait for o_ready to deassert (transmission started)
    saw_busy = False
    for _ in range(20):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if not int(dut.o_ready.value):
            saw_busy = True
            break
        await NextTimeStep()
    assert saw_busy, "o_ready should deassert after write (transmission in progress)"

    # Check that o_pwm goes high at some point during the frame
    saw_high = False
    for _ in range(500):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.o_pwm.value):
            saw_high = True
            break
        await NextTimeStep()
    assert saw_high, "o_pwm should go high during DSHOT frame transmission"


@cocotb.test()
async def test_ready_reasserts_after_frame(dut):
    """o_ready must return high after 16-bit frame + guard time completes."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    await _reset(dut)

    # Let mode change from default (150) to 600 latch first
    dut.i_dshot_mode.value = 600
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)

    dut.i_dshot_value.value = 0x0000
    dut.i_write.value = 1
    await RisingEdge(dut.clk)
    dut.i_write.value = 0

    # DSHOT600 at 100MHz: 16 bits * ~170 + guard (6250) ≈ 9000 cycles
    ready_again = False
    for _ in range(20_000):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.o_ready.value):
            ready_again = True
            break
        await NextTimeStep()
    assert ready_again, "o_ready should reassert after frame transmission completes"


@cocotb.test()
async def test_dshot150_mode(dut):
    """DSHOT150 mode should also produce pulses on o_pwm."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    await _reset(dut)

    dut.i_dshot_value.value = 0xFFFF
    dut.i_dshot_mode.value = 150
    dut.i_write.value = 1
    await RisingEdge(dut.clk)
    dut.i_write.value = 0

    saw_high = False
    for _ in range(500):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.o_pwm.value):
            saw_high = True
            break
        await NextTimeStep()
    assert saw_high, "DSHOT150 frame should drive o_pwm high"
