"""Cocotb tests for fcsp_stream_packetizer — byte-to-frame aggregator.

Tests: MAX_LEN trigger, TIMEOUT trigger, back-to-back fills,
backpressure during push, and empty-input quiescence.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, NextTimeStep

SIM_CLK_NS = 10  # 100 MHz


async def _reset(dut):
    dut.rst.value = 1
    dut.s_tdata.value = 0
    dut.s_tvalid.value = 0
    dut.m_tready.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def _push_byte(dut, val):
    """Push a single byte via the ingress AXIS port.  Waits for handshake."""
    dut.s_tdata.value = val & 0xFF
    dut.s_tvalid.value = 1
    for _ in range(20):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.s_tready.value):
            await NextTimeStep()
            dut.s_tvalid.value = 0
            return
        await NextTimeStep()
    raise TimeoutError("s_tready never asserted")


async def _push_bytes(dut, data: bytes):
    """Push multiple bytes, one per handshake."""
    for b in data:
        await _push_byte(dut, b)


async def _collect_frame(dut, max_cycles=5000) -> bytes:
    """Collect bytes from the egress AXIS port until tlast."""
    buf = bytearray()
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.m_tvalid.value) and int(dut.m_tready.value):
            buf.append(int(dut.m_tdata.value))
            if int(dut.m_tlast.value):
                await NextTimeStep()
                return bytes(buf)
        await NextTimeStep()
    raise TimeoutError(f"Timeout collecting frame (got {len(buf)} bytes)")


# ── Tests ──────────────────────────────────────────────────────────────


@cocotb.test()
async def test_max_len_trigger(dut):
    """Filling to MAX_LEN should emit a frame of exactly MAX_LEN bytes."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)

    # Default MAX_LEN=16; push exactly 16 bytes
    data = bytes(range(16))

    collector = cocotb.start_soon(_collect_frame(dut))
    await _push_bytes(dut, data)
    frame = await collector

    assert len(frame) == 16, f"Expected 16-byte frame, got {len(frame)}"
    assert frame == data, f"Frame data mismatch: {frame.hex()} vs {data.hex()}"


@cocotb.test()
async def test_timeout_trigger(dut):
    """Partial fill followed by idle should emit after TIMEOUT cycles."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)

    data = bytes([0xAA, 0xBB, 0xCC])
    collector = cocotb.start_soon(_collect_frame(dut, max_cycles=3000))

    await _push_bytes(dut, data)

    # Wait for timeout to fire (default TIMEOUT=1000 cycles + push time)
    frame = await collector

    assert len(frame) == 3, f"Expected 3-byte partial frame, got {len(frame)}"
    assert frame == data, f"Frame data mismatch: {frame.hex()} vs {data.hex()}"


@cocotb.test()
async def test_back_to_back_full_frames(dut):
    """Two consecutive full frames should emit correctly without data loss."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)

    frame1_data = bytes([0x10 + i for i in range(16)])
    frame2_data = bytes([0x20 + i for i in range(16)])

    # Collect first frame
    collector1 = cocotb.start_soon(_collect_frame(dut))
    await _push_bytes(dut, frame1_data)
    f1 = await collector1

    assert f1 == frame1_data, f"Frame1 mismatch: {f1.hex()}"

    # Collect second frame
    collector2 = cocotb.start_soon(_collect_frame(dut))
    await _push_bytes(dut, frame2_data)
    f2 = await collector2

    assert f2 == frame2_data, f"Frame2 mismatch: {f2.hex()}"


@cocotb.test()
async def test_backpressure_during_push(dut):
    """Toggling m_tready during push phase should stall output without data loss."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)

    # Push 3 bytes, then deassert m_tready BEFORE timeout fires so when
    # S_PUSH begins, the first byte is held and output stalls.
    data = bytes([0xDE, 0xAD, 0xBE])
    dut.m_tready.value = 1
    await _push_bytes(dut, data)

    dut.m_tready.value = 0

    # Wait for timeout to trigger S_PUSH (TIMEOUT=1000 cycles + margin)
    for _ in range(1020):
        await RisingEdge(dut.clk)

    # The packetizer is now in S_PUSH with byte0 stalled on m_tdata.
    # The RTL's always_ff consumes and advances in the same edge, so
    # after ReadOnly we'd see the NEXT byte.  Capture the stalled byte
    # before we assert m_tready.
    buf = bytearray()
    await ReadOnly()
    assert int(dut.m_tvalid.value) == 1, "Expected m_tvalid=1 after timeout"
    buf.append(int(dut.m_tdata.value))
    await NextTimeStep()

    # Now toggle m_tready to collect remaining bytes with backpressure
    for cycle in range(500):
        dut.m_tready.value = 1 if (cycle % 3 == 0) else 0
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.m_tvalid.value) and int(dut.m_tready.value):
            buf.append(int(dut.m_tdata.value))
            if int(dut.m_tlast.value):
                await NextTimeStep()
                break
        await NextTimeStep()

    dut.m_tready.value = 1
    frame = bytes(buf)
    assert len(frame) == 3, f"Expected 3-byte frame, got {len(frame)}"
    assert frame == data, f"Frame with backpressure mismatch: {frame.hex()} vs {data.hex()}"


@cocotb.test()
async def test_no_output_when_idle(dut):
    """With no input bytes, m_tvalid should never assert."""
    cocotb.start_soon(Clock(dut.clk, SIM_CLK_NS, unit="ns").start())
    await _reset(dut)

    saw_valid = False
    for _ in range(200):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.m_tvalid.value):
            saw_valid = True
            break
        await NextTimeStep()

    assert not saw_valid, "m_tvalid should not assert with no input"
