"""E2E test: LED controller via FCSP WRITE_BLOCK / READ_BLOCK.

The wb_led_controller sits outside fcsp_offloader_top — connected via the
LED WB pass-through ports.  This test emulates the controller with a simple
WB slave coroutine and exercises SET / CLEAR / TOGGLE / OUT via FCSP.
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
from hwlib.registers import LED_OUT, LED_TOGGLE, LED_CLEAR, LED_SET

SIM_CLK_NS = 18.5  # ~54 MHz


# ---------------------------------------------------------------------------
# WB slave emulator for the external LED controller
# ---------------------------------------------------------------------------
class _LedSlaveState:
    """Mutable LED register accessible from the test and the coroutine."""
    def __init__(self):
        self.reg = 0


async def _led_wb_responder(dut, state: _LedSlaveState):
    """Registered-ACK WB slave matching wb_led_controller behavior."""
    prev_ack = False
    while True:
        await RisingEdge(dut.clk)
        await ReadOnly()
        cyc = bool(dut.led_cyc_o.value)
        stb = bool(dut.led_stb_o.value)
        we  = bool(dut.led_we_o.value)
        adr = int(dut.led_adr_o.value)
        wdata = int(dut.led_dat_o.value)
        await NextTimeStep()

        if cyc and stb and not prev_ack:
            addr_bits = (adr >> 2) & 0x3
            if we:
                wd = wdata & 0xF
                if addr_bits == 0:
                    state.reg = wd
                elif addr_bits == 1:
                    state.reg ^= wd
                elif addr_bits == 2:
                    state.reg &= ~wd & 0xF
                elif addr_bits == 3:
                    state.reg |= wd
            dut.led_dat_i.value = state.reg
            dut.led_ack_i.value = 1
            prev_ack = True
        else:
            dut.led_ack_i.value = 0
            prev_ack = False


# ---------------------------------------------------------------------------
# Common helpers (same pattern as test_e2e_fcsp_wb_io_cocotb)
# ---------------------------------------------------------------------------
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


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_led_set_and_readback(dut):
    """WRITE_BLOCK LED_SET should set bits; READ_BLOCK returns updated register."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)
    led = _LedSlaveState()
    cocotb.start_soon(_led_wb_responder(dut, led))

    raw = await _write_reg(dut, LED_SET, 0x00000005, seq=1)
    rsp = _try_decode_first_frame(raw)
    assert rsp is not None, f"no WRITE_BLOCK response in {raw.hex()}"
    assert rsp.payload[0] == 0x00, "expected RES_OK"

    val = await _read_reg(dut, LED_OUT, seq=2)
    assert val & 0xF == 0x5, f"expected LED reg 0x5, got 0x{val:08x}"
    assert led.reg == 0x5


@cocotb.test()
async def test_led_clear_bits(dut):
    """LED_SET then LED_CLEAR removes targeted bits."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)
    led = _LedSlaveState()
    cocotb.start_soon(_led_wb_responder(dut, led))

    await _write_reg(dut, LED_SET, 0x0000000F, seq=10)
    await _write_reg(dut, LED_CLEAR, 0x0000000A, seq=11)

    val = await _read_reg(dut, LED_OUT, seq=12)
    assert val & 0xF == 0x5, f"expected 0x5 after clear, got 0x{val:08x}"


@cocotb.test()
async def test_led_toggle(dut):
    """LED_TOGGLE XORs the register."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)
    led = _LedSlaveState()
    cocotb.start_soon(_led_wb_responder(dut, led))

    await _write_reg(dut, LED_OUT, 0x00000003, seq=20)  # direct write
    await _write_reg(dut, LED_TOGGLE, 0x00000006, seq=21)  # XOR → 0x5

    val = await _read_reg(dut, LED_OUT, seq=22)
    assert val & 0xF == 0x5, f"expected 0x5 after toggle, got 0x{val:08x}"


@cocotb.test()
async def test_led_walk_pattern(dut):
    """Walk a single bit across all 4 LED positions."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)
    led = _LedSlaveState()
    cocotb.start_soon(_led_wb_responder(dut, led))

    for bit in range(4):
        expected = 1 << bit
        await _write_reg(dut, LED_OUT, expected, seq=30 + bit * 2)
        val = await _read_reg(dut, LED_OUT, seq=31 + bit * 2)
        assert val & 0xF == expected, (
            f"bit {bit}: expected 0x{expected:x}, got 0x{val & 0xF:x}"
        )
