"""End-to-end FCSP → Wishbone → IO test on fcsp_offloader_top.

Verifies the complete data path: USB RX ingress → parser → CRC gate → router →
ctrl RX FIFO → fcsp_wishbone_master → wb_io_bus → response → TX framer → USB TX.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, NextTimeStep, with_timeout

from python_fcsp.fcsp_codec import (
    build_read_block_payload,
    build_control_payload,
    decode_frame,
    encode_frame,
)
from hwlib.registers import EXPECTED_WHO_AM_I, WHO_AM_I


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


async def _collect_usb_tx_bytes(dut, max_bytes: int, max_cycles: int = 2000) -> bytes:
    collected = bytearray()
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if bool(dut.o_usb_tx_valid.value):
            collected.append(int(dut.o_usb_tx_byte.value))
            if len(collected) >= max_bytes:
                await NextTimeStep()
                break
        await NextTimeStep()
    return bytes(collected)


def _try_decode_first_frame(raw: bytes):
    """Scan for the first valid FCSP frame in raw bytes."""
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


@cocotb.test()
async def test_read_block_who_am_i(dut):
    """E2E: READ_BLOCK of WHO_AM_I register returns 0xFC500002."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    # Build READ_BLOCK command: space=0x01, address=WHO_AM_I, length=4
    cmd_payload = build_read_block_payload(space=0x01, address=WHO_AM_I, length=4)
    frame = encode_frame(flags=0, channel=0x01, seq=0x42, payload=cmd_payload)

    # Start collecting response before sending (response comes after processing)
    collector = cocotb.start_soon(_collect_usb_tx_bytes(dut, max_bytes=30, max_cycles=3000))

    await with_timeout(_drive_usb_bytes(dut, frame), 100, "us")

    raw_tx = await with_timeout(collector, 200, "us")
    assert len(raw_tx) > 0, "Expected USB TX response bytes"

    rsp_frame = _try_decode_first_frame(raw_tx)
    assert rsp_frame is not None, f"Could not decode response frame from {raw_tx.hex()}"

    # Response payload: [result_code, len_hi, len_lo, data[3], data[2], data[1], data[0]]
    rsp = rsp_frame.payload
    assert rsp[0] == 0x00, f"Expected RES_OK (0x00), got 0x{rsp[0]:02x}"

    data_len = (rsp[1] << 8) | rsp[2]
    assert data_len == 4, f"Expected read length 4, got {data_len}"

    who_am_i = (rsp[3] << 24) | (rsp[4] << 16) | (rsp[5] << 8) | rsp[6]
    assert who_am_i == EXPECTED_WHO_AM_I, f"WHO_AM_I expected 0x{EXPECTED_WHO_AM_I:08x}, got 0x{who_am_i:08x}"


@cocotb.test()
async def test_ping_response(dut):
    """E2E: PING command returns a single-byte RES_OK (0x00) result."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    cmd_payload = build_control_payload(0x06)  # OP_PING, no extra data
    frame = encode_frame(flags=0, channel=0x01, seq=0x01, payload=cmd_payload)

    collector = cocotb.start_soon(_collect_usb_tx_bytes(dut, max_bytes=20, max_cycles=3000))
    await with_timeout(_drive_usb_bytes(dut, frame), 100, "us")
    raw_tx = await with_timeout(collector, 200, "us")

    rsp_frame = _try_decode_first_frame(raw_tx)
    assert rsp_frame is not None, f"Could not decode PING response from {raw_tx.hex()}"
    assert rsp_frame.channel == 0x01, f"Expected CONTROL channel (0x01), got 0x{rsp_frame.channel:02x}"
    assert rsp_frame.payload[0] == 0x00, f"Expected RES_OK, got 0x{rsp_frame.payload[0]:02x}"


@cocotb.test()
async def test_hello_response(dut):
    """E2E: HELLO command (0x13) returns RES_OK."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    cmd_payload = build_control_payload(0x13)  # OP_HELLO
    frame = encode_frame(flags=0, channel=0x01, seq=0x02, payload=cmd_payload)

    collector = cocotb.start_soon(_collect_usb_tx_bytes(dut, max_bytes=20, max_cycles=3000))
    await with_timeout(_drive_usb_bytes(dut, frame), 100, "us")
    raw_tx = await with_timeout(collector, 200, "us")

    rsp_frame = _try_decode_first_frame(raw_tx)
    assert rsp_frame is not None, f"Could not decode HELLO response from {raw_tx.hex()}"
    assert rsp_frame.payload[0] == 0x00, f"Expected RES_OK, got 0x{rsp_frame.payload[0]:02x}"


@cocotb.test()
async def test_two_sequential_reads(dut):
    """E2E: Two back-to-back READ_BLOCK commands should both get responses."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    RESP_LEN = 17

    cmd1 = build_read_block_payload(space=0x01, address=WHO_AM_I, length=4)
    frame1 = encode_frame(flags=0, channel=0x01, seq=0x10, payload=cmd1)
    collector1 = cocotb.start_soon(_collect_usb_tx_bytes(dut, max_bytes=RESP_LEN, max_cycles=3000))
    await with_timeout(_drive_usb_bytes(dut, frame1), 100, "us")
    raw1 = await with_timeout(collector1, 200, "us")
    rsp1 = _try_decode_first_frame(raw1)
    assert rsp1 is not None, f"First read: no response in {raw1.hex()}"

    cmd2 = build_read_block_payload(space=0x01, address=WHO_AM_I, length=4)
    frame2 = encode_frame(flags=0, channel=0x01, seq=0x11, payload=cmd2)
    collector2 = cocotb.start_soon(_collect_usb_tx_bytes(dut, max_bytes=RESP_LEN, max_cycles=3000))
    await with_timeout(_drive_usb_bytes(dut, frame2), 100, "us")
    raw2 = await with_timeout(collector2, 200, "us")
    rsp2 = _try_decode_first_frame(raw2)
    assert rsp2 is not None, f"Second read: no response in {raw2.hex()}"


@cocotb.test()
async def test_get_caps_e2e(dut):
    """E2E: GET_CAPS (0x12) returns RES_OK through the full frame path."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    cmd_payload = build_control_payload(0x12)  # OP_GET_CAPS
    frame = encode_frame(flags=0, channel=0x01, seq=0x20, payload=cmd_payload)

    collector = cocotb.start_soon(_collect_usb_tx_bytes(dut, max_bytes=20, max_cycles=3000))
    await with_timeout(_drive_usb_bytes(dut, frame), 100, "us")
    raw_tx = await with_timeout(collector, 200, "us")

    rsp_frame = _try_decode_first_frame(raw_tx)
    assert rsp_frame is not None, f"Could not decode GET_CAPS response from {raw_tx.hex()}"
    assert rsp_frame.payload[0] == 0x00, f"Expected RES_OK, got 0x{rsp_frame.payload[0]:02x}"


@cocotb.test()
async def test_unknown_opcode_e2e(dut):
    """E2E: Unknown single-byte opcode returns RES_NOT_SUPPORTED (0x04)."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    cmd_payload = build_control_payload(0xFF)  # Unknown opcode
    frame = encode_frame(flags=0, channel=0x01, seq=0x30, payload=cmd_payload)

    collector = cocotb.start_soon(_collect_usb_tx_bytes(dut, max_bytes=20, max_cycles=3000))
    await with_timeout(_drive_usb_bytes(dut, frame), 100, "us")
    raw_tx = await with_timeout(collector, 200, "us")

    rsp_frame = _try_decode_first_frame(raw_tx)
    assert rsp_frame is not None, f"Could not decode response from {raw_tx.hex()}"
    assert rsp_frame.payload[0] == 0x04, \
        f"Expected RES_NOT_SUPPORTED (0x04), got 0x{rsp_frame.payload[0]:02x}"
