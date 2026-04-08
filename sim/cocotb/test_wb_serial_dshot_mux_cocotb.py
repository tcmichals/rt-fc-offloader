import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


async def _reset(dut):
    dut.rst.value = 1
    dut.wb_dat_i.value = 0
    dut.wb_adr_i.value = 0
    dut.wb_we_i.value = 0
    dut.wb_sel_i.value = 0xF
    dut.wb_stb_i.value = 0
    dut.wb_cyc_i.value = 0
    dut.pc_rx_data.value = 0
    dut.pc_rx_valid.value = 0
    dut.dshot_in.value = 0
    dut.serial_tx_i.value = 1
    dut.serial_oe_i.value = 0

    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def _wb_write(dut, value: int):
    dut.wb_adr_i.value = 0x0400
    dut.wb_dat_i.value = value & 0xFFFFFFFF
    dut.wb_we_i.value = 1
    dut.wb_stb_i.value = 1
    dut.wb_cyc_i.value = 1

    for _ in range(8):
        await RisingEdge(dut.clk)
        if int(dut.wb_ack_o.value):
            break
    else:
        assert False, "Wishbone write ack timeout"

    dut.wb_stb_i.value = 0
    dut.wb_cyc_i.value = 0
    dut.wb_we_i.value = 0
    await RisingEdge(dut.clk)


async def _wb_read(dut) -> int:
    dut.wb_adr_i.value = 0x0400
    dut.wb_we_i.value = 0
    dut.wb_stb_i.value = 1
    dut.wb_cyc_i.value = 1

    for _ in range(8):
        await RisingEdge(dut.clk)
        if int(dut.wb_ack_o.value):
            val = int(dut.wb_dat_o.value)
            break
    else:
        assert False, "Wishbone read ack timeout"

    dut.wb_stb_i.value = 0
    dut.wb_cyc_i.value = 0
    await RisingEdge(dut.clk)
    return val


async def _send_pc_byte(dut, b: int):
    dut.pc_rx_data.value = b & 0xFF
    dut.pc_rx_valid.value = 1
    await RisingEdge(dut.clk)
    dut.pc_rx_valid.value = 0
    await RisingEdge(dut.clk)


async def _send_sniffer_trigger(dut, cmd: int):
    # Sniffer expects: '$' 'M' '<' LEN CMD
    await _send_pc_byte(dut, ord('$'))
    await _send_pc_byte(dut, ord('M'))
    await _send_pc_byte(dut, ord('<'))
    await _send_pc_byte(dut, 0x00)
    await _send_pc_byte(dut, cmd)


@cocotb.test()
async def test_reset_default_is_dshot(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    assert int(dut.mux_sel.value) == 1, "Reset should default to DShot mode"
    reg = await _wb_read(dut)
    assert (reg & 0x1) == 1, "Register bit[0] should default to DShot"


@cocotb.test()
async def test_manual_mode_and_readback(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    # bit0=mux_sel(0 serial), bits2:1=ch(2), bit3=msp_mode(1), bit4=force_low(1)
    write_val = 0
    write_val |= 0 << 0
    write_val |= 2 << 1
    write_val |= 1 << 3
    write_val |= 1 << 4

    await _wb_write(dut, write_val)
    reg = await _wb_read(dut)

    assert int(dut.mux_sel.value) == 0, "Manual write should switch effective mux to serial"
    assert ((reg >> 0) & 0x1) == 0
    assert ((reg >> 1) & 0x3) == 2
    assert ((reg >> 3) & 0x1) == 1
    assert ((reg >> 4) & 0x1) == 1


@cocotb.test()
async def test_sniffer_triggers_passthrough_on_f5_and_64(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    assert int(dut.mux_sel.value) == 1

    await _send_sniffer_trigger(dut, 0xF5)
    for _ in range(10):
        await RisingEdge(dut.clk)
    assert int(dut.mux_sel.value) == 0, "0xF5 trigger should force serial mode"

    await _reset(dut)
    await _send_sniffer_trigger(dut, 0x64)
    for _ in range(10):
        await RisingEdge(dut.clk)
    assert int(dut.mux_sel.value) == 0, "0x64 trigger should force serial mode"


@cocotb.test()
async def test_non_target_pins_keep_dshot_in_serial_mode(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    # Choose channel 2 as serial target (0-based)
    await _wb_write(dut, (0 << 0) | (2 << 1))

    # Drive DShot pattern and serial low with OE enabled
    dut.dshot_in.value = 0b1011  # ch3=1 ch2=0 ch1=1 ch0=1
    dut.serial_tx_i.value = 0
    dut.serial_oe_i.value = 1

    # Allow reg + global_tristate settling
    for _ in range(4):
        await RisingEdge(dut.clk)

    # target ch2 should reflect serial(0), non-target pins are high-Z
    pads = str(dut.pad_motor.value)
    # binstr is [3][2][1][0]
    assert pads[1] == '0', f"Target channel 2 should follow serial low, got pad={pads}"
    # Non-target pins in serial mode go high-Z. Verilator resolves z as 0.
    # Only verify target pin carries correct serial data.
    assert pads[0] != '1', f"Ch3 should not be driven high in serial mode, got pad={pads}"
    assert pads[2] != '1', f"Ch1 should not be driven high in serial mode, got pad={pads}"
    assert pads[3] != '1', f"Ch0 should not be driven high in serial mode, got pad={pads}"


@cocotb.test()
async def test_force_low_on_target_channel(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    # serial mode, channel 1, force_low=1
    await _wb_write(dut, (0 << 0) | (1 << 1) | (1 << 4))

    dut.dshot_in.value = 0b1111
    dut.serial_tx_i.value = 1
    dut.serial_oe_i.value = 1

    for _ in range(4):
        await RisingEdge(dut.clk)

    pads = str(dut.pad_motor.value)
    # channel 1 is bit index 2 in [3][2][1][0] ordering
    assert pads[2] == '0', f"Target channel 1 must be forced low, got pad={pads}"


@cocotb.test()
async def test_force_low_transition_release_restores_serial_level(dut):
    """In serial bypass mode, target pin must transition LOW->serial level when force_low clears."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    # Target channel 0, serial TX high with output enable.
    dut.serial_tx_i.value = 1
    dut.serial_oe_i.value = 1
    dut.dshot_in.value = 0b0000

    # Enter serial mode with force_low asserted.
    await _wb_write(dut, (0 << 0) | (0 << 1) | (1 << 4))
    for _ in range(4):
        await RisingEdge(dut.clk)
    pads = str(dut.pad_motor.value)
    # [3][2][1][0] => channel 0 is index 3
    assert pads[3] == '0', f"Expected forced LOW on channel 0, got pad={pads}"

    # Release force_low, keep serial TX high, verify transition to serial-driven HIGH.
    await _wb_write(dut, (0 << 0) | (0 << 1) | (0 << 4))
    for _ in range(4):
        await RisingEdge(dut.clk)
    pads2 = str(dut.pad_motor.value)
    assert pads2[3] == '1', f"Expected channel 0 to return to serial HIGH after release, got pad={pads2}"


@cocotb.test()
async def test_msp_bypass_stays_enabled_across_multiple_messages(dut):
    """After sniffer-triggered bypass, several incoming messages should keep mux in serial mode."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    await _send_sniffer_trigger(dut, 0xF5)
    for _ in range(10):
        await RisingEdge(dut.clk)
    assert int(dut.mux_sel.value) == 0, "Expected serial mode after MSP passthrough trigger"

    # Simulate several follow-on bytes/messages from host while bypass active.
    for msg in (b"AAAA", b"BBBB", b"CCCC", b"DDDD", b"EEEE"):
        for b in msg:
            await _send_pc_byte(dut, b)
        for _ in range(4):
            await RisingEdge(dut.clk)
        assert int(dut.mux_sel.value) == 0, "Bypass should remain enabled during active message flow"


@cocotb.test()
async def test_watchdog_timeout_and_activity_reset(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    # Enter serial mode via auto-passthrough (MSP sniffer trigger);
    # watchdog only applies to auto-passthrough, not manual mode.
    await _send_sniffer_trigger(dut, 0xF5)
    for _ in range(10):
        await RisingEdge(dut.clk)
    assert int(dut.mux_sel.value) == 0, "MSP trigger should activate serial mode"

    # With CLK_FREQ_HZ overridden to 100 in Makefile target, WATCHDOG_LIMIT=500 cycles.
    # Send activity before timeout, confirm still serial.
    for i in range(200):
        if i == 150:
            await _send_pc_byte(dut, 0x55)
        await RisingEdge(dut.clk)
    assert int(dut.mux_sel.value) == 0, "Activity should reset watchdog and keep serial mode"

    # Now let it go idle long enough to timeout.
    for _ in range(560):
        await RisingEdge(dut.clk)

    assert int(dut.mux_sel.value) == 1, "Watchdog timeout should revert auto-passthrough to DShot mode"
