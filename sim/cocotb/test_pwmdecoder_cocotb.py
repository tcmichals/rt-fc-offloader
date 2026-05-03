"""Cocotb tests for pwmdecoder_wb — N-channel RC PWM pulse width measurement via Wishbone."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, NextTimeStep, Timer


CLK_PERIOD_NS = 10  # 100 MHz
CLK_FREQ_HZ = 100_000_000

# Guard error codes from the RTL
GUARD_ERROR_LOW = 0xC000
GUARD_ERROR_HIGH = 0x8000
GUARD_ERROR_SHORT = 0x4000


async def wb_read(dut, addr_word):
    """Perform a Wishbone read at the given word address."""
    dut.wb_adr_i.value = addr_word << 2
    dut.wb_we_i.value = 0
    dut.wb_sel_i.value = 0xF
    dut.wb_stb_i.value = 1
    dut.wb_cyc_i.value = 1
    await RisingEdge(dut.clk)
    
    while int(dut.wb_ack_o.value) == 0:
        await RisingEdge(dut.clk)
        
    val = int(dut.wb_dat_o.value)
    dut.wb_stb_i.value = 0
    dut.wb_cyc_i.value = 0
    await RisingEdge(dut.clk)
    return val


async def _reset(dut):
    dut.rst.value = 1
    dut.i_pwm.value = 0
    dut.wb_adr_i.value = 0
    dut.wb_we_i.value = 0
    dut.wb_sel_i.value = 0
    dut.wb_stb_i.value = 0
    dut.wb_cyc_i.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def _generate_pulse(dut, high_us: int):
    """Generate a single PWM pulse with given high time in microseconds."""
    clk_ticks_per_us = CLK_FREQ_HZ // 1_000_000  # 100 ticks/us
    high_ticks = high_us * clk_ticks_per_us

    # Low period before the pulse (>1 ms for proper measurement start)
    for _ in range(200 * clk_ticks_per_us):
        await RisingEdge(dut.clk)

    # Rising edge (testing channel 0)
    dut.i_pwm.value = 1
    for _ in range(high_ticks):
        await RisingEdge(dut.clk)

    # Falling edge
    dut.i_pwm.value = 0

    # Wait a bit for measurement to complete
    for _ in range(1000):
        await RisingEdge(dut.clk)


@cocotb.test()
async def test_startup_guard_error(dut):
    """After reset with no pulse, value should indicate GUARD_ERROR_LOW."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    await _reset(dut)

    val = await wb_read(dut, 0)
    assert val & GUARD_ERROR_LOW, f"Initial value 0x{val:04x} should have GUARD_ERROR_LOW set"


@cocotb.test()
async def test_valid_1500us_pulse(dut):
    """A 1500µs pulse (midpoint RC servo) should be measured accurately."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    await _reset(dut)

    await _generate_pulse(dut, 1500)

    val = await wb_read(dut, 0)
    # Allow ±5µs tolerance for synchronizer latency and 1MHz clock boundary sampling
    raw = val & 0x3FFF  # mask off guard error bits
    assert 1490 <= raw <= 1510, f"Expected ~1500µs, got {raw}µs (raw 0x{val:04x})"


@cocotb.test()
async def test_valid_1000us_pulse(dut):
    """A 1000µs pulse (low-end throttle) should be measured correctly."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    await _reset(dut)

    await _generate_pulse(dut, 1000)

    val = await wb_read(dut, 0)
    raw = val & 0x3FFF
    assert 990 <= raw <= 1010, f"Expected ~1000µs, got {raw}µs (raw 0x{val:04x})"


@cocotb.test()
async def test_ready_asserts_on_measurement(dut):
    """Status register should show ready bit asserted when a measurement is complete."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    await _reset(dut)

    saw_ready = [False]
    
    async def monitor_ready():
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            if int(dut.pwm_ready_flags.value) & 1:
                saw_ready[0] = True

    # Start the monitor concurrently before generating the pulse
    cocotb.start_soon(monitor_ready())

    # This function takes time and blocks, so the monitor will catch the 1-cycle pulse in the background
    await _generate_pulse(dut, 1500)
    
    assert saw_ready[0], "Ready bit (status reg) was never asserted."
