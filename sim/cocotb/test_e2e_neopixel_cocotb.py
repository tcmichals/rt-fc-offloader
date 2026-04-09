"""E2E test: NeoPixel engine via FCSP WRITE_BLOCK.

Verifies pixel data can be written and triggered through the full FCSP path,
and that o_neo_data produces output activity after trigger.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, NextTimeStep, with_timeout

from python_fcsp.fcsp_codec import (
    build_write_block_payload,
    build_read_block_payload,
    decode_frame,
    encode_frame,
)

SIM_CLK_NS = 18.5  # ~54 MHz

NEO_BASE    = 0x4000_0600
NEO_PIXEL0  = NEO_BASE + 0x00
NEO_PIXEL1  = NEO_BASE + 0x04
NEO_TRIGGER = NEO_BASE + 0x20


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


@cocotb.test()
async def test_neopixel_write_and_trigger(dut):
    """Writing pixel data + trigger should cause o_neo_data activity."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)

    # Write pixel 0 = 0x00FF0000 (green=0xFF in GRB encoding)
    raw = await _write_reg(dut, NEO_PIXEL0, 0x00FF0000, seq=1)
    rsp = _try_decode_first_frame(raw)
    assert rsp is not None, f"no response for PIXEL0 write: {raw.hex()}"
    assert rsp.payload[0] == 0x00, "expected RES_OK for PIXEL0 write"

    # Trigger the NeoPixel update FSM
    raw = await _write_reg(dut, NEO_TRIGGER, 0x00000001, seq=2)
    rsp = _try_decode_first_frame(raw)
    assert rsp is not None, f"no response for TRIGGER write: {raw.hex()}"
    assert rsp.payload[0] == 0x00, "expected RES_OK for TRIGGER write"

    # Watch o_neo_data for any transition (WS2812 bit encoding produces edges)
    saw_edge = False
    prev = 0
    for _ in range(50000):
        await RisingEdge(dut.clk)
        await ReadOnly()
        cur = int(dut.o_neo_data.value)
        if cur != prev:
            saw_edge = True
            break
        prev = cur
        await NextTimeStep()

    assert saw_edge, "expected o_neo_data transitions after trigger"


@cocotb.test()
async def test_neopixel_two_pixels(dut):
    """Write two different pixel values and trigger; expect sustained waveform."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)

    await _write_reg(dut, NEO_PIXEL0, 0x00FF00FF, seq=10)
    await _write_reg(dut, NEO_PIXEL1, 0x00AABB00, seq=11)
    await _write_reg(dut, NEO_TRIGGER, 0x00000001, seq=12)

    # Count edges on o_neo_data over a window
    edge_count = 0
    prev = 0
    for _ in range(80000):
        await RisingEdge(dut.clk)
        await ReadOnly()
        cur = int(dut.o_neo_data.value)
        if cur != prev:
            edge_count += 1
        prev = cur
        await NextTimeStep()

    # Two 24-bit pixels = 48 bits; each bit is one pulse = 2 edges
    # Expect at least some edges (exact count depends on timing engine)
    assert edge_count >= 10, (
        f"expected >=10 edges on o_neo_data for 2-pixel update, got {edge_count}"
    )
