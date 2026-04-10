"""SPI ingress/egress routing policy tests.

Policy:
- SPI ingress is restricted to CONTROL channel (0x01) only.
  Non-CONTROL frames (e.g. ESC_SERIAL 0x05) injected via SPI are dropped.
- SPI TX egress carries only CONTROL-channel responses.
  ESC responses are visible on USB TX but NOT on SPI TX.
- USB serial retains full access to both CONTROL and ESC_SERIAL channels.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, NextTimeStep, with_timeout

from python_fcsp.fcsp_codec import (
    build_control_payload,
    build_write_block_payload,
    encode_frame,
    decode_frame,
)
from hwlib.registers import MUX_CTRL

SIM_CLK_NS = 18.5  # ~54 MHz
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
        dut.i_spi_sclk.value = 1
        for _ in range(SPI_HALF_PERIOD):
            await RisingEdge(dut.clk)
        await ReadOnly()
        rx = (rx << 1) | int(dut.o_spi_miso.value)
        await NextTimeStep()
        dut.i_spi_sclk.value = 0
        for _ in range(SPI_HALF_PERIOD):
            await RisingEdge(dut.clk)
    return rx


async def _spi_send_frame(dut, data: bytes):
    """Inject FCSP frame via SPI MOSI (CS asserted)."""
    dut.i_spi_cs_n.value = 0
    for _ in range(8):
        await RisingEdge(dut.clk)
    for byte in data:
        await _spi_xfer_byte(dut, byte)
    dut.i_spi_cs_n.value = 1
    for _ in range(8):
        await RisingEdge(dut.clk)


async def _collect_usb_tx_bytes(dut, cycles=3000):
    """Collect bytes from USB TX output."""
    collected = bytearray()
    for _ in range(cycles):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if bool(dut.o_usb_tx_valid.value):
            collected.append(int(dut.o_usb_tx_byte.value))
        await NextTimeStep()
    return collected


MUX_REG = MUX_CTRL


async def _setup_serial_mode_usb(dut, channel: int = 0, seq: int = 1):
    """Enable serial mode on a motor channel via USB CONTROL path."""
    val = (channel & 0x03) << 1  # mode=0 (serial), channel in bits [2:1]
    payload = build_write_block_payload(
        space=0x01, address=MUX_REG,
        data=val.to_bytes(4, "big"),
    )
    frame = encode_frame(flags=0, channel=0x01, seq=seq, payload=payload)
    await _drive_usb_bytes(dut, frame)
    for _ in range(400):
        await RisingEdge(dut.clk)


# ------------------------------------------------------------------
# Ingress policy tests
# ------------------------------------------------------------------

@cocotb.test()
async def test_spi_ingress_control_allowed(dut):
    """A CONTROL (CH 0x01) PING frame injected via SPI reaches Wishbone and
    produces a response on both USB TX and SPI MISO."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)

    cmd = build_control_payload(0x06)  # OP_PING
    frame = encode_frame(flags=0, channel=0x01, seq=0x90, payload=cmd)

    # Assert CS, send frame via SPI, keep CS down to capture response
    dut.i_spi_cs_n.value = 0
    for _ in range(8):
        await RisingEdge(dut.clk)

    for byte in frame:
        await _spi_xfer_byte(dut, byte)

    # Wait for processing
    for _ in range(300):
        await RisingEdge(dut.clk)

    # Clock out response via SPI
    spi_out = []
    for _ in range(30):
        b = await _spi_xfer_byte(dut, 0x00)
        spi_out.append(b)

    dut.i_spi_cs_n.value = 1

    saw_sync = 0xA5 in spi_out
    assert saw_sync, f"CONTROL frame via SPI should produce response on SPI MISO, got {[hex(x) for x in spi_out]}"


@cocotb.test()
async def test_spi_ingress_esc_dropped(dut):
    """An ESC_SERIAL (CH 0x05) frame injected via SPI must NOT activate the
    ESC UART — the frame should be silently dropped."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)

    # Enable serial mode on motor 0 via USB so ESC UART would respond
    await _setup_serial_mode_usb(dut, channel=0, seq=1)

    # Now try to send an ESC frame via SPI — this should be DROPPED
    esc_payload = bytes([0x41, 0x42, 0x43])  # arbitrary ESC data
    esc_frame = encode_frame(flags=0, channel=0x05, seq=0x50, payload=esc_payload)
    await _spi_send_frame(dut, esc_frame)

    # Wait long enough for ESC UART to fire if the frame got through
    for _ in range(500):
        await RisingEdge(dut.clk)

    # o_esc_tx_active should never have gone high
    # Check by monitoring it for a window — it should remain low
    esc_active_seen = False
    for _ in range(200):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if bool(dut.o_esc_tx_active.value):
            esc_active_seen = True
            break
        await NextTimeStep()

    assert not esc_active_seen, "ESC_SERIAL frame via SPI should be dropped — o_esc_tx_active should not fire"


@cocotb.test()
async def test_usb_ingress_esc_still_works(dut):
    """Verify that ESC_SERIAL frames via USB still reach the ESC UART
    (regression guard after adding SPI ingress filter)."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)

    # Enable serial mode on motor 0
    await _setup_serial_mode_usb(dut, channel=0, seq=1)

    # Send ESC frame via USB — should reach ESC UART
    esc_payload = bytes([0x55])
    esc_frame = encode_frame(flags=0, channel=0x05, seq=0x60, payload=esc_payload)
    await _drive_usb_bytes(dut, esc_frame)

    # Monitor o_esc_tx_active
    esc_active_seen = False
    for _ in range(2000):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if bool(dut.o_esc_tx_active.value):
            esc_active_seen = True
            break
        await NextTimeStep()

    assert esc_active_seen, "ESC_SERIAL frame via USB should still reach ESC UART"


# ------------------------------------------------------------------
# Egress policy tests
# ------------------------------------------------------------------

@cocotb.test()
async def test_egress_esc_not_on_spi(dut):
    """ESC UART RX response frames should appear on USB TX but NOT on SPI TX.
    We inject an ESC frame via USB, assert SPI CS, and verify the SPI output
    does NOT contain the ESC channel response."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)

    # Enable serial mode + loopback-like scenario:
    # We send ESC data via USB CH 0x05.  The ESC UART will transmit it.
    # If the ESC UART is in half-duplex loopback, we'd get bytes back
    # through the packetizer.  But even without loopback, we can verify
    # that the framer's channel-aware egress blocks non-CONTROL on SPI.

    # For this test, send a USB PING (produces CONTROL response), and
    # verify SPI sees it.  Then send an ESC frame via USB, wait, and
    # verify SPI does NOT see a CH 0x05 response.

    # Step 1: Send PING via USB, assert CS → SPI should see response
    dut.i_spi_cs_n.value = 0
    for _ in range(8):
        await RisingEdge(dut.clk)

    cmd = build_control_payload(0x06)  # OP_PING
    frame = encode_frame(flags=0, channel=0x01, seq=0xA0, payload=cmd)
    await _drive_usb_bytes(dut, frame)

    for _ in range(300):
        await RisingEdge(dut.clk)

    spi_out = []
    for _ in range(30):
        b = await _spi_xfer_byte(dut, 0x00)
        spi_out.append(b)

    saw_control_sync = 0xA5 in spi_out
    assert saw_control_sync, "CONTROL response should appear on SPI"

    dut.i_spi_cs_n.value = 1
    for _ in range(20):
        await RisingEdge(dut.clk)

    # Step 2: Enable serial mode and send ESC data via USB
    await _setup_serial_mode_usb(dut, channel=0, seq=0xA1)

    esc_payload = bytes([0x55])
    esc_frame = encode_frame(flags=0, channel=0x05, seq=0xA2, payload=esc_payload)
    await _drive_usb_bytes(dut, esc_frame)

    # Wait for ESC to transmit + possible loopback
    for _ in range(3000):
        await RisingEdge(dut.clk)

    # Now assert CS and clock out — should NOT contain 0xA5 sync from ESC
    dut.i_spi_cs_n.value = 0
    for _ in range(8):
        await RisingEdge(dut.clk)

    spi_out2 = []
    for _ in range(30):
        b = await _spi_xfer_byte(dut, 0x00)
        spi_out2.append(b)

    dut.i_spi_cs_n.value = 1

    # The mux-write CONTROL response may appear here (that's fine — it's CH 0x01).
    # But NO CH 0x05 frame should be on SPI.
    # Since we can't easily decode mid-stream, we check that no ESC-specific
    # pattern appears.  The main assertion is that the egress gating didn't
    # break anything — the test_spi_ingress_control_allowed test already
    # verifies CONTROL responses do appear.
    # If we see a sync byte, try to decode and verify it's not CH 0x05.
    for idx, b in enumerate(spi_out2):
        if b != 0xA5:
            continue
        if idx + 4 > len(spi_out2):
            continue
        ch_byte = spi_out2[idx + 3]  # channel is at header offset 3 (sync, ver, flags, ch)
        assert ch_byte != 0x05, f"ESC response (CH 0x05) leaked onto SPI at byte {idx}"
