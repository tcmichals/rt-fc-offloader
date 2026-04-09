"""Reusable ESC simulator for cocotb-based BLHeli passthrough testing.

Provides helpers to:
- Drive serial bytes into a motor pad (simulating ESC responses)
- Capture UART TX bytes from a motor pad (verifying host→ESC data)
- Validate BLHeli 4-way interface framing
- Support configurable baud rate via clock divider
- Support programmable response delay
"""

import cocotb
from cocotb.triggers import RisingEdge, ReadOnly, NextTimeStep, Timer


async def drive_uart_byte(signal, byte_val: int, baud_div: int):
    """Bit-bang one UART byte onto *signal* (start + 8 data LSB-first + stop).

    Each bit is held for *baud_div* rising clock edges on the
    signal's associated clock (assumes ``dut.clk``).
    """
    clk = signal._entity.clk

    # Start bit (low)
    signal.value = 0
    for _ in range(baud_div):
        await RisingEdge(clk)

    # 8 data bits, LSB first
    for bit in range(8):
        signal.value = (byte_val >> bit) & 1
        for _ in range(baud_div):
            await RisingEdge(clk)

    # Stop bit (high)
    signal.value = 1
    for _ in range(baud_div):
        await RisingEdge(clk)


async def drive_uart_bytes(signal, data: bytes, baud_div: int, inter_byte_gap: int = 0):
    """Bit-bang a sequence of UART bytes onto *signal*.

    *inter_byte_gap* is additional idle clocks between bytes (0 = back-to-back).
    """
    clk = signal._entity.clk
    for b in data:
        await drive_uart_byte(signal, b, baud_div)
        for _ in range(inter_byte_gap):
            await RisingEdge(clk)


async def capture_uart_byte(signal, baud_div: int, timeout_cycles: int = 50000) -> int | None:
    """Wait for a start bit on *signal*, then sample 8 data bits + stop.

    Returns the received byte, or ``None`` if no start bit within *timeout_cycles*.
    """
    clk = signal._entity.clk

    # Wait for start bit (falling edge → low)
    for _ in range(timeout_cycles):
        await RisingEdge(clk)
        await ReadOnly()
        if int(signal.value) == 0:
            break
        await NextTimeStep()
    else:
        return None

    await NextTimeStep()

    # Advance to center of first data bit (half a bit period from start-bit leading edge)
    for _ in range(baud_div // 2):
        await RisingEdge(clk)

    # Already at ~center of start bit; advance one full bit to center of bit 0
    for _ in range(baud_div):
        await RisingEdge(clk)

    byte_val = 0
    for bit in range(8):
        await ReadOnly()
        byte_val |= (int(signal.value) & 1) << bit
        await NextTimeStep()
        if bit < 7:
            for _ in range(baud_div):
                await RisingEdge(clk)

    # Advance through stop bit
    for _ in range(baud_div):
        await RisingEdge(clk)

    return byte_val


async def capture_uart_bytes(signal, count: int, baud_div: int,
                             timeout_cycles: int = 50000) -> bytes:
    """Capture *count* UART bytes from *signal*.

    Returns collected bytes (may be shorter than *count* on timeout).
    """
    result = bytearray()
    for _ in range(count):
        b = await capture_uart_byte(signal, baud_div, timeout_cycles)
        if b is None:
            break
        result.append(b)
    return bytes(result)


# ---------------------------------------------------------------------------
# BLHeli 4-way interface helpers
# ---------------------------------------------------------------------------

# BLHeli 4-way interface command bytes
CMD_INTERFACE_GET_NAME    = 0x31  # 4-way interface: get protocol name
CMD_PROTOCOL_GET_VERSION  = 0x30  # 4-way interface: get version
CMD_DEVICE_INIT_FLASH     = 0x37  # init flash access
CMD_DEVICE_READ_FLASH     = 0x3A  # read flash
CMD_DEVICE_WRITE_FLASH    = 0x3B  # write flash
CMD_DEVICE_ERASE_FLASH    = 0x38  # erase flash
CMD_DEVICE_RESET          = 0x35  # reset ESC device
CMD_INTERFACE_EXIT        = 0x34  # exit 4-way interface

# BLHeli 4-way ACK codes
ACK_OK = 0x00


def build_blheli_4way_command(cmd: int, address: int = 0, params: bytes = b"") -> bytes:
    """Build a BLHeli 4-way interface command frame.

    Format: [0x2F (escape)] [cmd] [addr_hi] [addr_lo] [len] [params...] [crc_hi] [crc_lo]

    *len* = 0 means 256 bytes when params is 256 bytes; otherwise len = len(params).
    """
    addr_hi = (address >> 8) & 0xFF
    addr_lo = address & 0xFF
    param_len = len(params) & 0xFF  # 0 means 256

    body = bytes([0x2F, cmd, addr_hi, addr_lo, param_len]) + params
    crc = _crc16_xmodem(body)
    return body + bytes([(crc >> 8) & 0xFF, crc & 0xFF])


def build_blheli_4way_response(cmd: int, address: int = 0,
                               data: bytes = b"", ack: int = ACK_OK) -> bytes:
    """Build a BLHeli 4-way interface response frame (ESC → host).

    Format: [0x2F] [cmd] [addr_hi] [addr_lo] [len] [data...] [ack] [crc_hi] [crc_lo]
    """
    addr_hi = (address >> 8) & 0xFF
    addr_lo = address & 0xFF
    data_len = len(data) & 0xFF

    body = bytes([0x2F, cmd, addr_hi, addr_lo, data_len]) + data + bytes([ack])
    crc = _crc16_xmodem(body)
    return body + bytes([(crc >> 8) & 0xFF, crc & 0xFF])


def decode_blheli_4way_frame(raw: bytes):
    """Decode a BLHeli 4-way frame and return (cmd, address, payload, ack_or_none).

    For commands (host→ESC) ack_or_none is None.
    For responses (ESC→host) ack_or_none is the ACK byte.
    Raises ValueError on CRC mismatch or bad framing.
    """
    if len(raw) < 7:
        raise ValueError(f"frame too short ({len(raw)} bytes)")
    if raw[0] != 0x2F:
        raise ValueError(f"bad escape byte 0x{raw[0]:02X}")

    cmd = raw[1]
    address = (raw[2] << 8) | raw[3]
    data_len = raw[4] if raw[4] != 0 else 256

    # Check CRC on everything except the last 2 bytes
    body = raw[:-2]
    expected_crc = (raw[-2] << 8) | raw[-1]
    actual_crc = _crc16_xmodem(body)
    if expected_crc != actual_crc:
        raise ValueError(f"CRC mismatch: expected 0x{expected_crc:04X}, got 0x{actual_crc:04X}")

    # Determine if this is a command (no ack) or response (has ack after data)
    # Commands: 5 header + data_len + 2 CRC = 7 + data_len
    # Responses: 5 header + data_len + 1 ack + 2 CRC = 8 + data_len
    if len(raw) == 7 + data_len:
        # Command frame
        payload = raw[5:5 + data_len]
        return cmd, address, payload, None
    elif len(raw) == 8 + data_len:
        # Response frame
        payload = raw[5:5 + data_len]
        ack = raw[5 + data_len]
        return cmd, address, payload, ack
    else:
        # Ambiguous — try response interpretation
        payload = raw[5:5 + data_len]
        ack = raw[5 + data_len] if 5 + data_len < len(raw) - 2 else None
        return cmd, address, payload, ack


def _crc16_xmodem(data: bytes) -> int:
    """CRC-16/XMODEM (poly 0x1021, init 0)."""
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            if crc & 0x8000:
                crc = (crc << 1) ^ 0x1021
            else:
                crc <<= 1
            crc &= 0xFFFF
    return crc


class EscSimulator:
    """Cocotb-based ESC simulator that responds to BLHeli 4-way commands.

    Drives responses back onto a motor pad signal after receiving commands
    via UART. Configurable baud rate and response delay.

    Usage::

        esc = EscSimulator(dut.pad_motor_0, baud_div=2812)
        cocotb.start_soon(esc.run())
        # ... send commands via FCSP CH 0x05 ...
        # ESC automatically responds
    """

    def __init__(self, pad_signal, baud_div: int = 2812,
                 response_delay_ns: int = 500,
                 device_name: bytes = b"BLHeli_S"):
        self.pad = pad_signal
        self.baud_div = baud_div
        self.response_delay_ns = response_delay_ns
        self.device_name = device_name
        self.received_commands: list[tuple] = []
        self._running = True

    def stop(self):
        self._running = False

    async def run(self):
        """Main loop: receive commands, send responses."""
        while self._running:
            # Receive a command frame
            raw = await self._receive_frame()
            if raw is None:
                continue

            try:
                cmd, addr, payload, _ = decode_blheli_4way_frame(raw)
            except ValueError:
                continue

            self.received_commands.append((cmd, addr, payload))

            # Generate and send response
            response = self._build_response(cmd, addr, payload)
            if response is not None:
                if self.response_delay_ns > 0:
                    await Timer(self.response_delay_ns, units="ns")
                await drive_uart_bytes(self.pad, response, self.baud_div)

    async def _receive_frame(self) -> bytes | None:
        """Receive a BLHeli 4-way frame from the UART line.

        Waits for escape byte (0x2F), then reads header + payload + CRC.
        """
        # Wait for the escape byte
        first = await capture_uart_byte(self.pad, self.baud_div, timeout_cycles=100000)
        if first is None or first != 0x2F:
            return None

        # Read cmd, addr_hi, addr_lo, len (4 more bytes)
        header_rest = await capture_uart_bytes(self.pad, 4, self.baud_div)
        if len(header_rest) < 4:
            return None

        data_len = header_rest[3] if header_rest[3] != 0 else 256

        # Read payload + 2 CRC bytes
        remaining = await capture_uart_bytes(self.pad, data_len + 2, self.baud_div)
        if len(remaining) < data_len + 2:
            return None

        return bytes([0x2F]) + header_rest + remaining

    def _build_response(self, cmd: int, addr: int, payload: bytes) -> bytes | None:
        """Build a BLHeli 4-way response based on the received command."""
        if cmd == CMD_INTERFACE_GET_NAME:
            return build_blheli_4way_response(cmd, addr, self.device_name)
        elif cmd == CMD_PROTOCOL_GET_VERSION:
            return build_blheli_4way_response(cmd, addr, bytes([0x01, 0x06]))
        elif cmd == CMD_DEVICE_INIT_FLASH:
            return build_blheli_4way_response(cmd, addr, b"")
        elif cmd == CMD_DEVICE_READ_FLASH:
            # Return dummy flash data
            read_len = len(payload) if payload else 16
            return build_blheli_4way_response(cmd, addr, bytes(read_len))
        elif cmd == CMD_DEVICE_RESET:
            return build_blheli_4way_response(cmd, addr, b"")
        elif cmd == CMD_INTERFACE_EXIT:
            return build_blheli_4way_response(cmd, addr, b"")
        else:
            # Unknown command — still ACK
            return build_blheli_4way_response(cmd, addr, b"")
