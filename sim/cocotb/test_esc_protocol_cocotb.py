"""E2E test: ESC protocol via FCSP CH 0x05 + BLHeli 4-way framing.

Verifies the full BLHeli passthrough protocol:
1. Send BLHeli 4-way interface commands via FCSP CH 0x05
2. Verify UART TX activity for correct byte count
3. Configure ESC UART baud rate via Wishbone
4. Multi-byte command exchange verification
5. Channel switch (motor 0 → motor 1)
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

from esc_traffic_gen import (
    build_blheli_4way_command,
    build_blheli_4way_response,
    decode_blheli_4way_frame,
    CMD_INTERFACE_GET_NAME,
    CMD_PROTOCOL_GET_VERSION,
    CMD_DEVICE_INIT_FLASH,
    CMD_DEVICE_RESET,
    CMD_INTERFACE_EXIT,
)

SIM_CLK_NS = 18.5  # ~54 MHz
MUX_REG = 0x4000_0400
ESC_BAUD_REG = 0x4000_090C
ESC_STATUS_REG = 0x4000_0904


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
    await _drive_usb_bytes(dut, frame)
    return await _collect_usb_tx_bytes(dut, max_bytes=30, max_cycles=6000)


async def _read_reg(dut, address: int, seq: int) -> int:
    payload = build_read_block_payload(space=0x01, address=address, length=4)
    frame = encode_frame(flags=0, channel=0x01, seq=seq, payload=payload)
    await _drive_usb_bytes(dut, frame)
    raw = await _collect_usb_tx_bytes(dut, max_bytes=30, max_cycles=6000)
    rsp = _try_decode_first_frame(raw)
    assert rsp is not None, f"no valid response frame in {raw.hex()}"
    assert rsp.payload[0] == 0x00, f"expected RES_OK, got 0x{rsp.payload[0]:02x}"
    d = rsp.payload[3:7]
    return (d[0] << 24) | (d[1] << 16) | (d[2] << 8) | d[3]


async def _setup_serial_mode(dut, channel: int = 0, seq_start: int = 1):
    """Switch mux to serial mode on given channel and wait for response."""
    val = (channel & 0x03) << 1  # mode=0 (serial), channel in bits [2:1]
    raw = await _write_reg(dut, MUX_REG, val, seq=seq_start)
    rsp = _try_decode_first_frame(raw)
    assert rsp is not None and rsp.payload[0] == 0x00, "failed to set serial mode"


@cocotb.test()
async def test_blheli_4way_get_name_reaches_uart(dut):
    """BLHeli 4-way GET_NAME command via CH 0x05 should fire UART TX for correct byte count."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)

    # Switch to serial mode
    await _setup_serial_mode(dut, channel=0, seq_start=1)

    # Build BLHeli 4-way GET_NAME command and send via CH 0x05
    cmd_frame = build_blheli_4way_command(CMD_INTERFACE_GET_NAME)
    fcsp_frame = encode_frame(
        flags=0, channel=Channel.ESC_SERIAL, seq=20, payload=cmd_frame
    )
    await _drive_usb_bytes(dut, fcsp_frame)

    # Count TX active rising edges — should have one per byte in the BLHeli frame
    expected_bytes = len(cmd_frame)
    tx_rises = 0
    prev_active = False
    for _ in range(expected_bytes * 35000):  # ~35000 clocks per byte at default baud
        await RisingEdge(dut.clk)
        await ReadOnly()
        cur = bool(dut.o_esc_tx_active.value)
        if cur and not prev_active:
            tx_rises += 1
        prev_active = cur
        await NextTimeStep()
        if tx_rises >= expected_bytes:
            break

    assert tx_rises >= expected_bytes, \
        f"Expected {expected_bytes} TX active events, got {tx_rises}"


@cocotb.test()
async def test_blheli_multi_byte_command_integrity(dut):
    """Multi-byte BLHeli command should transmit all bytes via UART TX."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)

    await _setup_serial_mode(dut, channel=0, seq_start=1)

    # INIT_FLASH command with 4 address bytes
    cmd_frame = build_blheli_4way_command(CMD_DEVICE_INIT_FLASH, address=0x1000)
    fcsp_frame = encode_frame(
        flags=0, channel=Channel.ESC_SERIAL, seq=30, payload=cmd_frame
    )
    await _drive_usb_bytes(dut, fcsp_frame)

    # Verify all bytes transmitted (count TX active events)
    expected_bytes = len(cmd_frame)
    tx_rises = 0
    prev_active = False
    for _ in range(expected_bytes * 35000):
        await RisingEdge(dut.clk)
        await ReadOnly()
        cur = bool(dut.o_esc_tx_active.value)
        if cur and not prev_active:
            tx_rises += 1
        prev_active = cur
        await NextTimeStep()
        if tx_rises >= expected_bytes:
            break

    assert tx_rises >= expected_bytes, \
        f"Expected {expected_bytes} TX events for {len(cmd_frame)}-byte frame, got {tx_rises}"


@cocotb.test()
async def test_esc_baud_rate_config(dut):
    """Write a new BAUD_DIV via Wishbone; read back confirms the value."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)

    # Read default baud divider (should be ~2812 for 54MHz/19200)
    default_baud = await _read_reg(dut, ESC_BAUD_REG, seq=1)
    assert 2800 <= default_baud <= 2820, f"unexpected default baud_div: {default_baud}"

    # Write a faster baud for testing (e.g., 100 = 540 kbaud)
    new_baud = 100
    raw = await _write_reg(dut, ESC_BAUD_REG, new_baud, seq=2)
    rsp = _try_decode_first_frame(raw)
    assert rsp is not None and rsp.payload[0] == 0x00, "baud write failed"

    # Read back
    readback = await _read_reg(dut, ESC_BAUD_REG, seq=3)
    assert readback == new_baud, f"expected baud_div={new_baud}, got {readback}"


@cocotb.test()
async def test_esc_channel_switch(dut):
    """Switch ESC mux from motor 0 to motor 1; verify TX still fires on CH 0x05."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)

    # Serial mode, channel 1
    await _setup_serial_mode(dut, channel=1, seq_start=1)

    # Verify mux register shows channel 1
    val = await _read_reg(dut, MUX_REG, seq=5)
    assert (val >> 1) & 0x03 == 1, f"expected channel=1, got {(val >> 1) & 0x03}"

    # Send ESC data on CH 0x05
    cmd_frame = build_blheli_4way_command(CMD_PROTOCOL_GET_VERSION)
    fcsp_frame = encode_frame(
        flags=0, channel=Channel.ESC_SERIAL, seq=40, payload=cmd_frame
    )
    await _drive_usb_bytes(dut, fcsp_frame)

    # Verify TX activity
    saw_tx = False
    for _ in range(5000):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if bool(dut.o_esc_tx_active.value):
            saw_tx = True
            break
        await NextTimeStep()

    assert saw_tx, "UART TX should fire on channel 1"


@cocotb.test()
async def test_blheli_4way_framing_helpers(dut):
    """Verify BLHeli 4-way frame build/decode round-trips correctly."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)

    # Test command frame round-trip
    cmd = build_blheli_4way_command(CMD_INTERFACE_GET_NAME, address=0x0000)
    decoded_cmd, addr, payload, ack = decode_blheli_4way_frame(cmd)
    assert decoded_cmd == CMD_INTERFACE_GET_NAME
    assert addr == 0x0000
    assert ack is None  # command, not response

    # Test response frame round-trip
    resp_data = b"BLHeli_S"
    resp = build_blheli_4way_response(CMD_INTERFACE_GET_NAME, data=resp_data)
    decoded_cmd, addr, payload, ack = decode_blheli_4way_frame(resp)
    assert decoded_cmd == CMD_INTERFACE_GET_NAME
    assert payload == resp_data
    assert ack == 0x00  # ACK_OK

    # Test response with non-zero address
    resp2 = build_blheli_4way_response(CMD_DEVICE_INIT_FLASH, address=0x1000, data=b"\x01\x02")
    decoded_cmd, addr, payload, ack = decode_blheli_4way_frame(resp2)
    assert decoded_cmd == CMD_DEVICE_INIT_FLASH
    assert addr == 0x1000
    assert payload == b"\x01\x02"
    assert ack == 0x00
