"""Cocotb tests for wb_led_controller.

NOTE on LED polarity
====================
wb_led_controller is instantiated with LED_POLARITY=0 (active-low).
  led_out (physical pin) = ~led_out_reg
  wbs_dat_o / register readback = led_out_reg  (logical value)

The board wrapper inverts again: o_led_N = ~led_reg_out[N]
  => o_led_N = ~~led_out_reg[N] = led_out_reg[N]
  => LED physically ON when the register bit is 1.

Tests check BOTH:
  - readback  (logical == written value)
  - led_out   (physical == ~written value & mask)
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, NextTimeStep

_LED_OUT    = 0x00
_LED_TOGGLE = 0x04
_LED_CLEAR  = 0x08
_LED_SET    = 0x0C

LED_WIDTH = 4
LED_MASK  = (1 << LED_WIDTH) - 1   # 0xF


def _phys(logical):
    """Expected physical active-low pin value for a given logical register value."""
    return (~logical) & LED_MASK


async def _reset(dut):
    dut.rst.value = 1
    dut.wbs_cyc_i.value = 0
    dut.wbs_stb_i.value = 0
    dut.wbs_we_i.value = 0
    dut.wbs_sel_i.value = 0xF
    dut.wbs_adr_i.value = 0
    dut.wbs_dat_i.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def _wb_write(dut, reg_off, data):
    dut.wbs_adr_i.value = reg_off & 0xFF
    dut.wbs_dat_i.value = data & 0xFFFFFFFF
    dut.wbs_we_i.value = 1
    dut.wbs_cyc_i.value = 1
    dut.wbs_stb_i.value = 1
    for _ in range(8):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if bool(dut.wbs_ack_o.value):
            break
    else:
        raise AssertionError(f"wb_write ack timeout reg_off=0x{reg_off:02X}")
    await NextTimeStep()
    dut.wbs_cyc_i.value = 0
    dut.wbs_stb_i.value = 0
    dut.wbs_we_i.value = 0
    await RisingEdge(dut.clk)


async def _wb_read(dut, reg_off):
    dut.wbs_adr_i.value = reg_off & 0xFF
    dut.wbs_we_i.value = 0
    dut.wbs_cyc_i.value = 1
    dut.wbs_stb_i.value = 1
    val = 0
    for _ in range(8):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if bool(dut.wbs_ack_o.value):
            val = int(dut.wbs_dat_o.value)
            break
    else:
        raise AssertionError(f"wb_read ack timeout reg_off=0x{reg_off:02X}")
    await NextTimeStep()
    dut.wbs_cyc_i.value = 0
    dut.wbs_stb_i.value = 0
    await RisingEdge(dut.clk)
    return val


@cocotb.test()
async def reset_clears_all_leds(dut):
    """After reset: register reads 0 and led_out pin is fully high (active-low idle)."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)
    readback = await _wb_read(dut, _LED_OUT)
    assert (readback & LED_MASK) == 0, \
        f"LED_OUT register must be 0 after reset, got 0x{readback:08X}"
    pin = int(dut.led_out.value) & LED_MASK
    assert pin == _phys(0), \
        f"led_out pin after reset: expected 0x{_phys(0):X} got 0x{pin:X}"


@cocotb.test()
async def led_set_ors_bits(dut):
    """LED_SET ORs new bits without clearing existing ones."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)
    await _wb_write(dut, _LED_SET, 0x5)
    rb  = (await _wb_read(dut, _LED_OUT)) & LED_MASK
    pin = int(dut.led_out.value) & LED_MASK
    assert rb  == 0x5,        f"Readback after SET(5): expected 5, got 0x{rb:X}"
    assert pin == _phys(0x5), f"led_out after SET(5): expected 0x{_phys(0x5):X} got 0x{pin:X}"
    await _wb_write(dut, _LED_SET, 0xA)
    rb  = (await _wb_read(dut, _LED_OUT)) & LED_MASK
    pin = int(dut.led_out.value) & LED_MASK
    assert rb  == 0xF,        f"Readback after SET(5)|SET(A): expected F, got 0x{rb:X}"
    assert pin == _phys(0xF), f"led_out after OR-full: expected 0x{_phys(0xF):X} got 0x{pin:X}"


@cocotb.test()
async def led_clear_masks_bits(dut):
    """LED_CLEAR ANDs-NOT: clears specified bits, leaves others."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)
    await _wb_write(dut, _LED_SET, 0xF)
    await _wb_write(dut, _LED_CLEAR, 0x3)
    rb  = (await _wb_read(dut, _LED_OUT)) & LED_MASK
    pin = int(dut.led_out.value) & LED_MASK
    assert rb  == 0xC,        f"Readback after CLEAR(3): expected C, got 0x{rb:X}"
    assert pin == _phys(0xC), f"led_out after CLEAR(3): expected 0x{_phys(0xC):X} got 0x{pin:X}"


@cocotb.test()
async def led_toggle_xors_bits(dut):
    """LED_TOGGLE XORs: double-toggle returns to original state."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)
    await _wb_write(dut, _LED_SET, 0x5)
    await _wb_write(dut, _LED_TOGGLE, 0xF)
    rb  = (await _wb_read(dut, _LED_OUT)) & LED_MASK
    pin = int(dut.led_out.value) & LED_MASK
    assert rb  == 0xA,        f"Readback after TOGGLE: expected A, got 0x{rb:X}"
    assert pin == _phys(0xA), f"led_out after TOGGLE: expected 0x{_phys(0xA):X} got 0x{pin:X}"
    await _wb_write(dut, _LED_TOGGLE, 0xF)
    rb  = (await _wb_read(dut, _LED_OUT)) & LED_MASK
    pin = int(dut.led_out.value) & LED_MASK
    assert rb  == 0x5,        f"Readback after double TOGGLE: expected 5, got 0x{rb:X}"
    assert pin == _phys(0x5), f"led_out after double TOGGLE: expected 0x{_phys(0x5):X} got 0x{pin:X}"


@cocotb.test()
async def led_out_direct_write_and_readback(dut):
    """LED_OUT direct write: register readback and physical pin both match."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)
    for val in (0x0, 0x1, 0x7, 0xA, 0xF):
        await _wb_write(dut, _LED_OUT, val)
        reg = (await _wb_read(dut, _LED_OUT)) & LED_MASK
        pin = int(dut.led_out.value) & LED_MASK
        assert reg == val,        f"LED_OUT readback: write=0x{val:X} expected 0x{val:X} got 0x{reg:X}"
        assert pin == _phys(val), f"led_out pin: write=0x{val:X} expected 0x{_phys(val):X} got 0x{pin:X}"


@cocotb.test()
async def upper_bits_do_not_affect_led_out(dut):
    """Writes to upper 28 bits must not corrupt the lower 4-bit LED state."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)
    await _wb_write(dut, _LED_SET, 0xDEADBEEF)
    logical = 0xDEADBEEF & LED_MASK   # 0xF
    rb  = (await _wb_read(dut, _LED_OUT)) & LED_MASK
    pin = int(dut.led_out.value) & LED_MASK
    assert rb  == logical,        f"Readback: expected 0x{logical:X}, got 0x{rb:X}"
    assert pin == _phys(logical), f"led_out: expected 0x{_phys(logical):X}, got 0x{pin:X}"
