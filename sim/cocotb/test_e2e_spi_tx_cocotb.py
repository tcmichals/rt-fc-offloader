"""E2E test: SPI TX egress path.

Verifies that when SPI CS is asserted (active-low) and a response is
produced (e.g. from a USB-injected PING), the response bytes appear on the
SPI MISO output (shifted out on SCLK falling edges by the SPI frontend).
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, NextTimeStep, with_timeout

from python_fcsp.fcsp_codec import (
    build_control_payload,
    encode_frame,
    decode_frame,
)

SIM_CLK_NS = 18.5  # ~54 MHz

# SPI half-period in system clocks (slow enough for 3-stage CDC).
SPI_HALF_PERIOD = 12


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


async def _spi_xfer_byte(dut, tx_byte: int = 0x00) -> int:
    """Clock one SPI byte (Mode 0): MOSI driven per tx_byte, returns MISO byte."""
    rx = 0
    for bit in range(7, -1, -1):
        dut.i_spi_mosi.value = (tx_byte >> bit) & 1
        # Rising SCLK: slave samples MOSI; master samples MISO
        dut.i_spi_sclk.value = 1
        for _ in range(SPI_HALF_PERIOD):
            await RisingEdge(dut.clk)
        await ReadOnly()
        rx = (rx << 1) | int(dut.o_spi_miso.value)
        await NextTimeStep()
        # Falling SCLK: slave shifts next TX bit onto MISO
        dut.i_spi_sclk.value = 0
        for _ in range(SPI_HALF_PERIOD):
            await RisingEdge(dut.clk)
    return rx


@cocotb.test()
async def test_spi_tx_egress_ping_response(dut):
    """Send PING via SPI MOSI, assert SPI CS, clock out response via SPI MISO.

    Frames injected via SPI get ingress_tid=1 (SPI origin), so the response
    is routed back to SPI egress (tdest=1).  We bit-bang the PING frame byte
    by byte over MOSI, then clock out the response from MISO.
    """
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)

    # Build PING frame
    cmd = build_control_payload(0x06)  # OP_PING
    frame = encode_frame(flags=0, channel=0x01, seq=0x70, payload=cmd)

    # Assert SPI CS (active-low) and let CDC settle
    dut.i_spi_cs_n.value = 0
    for _ in range(8):
        await RisingEdge(dut.clk)

    # Inject PING via SPI MOSI (bit-bang each frame byte)
    for byte in frame:
        await _spi_xfer_byte(dut, tx_byte=byte)

    # Wait for processing latency (parser → CRC → WB master → framer)
    for _ in range(500):
        await RisingEdge(dut.clk)

    # Clock out enough bytes to capture the response on MISO
    spi_out = []
    for _ in range(30):
        b = await _spi_xfer_byte(dut, tx_byte=0x00)
        spi_out.append(b)

    dut.i_spi_cs_n.value = 1

    # Look for sync byte (0xA5) in the SPI output
    saw_sync = 0xA5 in spi_out
    assert saw_sync, f"expected 0xA5 sync in SPI output, got {[hex(x) for x in spi_out]}"


@cocotb.test()
async def test_spi_tx_inactive_when_cs_high(dut):
    """When CS is deasserted, SPI TX should not block the USB TX path."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)

    # Allow CDC sync stages to settle after reset
    for _ in range(20):
        await RisingEdge(dut.clk)

    # CS stays high (deasserted) — default
    cmd = build_control_payload(0x06)  # OP_PING
    frame = encode_frame(flags=0, channel=0x01, seq=0x80, payload=cmd)

    # Collect USB TX response
    collected = bytearray()

    async def _collect():
        for _ in range(3000):
            await RisingEdge(dut.clk)
            await ReadOnly()
            if bool(dut.o_usb_tx_valid.value):
                collected.append(int(dut.o_usb_tx_byte.value))
            await NextTimeStep()

    collector = cocotb.start_soon(_collect())
    await with_timeout(_drive_usb_bytes(dut, frame), 100, "us")
    await with_timeout(collector, 200, "us")

    assert len(collected) > 0, "USB TX should produce response even with SPI CS high"

    # Verify it's a valid PING response
    for idx, b in enumerate(collected):
        if b != 0xA5:
            continue
        if idx + 8 > len(collected):
            continue
        plen = (collected[idx + 6] << 8) | collected[idx + 7]
        total = 1 + 7 + plen + 2
        end = idx + total
        if end > len(collected):
            continue
        try:
            rsp = decode_frame(bytes(collected[idx:end]))
            assert rsp.payload[0] == 0x00, f"expected RES_OK, got 0x{rsp.payload[0]:02x}"
            return
        except ValueError:
            continue
    raise AssertionError(f"could not decode PING response from USB TX: {collected.hex()}")
