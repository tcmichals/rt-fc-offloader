"""E2E test: BLHeli ESC boot sequence via FCSP.

Exercises the full passthrough boot flow:
  1. WRITE_BLOCK mux → serial mode, channel 0
  2. WRITE_BLOCK mux → force_low (ESC bootloader break signal)
  3. WRITE_BLOCK mux → release force_low
  4. CH 0x05 ESC serial data → verify UART TX activity
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, NextTimeStep, with_timeout

from python_fcsp.fcsp_codec import (
    build_write_block_payload,
    build_read_block_payload,
    decode_frame,
    encode_frame,
    Channel,
)

SIM_CLK_NS = 18.5  # ~54 MHz

MUX_REG = 0x4000_0400


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
    payload = build_write_block_payload(
        space=0x01, address=address,
        data=value.to_bytes(4, "big"),
    )
    frame = encode_frame(flags=0, channel=0x01, seq=seq, payload=payload)
    collector = cocotb.start_soon(_collect_usb_tx_bytes(dut, max_bytes=30, max_cycles=4000))
    await with_timeout(_drive_usb_bytes(dut, frame), 100, "us")
    return await with_timeout(collector, 200, "us")


async def _read_reg(dut, address: int, seq: int) -> int:
    payload = build_read_block_payload(space=0x01, address=address, length=4)
    frame = encode_frame(flags=0, channel=0x01, seq=seq, payload=payload)
    collector = cocotb.start_soon(_collect_usb_tx_bytes(dut, max_bytes=30, max_cycles=4000))
    await with_timeout(_drive_usb_bytes(dut, frame), 100, "us")
    raw = await with_timeout(collector, 200, "us")
    rsp = _try_decode_first_frame(raw)
    assert rsp is not None, f"no response frame in {raw.hex()}"
    assert rsp.payload[0] == 0x00, f"expected RES_OK, got 0x{rsp.payload[0]:02x}"
    d = rsp.payload[3:7]
    return (d[0] << 24) | (d[1] << 16) | (d[2] << 8) | d[3]


@cocotb.test()
async def test_blheli_boot_force_low_release(dut):
    """Boot sequence: serial mode → force_low → release → verify mux state."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)

    # Step 1: Switch to serial mode, channel 0
    # mode=0, channel=0 → value = 0x00
    raw = await _write_reg(dut, MUX_REG, 0x00000000, seq=1)
    rsp = _try_decode_first_frame(raw)
    assert rsp is not None and rsp.payload[0] == 0x00, "serial mode write failed"

    val = await _read_reg(dut, MUX_REG, seq=2)
    assert val & 0x01 == 0, "expected serial mode"

    # Step 2: Assert force_low (bit 4)
    raw = await _write_reg(dut, MUX_REG, 0x00000010, seq=3)
    rsp = _try_decode_first_frame(raw)
    assert rsp is not None and rsp.payload[0] == 0x00, "force_low write failed"

    val = await _read_reg(dut, MUX_REG, seq=4)
    assert val & 0x10 == 0x10, f"expected force_low set, got 0x{val:08x}"

    # Step 3: Release force_low (serial mode stays)
    raw = await _write_reg(dut, MUX_REG, 0x00000000, seq=5)
    rsp = _try_decode_first_frame(raw)
    assert rsp is not None and rsp.payload[0] == 0x00, "release force_low failed"

    val = await _read_reg(dut, MUX_REG, seq=6)
    assert val & 0x10 == 0, "force_low should be cleared"
    assert val & 0x01 == 0, "should still be serial mode"


@cocotb.test()
async def test_blheli_boot_then_esc_data(dut):
    """After boot sequence, CH 0x05 data should trigger ESC UART TX."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)

    # Enter serial mode, channel 0, force_low
    await _write_reg(dut, MUX_REG, 0x00000010, seq=10)

    # Hold force_low for a few cycles (simulated break)
    for _ in range(100):
        await RisingEdge(dut.clk)

    # Release force_low
    await _write_reg(dut, MUX_REG, 0x00000000, seq=11)

    # Send ESC serial data via CH 0x05
    esc_payload = b"\x2F\x01"  # BLHeli init byte sequence (example)
    frame = encode_frame(flags=0, channel=Channel.ESC_SERIAL, seq=12, payload=esc_payload)
    await _drive_usb_bytes(dut, frame)

    # Verify UART TX fires
    saw_tx_active = False
    for _ in range(5000):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if bool(dut.o_esc_tx_active.value):
            saw_tx_active = True
            break
        await NextTimeStep()

    assert saw_tx_active, "o_esc_tx_active should fire after CH 0x05 data post-boot"
