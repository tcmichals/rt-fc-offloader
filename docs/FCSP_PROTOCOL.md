# FCSP Protocol Specification (FCSP/1)

**FCSP** = **Flight Controller Serial Protocol**

This document defines the FCSP protocol as implemented in the **Pure Hardware** offloader architecture. This protocol is used for all communication between the Host (Linux/PC) and the FPGA (Actuators/Sensors).

## Architecture Profile: Pure Hardware
- **Core**: CPU-less RTL (No Firmware, No SERV).
- **Clock**: 54 MHz.
- **Handling**: All packet parsing, CRC verification, and Wishbone execution are performed in hardware gates.
- **Latency**: Nanosecond-level command execution once the packet is received.

## Frame Format

All multi-byte integers are **Big-Endian** on the wire.

| Field | Size | Description |
|---|---:|---|
| `sync` | 1 | `0xA5` |
| `version` | 1 | Protocol version, currently `1` |
| `flags` | 1 | Bitfield (0x01: ACK Req) |
| `channel` | 1 | Logical channel |
| `seq` | 2 | Sequence number |
| `payload_len` | 2 | Payload byte length (Max 512) |
| `payload` | N | Data bytes |
| `crc16` | 2 | CRC16/XMODEM over `version..payload` |

---

## Channel Map (FCSP/1)

- **`0x01` CONTROL**: Handled by `fcsp_wishbone_master` (Wishbone Slave access).
- **`0x05` ESC_SERIAL**: Handled by `fcsp_io_engines` (Hardware Passthrough Tunnel).

---

## CONTROL Channel (0x01) — Hardware Wishbone Master

The payload for Channel `0x01` starts with an `op_id`. In the Pure Hardware design, the RTL implements these specific operations:

### 1) WRITE_BLOCK (0x11)
Writes a block of data to the internal Wishbone bus.

| Offset | Field | Size | Description |
|---|---|---:|---|
| 0 | `op_id` | 1 | `0x11` |
| 1 | `space` | 1 | Memory space (currently ignore/default) |
| 2-5 | `address` | 4 | 32-bit Wishbone Address (Big-Endian) |
| 6-7 | `len` | 2 | Number of bytes to write (must be multiple of 4) |
| 8.. | `data` | len | 32-bit words to write |

### 2) READ_BLOCK (0x10)
Reads a block of data from the internal Wishbone bus and returns it.

| Offset | Field | Size | Description |
|---|---|---:|---|
| 0 | `op_id` | 1 | `0x10` |
| 1 | `space` | 1 | Memory space |
| 2-5 | `address` | 4 | 32-bit Wishbone Address (Big-Endian) |
| 6-7 | `len` | 2 | Number of bytes to read |

---

## Memory Map (Wishbone Internals)

The RTL maps the following registers for control:

| Address | Register | Description |
|---|---|---|
| `0x00000000` | DShot 0-1 | 16-bit motor counts for 0 and 1 |
| `0x00000004` | DShot 2-3 | 16-bit motor counts for 2 and 3 |
| `0x00000010` | NeoPixel | 24-bit RGB value |
| `0x00000020` | Mode Register | **The Switch** (bit 0: Mode, bit 4: Force Low) |

---

## ESC_SERIAL Channel (0x05) — Physical Pin Tunnel

When the **Mode Register (0x20)** bit 0 is set to `1`, Channel `0x05` becomes a physical bridge.

- **Ingress**: Bytes received on this channel are shifted out of the selected motor pin at a 1:1 bit rate (transparent bridge).
- **Egress**: Feedback from the motor pins is wrapped in FCSP Channel `0x05` frames and returned to the host.
- **Latency**: The only latency is the framing time; the bit-switching itself is purely combinational in RTL.

---

## Resynchronization and Error Handling

The hardware `fcsp_parser` performs the following on every byte:
1. Search for `0xA5`.
2. Verify Version and Header constraints.
3. Accumulate payload and verify CRC16.
4. If CRC fails, the frame is dropped and the parser restarts at the next byte after the original `0xA5`.

This ensures that bit-errors on the SPI or USB link do not result in "stuck" states or invalid motor commands.
