# FCSP Protocol Specification (FCSP/1)

**FCSP** = **Flight Controller Switch Protocol**

This is the shared host↔controller protocol for both repositories:

- FPGA/offloader implementation: `rt-fc-offloader`
- Python GUI/worker implementation: `python-imgui-esc-configurator`

## Purpose

FCSP replaces MSP for high-rate runtime traffic while preserving MSP-compatible workflows during migration.

- MSP path: feature validation, compatibility, and bring-up
- FCSP path: deterministic runtime transport and lower CPU overhead

## FCSP/1 profile target

- CPU: **SERV 8-bit parallel**
- Clock target: **50 MHz FMAX**
- Transport: SPI byte stream (no packet boundary assumptions)
- Parse model: RTL fast-path + lightweight control-plane firmware

## Frame format

All multi-byte integers are big-endian.

| Field | Size | Description |
|---|---:|---|
| `sync` | 1 | `0xA5` |
| `version` | 1 | Protocol version, currently `1` |
| `flags` | 1 | Bitfield |
| `channel` | 1 | Logical channel |
| `seq` | 2 | Sequence number (wraps) |
| `payload_len` | 2 | Payload byte length |
| `payload` | N | Channel payload |
| `crc16` | 2 | CRC16/XMODEM over `version..payload` |

Total length = `1 + 1 + 1 + 1 + 2 + 2 + payload_len + 2`.

## Flags (FCSP/1)

- `0x01` ACK requested
- `0x02` ACK response
- `0x04` Error indication
- others reserved

## Channel map (FCSP/1)

- `0x01` CONTROL — command/reply control-plane
- `0x02` TELEMETRY — high-rate status stream
- `0x03` FC_LOG — runtime logs/events
- `0x04` DEBUG_TRACE — verbose protocol diagnostics
- `0x05` ESC_SERIAL — passthrough tunnel (MSP/4-way bridge payload)

## 50 MHz implementation requirements

To hit 50 MHz reliably on SERV-8:

1. RTL handles sync detect, length tracking, CRC16, channel routing
2. SERV interrupts only on complete validated frame or FIFO watermark
3. Deep RX/TX FIFOs (target >= 4 KB aggregate)
4. Avoid per-byte ISR handling
5. Host batches small control messages when possible

## Resynchronization rules

Receiver behavior:

1. Search for `0xA5`
2. Parse header and validate `payload_len` cap
3. Wait for full frame bytes
4. Verify CRC16
5. On failure: advance by one byte and continue scan

## Migration policy

- Keep MSP functional during GUI parity validation
- Add FCSP adapter in Python worker without changing GUI workflow
- Move runtime traffic channel-by-channel from MSP to FCSP
- Keep passthrough safety/ownership constraints unchanged

## Versioning

- Family name: `FCSP`
- Version tag: `FCSP/1`
- Future incompatible change: bump version field
