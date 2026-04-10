"""Cocotb tests for fcsp_wishbone_master.

The DUT receives raw FCSP CONTROL payload byte-streams (fcsp_router output)
and drives a Wishbone master interface.  It also emits a response payload
stream back toward the TX framer.

Payload format fed to s_cmd_*:
  READ_BLOCK:   [OP=0x10][SPACE=0x01][ADDR 4B big-endian][LEN 2B big-endian]
  WRITE_BLOCK:  [OP=0x11][SPACE=0x01][ADDR 4B big-endian][LEN 2B big-endian][DATA...]
  GET_CAPS:     [OP=0x12]  (tlast on first byte)
  HELLO:        [OP=0x13]  (tlast on first byte)
  other:        [OP=??]    (no/unknown body) -> RES_NOT_SUPPORTED

Response payload from m_rsp_*:
  READ success:  [RES_OK=0x00][0x00][0x04][data 4B big-endian]
  WRITE success: [RES_OK=0x00][LEN_H][LEN_L]
  GET_CAPS/HELLO:[RES_OK=0x00]
  Unsupported:   [RES_NOT_SUPPORTED=0x04]

Design note on s_cmd_tlast:
  The DUT latches s_cmd_tlast when the last header/data byte is actually
  consumed (cmd_was_last register) so subsequent WB operations can use it
  after the source has de-asserted the stream.
"""

import struct
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, NextTimeStep, with_timeout

from hwlib.registers import EXPECTED_WHO_AM_I, WHO_AM_I, LED_OUT, LED_SET

_OP_READ_BLOCK  = 0x10
_OP_WRITE_BLOCK = 0x11
_OP_GET_CAPS    = 0x12
_OP_HELLO       = 0x13

_RES_OK            = 0x00
_RES_NOT_SUPPORTED = 0x04

_SPACE_FC_REG = 0x01


async def _reset(dut):
    dut.rst.value = 1
    dut.s_cmd_tvalid.value = 0
    dut.s_cmd_tdata.value  = 0
    dut.s_cmd_tlast.value  = 0
    dut.m_rsp_tready.value = 1
    dut.m_dbg_tready.value = 1
    dut.wb_ack_i.value     = 0
    dut.wb_dat_i.value     = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def _drive_cmd_payload(dut, payload: bytes):
    """Drive payload bytes hand-shake on s_cmd_*, tlast on last byte."""
    for i, byte in enumerate(payload):
        dut.s_cmd_tvalid.value = 1
        dut.s_cmd_tdata.value  = byte
        dut.s_cmd_tlast.value  = int(i == len(payload) - 1)
        accepted = False
        while not accepted:
            await ReadOnly()
            accepted = bool(dut.s_cmd_tready.value)
            await RisingEdge(dut.clk)
            await NextTimeStep()
    dut.s_cmd_tvalid.value = 0
    dut.s_cmd_tlast.value  = 0


async def _collect_rsp_payload(dut, timeout_cycles=500):
    """Collect m_rsp bytes until tlast. Started concurrently with the driver."""
    collected = bytearray()
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if bool(dut.m_rsp_tvalid.value) and bool(dut.m_rsp_tready.value):
            collected.append(int(dut.m_rsp_tdata.value))
            if bool(dut.m_rsp_tlast.value):
                await NextTimeStep()
                return bytes(collected)
        await NextTimeStep()
    raise AssertionError(
        f"Response not complete within {timeout_cycles} cycles; "
        f"collected={collected!r}"
    )


def _read_block_payload(addr, length, space=_SPACE_FC_REG):
    return bytes([_OP_READ_BLOCK, space]) + struct.pack(">I", addr) + struct.pack(">H", length)


def _write_block_payload(addr, data, space=_SPACE_FC_REG):
    return (bytes([_OP_WRITE_BLOCK, space])
            + struct.pack(">I", addr)
            + struct.pack(">H", len(data))
            + data)


# ---------------------------------------------------------------------------
# Stateless ops
# ---------------------------------------------------------------------------

@cocotb.test()
async def get_caps_returns_ok(dut):
    """GET_CAPS single-byte command returns RES_OK."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    collector = cocotb.start_soon(_collect_rsp_payload(dut))
    await _drive_cmd_payload(dut, bytes([_OP_GET_CAPS]))
    rsp = await with_timeout(collector, 10_000, "ns")
    assert rsp[0] == _RES_OK, f"Expected RES_OK, got 0x{rsp[0]:02X}"


@cocotb.test()
async def hello_returns_ok(dut):
    """HELLO single-byte command returns RES_OK."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    collector = cocotb.start_soon(_collect_rsp_payload(dut))
    await _drive_cmd_payload(dut, bytes([_OP_HELLO]))
    rsp = await with_timeout(collector, 10_000, "ns")
    assert rsp[0] == _RES_OK, f"Expected RES_OK, got 0x{rsp[0]:02X}"


@cocotb.test()
async def unknown_op_returns_not_supported(dut):
    """An unrecognised single-byte opcode must return RES_NOT_SUPPORTED."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    collector = cocotb.start_soon(_collect_rsp_payload(dut))
    await _drive_cmd_payload(dut, bytes([0xFF]))
    rsp = await with_timeout(collector, 10_000, "ns")
    assert rsp[0] == _RES_NOT_SUPPORTED, f"Expected RES_NOT_SUPPORTED, got 0x{rsp[0]:02X}"


# ---------------------------------------------------------------------------
# READ_BLOCK
# ---------------------------------------------------------------------------

@cocotb.test()
async def read_block_issues_wb_read_cycle(dut):
    """READ_BLOCK must assert wb_cyc_o/wb_stb_o/~wb_we_o with correct address."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    target_addr = WHO_AM_I

    cocotb.start_soon(_drive_cmd_payload(dut, _read_block_payload(target_addr, 4)))

    for _ in range(200):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if (bool(dut.wb_cyc_o.value) and bool(dut.wb_stb_o.value)
                and not bool(dut.wb_we_o.value)):
            assert int(dut.wb_adr_o.value) == target_addr, \
                f"WB addr: expected 0x{target_addr:08X}, got 0x{int(dut.wb_adr_o.value):08X}"
            await NextTimeStep()
            return
        await NextTimeStep()
    raise AssertionError("WB read cycle never observed")


@cocotb.test()
async def read_block_returns_wb_data(dut):
    """READ_BLOCK response payload contains the value returned on wb_dat_i."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    target_addr    = WHO_AM_I
    expected_value = EXPECTED_WHO_AM_I

    async def _wb_responder():
        for _ in range(400):
            await RisingEdge(dut.clk)
            await ReadOnly()
            if (bool(dut.wb_cyc_o.value) and bool(dut.wb_stb_o.value)
                    and not bool(dut.wb_we_o.value)):
                await NextTimeStep()
                dut.wb_dat_i.value = expected_value
                dut.wb_ack_i.value = 1
                await RisingEdge(dut.clk)
                await NextTimeStep()
                dut.wb_ack_i.value = 0
                dut.wb_dat_i.value = 0
                return
            await NextTimeStep()

    cocotb.start_soon(_wb_responder())
    collector = cocotb.start_soon(_collect_rsp_payload(dut))
    await _drive_cmd_payload(dut, _read_block_payload(target_addr, 4))
    rsp = await with_timeout(collector, 20_000, "ns")

    assert len(rsp) >= 7, f"Response too short: {rsp!r}"
    assert rsp[0] == _RES_OK, f"Expected RES_OK, got 0x{rsp[0]:02X}"
    got = struct.unpack(">I", rsp[3:7])[0]
    assert got == expected_value, \
        f"Expected 0x{expected_value:08X}, got 0x{got:08X}"


@cocotb.test()
async def read_block_who_am_i_full_roundtrip(dut):
    """Full roundtrip: READ_BLOCK @ WHO_AM_I, WB returns 0xFC500002."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    target_addr = WHO_AM_I
    expected_id = EXPECTED_WHO_AM_I

    async def _wb_responder():
        for _ in range(400):
            await RisingEdge(dut.clk)
            await ReadOnly()
            if (bool(dut.wb_cyc_o.value) and bool(dut.wb_stb_o.value)
                    and not bool(dut.wb_we_o.value)):
                assert int(dut.wb_adr_o.value) == target_addr, \
                    f"Address: 0x{int(dut.wb_adr_o.value):08X}"
                await NextTimeStep()
                dut.wb_dat_i.value = expected_id
                dut.wb_ack_i.value = 1
                await RisingEdge(dut.clk)
                await NextTimeStep()
                dut.wb_ack_i.value = 0
                dut.wb_dat_i.value = 0
                return
            await NextTimeStep()

    cocotb.start_soon(_wb_responder())
    collector = cocotb.start_soon(_collect_rsp_payload(dut))
    await _drive_cmd_payload(dut, _read_block_payload(target_addr, 4))
    rsp = await with_timeout(collector, 20_000, "ns")

    assert rsp[0] == _RES_OK
    got = struct.unpack(">I", rsp[3:7])[0]
    assert got == expected_id, f"WHO_AM_I: expected 0x{expected_id:08X}, got 0x{got:08X}"


# ---------------------------------------------------------------------------
# WRITE_BLOCK
# ---------------------------------------------------------------------------

@cocotb.test()
async def write_block_issues_wb_write_cycle(dut):
    """WRITE_BLOCK must assert wb_we_o with the correct address and data."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    target_addr = LED_SET
    write_val   = 0x00000005
    payload = _write_block_payload(target_addr, struct.pack(">I", write_val))

    async def _wb_acker():
        for _ in range(400):
            await RisingEdge(dut.clk)
            await ReadOnly()
            if (bool(dut.wb_cyc_o.value) and bool(dut.wb_stb_o.value)
                    and bool(dut.wb_we_o.value)):
                assert int(dut.wb_adr_o.value) == target_addr, \
                    f"Write addr: 0x{int(dut.wb_adr_o.value):08X}"
                assert int(dut.wb_dat_o.value) == write_val, \
                    f"Write data: 0x{int(dut.wb_dat_o.value):08X}"
                await NextTimeStep()
                dut.wb_ack_i.value = 1
                await RisingEdge(dut.clk)
                await NextTimeStep()
                dut.wb_ack_i.value = 0
                return
            await NextTimeStep()

    cocotb.start_soon(_wb_acker())
    collector = cocotb.start_soon(_collect_rsp_payload(dut))
    await _drive_cmd_payload(dut, payload)
    rsp = await with_timeout(collector, 20_000, "ns")

    assert rsp[0] == _RES_OK, f"Expected RES_OK, got 0x{rsp[0]:02X}"


@cocotb.test()
async def sequential_read_write_read(dut):
    """Write a value, then read it back via a minimal WB slave model."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)

    addr   = LED_OUT
    stored = [0x00000000]

    async def _wb_slave():
        for _ in range(1000):
            await RisingEdge(dut.clk)
            await ReadOnly()
            if bool(dut.wb_cyc_o.value) and bool(dut.wb_stb_o.value):
                if bool(dut.wb_we_o.value):
                    stored[0] = int(dut.wb_dat_o.value)
                await NextTimeStep()
                dut.wb_dat_i.value = stored[0]
                dut.wb_ack_i.value = 1
                await RisingEdge(dut.clk)
                await NextTimeStep()
                dut.wb_ack_i.value = 0
                dut.wb_dat_i.value = 0
            else:
                await NextTimeStep()

    cocotb.start_soon(_wb_slave())

    # --- Write 0xA ---
    wr_collector = cocotb.start_soon(_collect_rsp_payload(dut))
    await _drive_cmd_payload(dut, _write_block_payload(addr, struct.pack(">I", 0x0000000A)))
    wr_rsp = await with_timeout(wr_collector, 20_000, "ns")
    assert wr_rsp[0] == _RES_OK, f"Write response: expected RES_OK got 0x{wr_rsp[0]:02X}"

    # --- Read back ---
    rd_collector = cocotb.start_soon(_collect_rsp_payload(dut))
    await _drive_cmd_payload(dut, _read_block_payload(addr, 4))
    rd_rsp = await with_timeout(rd_collector, 20_000, "ns")
    assert rd_rsp[0] == _RES_OK, f"Read response: expected RES_OK got 0x{rd_rsp[0]:02X}"
    got = struct.unpack(">I", rd_rsp[3:7])[0]
    assert got == 0x0000000A, f"Read-after-write: expected 0x0000000A, got 0x{got:08X}"
