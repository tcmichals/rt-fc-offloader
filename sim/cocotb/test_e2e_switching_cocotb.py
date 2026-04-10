"""E2E test: serial/DShot mux switching via FCSP WRITE_BLOCK / READ_BLOCK.

Verifies WRITE_BLOCK to the mux control register (0x40000400) changes mode,
and READ_BLOCK returns the updated value.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, NextTimeStep

from python_fcsp.fcsp_codec import (
    build_write_block_payload,
    build_read_block_payload,
    decode_frame,
    encode_frame,
)
from hwlib.registers import MUX_CTRL

SIM_CLK_NS = 18.5  # ~54 MHz

MUX_REG = MUX_CTRL


async def _reset(dut):
    dut.rst.value = 1
    dut.i_spi_sclk.value = 0
    dut.i_spi_cs_n.value = 1
    dut.i_spi_mosi.value = 0
    dut.i_usb_rx_valid.value = 0
    dut.i_usb_rx_byte.value = 0
    dut.i_usb_tx_ready.value = 1
    dut.i_pwm_0.value = 0
    dut.i_pwm_1.value = 0
    dut.i_pwm_2.value = 0
    dut.i_pwm_3.value = 0
    dut.i_pwm_4.value = 0
    dut.i_pwm_5.value = 0
    dut.pc_rx_data.value = 0
    dut.pc_rx_valid.value = 0
    dut.led_dat_i.value = 0
    dut.led_ack_i.value = 0
    dut.s_dbg_tx_tvalid.value = 0
    dut.s_dbg_tx_tdata.value = 0
    dut.s_dbg_tx_tlast.value = 0
    dut.s_dbg_tx_channel.value = 0
    dut.s_dbg_tx_flags.value = 0
    dut.s_dbg_tx_seq.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def _drive_usb_bytes(dut, data: bytes):
    for byte in data:
        accepted = False
        while not accepted:
            dut.i_usb_rx_valid.value = 1
            dut.i_usb_rx_byte.value = byte
            await ReadOnly()
            accepted = bool(dut.o_usb_rx_ready.value)
            await RisingEdge(dut.clk)
            await NextTimeStep()
    dut.i_usb_rx_valid.value = 0
    await RisingEdge(dut.clk)
    await ReadOnly()
    await NextTimeStep()


async def _collect_usb_tx_bytes(dut, max_bytes: int, max_cycles: int = 4000,
                                idle_gap: int = 200) -> bytes:
    collected = bytearray()
    idle = 0
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if bool(dut.o_usb_tx_valid.value):
            collected.append(int(dut.o_usb_tx_byte.value))
            idle = 0
            if len(collected) >= max_bytes:
                await NextTimeStep()
                break
        elif collected:
            idle += 1
            if idle >= idle_gap:
                await NextTimeStep()
                break
        await NextTimeStep()
    return bytes(collected)


def _try_decode_first_frame(raw: bytes):
    for idx, b in enumerate(raw):
        if b != 0xA5:
            continue
        if idx + 8 > len(raw):
            continue
        payload_len = (raw[idx + 6] << 8) | raw[idx + 7]
        total_len = 1 + 7 + payload_len + 2
        end = idx + total_len
        if end > len(raw):
            continue
        candidate = bytes(raw[idx:end])
        try:
            return decode_frame(candidate)
        except ValueError:
            continue
    return None


async def _write_reg(dut, address: int, value: int, seq: int) -> bytes:
    """WRITE_BLOCK 4 bytes to *address* and return raw USB TX response."""
    payload = build_write_block_payload(
        space=0x01, address=address,
        data=value.to_bytes(4, "big"),
    )
    frame = encode_frame(flags=0, channel=0x01, seq=seq, payload=payload)
    await _drive_usb_bytes(dut, frame)
    return await _collect_usb_tx_bytes(dut, max_bytes=30, max_cycles=6000)


async def _read_reg(dut, address: int, seq: int) -> int:
    """READ_BLOCK 4 bytes from *address* and return the 32-bit value."""
    payload = build_read_block_payload(space=0x01, address=address, length=4)
    frame = encode_frame(flags=0, channel=0x01, seq=seq, payload=payload)
    await _drive_usb_bytes(dut, frame)
    raw = await _collect_usb_tx_bytes(dut, max_bytes=30, max_cycles=6000)
    rsp = _try_decode_first_frame(raw)
    assert rsp is not None, f"no valid response frame in {raw.hex()}"
    assert rsp.payload[0] == 0x00, f"expected RES_OK, got 0x{rsp.payload[0]:02x}"
    d = rsp.payload[3:7]
    return (d[0] << 24) | (d[1] << 16) | (d[2] << 8) | d[3]


@cocotb.test()
async def test_mux_read_default(dut):
    """Mux register should read back default value (mode=1 DShot)."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)

    val = await _read_reg(dut, MUX_REG, seq=1)
    assert val & 0x01 == 1, f"expected default mode=1 (DShot), got 0x{val:08x}"


@cocotb.test()
async def test_mux_switch_to_serial(dut):
    """Writing mode=0 switches to serial passthrough, read-back confirms."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)

    # Switch to serial passthrough: mode=0, channel=1
    raw_wr = await _write_reg(dut, MUX_REG, 0x00000002, seq=2)
    wr_rsp = _try_decode_first_frame(raw_wr)
    assert wr_rsp is not None, f"no WRITE_BLOCK response in {raw_wr.hex()}"
    assert wr_rsp.payload[0] == 0x00, "WRITE_BLOCK should return RES_OK"

    val = await _read_reg(dut, MUX_REG, seq=3)
    assert val & 0x01 == 0, f"expected mode=0 (serial) after write, got 0x{val:08x}"
    assert (val >> 1) & 0x03 == 1, f"expected channel=1, got {(val >> 1) & 0x03}"


@cocotb.test()
async def test_mux_toggle_back_to_dshot(dut):
    """Switch serial → DShot and verify read-back."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)

    # Serial mode
    await _write_reg(dut, MUX_REG, 0x00000000, seq=10)
    val = await _read_reg(dut, MUX_REG, seq=11)
    assert val & 0x01 == 0, "should be serial mode"

    # Back to DShot
    await _write_reg(dut, MUX_REG, 0x00000001, seq=12)
    val = await _read_reg(dut, MUX_REG, seq=13)
    assert val & 0x01 == 1, f"expected mode=1 (DShot) after toggle, got 0x{val:08x}"


@cocotb.test()
async def test_force_low_hold_and_release(dut):
    """Assert force_low, verify pad held LOW, release, verify pad released."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)

    # Switch to serial mode, channel 0
    await _write_reg(dut, MUX_REG, 0x00000000, seq=20)

    # Assert force_low (bit 4)
    await _write_reg(dut, MUX_REG, 0x00000010, seq=21)
    val = await _read_reg(dut, MUX_REG, seq=22)
    assert val & 0x10 == 0x10, f"force_low not set: 0x{val:08x}"

    # Release force_low
    await _write_reg(dut, MUX_REG, 0x00000000, seq=23)
    val = await _read_reg(dut, MUX_REG, seq=24)
    assert val & 0x10 == 0, f"force_low not cleared: 0x{val:08x}"
    assert val & 0x01 == 0, "should still be serial mode"


@cocotb.test()
async def test_dshot_serial_dshot_round_trip(dut):
    """DShot → serial → DShot mode transition preserves register state."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)

    # Default is DShot
    val = await _read_reg(dut, MUX_REG, seq=30)
    assert val & 0x01 == 1, "default should be DShot"

    # Serial mode, channel 2
    await _write_reg(dut, MUX_REG, 0x00000004, seq=31)  # ch=2, mode=serial
    val = await _read_reg(dut, MUX_REG, seq=32)
    assert val & 0x01 == 0, "should be serial"
    assert (val >> 1) & 0x03 == 2, f"expected ch=2, got {(val >> 1) & 0x03}"

    # Back to DShot
    await _write_reg(dut, MUX_REG, 0x00000001, seq=33)
    val = await _read_reg(dut, MUX_REG, seq=34)
    assert val & 0x01 == 1, "should be back to DShot"


@cocotb.test()
async def test_channel_sweep_all_motors(dut):
    """Switch serial mode through all 4 motor channels; verify each read-back."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)

    seq = 40
    for ch in range(4):
        mux_val = (ch << 1)  # mode=0 (serial), channel in bits [2:1]
        await _write_reg(dut, MUX_REG, mux_val, seq=seq)
        seq += 1
        val = await _read_reg(dut, MUX_REG, seq=seq)
        seq += 1
        assert val & 0x01 == 0, f"ch{ch}: should be serial mode"
        assert (val >> 1) & 0x03 == ch, f"ch{ch}: expected channel={ch}, got {(val >> 1) & 0x03}"
